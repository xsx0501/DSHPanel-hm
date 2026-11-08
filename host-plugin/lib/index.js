/**
 * dsh-panel-bridge — companion host plugin for the HarmonyOS DS-Harness client.
 *
 * Why this exists (see docs/design.md §3.6):
 *   - DSH auth is a one-shot startup token exchanged for a signed Cookie, and the
 *     startup token dies on every `dsh --profile web` restart, so a phone cannot
 *     persist it. This plugin mints revocable long-lived device tokens instead.
 *   - The phone must keep working while the WebView is frozen, so it needs a
 *     plain HTTP channel (SSE + POST) that does not depend on the browser.
 *
 * Route split (deliberate):
 *   owner-only (Cookie, via Connection exact routes):
 *     POST /api/panel/pair, GET /api/panel/devices, POST /api/panel/devices/:id/revoke
 *   device-token (own auth, via webServer, because Connection rejects anonymous peers):
 *     GET  /api/panel/bootstrap, GET /api/panel/events,
 *     POST /api/panel/confirm, POST /api/panel/abort
 *
 * SECURITY: the device-token routes are registered on the raw webServer, which
 * bypasses Connection's Host/Origin fence and admission. This file therefore
 * implements its own token check, Host/Origin check, rate limit and no-store
 * headers. Do not add file/terminal endpoints here.
 */
import { EventBus, sseFrame, sseHeaders, sseHeartbeat } from './events.js'
import { ApprovalQueue } from './approvals.js'
import { DeviceStore } from './devices.js'
import { bridgeScript } from './inject.js'
import { homedir } from 'node:os'
import { join } from 'node:path'
import { appendFile } from 'node:fs/promises'

export const name = 'panel-bridge'
// Both services must exist before apply() runs: the exact-route table lives on
// `connection`, and the data routes live on `webServer`. A profile without a
// browser transport (headless/acp) simply leaves this row dormant, which is the
// same behavior as the shipped `public-url` row.
export const inject = ['webServer', 'connection']

/** Test seam: the flatteners are pure and are covered by tools/flatten-test.mjs. */
export const __test = { flattenForType, extractMessageText }

const PANEL_PREFIX = '/api/panel'
const RATE_LIMIT_PER_SECOND = 10
const RATE_LIMIT_LOCK_MS = 60_000
const MAX_FAILED_AUTH = 5

/** Diagnostics snapshot surfaced by the loopback-only /api/panel/diag route. */
const diag = { version: 'v9', eventsSeen: 0, lastEventTypes: [], routes: [], connectionService: null, connectionKeys: [], hasFetchGetter: null, fetchRegisterType: null, sessionEvents: 0 }

/** @param {any} ctx */
export function apply(ctx, config = {}) {
  const home = config.home ?? process.env.DSH_HOME ?? join(homedir(), '.dsh')
  const store = new DeviceStore(home)
  const bus = new EventBus({ capacity: config.eventCapacity ?? 256 })
  const approvals = new ApprovalQueue({ timeoutMs: config.approvalTimeoutMs })
  const limiter = new RateLimiter(RATE_LIMIT_PER_SECOND, MAX_FAILED_AUTH, RATE_LIMIT_LOCK_MS)

  const logger = (level, message) => {
    const sink = ctx.logger?.[level] ?? console[level] ?? console.log
    try {
      sink.call(ctx.logger ?? console, `[panel-bridge] ${message}`)
    } catch {
      /* logging must never break a request */
    }
  }

  // ---- owner-only routes: use Connection's exact route table (inherits auth) ----
  // DSH 0.2.1 exposes `connection.fetch.register(route)`; 0.2.2 renamed it to
  // `connection.registerFetchRoute(owner, route)`. Support both.
  const registerFetchRoute = (connection, route) => {
    if (typeof connection.fetch?.register === 'function') {
      connection.fetch.register(route)
      return true
    }
    if (typeof connection.registerFetchRoute === 'function') {
      connection.registerFetchRoute(ctx, route)
      return true
    }
    return false
  }

  const connectionRoutes = [
    {
      path: `${PANEL_PREFIX}/pair`,
      methods: ['POST'],
      requestBody: 'buffered',
      fetch: async (request) =>
        json(async () => {
          const body = await readJson(request)
          const result = await store.pair({ name: body.deviceName, ua: request.headers.get('user-agent') ?? '' })
          logger('info', `paired device ${result.device.id} (${result.device.name})`)
          return { ok: true, device: result.device, deviceToken: result.token }
        })
    },
    {
      path: `${PANEL_PREFIX}/devices`,
      methods: ['GET'],
      requestBody: 'buffered',
      fetch: async () => json(async () => ({ ok: true, devices: await store.list() }))
    },
    {
      // Revocation stays one exact route: path parameters are not an exact-route
      // feature, so the device id travels in the body.
      path: `${PANEL_PREFIX}/devices/revoke`,
      methods: ['POST'],
      requestBody: 'buffered',
      fetch: async (request) =>
        json(async () => {
          const body = await readJson(request)
          const id = typeof body.deviceId === 'string' ? body.deviceId : ''
          const revoked = await store.revoke(id)
          if (!revoked) return { ok: false, code: 'NOT_FOUND' }
          logger('info', `revoked device ${id}`)
          return { ok: true, deviceId: id }
        })
    }
  ]

  try {
    const connection = ctx.connection
    diag.connectionService = connection === undefined ? 'undefined' : typeof connection
    diag.connectionKeys = connection ? Object.keys(connection).slice(0, 40) : []
    diag.hasFetchGetter = Boolean(connection && connection.fetch)
    diag.fetchRegisterType = typeof (connection?.fetch?.register ?? connection?.registerFetchRoute)
    for (const route of connectionRoutes) {
      try {
        const registered = registerFetchRoute(connection, route)
        diag.routes.push({ path: route.path, registered })
        if (!registered) logger('warn', `no exact-route API on connection; skipped ${route.path}`)
      } catch (error) {
        diag.routes.push({ path: route.path, error: String(error?.message ?? error) })
        logger('warn', `exact route ${route.path} failed: ${error?.message}`)
      }
    }
    logger('info', 'pairing routes registered on connection')
    diag.mapSize = connection?.fetchRoutes?.size ?? null
    diag.mapKeys = connection?.fetchRoutes ? [...connection.fetchRoutes.keys()].slice(0, 20) : []
    diag.hasPairNow = connection?.fetchRoutes?.has(`${PANEL_PREFIX}/pair`) ?? null
    diag.interceptors = connection?.interceptors ? [...connection.interceptors.keys()] : []
  } catch (error) {
    diag.routes.push({ path: '*', error: String(error?.message ?? error) })
    logger('warn', `connection route registration failed: ${error?.message}`)
  }

  // ---- approval responder: the single source of truth for HITL ----
  // The host `approval` service raises `approval/request` as a waterfall in the
  // agent's scope; a root listener sees it because scopes bubble to the root.
  // Only take over when at least one live (paired, unrevoked) device exists,
  // otherwise delegate to the browser UI with next().
  if (config.takeoverApprovals === true) {
    try {
      ctx.on('approval/request', async (request, next) => {
        try {
          const live = (await store.list()).some((item) => item.revokedAt === null)
          if (!live) return next()
          const sessionId =
            request?.agent?.session?.id ?? request?.sessionId ?? request?.agent?.sessionId ?? request?.agent?.id ?? 'unknown'
          const pending = approvals.request({
            sessionId,
            toolName: request?.tool ?? request?.toolName ?? 'unknown',
            riskLevel: request?.riskLevel ?? 'MEDIUM',
            preview: request?.reason ?? request?.displayReason ?? request?.command ?? '',
            signal: request?.signal
          })
          bus.publish(sessionId, 'approval/request', approvals.snapshot(sessionId).slice(-1)[0] ?? { sessionId })
          const outcome = await pending
          bus.publish(sessionId, 'approval/resolved', { approvalId: outcome.approvalId, decision: outcome.decision, by: outcome.by })
          return outcome.decision === 'APPROVE' ? 'allowed-once' : 'rejected'
        } catch (error) {
          diag.approvalError = String(error?.message ?? error)
          return next()
        }
      })
      diag.approvalResponder = true
    } catch (error) {
      diag.approvalResponder = false
      diag.approvalError = String(error?.message ?? error)
      logger('warn', `approval responder not attached: ${error?.message}`)
    }
  }

  // ---- session telemetry: DSH log records -> SSE frames ----
  // Host emits `session/event` as (session, event); `event.type` already uses DSH
  // naming (turn/start, step/start, tool/call, approval/asked, ...). We keep the
  // vocabulary and only add `sessionId` + a sanitized shallow payload.
  try {
    const sessionIdOf = (session) => session?.id ?? session?.sessionId ?? session?.address?.sessionId ?? 'unknown'
    ctx.on('session/created', (session) => {
      diag.sessionEvents += 1
      bus.publish(sessionIdOf(session), 'session/created', { title: safeText(session?.title) })
    })
    ctx.on('session/disposed', (session) => {
      diag.sessionEvents += 1
      bus.publish(sessionIdOf(session), 'session/disposed', {})
    })
    ctx.on('session/event', (session, event) => {
      const type = typeof event?.type === 'string' ? event.type : ''
      if (!PHONE_EVENT_TYPES.has(type)) return
      diag.sessionEvents += 1
      diag.eventsSeen += 1
      if (diag.lastEventTypes.length >= 10) diag.lastEventTypes.shift()
      diag.lastEventTypes.push(type)
      const flat = flattenRecord(type, event)
      bus.publish(sessionIdOf(session), type, flat)
      const sidForProgress = sessionIdOf(session)
      if (sidForProgress) {
        if (typeof flat.turn === 'number' || typeof flat.step === 'number') {
          progressBySession.set(sidForProgress, {
            turn: typeof flat.turn === 'number' ? flat.turn : null,
            step: typeof flat.step === 'number' ? flat.step : null,
            type,
            at: Date.now()
          })
        }
        latestEvent = {
          sessionId: sidForProgress,
          type,
          text: summarizeFlat(flat),
          at: Date.now()
        }
      }
    if (type === 'turn/end' || type === 'assistant/message') {
      // Shape probe: DSH nests these payloads, and the flattened view loses them.
      // Record a bounded raw sample so the mapping can be fixed from facts.
      appendAudit(home, {
        kind: 'raw-shape',
        type,
        data: JSON.stringify(event?.data ?? {}).slice(0, 1600)
      })
    }
    })
  } catch (error) {
    diag.sessionEventsError = String(error?.message ?? error)
    logger('warn', `session telemetry not attached: ${error?.message}`)
  }

  // ---- pairing QR: what the phone scans to receive endpoint + startup token ----
  // Loopback only: the query carries a live startup token, and the operator is
  // the only one who should be able to turn it into an image.
  ctx.webServer.register({
    path: `${PANEL_PREFIX}/qr`,
    exact: true,
    handler: async (req, res) => {
      const remote = String(req.socket?.remoteAddress ?? '')
      if (!['127.0.0.1', '::1', '::ffff:127.0.0.1'].includes(remote)) {
        writeJson(res, 403, { ok: false, code: 'LOOPBACK_ONLY' })
        return
      }
      const url = new URL(req.url ?? '/', 'http://127.0.0.1')
      const endpoint = url.searchParams.get('endpoint') ?? ''
      const token = url.searchParams.get('token') ?? ''
      const format = (url.searchParams.get('format') ?? 'png').toLowerCase()
      const explicit = url.searchParams.get('data') ?? ''
      const data = explicit !== ''
        ? explicit
        : (endpoint !== '' && token !== ''
          ? `dsh://connect?endpoint=${encodeURIComponent(endpoint)}&token=${encodeURIComponent(token)}`
          : '')
      if (data === '') {
        writeJson(res, 400, { ok: false, code: 'MISSING_DATA', hint: 'pass data=… or endpoint=…&token=…' })
        return
      }
      if (format === 'json') {
        writeJson(res, 200, { ok: true, data, length: data.length })
        return
      }
      let mod
      try {
        const imported = await import('qrcode')
        mod = imported?.default ?? imported
      } catch (error) {
        diag.qr = { error: String(error?.message ?? error) }
        writeJson(res, 501, { ok: false, code: 'QR_LIB_UNAVAILABLE', data })
        return
      }
      try {
        if (format === 'svg') {
          const svg = await mod.toString(data, { type: 'svg', margin: 1, width: 512 })
          res.statusCode = 200
          res.setHeader('content-type', 'image/svg+xml; charset=utf-8')
          res.setHeader('cache-control', 'no-store')
          res.end(svg)
          return
        }
        const png = await mod.toBuffer(data, { type: 'png', margin: 1, width: 512 })
        res.statusCode = 200
        res.setHeader('content-type', 'image/png')
        res.setHeader('cache-control', 'no-store')
        res.end(png)
      } catch (error) {
        writeJson(res, 500, { ok: false, code: 'QR_FAILED', message: String(error?.message ?? error) })
      }
    }
  })

  diag.qrRoute = PANEL_PREFIX + '/qr'

  // ---- loopback-only approval-policy switch (used to exercise the HITL path) ----
  // The deployment's default preset is danger-full-access, which never raises an
  // approval; this lets a test flip one throwaway session to `ask` without
  // touching the profile or other sessions. Loopback only.
  ctx.webServer.register({
    path: `${PANEL_PREFIX}/_policy`,
    exact: true,
    handler: async (req, res) => {
      const remote = String(req.socket?.remoteAddress ?? '')
      if (!['127.0.0.1', '::1', '::ffff:127.0.0.1'].includes(remote)) {
        writeJson(res, 403, { ok: false, code: 'LOOPBACK_ONLY' })
        return
      }
      try {
        const body = await readNodeJson(req)
        const sessionId = typeof body.sessionId === 'string' ? body.sessionId : ''
        const policy = body.policy === 'ask' ? 'ask' : body.policy === 'never' ? 'never' : ''
        const preset = typeof body.preset === 'string' ? body.preset : ''
        if (!sessionId || (policy === '' && preset === '')) {
          writeJson(res, 400, { ok: false, code: 'BAD_REQUEST' })
          return
        }
        const controller = ctx.get('sessionController')
        const approval = ctx.get('approval')
        diag.policySwitch = { sessionId, policy, preset, at: Date.now(), steps: [] }
        // Preferred path (pinned against 0.2.1): append the durable knob events on the
        // live session. dsh-user-approval's setApprovalPolicy is literally
        // `session.append('approval/policy', { policy })`; permission presets are
        // `session.append('permission/preset', { preset })`.
        let applied = false
        try {
          const sessions = ctx.get('sessions')
          const live = sessions?.get?.(sessionId)
          diag.policySwitch.steps.push({ via: 'sessions.get', found: Boolean(live), hasAppend: typeof live?.append === 'function' })
          if (live !== undefined && live !== null && typeof live.append === 'function') {
            if (policy !== '') live.append('approval/policy', { policy })
            if (preset !== '') live.append('permission/preset', { preset })
            applied = true
          }
        } catch (error) {
          diag.policySwitch.steps.push({ via: 'sessions.get', error: String(error?.message ?? error) })
        }
        if (!applied) {
          // Fallback: resolve the live agent, then let the service write the knob.
          const agent = await controller.resolveAgent(sessionId)
          diag.policySwitch.steps.push({ via: 'resolveAgent', hasSession: Boolean(agent?.session) })
          if (agent === undefined || agent === null || agent.session === undefined) {
            writeJson(res, 409, { ok: false, code: 'SESSION_NOT_LIVE', detail: diag.policySwitch.steps })
            return
          }
          if (policy !== '') approval.setPolicy(agent, policy)
          if (preset !== '') {
            try {
              agent.session.append('permission/preset', { preset })
            } catch (error) {
              diag.policySwitch.steps.push({ via: 'agent.session.append', error: String(error?.message ?? error) })
            }
          }
          applied = true
        }
        writeJson(res, 200, { ok: applied, sessionId, policy, preset })
      } catch (error) {
        writeJson(res, 500, { ok: false, code: 'POLICY_SWITCH_FAILED', message: String(error?.message ?? error) })
      }
    }
  })

  // ---- first-run pairing from the launch token (no browser cookie needed) ----
  // The phone only ever receives the `?token=` link, so it cannot present DSH's
  // browser cookie. We validate the startup token by asking the loopback /connect
  // endpoint — the same check the browser path performs — and only then mint a
  // device token. Anything that holds the launch token already has owner access.
  ctx.webServer.register({
    path: `${PANEL_PREFIX}/pair-with-token`,
    exact: true,
    handler: async (req, res) => {
      try {
        if (req.method !== 'POST') {
          writeJson(res, 405, { ok: false, code: 'METHOD_NOT_ALLOWED' })
          return
        }
        const remote = String(req.socket?.remoteAddress ?? '')
        if (!limiter.allow(`pair:${remote}`)) {
          writeJson(res, 429, { ok: false, code: 'RATE_LIMITED' })
          return
        }
        const body = await readNodeJson(req)
        const startupToken = typeof body.startupToken === 'string' ? body.startupToken.trim() : ''
        if (startupToken.length < 16 || startupToken.length > 512) {
          writeJson(res, 400, { ok: false, code: 'BAD_TOKEN' })
          return
        }
        const port = ctx.webServer?.port ?? 3080
        let verified = false
        try {
          const probe = await fetch(`http://127.0.0.1:${port}/connect?token=${encodeURIComponent(startupToken)}&interactions=none`, {
            redirect: 'manual'
          })
          verified = probe.status === 302 || probe.status === 303
        } catch (error) {
          diag.pairProbeError = String(error?.message ?? error)
        }
        if (!verified) {
          limiter.penalize(`pair:${remote}`)
          writeJson(res, 401, { ok: false, code: 'INVALID_STARTUP_TOKEN' })
          return
        }
        limiter.reset(`pair:${remote}`)
        const result = await store.pair({ name: body.deviceName, ua: String(req.headers['user-agent'] ?? '') })
        logger('info', `paired device ${result.device.id} via launch token (${result.device.name})`)
        writeJson(res, 200, { ok: true, device: result.device, deviceToken: result.token })
      } catch (error) {
        writeJson(res, 500, { ok: false, code: 'PAIR_FAILED', message: String(error?.message ?? error) })
      }
    }
  })

  // ---- loopback-only approval simulation (exercises the phone's HITL path) ----
  // Real approvals only fire when the deployment routes a tool through the
  // `approval/request` waterfall; native bash under a danger preset never asks.
  // This lets the client's confirm path be verified end to end without faking a
  // tool run: it enqueues a synthetic approval, broadcasts it, and returns the
  // decision the phone sends back.
  ctx.webServer.register({
    path: `${PANEL_PREFIX}/_simulate-approval`,
    exact: true,
    handler: async (req, res) => {
      const remote = String(req.socket?.remoteAddress ?? '')
      if (!['127.0.0.1', '::1', '::ffff:127.0.0.1'].includes(remote)) {
        writeJson(res, 403, { ok: false, code: 'LOOPBACK_ONLY' })
        return
      }
      try {
        const body = await readNodeJson(req)
        const sessionId = typeof body.sessionId === 'string' ? body.sessionId : 'test'
        const toolName = typeof body.toolName === 'string' ? body.toolName : 'bash'
        const preview = typeof body.preview === 'string' ? body.preview : 'rm -rf ./dist'
        const decision = await approvals.request({
          sessionId,
          toolName,
          riskLevel: typeof body.riskLevel === 'string' ? body.riskLevel : 'HIGH',
          preview,
          onPending: (record) => {
            appendAudit(home, { kind: 'approval/request', ...record })
            bus.publish(sessionId, 'approval/request', record)
          },
          onSettled: (record, decided, by) => {
            appendAudit(home, { kind: 'approval/resolved', approvalId: record.approvalId, decision: decided, by, sessionId: record.sessionId })
            bus.publish(sessionId, 'approval/resolved', { approvalId: record.approvalId, decision: decided, by })
          }
        })
        writeJson(res, 200, { ok: true, ...decision })
      } catch (error) {
        writeJson(res, 500, { ok: false, code: 'SIMULATE_FAILED', message: String(error?.message ?? error) })
      }
    }
  })

  // ---- loopback-only diagnostics (no auth; 127.0.0.1 only) ----
  ctx.webServer.register({
    path: `${PANEL_PREFIX}/diag`,
    exact: true,
    handler: async (req, res) => {
      try {
        const remote = String(req.socket?.remoteAddress ?? '')
        if (!['127.0.0.1', '::1', '::ffff:127.0.0.1'].includes(remote)) {
          writeJson(res, 403, { ok: false, code: 'LOOPBACK_ONLY' })
          return
        }
        const payload = JSON.stringify({ ok: true, diag, home, inject })
        res.writeHead(200, {
          'content-type': 'application/json; charset=utf-8',
          'cache-control': 'no-store',
          'content-length': Buffer.byteLength(payload)
        })
        res.end(payload)
      } catch (error) {
        try {
          writeJson(res, 500, { ok: false, code: 'DIAG_FAILED', message: String(error?.message ?? error) })
        } catch {
          try {
            res.end()
          } catch {
            /* socket already gone */
          }
        }
      }
    }
  })

  // ---- device-token routes: raw webServer, own auth ----
  ctx.webServer.register({
    path: `${PANEL_PREFIX}/bootstrap`,
    exact: true,
    handler: async (req, res) => {
      try {
        const device = await authenticate(req, res, store, limiter)
        if (!device) return
        let sessions = []
        try {
          sessions = await collectSessions(ctx, bus, approvals)
        } catch (error) {
          logger('warn', `collectSessions failed: ${error?.message}`)
        }
        writeJson(res, 200, {
          ok: true,
          schemaVersion: '1',
          host: { home, dshVersion: config.dshVersion ?? null },
          capabilities: { confirm: true, abort: true, stream: 'sse', pairing: true, rememberRule: true },
          sessions,
          pendingApprovals: safeSnapshot(approvals)
        })
      } catch (error) {
        logger('warn', `bootstrap failed: ${error?.message}`)
        if (!res.headersSent) writeJson(res, 500, { ok: false, code: 'INTERNAL', message: String(error?.message ?? error) })
        else res.end()
      }
    }
  })

  // Lightweight polling endpoint: background clients cannot rely on SSE staying
  // alive, so they ask for the newest progress instead of re-reading bootstrap.
  ctx.webServer.register({
    path: `${PANEL_PREFIX}/snapshot`,
    exact: true,
    handler: async (req, res) => {
      const device = await authenticate(req, res, store, limiter)
      if (!device) return
      const progress = {}
      for (const [sid, value] of progressBySession) progress[sid] = value
      writeJson(res, 200, {
        ok: true,
        progress,
        latest: latestEvent,
        pendingApprovals: safeSnapshot(approvals),
        seq: bus.seq ?? null
      })
    }
  })

  ctx.webServer.register({
    path: `${PANEL_PREFIX}/events`,
    exact: true,
    handler: async (req, res) => {
      const device = await authenticate(req, res, store, limiter)
      if (!device) return

      const url = new URL(req.url ?? '/', `http://${req.headers.host ?? 'localhost'}`)
      const sessionId = url.searchParams.get('sessionId') ?? undefined
      const sinceSeq = Number(req.headers['last-event-id'] ?? url.searchParams.get('sinceSeq') ?? 0) || 0

      res.writeHead(200, sseHeaders())
      res.write(`retry: 1000\n\n`)

      // Replay the ring buffer first so a reconnect does not lose the gap.
      for (const event of bus.after(sinceSeq, sessionId)) res.write(sseFrame(event))

      const unsubscribe = bus.subscribe((event) => {
        if (sessionId && event.sessionId !== sessionId) return
        res.write(sseFrame(event))
      })

      const heartbeat = setInterval(() => res.write(sseHeartbeat()), 15_000)
      if (typeof heartbeat.unref === 'function') heartbeat.unref()

      const close = () => {
        clearInterval(heartbeat)
        unsubscribe()
      }
      req.on('close', close)
      req.on('error', close)
    }
  })

  ctx.webServer.register({
    path: `${PANEL_PREFIX}/confirm`,
    exact: true,
    handler: async (req, res) => {
      const device = await authenticate(req, res, store, limiter)
      if (!device || req.method !== 'POST') return writeJson(res, 405, { ok: false, code: 'METHOD_NOT_ALLOWED' })
      const body = await readNodeJson(req)
      const approvalId = typeof body.approvalId === 'string' ? body.approvalId : ''
      const decision = body.decision === 'APPROVE' ? 'APPROVE' : 'REJECT'
      const settled = approvals.settle(approvalId, decision, body.rememberRule === true)
      appendAudit(home, { kind: 'approval/confirm', approvalId, decision, settled, deviceId: device.id })
      logger('info', `approval ${approvalId} -> ${decision} by ${device.id} (settled=${settled})`)
      writeJson(res, settled ? 200 : 409, settled ? { ok: true, approvalId } : { ok: false, code: 'ALREADY_RESOLVED' })
    }
  })

  ctx.webServer.register({
    path: `${PANEL_PREFIX}/abort`,
    exact: true,
    handler: async (req, res) => {
      const device = await authenticate(req, res, store, limiter)
      if (!device || req.method !== 'POST') return writeJson(res, 405, { ok: false, code: 'METHOD_NOT_ALLOWED' })
      const body = await readNodeJson(req)
      const result = await requestAbort(ctx, body.sessionId)
      writeJson(res, 200, result)
    }
  })

  // ---- WebView bridge injection (optional; J5 pins the row shape) ----
  // DSH 0.2.1 emits `webserver/index-inject` with the injection table only, and
  // rows are `{ kind, name, value }` / `{ kind: 'script', ... }`. Kept behind a
  // config flag until the exact row kinds are confirmed on the target build.
  if (config.injectBridge === true) {
    try {
      ctx.webServer.on('webserver/index-inject', (table) => {
        if (!Array.isArray(table)) return
        table.push({ kind: 'script', text: bridgeScript() })
      })
    } catch (error) {
      logger('warn', `index-inject hook not attached: ${error?.message}`)
    }
  }

  // ---- approval responder ----
  // INTEGRATION POINT (联调项 J3): the waterfall contract is not wired yet.
  // When pinned, register it here and forward each request into approvals.request()
  // so a phone decision settles the waterfall.
  logger('info', `ready (home=${home}, approvals pending=${approvals.snapshot().length})`)

  ctx.on('dispose', () => approvals.cancelAll('host-shutdown'))
}

/**
 * Session summaries for the phone.
 * INTEGRATION POINT (联调项 J2): the host-side session service name is not pinned
 * yet; every candidate is probed defensively because Cordis service access can
 * throw for an unknown name. Until J2 is closed the phone gets an empty list plus
 * live approval state.
 */
const SESSION_SERVICE_CANDIDATES = ['sessionController', 'sessionList', 'sessions', 'session']

function resolveService(ctx, candidates) {
  for (const name of candidates) {
    try {
      const service = ctx.get?.(name) ?? ctx[name]
      if (service !== undefined && service !== null) return service
    } catch {
      // Unknown service names throw on this Cordis build; try the next candidate.
    }
  }
  return undefined
}

async function collectSessions(ctx, bus, approvals) {
  const service = resolveService(ctx, SESSION_SERVICE_CANDIDATES)
  diag.sessionService = service === undefined ? 'undefined' : (service.constructor?.name ?? 'object')
  if (!service || typeof service.list !== 'function') {
    diag.sessionListError = 'no list()'
    return []
  }
  try {
    let result
    try {
      result = await service.list({})
    } catch (error) {
      diag.sessionListError = `${error?.message ?? error} (retry without args)`
      result = await service.list()
    }
    const items = Array.isArray(result?.items) ? result.items : Array.isArray(result) ? result : []
    diag.sessionCount = items.length
    return items.map((item) => ({
      sessionId: item.sessionId,
      title: item.projections?.values?.title ?? null,
      cwd: item.cwd ?? null,
      running: item.running === true,
      updatedAt: item.updatedAt ?? null,
      sessionStats: item.projections?.values?.sessionStats ?? null,
      contextPressure: item.projections?.values?.contextPressure ?? null,
      pendingApprovals: safeSnapshot(approvals).filter((entry) => entry.sessionId === item.sessionId).length
    }))
  } catch {
    return []
  }
}

/** Append one JSON line to the bridge audit log (best effort, never throws). */
function appendAudit(home, entry) {
  try {
    const dir = join(home, 'panel-bridge')
    const file = join(dir, 'audit.jsonl')
    appendFile(file, `${JSON.stringify({ ts: Date.now(), ...entry })}\n`).catch(() => {})
  } catch {
    // Auditing must never break a decision path.
  }
}

/** Keep a record payload small and JSON-safe for the phone channel. */
function sanitizeRecord(record) {
  const out = {}
  if (!record || typeof record !== 'object') return out
  for (const [key, value] of Object.entries(record)) {
    if (key === 'type') continue
    if (value === null || typeof value === 'boolean' || typeof value === 'number') {
      out[key] = value
      continue
    }
    if (typeof value === 'string') {
      out[key] = value.length > 240 ? `${value.slice(0, 240)}…` : value
      continue
    }
    if (Array.isArray(value)) {
      const size = safeSize(value)
      if (size <= 512) out[key] = value.length <= 8 ? value.map((item) => safePlain(item)) : { kind: 'array', length: value.length }
      continue
    }
    if (typeof value === 'object') {
      if (safeSize(value) <= 512) out[key] = safePlain(value)
      else out[key] = { kind: 'object' }
    }
  }
  return out
}

function safeSize(value) {
  try {
    return JSON.stringify(value)?.length ?? 0
  } catch {
    return Number.MAX_SAFE_INTEGER
  }
}

function safePlain(value) {
  if (value === null || typeof value !== 'object') return value
  try {
    return JSON.parse(JSON.stringify(value))
  } catch {
    return undefined
  }
}

function safeText(value) {
  return typeof value === 'string' ? (value.length > 80 ? `${value.slice(0, 80)}…` : value) : null
}

/** Events the phone actually renders. Everything else stays host-local. */
const PHONE_EVENT_TYPES = new Set([
  'turn/start',
  'turn/end',
  'step/start',
  'step/end',
  'tool/call',
  'tool/result',
  'assistant/message',
  'user/message',
  'session/title',
  'approval/asked',
  'approval/decided',
  'approval/policy',
  'session/created',
  'session/disposed'
])

/**
 * DSH records are `{ seq, time, data: {...} }`; the phone wants the inner data
 * flattened plus the log coordinates for ordering.
 */
/** One short line a notification/ball can show without a second lookup. */
function summarizeFlat(flat) {
  const bits = [flat.type]
  if (typeof flat.turn === 'number') bits.push(	urn )
  if (typeof flat.step === 'number') bits.push(step )
  if (typeof flat.tool === 'string') bits.push(flat.tool)
  if (typeof flat.preview === 'string' && flat.preview) bits.push(flat.preview.slice(0, 40))
  return bits.join(' · ').slice(0, 120)
}

function flattenRecord(type, event) {
  const data = event?.data && typeof event.data === 'object' ? event.data : {}
  const out = { seq: event?.seq ?? null, time: event?.time ?? null }
  const picked = flattenForType(type, data)
  return { ...out, ...picked }
}

function flattenForType(type, data) {
  switch (type) {
    case 'turn/start':
      return { turn: data.turn ?? null }
    case 'turn/end':
      // Real shape: { turn, reason: { kind } } — the kind is the outcome.
      return { turn: data.turn ?? null, outcome: data.outcome ?? data.status ?? data.reason?.kind ?? null }
    case 'step/start':
      return { turn: data.turn ?? null, step: data.step ?? data.index ?? null }
    case 'step/end':
      return { turn: data.turn ?? null, step: data.step ?? data.index ?? null, ok: data.ok ?? null }
    case 'tool/call':
      return { callId: data.callId ?? data.id ?? null, tool: data.tool ?? data.name ?? data.toolName ?? null, summary: safeText(data.title ?? data.summary ?? data.command ?? '') }
    case 'tool/result':
      return { callId: data.callId ?? data.id ?? null, ok: data.ok ?? data.status ?? null }
    case 'assistant/message':
      // Real shape: { turn, step, message: { content: [...] }, usage: {...} }.
      return { preview: safeText(extractMessageText(data.message ?? data)), tokens: data.usage?.totalTokens ?? null }
    case 'user/message':
      return { preview: safeText(extractMessageText(data.message ?? data)) }
    case 'session/title':
      return { title: safeText(data.title ?? data.text ?? '') }
    case 'approval/asked':
      return { approvalId: data.approvalId ?? data.id ?? null, tool: data.tool ?? data.toolName ?? null, reason: safeText(data.reason ?? '') }
    case 'approval/decided':
      return { approvalId: data.approvalId ?? data.id ?? null, outcome: data.outcome ?? data.decision ?? null }
    default:
      return sanitizeRecord(data)
  }
}

function extractMessageText(data) {
  const content = data?.content
  if (typeof content === 'string') return content
  if (Array.isArray(content)) {
    return content
      .filter((part) => part && part.type === 'text' && typeof part.text === 'string')
      .map((part) => part.text)
      .join(' ')
  }
  return ''
}

function safeSnapshot(approvals) {  try {
    return approvals.snapshot()
  } catch {
    return []
  }
}

async function requestAbort(ctx, sessionId) {
  // INTEGRATION POINT (J4): call the host session service's cancel path once pinned.
  const service = resolveService(ctx, SESSION_SERVICE_CANDIDATES)
  if (!service || typeof service.cancel !== 'function') {
    return { ok: false, code: 'NOT_IMPLEMENTED' }
  }
  try {
    await service.cancel({ sessionId })
    return { ok: true, sessionId }
  } catch (error) {
    return { ok: false, code: 'ABORT_FAILED', message: String(error?.message ?? error) }
  }
}

// ---------------------------------------------------------------- helpers

async function authenticate(req, res, store, limiter) {
  const origin = req.headers.origin
  const host = req.headers.host
  if (!checkAuthority(host, origin)) {
    writeJson(res, 403, { ok: false, code: 'FORBIDDEN_AUTHORITY' })
    return undefined
  }

  const deviceKey = String(req.headers['x-panel-device'] ?? '').slice(0, 128)
  if (!limiter.allow(deviceKey)) {
    writeJson(res, 429, { ok: false, code: 'RATE_LIMITED' })
    return undefined
  }

  const token = bearer(req.headers.authorization) ?? (deviceKey || undefined)
  const device = await store.verify(token)
  if (!device) {
    limiter.penalize(deviceKey)
    writeJson(res, 401, { ok: false, code: 'UNAUTHORIZED' })
    return undefined
  }
  limiter.reset(deviceKey)
  return device
}

/** Host/Origin check mirroring Connection's rule: same authority, no cross-site. */
function checkAuthority(host, origin) {
  if (!host) return false
  if (String(origin ?? '').toLowerCase() === 'cross-site') return false
  if (!origin) return true
  try {
    return new URL(origin).host === host
  } catch {
    return false
  }
}

function bearer(header) {
  if (typeof header !== 'string') return undefined
  const match = /^Bearer\s+(.+)$/i.exec(header.trim())
  return match ? match[1] : undefined
}

async function readJson(request) {
  try {
    return await request.json()
  } catch {
    return {}
  }
}

async function readNodeJson(req) {
  const chunks = []
  for await (const chunk of req) {
    chunks.push(chunk)
    if (chunks.reduce((sum, item) => sum + item.length, 0) > 64 * 1024) break
  }
  try {
    return JSON.parse(Buffer.concat(chunks).toString('utf8'))
  } catch {
    return {}
  }
}

function writeJson(res, status, body) {
  const payload = JSON.stringify(body)
  res.writeHead(status, {
    'content-type': 'application/json; charset=utf-8',
    'cache-control': 'no-store',
    'content-length': Buffer.byteLength(payload)
  })
  res.end(payload)
}

function json(produce) {
  return produce()
    .then((body) => Response.json(body, { headers: { 'cache-control': 'no-store' } }))
    .catch((error) => Response.json({ ok: false, code: 'INTERNAL', message: String(error?.message ?? error) }, { status: 500 }))
}

class RateLimiter {
  constructor(perSecond, maxFailures, lockMs) {
    this.perSecond = perSecond
    this.maxFailures = maxFailures
    this.lockMs = lockMs
    this.buckets = new Map()
  }

  #bucket(key) {
    let bucket = this.buckets.get(key)
    if (!bucket) {
      bucket = { tokens: this.perSecond, updatedAt: Date.now(), failures: 0, lockedUntil: 0 }
      this.buckets.set(key, bucket)
    }
    return bucket
  }

  allow(key) {
    const bucket = this.#bucket(key || 'anonymous')
    const now = Date.now()
    if (bucket.lockedUntil > now) return false
    const elapsed = (now - bucket.updatedAt) / 1000
    bucket.tokens = Math.min(this.perSecond, bucket.tokens + elapsed * this.perSecond)
    bucket.updatedAt = now
    if (bucket.tokens < 1) return false
    bucket.tokens -= 1
    return true
  }

  penalize(key) {
    const bucket = this.#bucket(key || 'anonymous')
    bucket.failures += 1
    if (bucket.failures >= this.maxFailures) {
      bucket.lockedUntil = Date.now() + this.lockMs
      bucket.failures = 0
    }
  }

  reset(key) {
    const bucket = this.#bucket(key || 'anonymous')
    bucket.failures = 0
  }
}
