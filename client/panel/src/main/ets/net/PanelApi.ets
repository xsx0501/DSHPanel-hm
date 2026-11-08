import { http } from '@kit.NetworkKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { AbortRequest, SnapshotResponse, BootstrapResponse, ConfirmRequest, ConfirmResponse, PairRequest, PairResponse } from '../model/PanelTypes';
import { SseParser } from './SseParser';

const DEFAULT_TIMEOUT_MS: number = 12_000;

/** Thin client for the `dsh-panel-bridge` companion API (docs/design.md §8.3). */
export class PanelApi {
  private readonly baseUrl: string;
  private deviceToken: string = '';

  constructor(baseUrl: string) {
    this.baseUrl = baseUrl.replace(/\/+$/, '');
  }

  setDeviceToken(token: string): void {
    this.deviceToken = token;
  }

  getDeviceToken(): string {
    return this.deviceToken;
  }

  getBaseUrl(): string {
    return this.baseUrl;
  }

  /** First run: exchange the launch token for a long-lived device token. */
  async pairWithToken(startupToken: string, deviceName: string): Promise<PairResponse> {
    const request: PairRequest = { startupToken: startupToken, deviceName: deviceName };
    const body: string = JSON.stringify(request);
    const response: http.HttpResponse = await this.request('POST', '/api/panel/pair-with-token', body, false);
    return this.parseJson<PairResponse>(response);
  }

  async bootstrap(): Promise<BootstrapResponse> {
    const response: http.HttpResponse = await this.request('GET', '/api/panel/bootstrap', '', true);
    return this.parseJson<BootstrapResponse>(response);
  }

  /** Small poll payload for the background catch-up loop. */
  async snapshot(): Promise<SnapshotResponse> {
    const response: http.HttpResponse = await this.request('GET', '/api/panel/snapshot', '', true);
    return this.parseJson<SnapshotResponse>(response);
  }

  async confirm(approvalId: string, decision: string, rememberRule: boolean): Promise<ConfirmResponse> {
    const request: ConfirmRequest = { approvalId: approvalId, decision: decision, rememberRule: rememberRule };
    const body: string = JSON.stringify(request);
    const response: http.HttpResponse = await this.request('POST', '/api/panel/confirm', body, true);
    return this.parseJson<ConfirmResponse>(response);
  }

  async abort(sessionId: string): Promise<ConfirmResponse> {
    const request: AbortRequest = { sessionId: sessionId };
    const body: string = JSON.stringify(request);
    const response: http.HttpResponse = await this.request('POST', '/api/panel/abort', body, true);
    return this.parseJson<ConfirmResponse>(response);
  }

  /**
   * Open the SSE channel. Returns a closer; the parser survives partial frames.
   * Callbacks fire on the http callback thread — marshal to the UI thread in the caller.
   */
  openEvents(
    sessionId: string,
    onEvent: (type: string, data: string) => void,
    onError: (message: string) => void,
    onClose: () => void,
    lastEventId: string = ''
  ): () => void {
    const request: http.HttpRequest = http.createHttp();
    const header: Record<string, string> = {
      'Accept': 'text/event-stream',
      'Cache-Control': 'no-store',
      'Authorization': `Bearer ${this.deviceToken}`
    };
    if (lastEventId.length > 0) {
      header['Last-Event-ID'] = lastEventId;
    }
    let query: string = '';
    if (sessionId.length > 0) {
      query = `?sessionId=${encodeURIComponent(sessionId)}`;
    }
    const parser: SseParser = new SseParser((type: string, data: string, id: string) => {
      onEvent(type, data);
    });

    request.on('dataReceive', (chunk: ArrayBuffer) => {
      parser.push(chunk);
    });
    request.on('dataEnd', () => {
      parser.end();
    });

    request.requestInStream(`${this.baseUrl}/api/panel/events${query}`, {
      method: http.RequestMethod.GET,
      header: header,
      connectTimeout: 10_000,
      readTimeout: 600_000,
      usingCache: false
    }).then(() => {
      onClose();
    }).catch((error: BusinessError) => {
      onError(`${error.code}: ${error.message}`);
      onClose();
    });

    return () => {
      request.destroy();
    };
  }

  private async request(method: string, path: string, body: string, authorized: boolean): Promise<http.HttpResponse> {
    const request: http.HttpRequest = http.createHttp();
    const header: Record<string, string> = { 'Content-Type': 'application/json' };
    if (authorized) {
      header['Authorization'] = `Bearer ${this.deviceToken}`;
    }
    const options: http.HttpRequestOptions = {
      method: method === 'POST' ? http.RequestMethod.POST : http.RequestMethod.GET,
      header: header,
      connectTimeout: DEFAULT_TIMEOUT_MS,
      readTimeout: DEFAULT_TIMEOUT_MS,
      usingCache: false
    };
    if (body.length > 0) {
      options.extraData = body;
    }
    try {
      return await request.request(`${this.baseUrl}${path}`, options);
    } finally {
      request.destroy();
    }
  }

  private parseJson<T>(response: http.HttpResponse): T {
    const raw: string = typeof response.result === 'string' ? response.result : JSON.stringify(response.result);
    return JSON.parse(raw) as T;
  }
}
