/**
 * Internal event bus + SSE framing for the panel bridge.
 *
 * The bridge does not invent a second event vocabulary: producers push
 * DSH-shaped records (`turn/start`, `step/start`, `tool/call`,
 * `approval/request`, ...) and the bus only adds a monotonic `seq` plus a
 * small ring buffer so a reconnecting phone can resume with Last-Event-ID.
 */

const DEFAULT_CAPACITY = 256

export class EventBus {
  /** @param {{ capacity?: number }} [options] */
  constructor(options = {}) {
    this.capacity = Math.max(16, options.capacity ?? DEFAULT_CAPACITY)
    this.seq = 0
    this.buffer = []
    /** @type {Set<(event: object) => void>} */
    this.listeners = new Set()
  }

  /**
   * Publish one DSH-shaped record. `sessionId` is required so the phone can
   * filter; `type` keeps DSH naming.
   * @param {string} sessionId
   * @param {string} type
   * @param {Record<string, unknown>} [payload]
   */
  publish(sessionId, type, payload = {}) {
    const event = {
      seq: ++this.seq,
      sessionId,
      type,
      ts: Date.now(),
      payload
    }
    this.buffer.push(event)
    if (this.buffer.length > this.capacity) this.buffer.shift()
    for (const listener of this.listeners) {
      try {
        listener(event)
      } catch (error) {
        // A broken subscriber must never break the producer.
        console.warn('[panel-bridge] subscriber failed:', error?.message)
      }
    }
    return event
  }

  /** @param {(event: object) => void} listener */
  subscribe(listener) {
    this.listeners.add(listener)
    return () => this.listeners.delete(listener)
  }

  /**
   * Resume support: events strictly newer than `sinceSeq`.
   * @param {number} sinceSeq
   * @param {string} [sessionId]
   */
  after(sinceSeq, sessionId) {
    return this.buffer.filter(
      (event) => event.seq > sinceSeq && (sessionId === undefined || event.sessionId === sessionId)
    )
  }
}

/**
 * Encode one record as an SSE frame. `retry` is emitted once by the caller.
 * @param {object} event
 */
export function sseFrame(event) {
  return `id: ${event.seq}\nevent: ${event.type}\ndata: ${JSON.stringify(event)}\n\n`
}

/** SSE handshake headers. No compression, no caching, keep-alive friendly. */
export function sseHeaders() {
  return {
    'content-type': 'text/event-stream; charset=utf-8',
    'cache-control': 'no-store, no-transform',
    connection: 'keep-alive',
    'x-accel-buffering': 'no'
  }
}

/** Heartbeat comment frame: keeps intermediaries from idling the socket out. */
export function sseHeartbeat() {
  return `: ping ${Date.now()}\n\n`
}
