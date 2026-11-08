import { util } from '@kit.ArkTS';

/**
 * Incremental Server-Sent Events parser.
 *
 * The host streams `id: <seq>` / `event: <type>` / `data: <json>` frames followed
 * by a blank line, plus `: ping` comments and an initial `retry:` directive.
 * Chunks can split anywhere — including inside a multi-byte UTF-8 character — so
 * the decoder must run in streaming mode and the buffer must survive chunks.
 */
export class SseParser {
  private decoder: util.TextDecoder = util.TextDecoder.create('utf-8');
  private pending: string = '';
  private lastEventId: string = '';
  private readonly onEvent: (type: string, data: string, id: string) => void;

  constructor(onEvent: (type: string, data: string, id: string) => void) {
    this.onEvent = onEvent;
  }

  /** Feed one raw chunk from `http` `dataReceive`. */
  push(chunk: ArrayBuffer): void {
    this.pending += this.decoder.decodeToString(new Uint8Array(chunk), { stream: true });
    this.drain();
  }

  /** Close the stream: flush a trailing frame that never got its blank line. */
  end(): void {
    this.pending += this.decoder.decodeToString(new Uint8Array(0), { stream: false });
    this.drain(true);
    this.pending = '';
  }

  private drain(flush: boolean = false): void {
    for (;;) {
      const index: number = this.pending.indexOf('\n\n');
      const indexCrLf: number = this.pending.indexOf('\r\n\r\n');
      let cut: number = -1;
      let width: number = 2;
      if (index >= 0 && (indexCrLf < 0 || index < indexCrLf)) {
        cut = index;
        width = 2;
      } else if (indexCrLf >= 0) {
        cut = indexCrLf;
        width = 4;
      }
      if (cut < 0) {
        if (!flush || this.pending.length === 0) {
          return;
        }
        this.dispatch(this.pending);
        this.pending = '';
        return;
      }
      const frame: string = this.pending.substring(0, cut);
      this.pending = this.pending.substring(cut + width);
      this.dispatch(frame);
      if (flush && this.pending.length === 0) {
        return;
      }
    }
  }

  private dispatch(frame: string): void {
    let type: string = 'message';
    let data: string = '';
    let id: string = this.lastEventId;
    const lines: string[] = frame.split('\n');
    for (const rawLine of lines) {
      const line: string = rawLine.endsWith('\r') ? rawLine.substring(0, rawLine.length - 1) : rawLine;
      if (line.length === 0 || line.startsWith(':')) {
        continue;
      }
      const colon: number = line.indexOf(':');
      const field: string = colon < 0 ? line : line.substring(0, colon);
      let value: string = colon < 0 ? '' : line.substring(colon + 1);
      if (value.startsWith(' ')) {
        value = value.substring(1);
      }
      if (field === 'event') {
        type = value;
      } else if (field === 'data') {
        data = data.length === 0 ? value : `${data}\n${value}`;
      } else if (field === 'id') {
        id = value;
        this.lastEventId = value;
      }
      // `retry:` is accepted and intentionally ignored for now.
    }
    if (data.length > 0) {
      this.onEvent(type, data, id);
    }
  }

  getLastEventId(): string {
    return this.lastEventId;
  }
}
