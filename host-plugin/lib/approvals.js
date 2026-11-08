/**
 * Approval queue + `approval/request` waterfall responder.
 *
 * One source of truth for HITL:
 *   - a pending approval is enqueued and broadcast as `approval/request`
 *   - the phone settles it through POST /api/panel/confirm
 *   - timeout settles it as a rejection and is recorded for audit
 *
 * INTEGRATION POINT (联调项 J3): the exact request/result shape of
 * `ctx.userApproval` / the `approval/request` waterfall must be pinned against
 * the installed DSH build before this responder is enabled.
 */

const DEFAULT_TIMEOUT_MS = 120_000

export class ApprovalQueue {
  /** @param {{ timeoutMs?: number, now?: () => number }} [options] */
  constructor(options = {}) {
    this.timeoutMs = options.timeoutMs ?? DEFAULT_TIMEOUT_MS
    this.now = options.now ?? (() => Date.now())
    /** @type {Map<string, { approvalId: string, sessionId: string, resolve: Function, timer: any, record: object }>} */
    this.pending = new Map()
    this.counter = 0
  }

  /**
   * Register an inbound approval request and wait for a decision.
   * @param {{ sessionId: string, toolName?: string, riskLevel?: string, preview?: string, signal?: AbortSignal }} input
   * @returns {Promise<{ decision: 'APPROVE' | 'REJECT', rememberRule: boolean, by: 'user' | 'timeout' | 'cancelled' }>}
   */
  request(input) {
    const approvalId = `ap_${++this.counter}_${Date.now().toString(36)}`
    const record = {
      approvalId,
      sessionId: input.sessionId,
      toolName: input.toolName ?? 'unknown',
      riskLevel: input.riskLevel ?? 'MEDIUM',
      preview: (input.preview ?? '').slice(0, 512),
      requestedAt: this.now(),
      timeoutSeconds: Math.floor(this.timeoutMs / 1000)
    }

    return new Promise((resolve) => {
      const settle = (decision, by, rememberRule = false) => {
        const entry = this.pending.get(approvalId)
        if (!entry) return false
        clearTimeout(entry.timer)
        this.pending.delete(approvalId)
        entry.resolve({ approvalId, decision, rememberRule, by })
        if (typeof input.onSettled === 'function') {
          try {
            input.onSettled(record, decision, by)
          } catch {
            // Reporting must never change the decision outcome.
          }
        }
        return true
      }

      const timer = setTimeout(() => settle('REJECT', 'timeout'), this.timeoutMs)
      if (typeof timer.unref === 'function') timer.unref()

      this.pending.set(approvalId, { approvalId, sessionId: input.sessionId, resolve, timer, record, settle })

      if (typeof input.onPending === 'function') {
        try {
          input.onPending(record)
        } catch {
          // A broadcast failure must not change the decision lifecycle.
        }
      }

      if (input.signal) {
        input.signal.addEventListener(
          'abort',
          () => settle('REJECT', 'cancelled'),
          { once: true }
        )
      }
    })
  }

  /**
   * Settle one pending approval. Idempotent: a second call returns false.
   * @param {string} approvalId
   * @param {'APPROVE' | 'REJECT'} decision
   * @param {boolean} rememberRule
   */
  settle(approvalId, decision, rememberRule = false) {
    const entry = this.pending.get(approvalId)
    if (!entry) return false
    return entry.settle(decision, 'user', rememberRule)
  }

  /** Pending approvals for the current session (drives bootstrap/state). */
  snapshot(sessionId) {
    const result = []
    for (const entry of this.pending.values()) {
      if (sessionId && entry.sessionId !== sessionId) continue
      result.push(entry.record)
    }
    return result
  }

  /** Reject everything (plugin unload / host shutdown). */
  cancelAll(reason = 'cancelled') {
    for (const [approvalId, entry] of [...this.pending.entries()]) {
      clearTimeout(entry.timer)
      this.pending.delete(approvalId)
      entry.resolve({ decision: 'REJECT', rememberRule: false, by: reason })
    }
  }
}
