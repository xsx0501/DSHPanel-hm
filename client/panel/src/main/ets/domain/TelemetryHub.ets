/**
 * Process-level telemetry fan-out (native → web handover, design §7.4.3).
 *
 * The Index page owns the SSE connection, but the ArkWeb workspace needs the same
 * picture. Pages publish here instead of talking to each other, so the WebView can
 * be opened at any time and immediately receive the current state.
 */
export interface PanelTelemetry {
  connected: boolean;
  sessionId: string;
  title: string;
  turn: number;
  step: number;
  status: string;
  approvalCount: number;
  approvalId: string;
  approvalPreview: string;
  updatedAt: number;
}

export class TelemetryHub {
  private static instance: TelemetryHub | null = null;
  private current: PanelTelemetry = TelemetryHub.empty();
  private listeners: Array<(state: PanelTelemetry) => void> = [];

  static get(): TelemetryHub {
    if (TelemetryHub.instance === null) {
      TelemetryHub.instance = new TelemetryHub();
    }
    return TelemetryHub.instance;
  }

  private static empty(): PanelTelemetry {
    const state: PanelTelemetry = {
      connected: false,
      sessionId: '',
      title: '',
      turn: 0,
      step: 0,
      status: '未连接',
      approvalCount: 0,
      approvalId: '',
      approvalPreview: '',
      updatedAt: 0
    };
    return state;
  }

  publish(state: PanelTelemetry): void {
    state.updatedAt = Date.now();
    this.current = state;
    for (const listener of this.listeners) {
      try {
        listener(state);
      } catch {
        // A dead page must not break the others.
      }
    }
  }

  snapshot(): PanelTelemetry {
    return this.current;
  }

  listen(listener: (state: PanelTelemetry) => void): void {
    this.listeners.push(listener);
  }

  unlisten(listener: (state: PanelTelemetry) => void): void {
    const index: number = this.listeners.indexOf(listener);
    if (index >= 0) {
      this.listeners.splice(index, 1);
    }
  }
}
