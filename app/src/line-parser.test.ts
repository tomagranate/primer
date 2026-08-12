import { describe, expect, test } from "bun:test";
import { LineParser } from "./line-parser";

function parse(chunks: Array<string | Uint8Array>) {
  const lines: Array<{ line: string; replace: boolean }> = [];
  const parser = new LineParser((line, replace) => lines.push({ line, replace }));
  for (const chunk of chunks) {
    if (typeof chunk === "string") parser.push(chunk);
    else parser.write(chunk);
  }
  parser.flush();
  return lines;
}

describe("LineParser", () => {
  test("preserves lines split across chunks", () => {
    expect(parse(["hel", "lo\nwor", "ld\n"])).toEqual([
      { line: "hello", replace: false },
      { line: "world", replace: false },
    ]);
  });

  test("preserves split UTF-8 code points", () => {
    const bytes = new TextEncoder().encode("café\n");
    expect(parse([bytes.slice(0, 4), bytes.slice(4)])).toEqual([
      { line: "café", replace: false },
    ]);
  });

  test("treats progress redraws as replacements", () => {
    expect(parse(["10%\r20%\r", "100%\n"])).toEqual([
      { line: "20%", replace: true },
      { line: "100%", replace: true },
    ]);
  });

  test("treats CRLF as a normal newline", () => {
    expect(parse(["one\r\ntwo\r\n"])).toEqual([
      { line: "one", replace: false },
      { line: "two", replace: false },
    ]);
  });

  test("normalizes readline cursor-home redraws", () => {
    expect(parse(["old\x1b[1Gnew\x1b[0J\n"])).toEqual([
      { line: "new", replace: false },
    ]);
  });
});
