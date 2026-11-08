import { hilog } from '@kit.PerformanceAnalysisKit';
import { PanelApi } from '../net/PanelApi';
import { ConfirmResponse } from '../model/PanelTypes';
import { PanelTelemetry, TelemetryHub } from '../domain/TelemetryHub';

/**
 * JSBridge exposed to the DSH web workspace (docs/design.md §7.4.2).
 *
 * Only the operations the web page cannot do on its own live here: minting an
 * approval decision through the paired device token, aborting a turn, and pulling
 * native telemetry. Every method returns a JSON string so the page can call it
 * synchronously from `evaluateJavascript`.
 */
const DOMAIN: number = 0x0001;

export class PanelWebBridge {
  private api: PanelApi;
  private emit: (js: string) => void;

  constructor(api: PanelApi, emit: (js: string) => void) {
    this.api = api;
    this.emit = emit;
  }

  /** Static description of the bridge; the page uses it to feature-detect. */
  info(): string {
    return `{"bridge":"dsh","version":1,"capabilities":["decide","abort","telemetry","log","state"]}`;
  }

  /** Current native telemetry snapshot, so a freshly loaded page is never blind. */
  state(): string {
    const snapshot: PanelTelemetry = TelemetryHub.get().snapshot();
    return JSON.stringify(snapshot);
  }

  /** `decision` accepts APPROVE / REJECT; result arrives via onDecision(). */
  decide(approvalId: string, decision: string): string {
    const normalized: string = decision === 'REJECT' ? 'REJECT' : 'APPROVE';
    this.api.confirm(approvalId, normalized, false).then((result: ConfirmResponse) => {
      this.emit(`window.__DSH_PANEL__ && window.__DSH_PANEL__.onDecision(${this.quote(approvalId)}, ${this.quote(normalized)}, ${result.ok ? 'true' : 'false'})`);
    }).catch(() => {
      this.emit(`window.__DSH_PANEL__ && window.__DSH_PANEL__.onDecision(${this.quote(approvalId)}, ${this.quote(normalized)}, false)`);
    });
    return `{"accepted":true,"approvalId":${this.quote(approvalId)},"decision":${this.quote(normalized)}}`;
  }

  /** Ask the host to cancel the running turn of a session. */
  abort(sessionId: string): string {
    this.api.abort(sessionId).then((result: ConfirmResponse) => {
      this.emit(`window.__DSH_PANEL__ && window.__DSH_PANEL__.onAbort(${this.quote(sessionId)}, ${result.ok ? 'true' : 'false'})`);
    }).catch(() => {
      this.emit(`window.__DSH_PANEL__ && window.__DSH_PANEL__.onAbort(${this.quote(sessionId)}, false)`);
    });
    return `{"accepted":true,"sessionId":${this.quote(sessionId)}}`;
  }

  /** Page-side diagnostics land in hilog so `hdc hilog` can prove the bridge works. */
  log(message: string): void {
    hilog.info(DOMAIN, 'panel', 'jsbridge: %{public}s', message);
  }

  private quote(value: string): string {
    // Keep the injected JS safe: escape backslashes and quotes.
    return `"${value.replace(/\\/g, '\\\\').replace(/"/g, '\\"')}"`;
  }
}
