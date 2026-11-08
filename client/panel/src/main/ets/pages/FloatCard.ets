import { emitter } from '@kit.BasicServicesKit';
import { common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { CardStateStore } from '../store/CardStateStore';

/**
 * The float view's own ArkUI page (rendered in a separate window/UIContext).
 *
 * It never talks to the network: state arrives through `emitter` from the main
 * page, and actions leave the same way so the page keeps a single authority over
 * the API client.
 */
const EVENT_DECISION: number = 1001;
const EVENT_OPEN_APP: number = 1002;
const EVENT_STATE: number = 1003;

/** State pushed from the main page into the card window. */
interface CardStatePayload {
  line: string;
  status: string;
  preview: string;
  approvalId: string;
  title: string;
  metrics: string;
  activity: string;
}

/** Payload carried through `emitter` from the card window back to the main page. */
interface DecisionPayload {
  approvalId: string;
  decision: string;
}

@Entry
@Component
struct FloatCard {
  @State private line: string = 'DSH';
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
  private pollTimer: number = -1;

  aboutToAppear(): void {
    this.refresh();
    // The main window is usually in the background while this card is visible, so
    // pull the state ourselves instead of waiting for a push.
    this.pollTimer = setInterval(() => {
      this.refresh();
    }, 1500);
  }

  aboutToDisappear(): void {
    if (this.pollTimer >= 0) {
      clearInterval(this.pollTimer);
      this.pollTimer = -1;
    }
  }

  private async refresh(): Promise<void> {
    const context: common.Context = getContext(this) as common.Context;
    const state: Record<string, string> = await CardStateStore.load(context);
    console.info(`[panel] card refresh title=${state.title} metrics=${state.metrics}`);
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
    if (state.line !== undefined && state.line.length > 0) {
      this.line = state.line;
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

  build() {
    Column({ space: 6 }) {
      // Header: brand + live status.
      Row({ space: 6 }) {
        Text('DSH')
          .fontSize(12)
          .fontWeight(FontWeight.Bold)
          .fontColor('#0A59F7')
        Text(this.status)
          .fontSize(11)
          .fontColor('#6B7480')
          .layoutWeight(1)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      .width('100%')

      // Session title.
      Text(this.title.length > 0 ? this.title : '未选择会话')
        .fontSize(13)
        .fontColor('#182431')
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .width('100%')

      // Turn / step, the part that actually moves.
      Row({ space: 8 }) {
        Text(this.metrics)
          .fontSize(20)
          .fontWeight(FontWeight.Bold)
          .fontColor('#182431')
      }
      .width('100%')

      // Meta chips: how much is going on, and anything waiting on the user.
      Row({ space: 6 }) {
        if (this.tokens.length > 0) {
          Text(this.tokens)
            .fontSize(9)
            .fontColor('#6B7480')
            .padding({ left: 6, right: 6, top: 2, bottom: 2 })
            .backgroundColor('#F1F3F6')
            .borderRadius(5)
        }
        if (this.pending.length > 0) {
          Text(this.pending)
            .fontSize(9)
            .fontColor('#B26A00')
            .padding({ left: 6, right: 6, top: 2, bottom: 2 })
            .backgroundColor('#FFF3E0')
            .borderRadius(5)
        }
        if (this.sessionShort.length > 0) {
          Text('# ' + this.sessionShort)
            .fontSize(9)
            .fontColor('#9AA3AE')
            .maxLines(1)
        }
      }
      .width('100%')

      if (this.events.length === 0) {
        Text(this.activity.length > 0 ? this.activity : '等待事件…')
          .fontSize(10)
          .fontColor('#9AA3AE')
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
      }

      // Timeline: the three most recent lines are the real "why should I look".
      if (this.events.length > 0) {
        Column({ space: 2 }) {
          ForEach(this.events.split('\n'), (line: string) => {
            Text(line)
              .fontSize(9)
              .fontFamily('monospace')
              .fontColor('#7C8797')
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .width('100%')
          }, (line: string, index: number) => line + index)
        }
        .width('100%')
        .padding(6)
        .backgroundColor('#FAFBFC')
        .borderRadius(6)
      }


      if (this.approvalId.length > 0) {
        Text(this.preview.length > 0 ? this.preview : '等待审批')
          .fontSize(10)
          .fontFamily('monospace')
          .fontColor('#182431')
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
          .padding(6)
          .backgroundColor('#F7F8FA')
          .borderRadius(6)
        Row({ space: 8 }) {
          Text('拒绝')
            .fontSize(13)
            .fontColor('#D93A2B')
            .textAlign(TextAlign.Center)
            .height(32)
            .layoutWeight(1)
            .backgroundColor('#FEECEA')
            .borderRadius(8)
            .onClick(() => {
              this.emit(EVENT_DECISION, this.approvalId, 'REJECT');
            })
          Text('允许')
            .fontSize(13)
            .fontWeight(FontWeight.Medium)
            .fontColor('#FFFFFF')
            .textAlign(TextAlign.Center)
            .height(32)
            .layoutWeight(1)
            .backgroundColor('#0A59F7')
            .borderRadius(8)
            .onClick(() => {
              this.emit(EVENT_DECISION, this.approvalId, 'APPROVE');
            })
        }
        .width('100%')
      }
    }
    .padding(12)
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .justifyContent(FlexAlign.Center)
    .backgroundColor('#FFFFFF')
  }
}
