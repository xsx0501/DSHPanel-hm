import { worker } from '@kit.ArkTS';
import { http } from '@kit.NetworkKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { SseParser } from '../net/SseParser';

/**
 * Background stream worker (docs/design.md §7.2).
 *
 * Why a worker: the SSE stream must not depend on the UI thread staying alive.
 * The page can be destroyed, the window can be recreated, and the stream keeps
 * reading; only the parsed frames cross the thread boundary.
 *
 * Protocol (all plain objects, structured-clone friendly):
 *   main → worker: { type: 'init', baseUrl, token }
 *                  { type: 'start', sessionId }
 *                  { type: 'stop' }
 *   worker → main: { type: 'event', eventType, data }
 *                  { type: 'status', state, detail }
 */
interface InitCommand {
  type: string;
  baseUrl?: string;
  token?: string;
  sessionId?: string;
}

const port: worker.ThreadWorker = worker.workerPort;
const TIMEOUT_MS: number = 600_000;
const MIN_BACKOFF_MS: number = 1000;
const MAX_BACKOFF_MS: number = 15000;

let baseUrl: string = '';
let token: string = '';
let sessionId: string = '';
let lastEventId: string = '';
let request: http.HttpRequest | null = null;
let backoffMs: number = MIN_BACKOFF_MS;
let started: boolean = false;
let connectTimer: number = -1;
let silentTimer: number = -1;

function post(payload: Object): void {
  try {
    port.postMessage(payload);
  } catch (error) {
    // The main thread may already be gone; nothing to do in a worker.
  }
}

function status(state: string, detail: string = ''): void {
  post({ type: 'status', state: state, detail: detail });
}

function clearTimers(): void {
  if (connectTimer >= 0) {
    clearTimeout(connectTimer);
    connectTimer = -1;
  }
  if (silentTimer >= 0) {
    clearTimeout(silentTimer);
    silentTimer = -1;
  }
}

function closeRequest(): void {
  clearTimers();
  if (request !== null) {
    try {
      request.destroy();
    } catch {
      // Already closed.
    }
    request = null;
  }
}

function scheduleReconnect(reason: string): void {
  closeRequest();
  if (!started) {
    return;
  }
  status('reconnecting', `${reason}; retry in ${Math.round(backoffMs / 1000)}s`);
  const delay: number = backoffMs;
  backoffMs = Math.min(backoffMs * 2, MAX_BACKOFF_MS);
  connectTimer = setTimeout(() => {
    connect();
  }, delay);
}

function connect(): void {
  if (!started || baseUrl.length === 0) {
    return;
  }
  closeRequest();
  status('connecting');

  const req: http.HttpRequest = http.createHttp();
  request = req;
  const header: Record<string, string> = {
    'Accept': 'text/event-stream',
    'Cache-Control': 'no-store',
    'Authorization': `Bearer ${token}`
  };
  if (lastEventId.length > 0) {
    header['Last-Event-ID'] = lastEventId;
  }
  let query: string = '';
  if (sessionId.length > 0) {
    query = `?sessionId=${encodeURIComponent(sessionId)}`;
  }

  const parser: SseParser = new SseParser((type: string, data: string, id: string) => {
    backoffMs = MIN_BACKOFF_MS;
    if (id.length > 0) {
      lastEventId = id;
    }
    post({ type: 'event', eventType: type, data: data });
  });

  req.on('dataReceive', (chunk: ArrayBuffer) => {
    parser.push(chunk);
    // Any byte proves the link is alive; restart the 45s silence watchdog.
    if (silentTimer >= 0) {
      clearTimeout(silentTimer);
    }
    silentTimer = setTimeout(() => {
      scheduleReconnect('silent for 45s');
    }, 45000);
  });
  req.on('dataEnd', () => {
    if (!started) {
      return;
    }
    parser.end();
    scheduleReconnect('stream ended');
  });

  req.requestInStream(`${baseUrl}/api/panel/events${query}`, {
    method: http.RequestMethod.GET,
    header: header,
    connectTimeout: 10000,
    readTimeout: TIMEOUT_MS,
    usingCache: false
  }).then(() => {
    if (started) {
      scheduleReconnect('request finished');
    }
  }).catch((error: BusinessError) => {
    if (started) {
      scheduleReconnect(`${error.code}`);
    }
  });
  status('connected');
}

port.onmessage = (event: MessageEvent) => {
  const command: InitCommand = event.data as InitCommand;
  if (command === null || command === undefined) {
    return;
  }
  if (command.type === 'init') {
    baseUrl = (command.baseUrl ?? '').replace(/\/+$/, '');
    token = command.token ?? '';
    if (started) {
      connect();
    }
    status('ready');
    return;
  }
  if (command.type === 'start') {
    sessionId = command.sessionId ?? '';
    lastEventId = '';
    backoffMs = MIN_BACKOFF_MS;
    started = true;
    connect();
    return;
  }
  if (command.type === 'stop') {
    started = false;
    closeRequest();
    status('stopped');
  }
};
