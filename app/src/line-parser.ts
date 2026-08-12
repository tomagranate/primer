/**
 * Stateful subprocess-output parser, adapted from Corsa's process pipeline.
 * It preserves decoder state across chunks and models carriage-return redraws
 * as replacements instead of allowing progress bars to flood the log.
 */
export type OnLine = (line: string, replacePrevious: boolean) => void;

const CURSOR_HOME = /\x1b\[1G/g;
const CURSOR_CONTROL = /\x1b\[[\d;]*[ABCDEFGHJK]/g;

export class LineParser {
  private buffer = "";
  private replacing = false;
  private decoder = new TextDecoder();

  constructor(private readonly onLine: OnLine) {}

  write(data: Uint8Array): void {
    this.push(this.decoder.decode(data, { stream: true }));
  }

  push(chunk: string): void {
    let text = chunk.replace(CURSOR_HOME, "\r").replace(CURSOR_CONTROL, "");

    // Backspace is common in interactive-ish progress output. Apply it to the
    // pending line rather than passing a control byte to the renderer.
    if (text.includes("\x08")) {
      for (const char of text) {
        if (char === "\x08") this.buffer = this.buffer.slice(0, -1);
        else this.buffer += char;
      }
    } else {
      this.buffer += text;
    }

    let newline = this.buffer.indexOf("\n");
    while (newline >= 0) {
      let line = this.buffer.slice(0, newline);
      this.buffer = this.buffer.slice(newline + 1);
      if (line.endsWith("\r")) line = line.slice(0, -1);
      const carriageReturn = line.lastIndexOf("\r");
      if (carriageReturn >= 0) line = line.slice(carriageReturn + 1);
      this.onLine(line, this.replacing);
      this.replacing = false;
      newline = this.buffer.indexOf("\n");
    }

    const carriageReturn = this.buffer.lastIndexOf("\r");
    if (carriageReturn >= 0) {
      let current = this.buffer.slice(carriageReturn + 1);
      // A trailing CR commits the text immediately before it as the latest
      // screen line. Keep an empty buffer so the next bytes overwrite it.
      if (!current && carriageReturn > 0) {
        const previous = this.buffer.lastIndexOf("\r", carriageReturn - 1);
        current = this.buffer.slice(previous + 1, carriageReturn);
        this.buffer = "";
      } else {
        this.buffer = current;
      }
      if (current) {
        this.onLine(current, true);
        this.replacing = true;
      }
    }
  }

  flush(): void {
    this.push(this.decoder.decode());
    if (!this.buffer) return;
    const carriageReturn = this.buffer.lastIndexOf("\r");
    const line = carriageReturn >= 0 ? this.buffer.slice(carriageReturn + 1) : this.buffer;
    if (line) this.onLine(line, this.replacing);
    this.buffer = "";
    this.replacing = false;
  }
}
