import { emitter } from '@kit.BasicServicesKit';
import { common } from '@kit.AbilityKit';
import { window } from '@kit.ArkUI';
import { CardStateStore } from '../store/CardStateStore';
import { Theme } from '../theme/Theme';

/**
 * The float view's own ArkUI page (rendered in a separate window/UIContext).
 *
 * Two shapes share this page, driven by the *window size* rather than by a pushed
 * flag (the main window is often in the background, so pushes are unreliable):
 *   - compact  → a small frosted glass block floating on the screen
 *   - card     → the same content expanded: session, progress, recent events
 * Tapping the block asks the main page to grow the window; the card shrinks it.
 */
const EVENT_DECISION: number = 1001;
const EVENT_RESIZE: number = 1004;
const CARD_MIN_WIDTH: number = 700;

/** Payload carried through `emitter` from the card window back to the main page. */
interface DecisionPayload {
  approvalId: string;
  decision: string;
}

@Entry
@Component
struct FloatCard {
  @State private status: string = '已连接';
  @State private preview: string = '';
  @State private approvalId: string = '';
  @State private title: string = '';
  @State private metrics: string = '待命';
  @State private activity: string = '';
  @State private events: string = '';
  @State private tokens: string = '';
  @State private pending: string = '';
  @State private sessionShort: string = '';
  @State private expanded: boolean = false;
  private pollTimer: number = -1;
  private sizeTimer: number = -1;

  aboutToAppear(): void {
    this.refresh();
    this.measure();
    // The main window is usually in the background while this window is visible,
    // so pull the state ourselves instead of waiting for a push.
    this.pollTimer = setInterval(() => {
      this.refresh();
    }, 1500);
    this.sizeTimer = setInterval(() => {
      this.measure();
    }, 500);
  }

  aboutToDisappear(): void {
    if (this.pollTimer >= 0) {
      clearInterval(this.pollTimer);
      this.pollTimer = -1;
    }
    if (this.sizeTimer >= 0) {
      clearInterval(this.sizeTimer);
      this.sizeTimer = -1;
    }
  }

  /** The window size is the single source of truth for compact vs expanded. */
  private async measure(): Promise<void> {
    try {
      const win: window.Window = await window.getLastWindow(getContext(this));
      const width: number = win.getWindowProperties().windowRect.width;
      const next: boolean = width > CARD_MIN_WIDTH;
      if (next !== this.expanded) {
        this.expanded = next;
      }
    } catch {
      // Keep the current shape when the window is not ready yet.
    }
  }

  private async refresh(): Promise<void> {
    const context: common.Context = getContext(this) as common.Context;
    const state: Record<string, string> = await CardStateStore.load(context);
    if (state.title !== undefined && state.title.length > 0) {
      this.title = state.title;
    }
    if (state.metrics !== undefined && state.metrics.length > 0) {
      this.metrics = state.metrics;
    }
    if (state.activity !== undefined) {
      this.activity = state.activity;
    }
    if (state.status !== undefined && state.status.length > 0) {
      this.status = state.status;
    }
    if (state.preview !== undefined) {
      this.preview = state.preview;
    }
    if (state.approvalId !== undefined) {
      this.approvalId = state.approvalId;
    }
    if (state.events !== undefined) {
      this.events = state.events;
    }
    if (state.tokens !== undefined) {
      this.tokens = state.tokens;
    }
    if (state.pending !== undefined) {
      this.pending = state.pending;
    }
    if (state.sessionShort !== undefined) {
      this.sessionShort = state.sessionShort;
    }
  }

  private emit(eventId: number, approvalId: string, decision: string): void {
    const payload: DecisionPayload = { approvalId: approvalId, decision: decision };
    emitter.emit({ eventId: eventId }, { data: payload });
  }

  /** The glass block: one number, one hint, frosted. */
  @Builder
  private CompactBlock() {
    Column({ space: 2 }) {
      Text(this.metrics)
        .fontSize(16)
        .fontWeight(FontWeight.Bold)
        .fontColor(Theme.brand)
        .maxLines(1)
      Text(this.approvalId.length > 0 ? '待审批' : (this.sessionShort.length > 0 ? this.sessionShort : this.status))
        .fontSize(9)
        .fontColor(Theme.textSecondary)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .backgroundColor(Theme.glass)
    .backgroundBlurStyle(BlurStyle.COMPONENT_THICK)
    .borderRadius(26)
    .border({ width: 1, color: Theme.border })
    .shadow({ radius: 18, color: '#33000000', offsetX: 0, offsetY: 6 })
    .onClick(() => {
      this.emit(EVENT_RESIZE, '', 'expand');
    })
  }

  /** The expanded card: the same window, more of the story. */
  @Builder
  private ExpandedCard() {
    Column({ space: 8 }) {
      Row({ space: 6 }) {
        Text('DSH')
          .fontSize(12)
          .fontWeight(FontWeight.Bold)
          .fontColor(Theme.brand)
        Text(this.status)
          .fontSize(11)
          .fontColor(Theme.textSecondary)
          .layoutWeight(1)
          .maxLines(1)
        Text('收起')
          .fontSize(11)
          .fontColor(Theme.textSecondary)
          .padding({ left: 8, right: 8, top: 3, bottom: 3 })
          .backgroundColor(Theme.cardAlt)
          .borderRadius(8)
          .onClick(() => {
            this.emit(EVENT_RESIZE, '', 'collapse');
          })
      }
      .width('100%')

      Text(this.title.length > 0 ? this.title : '未选择会话')
        .fontSize(13)
        .fontColor(Theme.textPrimary)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .width('100%')

      Row({ space: 8 }) {
        Text(this.metrics)
          .fontSize(22)
          .fontWeight(FontWeight.Bold)
          .fontColor(Theme.textPrimary)
        Blank()
        if (this.pending.length > 0) {
          Text(this.pending)
            .fontSize(10)
            .fontColor(Theme.warning)
            .padding({ left: 8, right: 8, top: 3, bottom: 3 })
            .backgroundColor(Theme.warningSoft)
            .borderRadius(6)
        }
        if (this.tokens.length > 0) {
          Text(this.tokens)
            .fontSize(10)
            .fontColor(Theme.textSecondary)
            .padding({ left: 8, right: 8, top: 3, bottom: 3 })
            .backgroundColor(Theme.cardAlt)
            .borderRadius(6)
        }
      }
      .width('100%')

      if (this.events.length > 0) {
        Column({ space: 3 }) {
          ForEach(this.events.split('\n'), (line: string) => {
            Text(line)
              .fontSize(10)
              .fontFamily('monospace')
              .fontColor(Theme.textTertiary)
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .width('100%')
          }, (line: string, index: number) => line + index)
        }
        .width('100%')
        .padding(8)
        .backgroundColor(Theme.cardAlt)
        .borderRadius(10)
      } else {
        Text(this.activity.length > 0 ? this.activity : '等待事件…')
          .fontSize(11)
          .fontColor(Theme.textTertiary)
          .maxLines(2)
          .width('100%')
      }

      if (this.approvalId.length > 0) {
        Text(this.preview.length > 0 ? this.preview : '等待审批')
          .fontSize(10)
          .fontFamily('monospace')
          .fontColor(Theme.textPrimary)
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
          .padding(8)
          .backgroundColor(Theme.cardAlt)
          .borderRadius(8)
        Row({ space: 8 }) {
          Text('拒绝')
            .fontSize(13)
            .fontColor(Theme.danger)
            .textAlign(TextAlign.Center)
            .height(34)
            .layoutWeight(1)
            .backgroundColor(Theme.dangerSoft)
            .borderRadius(9)
            .onClick(() => {
              this.emit(EVENT_DECISION, this.approvalId, 'REJECT');
            })
          Text('允许')
            .fontSize(13)
            .fontWeight(FontWeight.Medium)
            .fontColor(Theme.textOnBrand)
            .textAlign(TextAlign.Center)
            .height(34)
            .layoutWeight(1)
            .backgroundColor(Theme.brand)
            .borderRadius(9)
            .onClick(() => {
              this.emit(EVENT_DECISION, this.approvalId, 'APPROVE');
            })
        }
        .width('100%')
      }
    }
    .padding(14)
    .width('100%')
    .height('100%')
    .alignItems(HorizontalAlign.Start)
    .backgroundColor(Theme.glass)
    .backgroundBlurStyle(BlurStyle.COMPONENT_THICK)
    .borderRadius(22)
    .border({ width: 1, color: Theme.border })
    .shadow({ radius: 22, color: '#33000000', offsetX: 0, offsetY: 8 })
  }

  build() {
    Column() {
      if (this.expanded) {
        this.ExpandedCard()
      } else {
        this.CompactBlock()
      }
    }
    .width('100%')
    .height('100%')
    .padding(2)
    .backgroundColor(Color.Transparent)
  }
}
