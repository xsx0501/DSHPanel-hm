import { worker, MessageEvents, ErrorEvent } from '@kit.ArkTS';
import { BusinessError } from '@kit.BasicServicesKit';

/** Command envelopes sent to the worker (typed so ArkTS accepts the literals). */
interface InitCommand {
  type: string;
  baseUrl: string;
  token: string;
}

interface StartCommand {
  type: string;
  sessionId: string;
}

interface StopCommand {
  type: string;
}

/**
 * Main-thread handle over `StreamWorker`.
 *
 * The worker owns the SSE connection; this class only forwards commands and
 * relays parsed frames, so a destroyed page never drops the stream.
 */
export class WorkerClient {
  private thread: worker.ThreadWorker | null = null;
  private baseUrl: string = '';
  private token: string = '';
  private running: boolean = false;
  private onEvent: (type: string, data: string) => void = () => {};
  private onStatus: (state: string, detail: string) => void = () => {};

  /** Wire callbacks before `configure`/`start`. */
  listen(onEvent: (type: string, data: string) => void, onStatus: (state: string, detail: string) => void): void {
    this.onEvent = onEvent;
    this.onStatus = onStatus;
  }

  /** Start (or restart) the worker with fresh credentials. */
  configure(baseUrl: string, token: string): void {
    this.baseUrl = baseUrl;
    this.token = token;
    this.ensureThread();
    const command: InitCommand = { type: 'init', baseUrl: baseUrl, token: token };
    this.post(command);
  }

  start(sessionId: string): void {
    this.ensureThread();
    this.running = true;
    const command: StartCommand = { type: 'start', sessionId: sessionId };
    this.post(command);
  }

  stop(): void {
    this.running = false;
    const command: StopCommand = { type: 'stop' };
    this.post(command);
  }

  isRunning(): boolean {
    return this.running;
  }

  terminate(): void {
    this.running = false;
    if (this.thread !== null) {
      try {
        this.thread.terminate();
      } catch {
        // Already terminated.
      }
      this.thread = null;
    }
  }

  private ensureThread(): void {
    if (this.thread !== null) {
      return;
    }
    try {
      const thread: worker.ThreadWorker = new worker.ThreadWorker('@bundle:com.233craft.xsx.hmos.dsh.panel/panel/ets/worker/StreamWorker.ets');
      thread.onmessage = (event: MessageEvents) => {
        const payload = event.data as Record<string, string>;
        const kind: string = payload['type'] ?? '';
        if (kind === 'event') {
          this.onEvent(payload['eventType'] ?? '', payload['data'] ?? '');
        } else if (kind === 'status') {
          this.onStatus(payload['state'] ?? '', payload['detail'] ?? '');
        }
      };
      thread.onerror = (error: ErrorEvent) => {
        this.onStatus('worker-error', error.message ?? 'worker error');
      };
      this.thread = thread;
    } catch (error) {
      const businessError: BusinessError = error as BusinessError;
      this.onStatus('worker-create-failed', `${businessError.code}: ${businessError.message}`);
    }
  }

  private post(payload: Object): void {
    if (this.thread === null) {
      return;
    }
    try {
      this.thread.postMessage(payload);
    } catch (error) {
      const businessError: BusinessError = error as BusinessError;
      this.onStatus('worker-post-failed', `${businessError.code}: ${businessError.message}`);
    }
  }
}
