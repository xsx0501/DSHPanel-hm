/**
 * Device store for the panel bridge.
 *
 * Responsibilities:
 *  - mint long-lived device tokens (the DSH startup token is process-scoped and dies on restart)
 *  - keep only sha256(token), never the plaintext
 *  - support per-device revocation (Q13)
 *
 * File: $DSH_HOME/panel-bridge/devices.json  (mode 0600)
 * Layout:
 *   { version: 1, devices: [ { id, name, tokenHash, createdAt, lastSeenAt, revokedAt, ua, scopes } ] }
 */
import { createHash, randomBytes, timingSafeEqual } from 'node:crypto'
import { chmod, mkdir, readFile, rename, writeFile } from 'node:fs/promises'
import { dirname, join } from 'node:path'

const SCOPE_READ = 'read'
const SCOPE_APPROVE = 'approve'
const SCOPE_ABORT = 'abort'
export const DEFAULT_SCOPES = [SCOPE_READ, SCOPE_APPROVE, SCOPE_ABORT]

export function sha256Hex(input) {
  return createHash('sha256').update(input, 'utf8').digest('hex')
}

/** Constant-time compare of two hex digests (both must be 64 chars). */
export function safeEqualHex(a, b) {
  if (typeof a !== 'string' || typeof b !== 'string') return false
  if (a.length !== b.length || a.length !== 64) return false
  try {
    return timingSafeEqual(Buffer.from(a, 'hex'), Buffer.from(b, 'hex'))
  } catch {
    return false
  }
}

export class DeviceStore {
  /**
   * @param {string} homeDir DSH home (already resolved by the caller)
   * @param {{ now?: () => number }} [options]
   */
  constructor(homeDir, options = {}) {
    this.file = join(homeDir, 'panel-bridge', 'devices.json')
    this.now = options.now ?? (() => Date.now())
    this.state = { version: 1, devices: [] }
    this.loaded = false
    this.#writeChain = Promise.resolve()
  }

  #writeChain

  async load() {
    if (this.loaded) return this.state
    try {
      const raw = await readFile(this.file, 'utf8')
      const parsed = JSON.parse(raw)
      if (parsed && typeof parsed === 'object' && Array.isArray(parsed.devices)) {
        this.state = { version: 1, devices: parsed.devices }
      }
    } catch (error) {
      // Missing file is the normal first-run path; anything else is reported once.
      if (error?.code !== 'ENOENT') {
        console.warn('[panel-bridge] devices.json unreadable, starting empty:', error?.message)
      }
    }
    this.loaded = true
    return this.state
  }

  /** Atomic, serialized persist (mode 0600). */
  async #persist() {
    const body = JSON.stringify(this.state, null, 2)
    this.#writeChain = this.#writeChain.then(async () => {
      await mkdir(dirname(this.file), { recursive: true, mode: 0o700 })
      const tmp = `${this.file}.${process.pid}.tmp`
      await writeFile(tmp, body, { mode: 0o600 })
      await rename(tmp, this.file)
      await chmod(this.file, 0o600).catch(() => {})
    })
    return this.#writeChain
  }

  /**
   * Mint a device token. Returns the plaintext exactly once.
   * @param {{ name?: string, ua?: string, scopes?: string[] }} input
   */
  async pair(input = {}) {
    await this.load()
    const token = randomBytes(32).toString('base64url')
    const device = {
      id: `dev_${randomBytes(8).toString('hex')}`,
      name: (input.name || 'HarmonyOS device').slice(0, 64),
      tokenHash: sha256Hex(token),
      createdAt: this.now(),
      lastSeenAt: null,
      revokedAt: null,
      ua: (input.ua || '').slice(0, 200),
      scopes: Array.isArray(input.scopes) && input.scopes.length > 0 ? input.scopes : DEFAULT_SCOPES
    }
    this.state.devices.push(device)
    await this.#persist()
    return { device: publicDevice(device), token }
  }

  /**
   * Verify a presented token. Returns the live device record or undefined.
   * @param {string} token
   */
  async verify(token) {
    if (typeof token !== 'string' || token.length < 32) return undefined
    await this.load()
    const digest = sha256Hex(token)
    const device = this.state.devices.find((item) => safeEqualHex(item.tokenHash, digest))
    if (!device || device.revokedAt !== null) return undefined
    device.lastSeenAt = this.now()
    // lastSeenAt is best-effort: do not block the request on disk I/O.
    this.#persist().catch(() => {})
    return device
  }

  async list() {
    await this.load()
    return this.state.devices.map(publicDevice)
  }

  /** @param {string} id */
  async revoke(id) {
    await this.load()
    const device = this.state.devices.find((item) => item.id === id)
    if (!device) return false
    if (device.revokedAt === null) {
      device.revokedAt = this.now()
      await this.#persist()
    }
    return true
  }

  /** Drop revoked records entirely (housekeeping). */
  async purgeRevoked() {
    await this.load()
    const before = this.state.devices.length
    this.state.devices = this.state.devices.filter((item) => item.revokedAt === null)
    if (this.state.devices.length !== before) await this.#persist()
    return before - this.state.devices.length
  }
}

function publicDevice(device) {
  return {
    id: device.id,
    name: device.name,
    createdAt: device.createdAt,
    lastSeenAt: device.lastSeenAt,
    revokedAt: device.revokedAt,
    scopes: device.scopes
  }
}
