import { common, wantAgent, Want } from '@kit.AbilityKit';
import { window, uiMaterial } from '@kit.ArkUI';
import { BusinessError } from '@kit.BasicServicesKit';
import { ImportIntent, NodeInfo, PanelEvent, PanelEventPayload, PendingApproval, SessionSummary, SnapshotProgress, SnapshotResponse } from '../model/PanelTypes';
import { PanelApi } from '../net/PanelApi';
import { StreamService } from '../domain/StreamService';
import { PanelTelemetry, TelemetryHub } from '../domain/TelemetryHub';
import { FloatingBallPresenter } from '../presenter/FloatingBallPresenter';
import { FloatViewPresenter } from '../presenter/FloatViewPresenter';
import { emitter } from '@kit.BasicServicesKit';
import { router } from '@kit.ArkUI';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { KeepAlivePresenter } from '../presenter/KeepAlivePresenter';
import { NotificationPresenter } from '../presenter/NotificationPresenter';
import { CapabilityReport, CapabilityProbe } from '../probe/CapabilityProbe';
import { CardStateStore } from '../store/CardStateStore';
import { PanelStore } from '../store/PanelStore';
import { Theme } from '../theme/Theme';
import { scanBarcode, scanCore } from '@kit.ScanKit';

const MAX_LOG_LINES: number = 40;
/** Client-side approval TTL; the host settles at 120s, so allow a little slack. */
const GLASS_SIZE: number = 300;
const CARD_WIDTH: number = 1120;
const CARD_HEIGHT: number = 1460;
const APPROVAL_TTL_MS: number = 150_000;

/** An approval waiting for the user, kept minimal so it survives re-render cheaply. */
@Observed
class PendingApprovalView {
  approvalId: string = '';
  toolName: string = '';
  preview: string = '';
  sessionId: string = '';
  riskLevel: string = '';
  receivedAt: number = 0;
}

/** State pushed into the float card window (must stay JSON-plain for emitter). */
class CardStatePayload {
  line: string = '';
  status: string = '';
  preview: string = '';
  approvalId: string = '';
  title: string = '';
  metrics: string = '';
  activity: string = '';
  /** Last few timeline lines, newline separated ("what just happened"). */
  events: string = '';
  tokens: string = '';
  pending: string = '';
  sessionShort: string = '';

  toMap(): Record<string, string> {
    const map: Record<string, string> = {};
    map['line'] = this.line;
    map['status'] = this.status;
    map['preview'] = this.preview;
    map['approvalId'] = this.approvalId;
    map['title'] = this.title;
    map['metrics'] = this.metrics;
    map['activity'] = this.activity;
    map['events'] = this.events;
    map['tokens'] = this.tokens;
    map['pending'] = this.pending;
    map['sessionShort'] = this.sessionShort;
    return map;
  }
}

/** Per-session progress, so the floating ball never shows another session's turn. */
class SessionProgress {
  turn: number = 0;
  step: number = 0;
}

/** Local preview type so the list stays simple and cheap to re-render. */@Observed
class SessionRow {
  sessionId: string = '';
  title: string = '';
  running: boolean = false;
  steps: number = 0;
  updatedAt: number = 0;
}

@Entry
@Component
struct Index {
  @State private importUrl: string = '';
  @State private status: string = '未连接';
  @State private connected: boolean = false;
  @State private busy: boolean = false;
  @State private sessions: SessionRow[] = [];
  @State private sessionCount: number = 0;
  private activeNodeId: string = '';
  @State private events: string[] = [];
  @State private capability: string = '尚未探测';
  @State private activeSessionId: string = '';

  private store: PanelStore | null = null;
  private api: PanelApi | null = null;
  private stream: StreamService = StreamService.get();
  private hub: TelemetryHub = TelemetryHub.get();
  private ball: FloatingBallPresenter | null = null;
  private floatView: FloatViewPresenter | null = null;
  private keepAlive: KeepAlivePresenter | null = null;
  private notifier: NotificationPresenter | null = null;
  private notifiedApprovalId: string = '';
  private notifiedApprovals: string[] = [];
  private lastNotifyAt: number = 0;
  @State private ballVisible: boolean = false;
  private ballUserStopped: boolean = false;
  /** True when the ball is bound to the card: the system owns the expand gesture. */
  private pairBound: boolean = false;
  @State private floatWindowVisible: boolean = false;
  @State private keepAliveMode: string = '';
  @State private lastTurn: number = 0;
  @State private lastStep: number = 0;
  /**
   * SSE callbacks arrive on an http worker thread; touching `@State` from there
   * aborts the stream (error 2300023). Buffer there, flush on the UI thread.
   */
  private pendingLines: string[] = [];
  private logScroller: Scroller = new Scroller();
  private reconnectDelayMs: number = 2000;
  private resumeCursor: string = '';
  private lastJournalAt: number = 0;
  private keepAliveUserStopped: boolean = false;
  private lastSeq: number = 0;
  @State private activeTab: number = 0;
  @State private showTools: boolean = false;
  private swiperController: SwiperController = new SwiperController();
  /** Status-bar height, so the frosted header sits below it while the backdrop runs under it. */
  @State private topInset: number = 38;
  /** Mirrors the system colour mode so the floating ball can re-theme itself. */
  @StorageLink('panel.dark') @Watch('onDarkModeChanged') private darkMode: boolean = false;
  @State private rememberIds: string[] = [];
  @State private tick: number = 0;
  private tickTimer: number = -1;
  /** turn/step are per session; the ball follows exactly one session at a time. */
  private progress: Map<string, SessionProgress> = new Map();
  @State private followSession: string = '';
  @State private lastActivity: string = '';
  private lastCardPushAt: number = 0;
  private pollTimer: number = -1;
  private snapshotBusy: boolean = false;
  private eventSessionId: string = '';
  private pendingTurn: number = 0;
  private pendingStep: number = 0;
  /** Approvals discovered on the http thread; flushed into @State on the UI thread. */
  private pendingApprovalQueue: PendingApprovalView[] = [];
  private resolvedApprovalQueue: string[] = [];
  @State private approvals: PendingApprovalView[] = [];
  private flushTimer: number = -1;
  /** SSE subscribes to all sessions until the user explicitly picks one. */
  private userPickedSession: boolean = false;

  aboutToAppear(): void {
    const context: common.UIAbilityContext = getContext(this) as common.UIAbilityContext;
    this.store = new PanelStore(context);
    this.tickTimer = setInterval(() => {
      if (this.approvals.length > 0) {
        this.tick = this.tick + 1;
      }
    }, 1000);
    this.flushTimer = setInterval(() => {
      this.flushPending();
    }, 300);
    this.ball = new FloatingBallPresenter(context);
    this.ball.onClick(() => {
      this.handleBallClick();
    });
    this.floatView = new FloatViewPresenter(context);
    this.keepAlive = new KeepAlivePresenter(context);
    this.notifier = new NotificationPresenter(context);
    this.notifier.requestEnable().then((granted: boolean) => {
      this.appendLine(granted ? '通知已启用（L0 可用）' : '通知未启用：L0 兜底不可用');
    });
    this.subscribeCardEvents();
    this.stream.listen(
      (type: string, data: string) => {
        this.appendEvent(type, data);
      },
      (state: string, detail: string) => {
        this.onStreamStatus(state, detail);
      }
    );
    const pending: string = AppStorage.get<string>('pendingImportUrl') ?? '';
    if (pending.length > 0) {
      AppStorage.setOrCreate<string>('pendingImportUrl', '');
      this.importUrl = pending;
    }
    this.restoreJournal().then(() => {
      this.loadSaved(pending);
    });
  }

  /** Page hidden == app went to background (onPageShow handles the return). */
  onPageHide(): void {
    this.startBackgroundPoll();
    // Background presence is the point of this app: show the ball automatically
    // unless the user explicitly turned it off.
    if (this.ball !== null) {
      this.ball.setDark(this.darkMode);
    }
    if (!this.ballUserStopped && !this.ballVisible && this.ball !== null && this.ball.isSupported()) {
      this.toggleBall();
    }
  }

  aboutToHide(): void {
    this.startBackgroundPoll();
  }

  aboutToDisappear(): void {
    this.stopBackgroundPoll();
    this.stopEvents();
    if (this.flushTimer >= 0) {
      clearInterval(this.flushTimer);
      this.flushTimer = -1;
    }
    if (this.tickTimer >= 0) {
      clearInterval(this.tickTimer);
      this.tickTimer = -1;
    }
  }

  /**
   * The node page writes the active node; pick it up without a restart.
   * @returns true when the connection was rebuilt for a different node.
   */
  private async syncActiveNode(): Promise<boolean> {
    if (this.store === null) {
      return false;
    }
    const active: string = await (this.store as PanelStore).activeNodeId();
    if (active.length === 0) {
      return false;
    }
    if (active === this.activeNodeId) {
      // Same id, but the address may have been edited or re-paired since.
      const current: NodeInfo | undefined = await this.findNode(active);
      if (current === undefined || current.baseUrl === this.importUrl) {
        return false;
      }
    }
    this.activeNodeId = active;
    const nodes = await (this.store as PanelStore).loadNodes();
    let node: NodeInfo | undefined = undefined;
    for (const item of nodes) {
      if (item.id === active) {
        node = item;
        break;
      }
    }
    if (node === undefined) {
      return false;
    }
    const token: string = await (this.store as PanelStore).loadDeviceTokenFor(active);
    this.importUrl = node.baseUrl;
    if (token.length === 0) {
      this.appendLine(`节点 ${node.name} 没有设备令牌，请重新导入`);
      return false;
    }
    const api: PanelApi = new PanelApi(node.baseUrl);
    api.setDeviceToken(token);
    this.api = api;
    this.stream.stop();
    this.connected = false;
    this.sessions = [];
    this.approvals = [];
    this.followSession = '';
    // Session ids are host-scoped: keep neither the selection nor the "user picked"
    // latch, otherwise the new host's events are filtered against a stale id.
    this.activeSessionId = '';
    this.userPickedSession = false;
    this.lastTurn = 0;
    this.lastStep = 0;
    this.appendLine(`切换节点：${node.name}`);
    // A different host has its own sequence space and its own sessions.
    this.lastSeq = 0;
    this.resumeCursor = '';
    this.stream.setResumeSince(0);
    await this.refreshSessions();
    this.openEvents();
    return true;
  }

  private async findNode(id: string): Promise<NodeInfo | undefined> {
    if (this.store === null) {
      return undefined;
    }
    const nodes: NodeInfo[] = await (this.store as PanelStore).loadNodes();
    for (const item of nodes) {
      if (item.id === id) {
        return item;
      }
    }
    return undefined;
  }
  /**
   * Background catch-up: the OS may suspend the SSE socket, so while the page is
   * in the background we poll a tiny snapshot and keep ball/card/notification live.
   */
  private startBackgroundPoll(): void {
    if (this.pollTimer >= 0 || this.api === null) {
      return;
    }
    this.pollTimer = setInterval(() => {
      this.pollSnapshot();
    }, 3000);
  }

  private stopBackgroundPoll(): void {
    if (this.pollTimer >= 0) {
      clearInterval(this.pollTimer);
      this.pollTimer = -1;
    }
  }

  private async pollSnapshot(): Promise<void> {
    if (this.api === null || this.snapshotBusy) {
      return;
    }
    this.snapshotBusy = true;
    try {
      const snapshot: SnapshotResponse = await this.api.snapshot();
      if (!snapshot.ok) {
        return;
      }
      // Pick the busiest session: that is what the user wants to see floating.
      let target: string = this.followSession;
      let best: number = -1;
      const keys: string[] = Object.keys(snapshot.progress);
      for (const sid of keys) {
        const item: SnapshotProgress = snapshot.progress[sid];
        const score: number = (item.turn ?? 0) * 1000 + (item.step ?? 0);
        if (score > best) {
          best = score;
          target = sid;
        }
      }
      if (target.length > 0) {
        const item: SnapshotProgress | undefined = snapshot.progress[target];
        const turn: number = item === undefined || item.turn === null ? 0 : item.turn;
        const step: number = item === undefined || item.step === null ? 0 : item.step;
        const cached: SessionProgress | undefined = this.progress.get(target);
        const knownTurn: number = cached === undefined ? 0 : cached.turn;
        if (turn > knownTurn || (turn === knownTurn && step > (cached === undefined ? 0 : cached.step))) {
          const record: SessionProgress = new SessionProgress();
          record.turn = turn;
          record.step = step;
          this.progress.set(target, record);
        }
        if (!this.userPickedSession) {
          this.followSession = target;
          this.lastTurn = this.progress.get(target)?.turn ?? 0;
          this.lastStep = this.progress.get(target)?.step ?? 0;
        }
      }
      if (snapshot.latest !== null) {
        this.lastActivity = snapshot.latest.text;
      }
      // Refresh the carriers without touching the UI list (page is hidden anyway).
      if (this.ballVisible && this.ball !== null) {
        this.ball.show(this.ballTitleLine(), this.ballContentLine());
      }
      if (this.floatWindowVisible || this.pairBound) {
        this.pushCardState();
      }
      this.syncApprovalNotification();
    } catch {
      // Network blips are expected in the background; the next tick retries.
    } finally {
      this.snapshotBusy = false;
    }
  }
  onPageShow(): void {
    // Coming back from the node page may mean a different host: rebuild first and
    // skip the old-node resync, otherwise the session list keeps the old host.
    this.syncActiveNode().then((switched: boolean) => {
      if (switched) {
        return;
      }
      if (this.api !== null && this.connected) {
        this.appendLine('回到前台，重新同步');
        this.stream.setResumeSince(this.lastSeq);
        this.stream.restart();
        this.refreshSessions();
      }
    });
  }

  private flushPending(): void {
    if (this.pendingTurn !== this.lastTurn || this.pendingStep !== this.lastStep) {
      this.lastTurn = this.pendingTurn;
      this.lastStep = this.pendingStep;
      if (this.followSession.length > 0) {
        const record: SessionProgress = new SessionProgress();
        record.turn = this.lastTurn;
        record.step = this.lastStep;
        this.progress.set(this.followSession, record);
      }
      if (this.ballVisible && this.ball !== null) {
        this.ball.show(this.ballTitleLine(), this.ballContentLine());
      }
    }
    if (this.pendingApprovalQueue.length > 0 || this.resolvedApprovalQueue.length > 0) {
      const current: PendingApprovalView[] = this.approvals.slice();
      for (const view of this.pendingApprovalQueue) {
        if (!current.some((item) => item.approvalId === view.approvalId)) {
          current.push(view);
        }
      }
      const resolved: string[] = this.resolvedApprovalQueue;
      this.pendingApprovalQueue = [];
      this.resolvedApprovalQueue = [];
      const now: number = Date.now();
      // Local TTL: a card whose server-side queue entry is gone (host restart,
      // timeout) must not linger forever.
      this.approvals = current
        .filter((item) => now - item.receivedAt < APPROVAL_TTL_MS)
        .filter((item) => !resolved.includes(item.approvalId));
      if (this.floatWindowVisible || this.pairBound) {
        this.pushCardState();
      }
      // L0 fallback: whenever the floating carriers are not showing the approval,
      // the notification must carry it (and its Allow/Reject buttons).
      this.syncApprovalNotification();
      this.syncProgressNotification();
    }
    // A decision tapped in the notification arrives through the ability and must
    // be consumed on every tick — not only when new approval events happen.
    this.consumePendingDecision();
    this.publishTelemetry();
    // The float card mirrors live telemetry, so refresh it on every tick (1 Hz cap).
    if (this.floatWindowVisible || this.pairBound) {
      const nowMs: number = Date.now();
      if (nowMs - this.lastCardPushAt > 900) {
        this.lastCardPushAt = nowMs;
        this.pushCardState();
      }
    }
    if (this.pendingLines.length === 0) {
      return;
    }
    const batch: string[] = this.pendingLines;
    this.pendingLines = [];
    const next: string[] = this.events.slice();
    for (const line of batch) {
      next.push(line);
    }
    this.events = next.slice(-MAX_LOG_LINES);
    // Keep the newest line visible; without this the log silently scrolls off-screen.
    try {
      this.logScroller.scrollEdge(Edge.Bottom);
    } catch {
      // Scroller may not be attached yet on the very first flush.
    }
  }

  /** Big line: progress / approval. Small line: which session it belongs to. */
  private ballTitleLine(): string {
    if (this.approvals.length > 0) {
      return '待审批';
    }
    if (this.lastTurn === 0 && this.lastStep === 0) {
      return '待命';
    }
    const parts: string[] = [];
    if (this.lastTurn > 0) {
      parts.push(`T${this.lastTurn}`);
    }
    if (this.lastStep > 0) {
      parts.push(`S${this.lastStep}`);
    }
    return parts.join('·');
  }

  /** Small line: session hint, or the tool waiting for approval. */
  private ballContentLine(): string {
    if (this.approvals.length > 0) {
      const item: PendingApprovalView = this.approvals[0];
      return item.toolName.length > 0 ? item.toolName : '敏感操作';
    }
    const title: string = this.titleOf(this.followSession);
    if (title.length === 0) {
      return this.connected ? '已连接' : '未连接';
    }
    return title.length > 10 ? title.substring(0, 10) : title;
  }

  private ballText(): string {
    // The ball renders roughly a dozen characters, so progress goes first and the
    // session title is only a hint — otherwise the numbers never become visible.
    const title: string = this.ballTitle();
    if (this.lastTurn === 0 && this.lastStep === 0) {
      return title.length > 0 ? `${title} · 待命` : '待命';
    }
    const progress: string[] = [];
    if (this.lastTurn > 0) {
      progress.push(`T${this.lastTurn}`);
    }
    if (this.lastStep > 0) {
      progress.push(`S${this.lastStep}`);
    }
    const suffix: string = progress.join('·');
    return title.length > 0 ? `${suffix} · ${title}` : suffix;
  }

  /** Six characters of title is all the ball can afford next to the numbers. */
  private ballTitle(): string {
    const full: string = this.titleOf(this.followSession);
    return full.length > 6 ? full.substring(0, 6) : full;
  }

  private sessionLabel(): string {
    if (this.followSession.length === 0) {
      return '随时待命';
    }
    const title: string = this.shortTitle(this.followSession);
    return title.length > 0 ? title : this.followSession.substring(8, 16);
  }
  private shortTitle(sessionId: string): string {
    const full: string = this.titleOf(sessionId);
    return full.length > 12 ? `${full.substring(0, 11)}…` : full;
  }

  private titleOf(sessionId: string): string {
    if (sessionId.length === 0) {
      return '';
    }
    for (const row of this.sessions) {
      if (row.sessionId === sessionId) {
        return row.title.length > 0 ? row.title : '';
      }
    }
    return '';
  }

  private activeTitle(): string {
    for (const row of this.sessions) {
      if (row.sessionId === this.activeSessionId) {
        return row.title.length > 0 ? row.title : '(未命名)';
      }
    }
    return '';
  }

  /** Publish the current picture for the ArkWeb workspace (native → web handover). */
  private publishTelemetry(): void {    const approval: PendingApprovalView | null = this.approvals.length > 0 ? this.approvals[0] : null;
    const state: PanelTelemetry = {
      connected: this.connected,
      sessionId: this.activeSessionId,
      title: this.activeTitle(),
      turn: this.lastTurn,
      step: this.lastStep,
      status: this.ballText(),
      approvalCount: this.approvals.length,
      approvalId: approval === null ? '' : approval.approvalId,
      approvalPreview: approval === null ? '' : approval.preview,
      updatedAt: Date.now()
    };
    this.hub.publish(state);
    this.saveJournalThrottled(state);
  }

  /** Cold-start journal: cheap enough to write every 5s, never on the hot path. */
  private saveJournalThrottled(state: PanelTelemetry): void {
    const now: number = Date.now();
    if (now - this.lastJournalAt < 5000 || this.store === null) {
      return;
    }
    this.lastJournalAt = now;
    const journal: string = JSON.stringify(state);
    (this.store as PanelStore).saveJournal(journal);
  }

  private async restoreJournal(): Promise<void> {
    if (this.store === null) {
      return;
    }
    const raw: string = await (this.store as PanelStore).loadJournal();
    if (raw.length === 0) {
      return;
    }
    try {
      const saved: PanelTelemetry = JSON.parse(raw) as PanelTelemetry;
      this.lastTurn = saved.turn;
      this.lastStep = saved.step;
      if (this.activeSessionId.length === 0 && saved.sessionId.length > 0) {
        this.activeSessionId = saved.sessionId;
      }
      const ageMinutes: number = Math.max(0, Math.round((Date.now() - saved.updatedAt) / 60000));
      this.appendLine(`上次运行：${saved.status}（${ageMinutes} 分钟前）`);
      hilog.info(0x0001, 'panel', 'journal restored: %{public}s', raw);
    } catch {
      // Corrupt journal: ignore and continue.
    }
  }

  private onDarkModeChanged(): void {
    if (this.ball === null) {
      return;
    }
    this.ball.setDark(this.darkMode);
    if (this.ballVisible) {
      this.ball.show(this.ballTitleLine(), this.ballContentLine());
    }
  }
  /** 悬浮球 entry: the system ball (tapping it expands our floating card). */
  private async toggleBall(): Promise<void> {
    if (this.ball === null) {
      return;
    }
    if (this.ballVisible) {
      await this.ball.hide();
      this.ballVisible = false;
      this.ballUserStopped = true;
      this.appendLine('悬浮球已关闭');
      return;
    }
    const context: common.UIAbilityContext = getContext(this) as common.UIAbilityContext;
    const granted: boolean = await CapabilityProbe.requestFloatView(context);
    if (!granted) {
      this.appendLine('FLOAT_VIEW 未授权，点球展开卡片会失败');
    }
    this.ball.setDark(this.darkMode);
    let bound: boolean = false;
    if (this.floatView !== null && FloatViewPresenter.isSupported()) {
      const controller = await this.ball.ensureController();
      if (controller !== null) {
        bound = await this.floatView.bindTo(controller,
          this.ball.paramsForBind(this.ballTitleLine(), this.ballContentLine()));
      }
    }
    const ok: boolean = await this.ball.show(this.ballTitleLine(), this.ballContentLine());
    this.ballVisible = ok;
    this.ballUserStopped = !ok;
    this.floatWindowVisible = false;
    this.pairBound = bound;
    if (bound) {
      this.ball.clearClick();
    }
    this.appendLine(ok ? '悬浮球已显示（点球展开卡片）' : '悬浮球创建失败（见 hilog）');
  }

  /** Compact size in px (~115vp on this density); the card is the expanded size. */
  private async startGlass(): Promise<void> {
    if (this.floatView === null) {
      return;
    }
    this.pushCardState();
    const min: window.Size = FloatViewPresenter.minSize();
    const width: number = Math.max(GLASS_SIZE, min.width);
    const height: number = Math.max(GLASS_SIZE, min.height);
    const ok: boolean = await this.floatView.startGlass(width, height);
    this.floatWindowVisible = ok;
    this.ballUserStopped = !ok;
    this.appendLine(ok ? '玻璃块已显示' : '玻璃块启动失败（见 hilog）');
  }

  /** Expand / collapse the same window; the card page derives its layout from size. */
  private async resizeGlass(expand: boolean): Promise<void> {
    if (this.floatView === null || !this.floatWindowVisible) {
      return;
    }
    this.pushCardState();
    if (expand) {
      await this.floatView.resize(CARD_WIDTH, CARD_HEIGHT);
    } else {
      await this.floatView.resize(GLASS_SIZE, GLASS_SIZE);
    }
  }

  /** Ball tap: hand the launch to the system through a tappable notification. */
  private async handleBallClick(): Promise<void> {
    hilog.info(0x0001, 'panel', 'ball click received');
    // When bound, the system expands the card itself; touching the float view here
    // would fail with 1300033 because we are in the background.
    if (this.pairBound) {
      this.appendLine('点球展开卡片（系统接管）');
      return;
    }
    if (this.floatView !== null && !this.floatWindowVisible) {
      this.pushCardState();
      const ok: boolean = await this.floatView.startStandalone();
      if (ok) {
        this.floatWindowVisible = true;
        return;
      }
    }
    const line: string = ` · `;
    if (this.notifier !== null) {
      const ok: boolean = await this.notifier.publishEntry(`点击回到面板 · ${line}`);
      this.appendLine(ok ? '已推送通知：点通知栏回到面板' : '通知推送失败');
    }
  }
  private async toggleFloatWindow(): Promise<void> {
    if (this.ball === null || this.floatView === null) {
      return;
    }
    if (this.floatWindowVisible) {
      await this.floatView.stop();
      this.floatWindowVisible = false;
      this.ballVisible = false;
      this.appendLine('闪控窗已关闭');
      return;
    }
    if (!FloatViewPresenter.isSupported()) {
      this.appendLine('闪控窗不可用（需 API 26 + FLOAT_VIEW 授权）');
      return;
    }
    const context: common.UIAbilityContext = getContext(this) as common.UIAbilityContext;
    const granted: boolean = await CapabilityProbe.requestFloatView(context);
    this.appendLine(`FLOAT_VIEW 授权：${granted ? '已允许' : '未允许'}`);
    const controller = await this.ball.ensureController();
    if (controller === null) {
      this.appendLine('悬浮球控制器创建失败，无法绑定闪控窗');
      return;
    }
    this.pushCardState();
    const ok: boolean = await this.floatView.start(controller, this.ball.params(this.ballTitleLine(), this.ballContentLine()));
    this.floatWindowVisible = ok;
    this.ballVisible = ok;
    this.appendLine(ok ? '闪控窗已启动（球↔窗已绑定）' : '闪控窗启动失败（见 hilog）');
  }

  /** Feed the float card window: LocalStorage at creation, emitter for live updates. */
  private pushCardState(): void {
    const approval: PendingApprovalView | null = this.approvals.length > 0 ? this.approvals[0] : null;
    const state: CardStatePayload = new CardStatePayload();
    state.line = this.ballText();
    state.status = this.approvals.length > 0 ? '等待审批' : (this.connected ? '运行中' : '未连接');
    state.preview = approval === null ? '' : approval.preview;
    state.approvalId = approval === null ? '' : approval.approvalId;
    state.title = this.sessionLabel();
    state.metrics = this.lastTurn > 0 ? `T${this.lastTurn} · S${this.lastStep}` : '待命';
    state.activity = this.lastActivity;
    state.events = this.events.slice(0, 3).join('\n');
    state.tokens = this.sessions.length > 0 ? `${this.sessions.length} 个会话` : '';
    state.pending = this.approvals.length > 0 ? `${this.approvals.length} 项待审批` : '';
    state.sessionShort = this.followSession.length > 6 ? this.followSession.substring(0, 6) : this.followSession;
    if (this.floatView !== null) {
      this.floatView.update(state.toMap());
    }
    CardStateStore.save(getContext(this) as common.Context, state.toMap());
    console.info(`[panel] card save title=${state.title} metrics=${state.metrics}`);
    try {
      emitter.emit({ eventId: 1003 }, { data: state });
    } catch {
      // Card window may be gone; nothing to update.
    }
  }

  /** Launch the panel; background launch is restricted, so fall back to a notification. */
  private async bringToFront(): Promise<void> {
    try {
      const context: common.UIAbilityContext = getContext(this) as common.UIAbilityContext;
      await context.startAbility({
        bundleName: context.abilityInfo.bundleName,
        abilityName: context.abilityInfo.name
      });
      return;
    } catch (error) {
      const businessError: BusinessError = error as BusinessError;
      hilog.warn(0x0001, 'panel', 'bringToFront blocked: %{public}s', String(businessError.code));
    }
    if (this.notifier !== null) {
      const ok: boolean = await this.notifier.publishEntry(`点击回到面板 · ${this.ballTitleLine()} · ${this.ballContentLine()}`);
      this.appendLine(ok ? '起不来前台，已推送通知：点通知回面板' : '通知推送失败');
    }
  }
  private syncApprovalNotification(): void {
    if (this.notifier === null) {
      return;
    }
    if (this.approvals.length === 0) {
      return;
    }
    const item: PendingApprovalView = this.approvals[0];
    for (const stale of this.notifiedApprovals) {
      if (!this.approvals.some((pending) => pending.approvalId === stale)) {
        // The queue settled (approved, rejected or timed out): drop the reminder.
        this.notifier.cancel(stale);
        this.notifiedApprovals.splice(this.notifiedApprovals.indexOf(stale), 1);
      }
    }
    if (this.floatWindowVisible && this.ballVisible) {
      return;
    }
    if (item.approvalId === this.notifiedApprovalId) {
      return;
    }
    this.notifiedApprovalId = item.approvalId;
    this.notifiedApprovals.push(item.approvalId);
    this.notifier.publishApproval(item.approvalId, item.toolName, item.preview);
    this.appendLine(`已推送审批通知：${item.approvalId}`);
  }

  private syncProgressNotification(): void {
    if (this.notifier === null) {
      return;
    }
    if (this.floatWindowVisible || this.ballVisible) {
      return;
    }
    const now: number = Date.now();
    if (now - this.lastNotifyAt < 30000) {
      return;
    }
    this.lastNotifyAt = now;
    this.notifier.publishProgress('session', {
      title: `DSH · ${this.connected ? '已连接' : '未连接'}`,
      text: this.ballText()
    });
  }

  /** Notification buttons relaunch the ability with `panelDecision` parameters. */
  private consumePendingDecision(): void {
    const raw: string = AppStorage.get<string>('pendingDecision') ?? '';
    if (raw.length === 0) {
      return;
    }
    AppStorage.setOrCreate<string>('pendingDecision', '');
    const parts: string[] = raw.split('|');
    if (parts.length !== 2 || parts[0].length === 0) {
      return;
    }
    const view: PendingApprovalView = new PendingApprovalView();
    view.approvalId = parts[0];
    view.receivedAt = Date.now();
    this.appendLine(`通知栏决策：${parts[0]} → ${parts[1]}`);
    this.decide(view, parts[1]);
  }

  private subscribeCardEvents(): void {
    try {
      emitter.on({ eventId: 1001 }, (data: emitter.EventData) => {
        const payload = data.data as Record<string, string>;
        const approvalId: string = payload.approvalId ?? '';
        const decision: string = payload.decision ?? 'REJECT';
        if (approvalId.length === 0) {
          return;
        }
        const view: PendingApprovalView = new PendingApprovalView();
        view.approvalId = approvalId;
        view.receivedAt = Date.now();
        this.decide(view, decision);
      });
      emitter.on({ eventId: 1004 }, (data: emitter.EventData) => {
        const payload = data.data as Record<string, string>;
        const action: string = payload.decision ?? '';
        this.resizeGlass(action === 'expand');
      });      emitter.on({ eventId: 1002 }, () => {
        this.appendLine('闪控窗请求回到主界面');
        this.bringToFront();
      });
    } catch (error) {
      this.appendLine(`事件订阅失败：${this.describe(error)}`);
    }
  }

  private async toggleKeepAlive(): Promise<void> {
    if (this.keepAlive === null) {
      return;
    }
    if (this.keepAlive.isRunning()) {
      await this.keepAlive.stop();
      this.keepAliveUserStopped = true;
      this.keepAliveMode = '';
      this.appendLine('保活已停止');
      return;
    }
    const mode: string = await this.keepAlive.start();
    this.keepAliveUserStopped = false;
    this.keepAliveMode = this.keepAlive.isRunning() ? mode : '';
    this.appendLine(this.keepAlive.isRunning() ? `保活已启动：${mode}` : `保活失败：${mode}`);
  }

  private async loadSaved(pendingImport: string = ''): Promise<void> {
    if (this.store === null) {
      return;
    }
    try {
      // A deep link always feeds the WebView's cookie exchange, even when the
      // stored device token already works — the launch token is the only way the
      // ArkWeb container can authenticate.
      if (pendingImport.length > 0) {
        const intent: ImportIntent | null = this.parseIntent(pendingImport);
        if (intent !== null) {
          await this.store.saveStartupToken(intent.startupToken);
          await this.store.saveBaseUrl(intent.baseUrl);
        }
      }
      const baseUrl: string = await this.store.loadBaseUrl();
      if (baseUrl.length > 0 && this.importUrl.length === 0) {
        this.importUrl = baseUrl;
      }
      const token: string = await this.store.loadDeviceToken();
      this.activeSessionId = await this.store.loadLastSession();
      // Prefer the stored device token: a deep link's launch token dies with the
      // host process, so re-pairing on every launch would fail after a restart.
      if (baseUrl.length > 0 && token.length > 0) {
        const api: PanelApi = new PanelApi(baseUrl);
        api.setDeviceToken(token);
        this.api = api;
        this.status = '已保存设备令牌，正在同步…';
        await this.refreshSessions();
        this.openEvents();
        if (this.connected) {
          return;
        }
        this.status = '设备令牌已失效，改用启动令牌重新配对…';
      }
      if (pendingImport.length > 0) {
        await this.connect();
      }
    } catch (error) {
      this.status = `读取本地状态失败：${this.describe(error)}`;
    }
  }

  /** `https://host/?token=...`, `dsh://connect?endpoint=…&token=…`, or a bare token. */
  private parseIntent(raw: string): ImportIntent | null {
    const text: string = raw.trim();
    if (text.length === 0) {
      return null;
    }
    if (text.startsWith('dsh://')) {
      const endpointMatch: RegExpMatchArray | null = text.match(/[?&]endpoint=([^&]+)/);
      const tokenMatch: RegExpMatchArray | null = text.match(/[?&]token=([A-Za-z0-9._~+/=-]+)/);
      if (endpointMatch === null || tokenMatch === null) {
        return null;
      }
      const endpoint: string = decodeURIComponent(endpointMatch[1]).replace(/\/+$/, '');
      return { baseUrl: endpoint, startupToken: tokenMatch[1] };
    }
    const tokenMatch: RegExpMatchArray | null = text.match(/[?&]token=([A-Za-z0-9._~+/=-]+)/);
    const startupToken: string = tokenMatch === null ? text : tokenMatch[1];
    let baseUrl: string = '';
    if (text.startsWith('http://') || text.startsWith('https://')) {
      const cut: number = text.indexOf('?');
      baseUrl = cut < 0 ? text : text.substring(0, cut);
    } else if (!text.includes('://') && text.includes('.')) {
      baseUrl = `https://${text}`;
    }
    if (baseUrl.length === 0) {
      return null;
    }
    return { baseUrl: baseUrl.replace(/\/+$/, ''), startupToken: startupToken };
  }

  /** Scan the QR printed by dsh web and import it straight away. */
  private async scanImport(): Promise<void> {
    try {
      const options: scanBarcode.ScanOptions = {
        scanTypes: [scanCore.ScanType.QR_CODE, scanCore.ScanType.ALL],
        enableMultiMode: false,
        enableAlbum: true
      };
      const context: common.UIAbilityContext = getContext(this) as common.UIAbilityContext;
      const result = await scanBarcode.startScanForResult(context, options);
      if (result.originalValue.length > 0) {
        this.importUrl = result.originalValue;
        await this.connect();
      }
    } catch (error) {
      this.appendLine(`扫码取消或失败：${this.describe(error)}`);
    }
  }
  private async connect(): Promise<void> {
    if (this.store === null || this.busy) {
      return;
    }
    const intent: ImportIntent | null = this.parseIntent(this.importUrl);
    if (intent === null) {
      this.status = '链接无效：需要一个 https://host/?token=… 形式的地址，或直接粘贴 token';
      return;
    }
    this.busy = true;
    this.status = '正在配对…';
    try {
      const api: PanelApi = new PanelApi(intent.baseUrl);
      const pair = await api.pairWithToken(intent.startupToken, 'HarmonyOS Phone');
      if (!pair.ok || pair.deviceToken === undefined) {
        this.status = `配对失败：${pair.code ?? 'UNKNOWN'}`;
        return;
      }
      api.setDeviceToken(pair.deviceToken);
      await this.store.saveBaseUrl(intent.baseUrl);
      await this.store.saveDeviceToken(pair.deviceToken);
      // The WebView container needs the launch token to mint DSH's browser cookie.
      await this.store.saveStartupToken(intent.startupToken);
      this.api = api;
      this.status = `已配对 ${pair.device?.id ?? ''}`;
      await this.refreshSessions();
      this.openEvents();
    } catch (error) {
      this.status = `配对异常：${this.describe(error)}`;
    } finally {
      this.busy = false;
    }
  }

  private async refreshSessions(): Promise<void> {
    if (this.api === null) {
      return;
    }
    try {
      const bootstrap = await this.api.bootstrap();
      if (!bootstrap.ok) {
        this.status = `bootstrap 失败：${bootstrap.code ?? 'UNKNOWN'}`;
        return;
      }
      const list: SessionRow[] = [];
      const source: SessionSummary[] = bootstrap.sessions ?? [];
      for (const item of source) {
        const row: SessionRow = new SessionRow();
        row.sessionId = item.sessionId;
        row.title = item.title ?? '(未命名)';
        row.running = item.running;
        row.steps = item.sessionStats?.steps ?? 0;
        row.updatedAt = item.updatedAt ?? 0;
        list.push(row);
      }
      list.sort((a: SessionRow, b: SessionRow) => b.updatedAt - a.updatedAt);
      this.sessions = list.slice(0, 20);
      this.sessionCount = list.length;
      this.connected = true;
      // The host is the authority on pending approvals: drop local cards it no
      // longer knows about (timeout, host restart, decided elsewhere).
      const pending: PendingApprovalView[] = [];
      const serverPending: PendingApproval[] = bootstrap.pendingApprovals ?? [];
      for (const item of serverPending) {
        const view: PendingApprovalView = new PendingApprovalView();
        view.approvalId = item.approvalId;
        view.toolName = item.toolName;
        view.preview = item.preview;
        view.sessionId = item.sessionId;
        view.receivedAt = Date.now();
        pending.push(view);
      }
      // Prefer the session the user last touched; otherwise the freshest one.
      if (this.followSession.length === 0) {
        const preferred: string = this.activeSessionId.length > 0
          ? this.activeSessionId
          : (this.sessions.length > 0 ? this.sessions[0].sessionId : '');
        this.followSession = preferred;
        const saved: SessionProgress | undefined = this.progress.get(preferred);
        this.lastTurn = saved === undefined ? 0 : saved.turn;
        this.lastStep = saved === undefined ? 0 : saved.step;
      }
      this.approvals = pending;
      const version: string = bootstrap.host?.dshVersion ?? '';
      this.status = version.length > 0 ? `已连接 · ${version} · ${list.length} 个会话` : `已连接 · ${list.length} 个会话`;
      // Background delivery is the product's whole value, so keep-alive starts with
      // the first successful connection unless the user explicitly turned it off.
      if (!this.keepAliveUserStopped && this.keepAlive !== null && !this.keepAlive.isRunning()) {
        const mode: string = await this.keepAlive.start();
        this.keepAliveMode = this.keepAlive.isRunning() ? mode : '';
        this.appendLine(this.keepAlive.isRunning() ? `自动保活：${mode}` : `自动保活失败：${mode}`);
      }
      // System ball, bound to our floating card. Created while the app is still in
      // the foreground: the system rejects float windows created later, and the
      // ball is the only carrier that survives the app going to the background.
      if (!this.ballUserStopped && !this.ballVisible && this.ball !== null && this.ball.isSupported()) {
        this.ball.setDark(this.darkMode);
        let bound: boolean = false;
        if (this.floatView !== null && FloatViewPresenter.isSupported()) {
          const controller = await this.ball.ensureController();
          if (controller !== null) {
            bound = await this.floatView.bindTo(controller,
              this.ball.paramsForBind(this.ballTitleLine(), this.ballContentLine()));
          }
        }
        const shown: boolean = await this.ball.show(this.ballTitleLine(), this.ballContentLine());
        this.ballVisible = shown;
        this.pairBound = bound;
        if (bound) {
          this.ball.clearClick();
        }
        this.appendLine(shown ? '悬浮球已就绪（点球展开卡片）' : '悬浮球创建失败（见 hilog）');
      }
    } catch (error) {
      this.status = `同步失败：${this.describe(error)}`;
    }
  }

  private openEvents(): void {
    if (this.api === null) {
      this.appendLine('! 未连接，无法订阅事件');
      return;
    }
    const scope: string = this.userPickedSession ? this.activeSessionId : '';
    this.appendLine(`SSE 订阅中… (${scope.length === 0 ? '全部会话' : scope})`);
    this.stream.start((this.api as PanelApi).getBaseUrl(), this.api.getDeviceToken(), scope, this.resumeCursor);
  }

  private onStreamStatus(state: string, detail: string): void {
    if (state === 'connected') {
      this.reconnectDelayMs = 2000;
      return;
    }
    if (state === 'reconnecting') {
      this.appendLine(`SSE 断开（${detail}），自动重连中…`);
      return;
    }
    if (state === 'network-restored') {
      this.appendLine('网络恢复，立即重连');
      return;
    }
    if (state === 'offline') {
      this.appendLine(`! 网络已断开：${detail}`);
      return;
    }
    if (state === 'worker-error' || state === 'worker-create-failed' || state === 'worker-post-failed') {
      this.appendLine(`! Worker ${state}: ${detail}`);
    }
  }

  /** Kept for the deep-link/refresh paths that used to reopen the stream. */
  private scheduleReconnect(): void {
    // Reconnection now lives inside the worker; nothing to schedule here.
  }

  private stopEvents(): void {
    this.stream.stop();
  }

  private appendEvent(type: string, data: string): void {
    let payload: PanelEventPayload = {};
    this.eventSessionId = '';
    try {
      const parsed: PanelEvent = JSON.parse(data) as PanelEvent;
      payload = parsed.payload ?? {};
      this.eventSessionId = parsed.sessionId ?? '';
      // Resume replays the host ring; the envelope seq is the de-duplicator
      // (payload.seq belongs to the DSH record and is usually null).
      const envelopeSeq: number = Number(parsed.seq ?? 0);
      if (envelopeSeq > 0) {
        if (envelopeSeq <= this.lastSeq) {
          return;
        }
        this.lastSeq = envelopeSeq;
      }
      if (type === 'approval/request' || type === 'approval/asked') {
        const view: PendingApprovalView = new PendingApprovalView();
        view.approvalId = payload.approvalId ?? '';
        view.toolName = payload.toolName ?? payload.tool ?? 'tool';
        view.preview = payload.preview ?? payload.reason ?? '';
        view.riskLevel = payload.riskLevel ?? '';
        view.sessionId = parsed.sessionId;
        view.receivedAt = Date.now();
        if (view.approvalId.length > 0) {
          this.pendingApprovalQueue.push(view);
        }
      } else if (type === 'approval/resolved' || type === 'approval/decided') {
        const id: string = payload.approvalId ?? '';
        if (id.length > 0) {
          this.resolvedApprovalQueue.push(id);
        }
      }
    } catch {
      // Keep the raw line when the frame is not JSON.
    }
    const parts: string[] = [type];
    const sid: string = this.eventSessionId;
    if (sid.length > 0 && this.followSession.length === 0) {
      this.followSession = sid;
    }
    // A fresh session takes over the ball unless the user pinned another one.
    if (type === 'session/created' && sid.length > 0 && !this.userPickedSession && sid !== this.followSession) {
      this.followSession = sid;
      this.pendingTurn = 0;
      this.pendingStep = 0;
    }
    // Work in progress anywhere becomes "the" followed session: a floating ball
    // stuck on an idle session is useless. An explicit tap still wins.
    const running: boolean = payload.turn !== undefined || payload.step !== undefined;
    if (running && sid.length > 0 && !this.userPickedSession && sid !== this.followSession) {
      this.followSession = sid;
      const cached: SessionProgress | undefined = this.progress.get(sid);
      this.pendingTurn = cached === undefined ? 0 : cached.turn;
      this.pendingStep = cached === undefined ? 0 : cached.step;
      this.lastTurn = this.pendingTurn;
      this.lastStep = this.pendingStep;
    }
    const follows: boolean = sid.length === 0 || sid === this.followSession;
    if (payload.turn !== undefined) {
      parts.push(`turn ${payload.turn}`);
      if (follows) {
        this.pendingTurn = payload.turn;
      }
    }
    if (payload.step !== undefined) {
      parts.push(`step ${payload.step}`);
      if (follows) {
        this.pendingStep = payload.step;
      }
    }
    if (payload.tool !== undefined) {
      parts.push(`${payload.tool}`);
    }
    if (payload.preview !== undefined) {
      parts.push(payload.preview);
    } else if (payload.summary !== undefined) {
      parts.push(payload.summary);
    }
    if (payload.tokens !== undefined) {
      parts.push(`${payload.tokens} tok`);
    }
    if (payload.outcome !== undefined) {
      parts.push(`→ ${payload.outcome}`);
    }
    const summary: string = parts.join(' · ');
    // The float card shows the newest activity, so keep it separate from the log.
    this.lastActivity = summary.length > 90 ? `${summary.substring(0, 88)}…` : summary;
    this.appendLine(summary);
  }

  private appendLine(line: string): void {
    this.pendingLines.push(`${new Date().toLocaleTimeString()}  ${line}`);
  }

  private async probeCapability(): Promise<void> {
    this.status = '正在探测能力…';
    try {
      const context: common.UIAbilityContext = getContext(this) as common.UIAbilityContext;
      const report: CapabilityReport = await CapabilityProbe.probe(context);
      this.capability =
        `API ${report.apiLevel} · SessionManager ${report.sessionManager ? '✓' : '✗'} · ` +
        `球 ${report.floatingBallEnabled ? '✓' : '✗'}(${report.permissionFloatBall ? 'perm✓' : 'perm✗'}) · ` +
        `窗 ${report.floatViewAvailable ? (report.floatViewEnabled ? '✓' : '✗') : 'n/a'}` +
        `(${report.permissionFloatView ? 'perm✓' : 'perm✗'}) · ` +
        `保活 ${report.permissionKeepAlive ? '✓' : '✗'}/${report.permissionKeepAliveSystem ? '✓' : '✗'} · ` +
        `实况窗 ${report.liveViewEnabled ? '✓' : '✗'}`;
      if (report.notes.length > 0) {
        this.capability += `\n${report.notes.join('\n')}`;
      }
      this.status = '能力探测完成';
    } catch (error) {
      this.status = `能力探测失败：${this.describe(error)}`;
    }
  }

  private async abortActive(): Promise<void> {
    if (this.api === null || this.activeSessionId.length === 0) {
      this.status = '没有选中的会话';
      return;
    }
    try {
      const result = await this.api.abort(this.activeSessionId);
      this.appendLine(result.ok ? `已请求停止 ${this.activeSessionId}` : `停止失败 ${result.code ?? ''}`);
    } catch (error) {
      this.appendLine(`停止异常：${this.describe(error)}`);
    }
  }

  private async decide(item: PendingApprovalView, decision: string): Promise<void> {
    if (this.api === null) {
      return;
    }
    try {
      const result = await this.api.confirm(item.approvalId, decision, this.isRemembered(item.approvalId));
      this.appendLine(result.ok ? `审批 ${item.approvalId} → ${decision}` : `审批失败：${result.code ?? 'UNKNOWN'}`);
      this.resolvedApprovalQueue.push(item.approvalId);
    } catch (error) {
      this.appendLine(`审批异常：${this.describe(error)}`);
    }
  }

  private selectSession(row: SessionRow): void {
    this.activeSessionId = row.sessionId;
    this.userPickedSession = true;
    // Follow the picked session: its own counters, never the previous one's.
    this.followSession = row.sessionId;
    const saved: SessionProgress | undefined = this.progress.get(row.sessionId);
    this.pendingTurn = saved === undefined ? 0 : saved.turn;
    this.pendingStep = saved === undefined ? 0 : saved.step;
    this.lastTurn = this.pendingTurn;
    this.lastStep = this.pendingStep;
    if (this.ballVisible && this.ball !== null) {
      this.ball.show(this.ballTitleLine(), this.ballContentLine());
    }
    this.publishTelemetry();
    if (this.store !== null) {
      this.store.saveLastSession(row.sessionId);
    }
    this.events = [];
    this.openEvents();
    this.status = `已选中：${row.title}`;
  }

  private describe(error: Object): string {
    const businessError: BusinessError = error as BusinessError;
    if (businessError.code !== undefined) {
      return `${businessError.code}: ${businessError.message}`;
    }
    return `${error}`;
  }


  // ── presentation helpers ────────────────────────────────────────────────

  private riskColor(level: string): ResourceColor {
    if (level === 'CRITICAL' || level === 'HIGH') {
      return Theme.danger;
    }
    if (level === 'MEDIUM') {
      return Theme.warning;
    }
    return Theme.success;
  }

  private riskSoft(level: string): ResourceColor {
    if (level === 'CRITICAL' || level === 'HIGH') {
      return Theme.dangerSoft;
    }
    if (level === 'MEDIUM') {
      return Theme.warningSoft;
    }
    return Theme.successSoft;
  }

  private riskLabel(level: string): string {
    if (level === 'CRITICAL') {
      return '极高风险';
    }
    if (level === 'HIGH') {
      return '高风险';
    }
    if (level === 'MEDIUM') {
      return '中风险';
    }
    if (level === 'LOW') {
      return '低风险';
    }
    return '待确认';
  }

  private remainingSeconds(item: PendingApprovalView): number {
    const deadline: number = item.receivedAt + APPROVAL_TTL_MS;
    const left: number = Math.floor((deadline - Date.now()) / 1000);
    return left > 0 ? left : 0;
  }

  private isRemembered(id: string): boolean {
    return this.rememberIds.indexOf(id) >= 0;
  }

  private toggleRemember(id: string): void {
    const index: number = this.rememberIds.indexOf(id);
    if (index >= 0) {
      this.rememberIds.splice(index, 1);
    } else {
      this.rememberIds.push(id);
    }
    // Touch state so the checkbox repaints.
    this.rememberIds = this.rememberIds.slice();
  }

  private statusDotColor(): ResourceColor {
    if (!this.connected) {
      return Theme.textTertiary;
    }
    return this.keepAliveMode.length > 0 ? Theme.success : Theme.brand;
  }

  // ── UI ──────────────────────────────────────────────────────────────────

  @Builder
  private Header() {
    Column({ space: 10 }) {
      Row({ space: 10 }) {
        Column({ space: 3 }) {
          Text('DSH 面板')
            .fontSize(26)
            .fontWeight(FontWeight.Bold)
            .fontColor(Theme.textPrimary)
          Text(this.connected ? `${this.sessionCount} 个会话 · 已连接` : '未连接')
            .fontSize(12)
            .fontColor(Theme.textSecondary)
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)

        Row({ space: 6 }) {
          Circle({ width: 7, height: 7 }).fill(this.statusDotColor())
          Text(this.keepAliveMode.length > 0 ? '运行中' : (this.connected ? '在线' : '离线'))
            .fontSize(12)
            .fontWeight(FontWeight.Medium)
            .fontColor(this.connected ? Theme.textPrimary : Theme.textSecondary)
        }
        .padding({ left: 10, right: 12, top: 6, bottom: 6 })
        .backgroundColor(Theme.card)
        .borderRadius(Theme.radiusPill)
        .border({ width: 1, color: Theme.border })
      }
      .width('100%')

      Row({ space: 8 }) {
        Row({ space: 6 }) {
          Circle({ width: 5, height: 5 }).fill(Theme.textTertiary)
          Text(this.importUrl.length > 0 ? this.shortNode(this.importUrl) : '未绑定节点')
            .fontSize(12)
            .fontColor(Theme.textSecondary)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
        .padding({ left: 10, right: 12, top: 5, bottom: 5 })
        .backgroundColor(Theme.card)
        .borderRadius(Theme.radiusPill)
        .border({ width: 1, color: Theme.border })
        .layoutWeight(1)
      }
      .width('100%')
    }
    .width('100%')
    .padding({ left: Theme.pagePadding, right: Theme.pagePadding, top: 14, bottom: 8 })
  }

  private shortNode(url: string): string {
    // The import field may hold either a deep link or a plain endpoint.
    const marker: number = url.indexOf('endpoint=');
    if (marker >= 0) {
      const value: string = decodeURIComponent(url.substring(marker + 9).split('&')[0]);
      return this.shortNode(value);
    }
    const stripped: string = url.replace('dsh://', '').replace('https://', '').replace('http://', '');
    const cut: number = stripped.indexOf('/');
    return cut > 0 ? stripped.substring(0, cut) : stripped;
  }

  @Builder
  private StatusCard() {
    Column({ space: 12 }) {
      Row({ space: 8 }) {
        Text(this.lastTurn > 0 ? `Turn ${this.lastTurn}` : '待命中')
          .fontSize(32)
          .fontWeight(FontWeight.Bold)
          .fontColor(Theme.textOnBrand)
        Blank()
        Text(this.lastStep > 0 ? `Step ${this.lastStep}` : '—')
          .fontSize(14)
          .fontWeight(FontWeight.Medium)
          .fontColor(Theme.textOnBrand)
          .padding({ left: 12, right: 12, top: 5, bottom: 5 })
          .backgroundColor(Theme.pillOnBrand)
          .borderRadius(Theme.radiusPill)
      }
      .width('100%')

      Row({ space: 8 }) {
        Text(this.sessionLabel())
          .fontSize(13)
          .fontColor(Theme.textOnBrandDim)
          .layoutWeight(1)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        if (this.activeSessionId.length > 0) {
          Text(this.approvals.length > 0 ? '待审批' : '运行中')
            .fontSize(11)
            .fontColor(Theme.textOnBrandDim)
            .padding({ left: 10, right: 10, top: 4, bottom: 4 })
            .backgroundColor(Theme.pillOnBrand)
            .borderRadius(Theme.radiusPill)
        }
      }
      .width('100%')
    }
    .width('100%')
    .padding(18)
    .borderRadius(Theme.radiusCard)
    .linearGradient({
      angle: 135,
      colors: [[Theme.heroFrom, 0.0], [Theme.heroTo, 1.0]]
    })
    .shadow({ radius: 18, color: '#1A0A59F7', offsetX: 0, offsetY: 8 })
  }

  @Builder
  private QuickActions() {
    Row({ space: 10 }) {
      this.ActionPill('悬浮球', this.ballVisible, Theme.brand, (): void => {
        this.toggleBall();
      })
      this.ActionPill('闪控窗', this.floatWindowVisible, Theme.brand, (): void => {
        this.toggleFloatWindow();
      })
      this.ActionPill('保活', this.keepAliveMode.length > 0, Theme.success, (): void => {
        this.toggleKeepAlive();
      })
      this.ActionPill('网页', false, Theme.brand, (): void => {
        router.pushUrl({ url: 'pages/Browse' });
      })
    }
    .width('100%')
  }

  /** A tile with a coloured dot: reads as a status + toggle, not a bare button. */
  @Builder
  private ActionPill(label: string, active: boolean, accent: ResourceColor, action: () => void) {
    Column({ space: 6 }) {
      Circle({ width: 10, height: 10 }).fill(active ? accent : Theme.divider)
      Text(label)
        .fontSize(12)
        .fontWeight(active ? FontWeight.Medium : FontWeight.Normal)
        .fontColor(active ? Theme.textPrimary : Theme.textSecondary)
    }
    .height(60)
    .layoutWeight(1)
    .justifyContent(FlexAlign.Center)
    .backgroundColor(Theme.card)
    .borderRadius(14)
    .border({ width: 1, color: active ? accent : Theme.border })
    .onClick(action)
  }

  @Builder
  private ApprovalCardView(item: PendingApprovalView) {
    Column({ space: 10 }) {
      Row({ space: 8 }) {
        Text(this.riskLabel(item.riskLevel))
          .fontSize(11)
          .fontColor(this.riskColor(item.riskLevel))
          .padding({ left: 8, right: 8, top: 3, bottom: 3 })
          .backgroundColor(this.riskSoft(item.riskLevel))
          .borderRadius(8)
        Text(item.toolName)
          .fontSize(13)
          .fontWeight(FontWeight.Medium)
          .fontColor(Theme.textPrimary)
          .layoutWeight(1)
        Text(`${this.remainingSeconds(item)}s`)
          .fontSize(12)
          .fontColor(this.remainingSeconds(item) < 30 ? Theme.danger : Theme.textTertiary)
      }
      .width('100%')

      Text(item.preview.length === 0 ? '(无命令详情)' : item.preview)
        .fontSize(12)
        .fontFamily('monospace')
        .fontColor(Theme.textPrimary)
        .maxLines(3)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .width('100%')
        .padding(10)
        .backgroundColor(Theme.cardAlt)
        .borderRadius(10)

      Row({ space: 6 }) {
        Toggle({ type: ToggleType.Checkbox, isOn: this.isRemembered(item.approvalId) })
          .onChange(() => {
            this.toggleRemember(item.approvalId);
          })
          .width(20)
          .height(20)
        Text('记住这个选择')
          .fontSize(12)
          .fontColor(Theme.textSecondary)
        Blank()
        Text('拒绝')
          .fontSize(13)
          .fontColor(Theme.danger)
          .height(34)
          .padding({ left: 18, right: 18 })
          .backgroundColor(Theme.dangerSoft)
          .borderRadius(10)
          .onClick(() => {
            this.decide(item, 'REJECT');
          })
        Text('允许')
          .fontSize(13)
          .fontWeight(FontWeight.Medium)
          .fontColor(Theme.textOnBrand)
          .height(34)
          .padding({ left: 20, right: 20 })
          .backgroundColor(Theme.brand)
          .borderRadius(10)
          .onClick(() => {
            this.decide(item, 'APPROVE');
          })
      }
      .width('100%')
    }
    .width('100%')
    .padding(14)
    .backgroundColor(Theme.card)
    .borderRadius(Theme.radiusCard)
    .border({ width: 1, color: this.riskSoft(item.riskLevel) })
  }

  @Builder
  private SectionTitle(text: string, trailing: string) {
    Row({ space: 8 }) {
      Rect()
        .width(3)
        .height(13)
        .radius(2)
        .fill(Theme.brand)
      Text(text)
        .fontSize(15)
        .fontWeight(FontWeight.Medium)
        .fontColor(Theme.textPrimary)
      Blank()
      if (trailing.length > 0) {
        Text(trailing)
          .fontSize(12)
          .fontColor(Theme.textTertiary)
      }
    }
    .width('100%')
    .padding({ top: 6, bottom: 2 })
  }

  @Builder
  private OverviewTab() {
    Scroll() {
      Column({ space: Theme.gap }) {
        this.StatusCard()

        if (this.approvals.length > 0) {
          this.SectionTitle('待审批', `${this.approvals.length} 项`)
          ForEach(this.approvals, (item: PendingApprovalView) => {
            this.ApprovalCardView(item)
          }, (item: PendingApprovalView) => item.approvalId + '-' + this.tick)
        }

        this.SectionTitle('运行信息', '')
        Column({ space: 0 }) {
          this.InfoLineNode()
          Divider().color(Theme.divider).strokeWidth(1)
          this.InfoLineKeepAlive()
          Divider().color(Theme.divider).strokeWidth(1)
          this.InfoLineBalls()
          Divider().color(Theme.divider).strokeWidth(1)
          this.InfoLineWindows()
          Divider().color(Theme.divider).strokeWidth(1)
          this.InfoLineCapability()
          Divider().color(Theme.divider).strokeWidth(1)
          this.InfoLineStatus()
        }
        .width('100%')
        .padding({ left: 14, right: 14, top: 4, bottom: 4 })
        .backgroundColor(Theme.card)
        .borderRadius(Theme.radiusCard)
      }
      .width('100%')
      .padding({ left: Theme.pagePadding, right: Theme.pagePadding, bottom: 24 })
    }
    .scrollBar(BarState.Off)
    .align(Alignment.Top)
    .width('100%')
    .layoutWeight(1)
  }

  /** Each row reads one state field directly, so updates repaint immediately. */
  @Builder
  private InfoRowView(label: string) {
    Text(label)
      .fontSize(13)
      .fontColor(Theme.textSecondary)
      .width(58)
  }

  @Builder
  private InfoLineNode() {
    Row({ space: 10 }) {
      this.InfoRowView('节点')
      Text(this.importUrl.length > 0 ? this.shortNode(this.importUrl) : '—')
        .fontSize(13)
        .fontColor(Theme.textPrimary)
        .layoutWeight(1)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
    }
    .width('100%')
    .padding({ top: 9, bottom: 9 })
  }

  @Builder
  private InfoLineKeepAlive() {
    Row({ space: 10 }) {
      this.InfoRowView('保活')
      Text(this.keepAliveMode.length > 0 ? this.keepAliveMode : '未开启')
        .fontSize(13)
        .fontColor(this.keepAliveMode.length > 0 ? Theme.success : Theme.textSecondary)
        .layoutWeight(1)
    }
    .width('100%')
    .padding({ top: 9, bottom: 9 })
  }

  @Builder
  private InfoLineBalls() {
    Row({ space: 10 }) {
      this.InfoRowView('悬浮球')
      Text(this.ballVisible ? '已显示' : '未显示')
        .fontSize(13)
        .fontColor(this.ballVisible ? Theme.textPrimary : Theme.textSecondary)
        .layoutWeight(1)
    }
    .width('100%')
    .padding({ top: 9, bottom: 9 })
  }

  @Builder
  private InfoLineWindows() {
    Row({ space: 10 }) {
      this.InfoRowView('闪控窗')
      Text(this.floatWindowVisible ? '已显示' : '未显示')
        .fontSize(13)
        .fontColor(this.floatWindowVisible ? Theme.textPrimary : Theme.textSecondary)
        .layoutWeight(1)
    }
    .width('100%')
    .padding({ top: 9, bottom: 9 })
  }

  @Builder
  private InfoLineCapability() {
    Row({ space: 10 }) {
      this.InfoRowView('能力')
      Text(this.capability)
        .fontSize(13)
        .fontColor(Theme.textPrimary)
        .layoutWeight(1)
        .maxLines(2)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
    }
    .width('100%')
    .padding({ top: 9, bottom: 9 })
  }

  @Builder
  private InfoLineStatus() {
    Row({ space: 10 }) {
      this.InfoRowView('状态')
      Text(this.status)
        .fontSize(13)
        .fontColor(this.connected ? Theme.textPrimary : Theme.textSecondary)
        .layoutWeight(1)
        .maxLines(2)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
    }
    .width('100%')
    .padding({ top: 9, bottom: 9 })
  }

  @Builder
  private SessionsTab() {
    Column({ space: 8 }) {
      Row({ space: 8 }) {
        TextInput({ text: this.importUrl, placeholder: '粘贴 dsh://connect?… 或 https://host/?token=…' })
          .onChange((value: string) => {
            this.importUrl = value;
          })
          .height(40)
          .fontSize(13)
          .layoutWeight(1)
        Text('导入')
          .fontSize(13)
          .fontColor(Theme.brand)
          .height(40)
          .padding({ left: 14, right: 14 })
          .backgroundColor(Theme.brandSoft)
          .borderRadius(12)
          .onClick(() => {
            this.connect();
          })
        Text('扫码')
          .fontSize(13)
          .fontColor(Theme.brand)
          .height(40)
          .padding({ left: 14, right: 14 })
          .backgroundColor(Theme.brandSoft)
          .borderRadius(12)
          .onClick(() => {
            this.scanImport();
          })
      }
      .width('100%')
      .padding({ left: Theme.pagePadding, right: Theme.pagePadding })

      List({ space: 8 }) {
        ForEach(this.sessions, (row: SessionRow) => {
          ListItem() {
            Row({ space: 12 }) {
              Circle({ width: 8, height: 8 })
                .fill(row.running ? Theme.success : Theme.divider)
                .margin({ top: 6 })
              Column({ space: 4 }) {
                Text(row.title.length > 0 ? row.title : '(未命名)')
                  .fontSize(15)
                  .fontColor(Theme.textPrimary)
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                Text(`steps ${row.steps} · ${row.sessionId.substring(8, 16)}`)
                  .fontSize(11)
                  .fontColor(Theme.textTertiary)
              }
              .alignItems(HorizontalAlign.Start)
              .layoutWeight(1)

              if (row.sessionId === this.followSession) {
                Text('跟随中')
                  .fontSize(10)
                  .fontColor(Theme.brand)
                  .padding({ left: 8, right: 8, top: 3, bottom: 3 })
                  .backgroundColor(Theme.brandSoft)
                  .borderRadius(8)
              }
              Text('网页')
                .fontSize(11)
                .fontColor(Theme.textSecondary)
                .padding({ left: 10, right: 10, top: 4, bottom: 4 })
                .backgroundColor(Theme.cardAlt)
                .borderRadius(8)
                .onClick(() => {
                  router.pushUrl({ url: 'pages/Browse' });
                })
            }
            .width('100%')
            .padding(14)
            .backgroundColor(Theme.card)
            .borderRadius(Theme.radiusCard)
          }
          .onClick(() => {
            this.selectSession(row);
          })
        }, (row: SessionRow) => row.sessionId)
      }
      .layoutWeight(1)
      .width('100%')
      .padding({ left: Theme.pagePadding, right: Theme.pagePadding })
      .scrollBar(BarState.Off)
    }
    .width('100%')
    .height('100%')
    .padding({ top: 8 })
  }

  @Builder
  private LogsTab() {
    Column({ space: 8 }) {
      Row() {
        Text('实时事件')
          .fontSize(15)
          .fontWeight(FontWeight.Medium)
          .fontColor(Theme.textPrimary)
        Blank()
        Text('清空')
          .fontSize(12)
          .fontColor(Theme.textSecondary)
          .onClick(() => {
            this.events = [];
          })
      }
      .width('100%')
      .padding({ left: Theme.pagePadding, right: Theme.pagePadding })

      Scroll(this.logScroller) {
        Column({ space: 6 }) {
          ForEach(this.events, (line: string) => {
            Text(line)
              .fontSize(11)
              .fontFamily('monospace')
              .fontColor(Theme.textSecondary)
              .maxLines(3)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .width('100%')
          }, (line: string, index: number) => `${index}-${line}`)
        }
        .alignItems(HorizontalAlign.Start)
        .width('100%')
        .padding(12)
      }
      .layoutWeight(1)
      .width('100%')
      .margin({ left: Theme.pagePadding, right: Theme.pagePadding })
      .backgroundColor(Theme.card)
      .borderRadius(Theme.radiusCard)
      .scrollBar(BarState.Off)
    }
    .width('100%')
    .height('100%')
    .padding({ top: 8, bottom: 8 })
  }

  build() {
    Stack({ alignContent: Alignment.Top }) {
      // Full-bleed backdrop: it extends under the status/navigation bars, so the
      // window reads as one immersive surface instead of a white-framed box.
      Column()
        .width('100%')
        .height('100%')
        .linearGradient({
          angle: 160,
          colors: [[Theme.bgTop, 0.0], [Theme.bgMid, 0.5], [Theme.bgBottom, 1.0]]
        })
        .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])

      Column() {
        this.Header()

        // Swipeable pages: the bottom bar and the gesture stay in sync.
        Swiper(this.swiperController) {
          Column() {
            this.OverviewTab()
          }
          .width('100%')
          .height('100%')
          .alignItems(HorizontalAlign.Start)
          .justifyContent(FlexAlign.Start)

          Column() {
            this.SessionsTab()
          }
          .width('100%')
          .height('100%')
          .alignItems(HorizontalAlign.Start)
          .justifyContent(FlexAlign.Start)

          Column() {
            this.LogsTab()
          }
          .width('100%')
          .height('100%')
          .alignItems(HorizontalAlign.Start)
          .justifyContent(FlexAlign.Start)
        }
        .index(this.activeTab)
        .indicator(false)
        .loop(false)
        .duration(220)
        .onChange((index: number) => {
          this.activeTab = index;
          // Entering the session list is exactly when a stale host shows up.
          if (index === 1) {
            this.syncActiveNode();
          }
        })
        .width('100%')
        .layoutWeight(1)

        // Everything tappable lives at the bottom, inside thumb reach.
        this.BottomBar()
      }
      .width('100%')
      .height('100%')
      .alignItems(HorizontalAlign.Start)
      // Keep the content clear of the status bar while the backdrop goes under it.
      .padding({ top: this.topInset })

      if (this.showTools) {
        this.ToolOverlay()
      }
    }
    .width('100%')
    .height('100%')
  }

  /** Bottom navigation: three sections plus a tools sheet. */
  @Builder
  private BottomBar() {
    Column({ space: 6 }) {
      Row({ space: 4 }) {
        this.BottomItem('概览', 0)
        this.BottomItem('会话', 1)
        this.BottomItem('日志', 2)
        Column({ space: 3 }) {
          Text('⋯')
            .fontSize(18)
            .fontColor(Theme.textSecondary)
          Text('更多')
            .fontSize(10)
            .fontColor(Theme.textSecondary)
        }
        .layoutWeight(1)
        .height(52)
        .justifyContent(FlexAlign.Center)
        .onClick(() => {
          this.showTools = true;
        })
      }
      .width('100%')
      .height(52)
    }
    .width('100%')
    .padding({ bottom: 14 })
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.BOTTOM])
    .backgroundBlurStyle(BlurStyle.COMPONENT_THICK)
    .backgroundColor(Theme.glass)
  }

  @Builder
  private BottomItem(label: string, index: number) {
    Column({ space: 3 }) {
      Circle({ width: 6, height: 6 })
        .fill(this.activeTab === index ? Theme.brand : Theme.divider)
      Text(label)
        .fontSize(11)
        .fontWeight(this.activeTab === index ? FontWeight.Medium : FontWeight.Normal)
        .fontColor(this.activeTab === index ? Theme.brand : Theme.textSecondary)
    }
    .layoutWeight(1)
    .height(52)
    .justifyContent(FlexAlign.Center)
    .onClick(() => {
      this.activeTab = index;
      this.swiperController.changeIndex(index);
    })
  }

  /** Sheet-style tools panel: scrim + bottom card, no system sheet API needed. */
  @Builder
  private ToolOverlay() {
    Stack({ alignContent: Alignment.Bottom }) {
      Column()
        .width('100%')
        .height('100%')
        .backgroundColor(Theme.scrim)
        .onClick(() => {
          this.showTools = false;
        })

      Column({ space: 14 }) {
        Row() {
          Text('工具箱')
            .fontSize(16)
            .fontWeight(FontWeight.Medium)
            .fontColor(Theme.textPrimary)
          Blank()
          Text('关闭')
            .fontSize(13)
            .fontColor(Theme.textSecondary)
            .onClick(() => {
              this.showTools = false;
            })
        }
        .width('100%')

        Row({ space: 10 }) {
          this.ToolTile('重连', this.connected ? Theme.textPrimary : Theme.brand, (): void => {
            this.showTools = false;
            this.connect();
          })
          this.ToolTile('节点', Theme.textPrimary, (): void => {
            this.showTools = false;
            router.pushUrl({ url: 'pages/Nodes' });
          })
          this.ToolTile('网页', Theme.textPrimary, (): void => {
            this.showTools = false;
            router.pushUrl({ url: 'pages/Browse' });
          })
        }
        .width('100%')

        Row({ space: 10 }) {
          this.ToolTile(this.ballVisible ? '关球' : '悬浮球',
            this.ballVisible ? Theme.brand : Theme.textPrimary, (): void => {
              this.showTools = false;
              this.toggleBall();
            })
          this.ToolTile(this.floatWindowVisible ? '关窗' : '闪控窗',
            this.floatWindowVisible ? Theme.brand : Theme.textPrimary, (): void => {
              this.showTools = false;
              this.toggleFloatWindow();
            })
          this.ToolTile(this.keepAliveMode.length > 0 ? '停保活' : '保活',
            this.keepAliveMode.length > 0 ? Theme.success : Theme.textPrimary, (): void => {
              this.showTools = false;
              this.toggleKeepAlive();
            })
        }
        .width('100%')

        if (this.activeSessionId.length > 0) {
          Text('停止当前任务')
            .fontSize(14)
            .fontWeight(FontWeight.Medium)
            .fontColor(Theme.danger)
            .textAlign(TextAlign.Center)
            .height(46)
            .width('100%')
            .backgroundColor(Theme.dangerSoft)
            .borderRadius(14)
            .onClick(() => {
              this.showTools = false;
              this.abortActive();
            })
        }
      }
      .width('100%')
      .padding({ left: 18, right: 18, top: 18, bottom: 30 })
      .borderRadius({ topLeft: 22, topRight: 22 })
      // Immersive system material: the sheet covers the page, so the filter has real
      // content behind it to refract (unlike a separate float window).
      .systemMaterial(new uiMaterial.ImmersiveMaterial({
        style: uiMaterial.ImmersiveStyle.ULTRA_THIN,
        interactive: true,
        lightEffect: { color: Theme.brand }
      }))
    }
    .width('100%')
    .height('100%')
  }

  @Builder
  private ToolTile(label: string, color: ResourceColor, action: () => void) {
    Column({ space: 6 }) {
      Text(label)
        .fontSize(13)
        .fontWeight(FontWeight.Medium)
        .fontColor(color)
    }
    .height(64)
    .layoutWeight(1)
    .justifyContent(FlexAlign.Center)
    .backgroundColor(Theme.glass)
    .borderRadius(14)
    .border({ width: 1, color: Theme.border })
    .onClick(action)
  }

  @Builder
  private SegmentedBar() {
    Row() {
      this.SegmentItem('概览', 0)
      this.SegmentItem('会话', 1)
      this.SegmentItem('日志', 2)
    }
    .width('100%')
    .height(44)
    .padding({ left: Theme.pagePadding, right: Theme.pagePadding })
    .backgroundBlurStyle(BlurStyle.COMPONENT_THIN)
    .backgroundColor(Theme.glass)
  }

  @Builder
  private SegmentItem(label: string, index: number) {
    Column({ space: 6 }) {
      Text(label)
        .fontSize(15)
        .fontWeight(this.activeTab === index ? FontWeight.Medium : FontWeight.Normal)
        .fontColor(this.activeTab === index ? Theme.textPrimary : Theme.textSecondary)
      Rect()
        .width(20)
        .height(3)
        .radius(2)
        .fill(this.activeTab === index ? Theme.brand : Color.Transparent)
    }
    .layoutWeight(1)
    .height(44)
    .justifyContent(FlexAlign.Center)
    .onClick(() => {
      this.activeTab = index;
      this.swiperController.changeIndex(index);
    })
  }
}
