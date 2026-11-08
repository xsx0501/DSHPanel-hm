import { http } from '@kit.NetworkKit';
import { connection } from '@kit.NetworkKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { SseParser } from '../net/SseParser';

/**
 * Process-level SSE manager (replaces the page-owned stream).
 *
 * Goal: the stream must outlive the page. The stream previously lived in the
 * page component, so a destroyed window killed it; here the connection, the
 * Last-Event-ID cursor and the reconnect policy live in a singleton owned by the
 * app process, and pages merely subscribe/unsubscribe.
 *
 * A dedicated Worker was attempted first and rejected: this toolchain
 * (useNormalizedOHMUrl) rejects every worker path form tried with error
 * 10200007. The singleton keeps the same durability guarantee for the page
 * lifecycle, which is what the scenario actually needs.
 */
export class StreamService {
  private static instance: StreamService | null = null;

  private baseUrl: string = '';
  private token: string = '';
  private sessionId: string = '';
  private lastEventId: string = '';
  private resumeSince: number = 0;
  private generation: number = 0;
  private lastReconnectReason: string = '';
  private lastReconnectAt: number = 0;
  private request: http.HttpRequest | null = null;
  private backoffMs: number = 1000;
  private active: boolean = false;
  private networkWatched: boolean = false;
  private netHandle: connection.NetConnection | null = null;
  private reconnectTimer: number = -1;
  private silentTimer: number = -1;
  private onEvent: (type: string, data: string) => void = () => {};
  private onStatus: (state: string, detail: string) => void = () => {};

  static get(): StreamService {
    if (StreamService.instance === null) {
      StreamService.instance = new StreamService();
    }
    return StreamService.instance;
  }

  listen(onEvent: (type: string, data: string) => void, onStatus: (state: string, detail: string) => void): void {
    this.onEvent = onEvent;
    this.onStatus = onStatus;
  }

  isRunning(): boolean {
    return this.active;
  }

  /** (Re)configure credentials and open the stream for one scope. */
  start(baseUrl: string, token: string, sessionId: string, resumeFrom: string = ''): void {
    this.baseUrl = baseUrl.replace(/\/+$/, '');
    this.token = token;
    this.sessionId = sessionId;
    // Cold-start resume: the journal carries the cursor, so a restarted process
    // replays only what it missed instead of re-reading the whole ring.
    this.lastEventId = resumeFrom;
    this.backoffMs = 1000;
    this.active = true;
    this.watchNetwork();
    this.connect();
  }

  /** Current cursor, persisted by the page journal. */
  cursor(): string {
    return this.lastEventId;
  }

  /**
   * Foreground compensation: while backgrounded the OS may retire the socket
   * without any callback. Resume by replaying the host ring from the start and
   * let the page drop already-seen seq numbers — simpler and safer than trusting
   * a cursor that may have gone stale while the stream was stalled.
   */
  restart(): void {
    if (!this.active || this.baseUrl.length === 0) {
      return;
    }
    this.clearTimers();
    this.destroy();
    this.backoffMs = 1000;
    this.connect();
  }

  /** Catch-up cursor used on resume (host accepts `sinceSeq` as a query param). */
  setResumeSince(seq: number): void {
    this.resumeSince = seq > 0 ? seq : 0;
  }

  /** Connectivity awareness: an offline gap must not burn the retry budget. */
  private watchNetwork(): void {
    if (this.networkWatched) {
      return;
    }
    this.networkWatched = true;
    try {
      const net: connection.NetConnection = connection.createNetConnection();
      this.netHandle = net;
      net.on('netAvailable', () => {
        // Only react when there is no live stream: tearing down a healthy request
        // mid-frame is what produced the 2300023 write errors.
        if (this.active && this.request === null) {
          this.backoffMs = 1000;
          this.onStatus('network-restored', '');
          this.connect();
        }
      });
      net.on('netLost', () => {
        if (this.active) {
          this.onStatus('offline', '网络已断开');
        }
      });
      net.register(() => {});
    } catch {
      // Older devices may not expose link events; the retry loop still works.
    }
  }

  stop(): void {
    this.active = false;
    this.clearTimers();
    this.destroy();
  }

  private clearTimers(): void {
    if (this.reconnectTimer >= 0) {
      clearTimeout(this.reconnectTimer);
      this.reconnectTimer = -1;
    }
    if (this.silentTimer >= 0) {
      clearTimeout(this.silentTimer);
      this.silentTimer = -1;
    }
  }

  private destroy(): void {
    if (this.request !== null) {
      try {
        this.request.destroy();
      } catch {
        // Already closed.
      }
      this.request = null;
    }
  }

  private scheduleReconnect(reason: string): void {
    this.clearTimers();
    this.destroy();
    if (!this.active) {
      return;
    }
    // Keep the UI honest but not chatty: report a reason once, not every cycle.
    const now: number = Date.now();
    if (reason !== this.lastReconnectReason || now - this.lastReconnectAt > 5000) {
      this.lastReconnectReason = reason;
      this.lastReconnectAt = now;
      this.onStatus('reconnecting', reason);
    }
    const delay: number = this.backoffMs;
    this.backoffMs = Math.min(this.backoffMs * 2, 15000);
    this.reconnectTimer = setTimeout(() => {
      this.connect();
    }, delay);
  }

  private connect(): void {
    if (!this.active || this.baseUrl.length === 0) {
      return;
    }
    if (this.request !== null) {
      // Already streaming: a second connect would destroy the live request.
      return;
    }
    this.clearTimers();
    this.destroy();

    const request: http.HttpRequest = http.createHttp();
    this.request = request;
    const header: Record<string, string> = {
      'Accept': 'text/event-stream',
      'Cache-Control': 'no-store',
      'Authorization': `Bearer ${this.token}`
    };
    if (this.lastEventId.length > 0) {
      header['Last-Event-ID'] = this.lastEventId;
    }
    let query: string = '';
    if (this.sessionId.length > 0) {
      query = `?sessionId=${encodeURIComponent(this.sessionId)}`;
    }
    if (this.resumeSince > 0) {
      query = `${query.length > 0 ? query : '?'}${query.length > 0 ? '&' : ''}sinceSeq=${this.resumeSince}`;
      // One-shot: later reconnects use the normal cursor.
      this.resumeSince = 0;
    }

    const parser: SseParser = new SseParser((type: string, data: string, id: string) => {
      this.backoffMs = 1000;
      if (id.length > 0) {
        this.lastEventId = id;
      }
      this.onEvent(type, data);
    });

    // Every connect gets a generation. A destroyed request still reports its
    // 2300023 rejection later; without this guard that late callback kills the
    // NEW request and the service reconnects forever.
    const generation: number = ++this.generation;
    const isCurrent = (): boolean => generation === this.generation;

    request.on('dataReceive', (chunk: ArrayBuffer) => {
      if (!isCurrent()) {
        return;
      }
      parser.push(chunk);
      if (this.silentTimer >= 0) {
        clearTimeout(this.silentTimer);
      }
      this.silentTimer = setTimeout(() => {
        if (isCurrent()) {
          this.scheduleReconnect('静默 45s');
        }
      }, 45000);
    });
    request.on('dataEnd', () => {
      if (this.active && isCurrent()) {
        parser.end();
        this.scheduleReconnect('流已结束');
      }
    });

    request.requestInStream(`${this.baseUrl}/api/panel/events${query}`, {
      method: http.RequestMethod.GET,
      header: header,
      connectTimeout: 10000,
      readTimeout: 600000,
      usingCache: false
    }).then(() => {
      if (this.active && isCurrent()) {
        this.scheduleReconnect('请求结束');
      }
    }).catch((error: BusinessError) => {
      if (this.active && isCurrent()) {
        this.scheduleReconnect(`${error.code}`);
      }
    });
    this.onStatus('connected', '');
  }
}
