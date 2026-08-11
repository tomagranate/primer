import { describe, expect, test } from "bun:test";
import { sanitizeLine } from "./ansi";

// biome-ignore lint/suspicious/noControlCharactersInRegex: verifies controls never survive
const UNSAFE = /[\x00-\x08\x0b\x0c\x0e-\x1f\x7f-\x9f\x1b]/;

describe("sanitizeLine", () => {
  test.each([
    ["plain text", "Hello, world!", "Hello, world!"],
    ["SGR colors dropped", "\x1b[31mred\x1b[0m plain", "red plain"],
    ["RIS", "before\x1bcafter", "beforeafter"],
    ["save/restore cursor", "a\x1b7b\x1b8c", "abc"],
    ["reverse index and keypad modes", "a\x1bMb\x1b=c\x1b>d", "abcd"],
    ["charset selection", "a\x1b(Bb\x1b)0c\x1b*Ad\x1b+0e", "abcde"],
    ["private CSI", "a\x1b[?25lb\x1b[?25hc\x1b[?1049hd\x1b[?2004le", "abcde"],
    ["prefixed CSI", "before\x1b[>4;2mafter", "beforeafter"],
    ["CSI intermediates", "a\x1b[ qb\x1b[?25$pc", "abc"],
    ["DECRQM query", "x\x1b[?2027$py", "xy"],
    ["OSC title", "\x1b]0;title\x07hello", "hello"],
    ["OSC palette query", "a\x1b]4;0;?\x07b", "ab"],
    ["OSC fg/bg query", "a\x1b]10;?\x07\x1b]11;?\x07b", "ab"],
    ["OSC hyperlink", "\x1b]8;;https://x\x1b\\link\x1b]8;;\x1b\\", "link"],
    ["unterminated OSC", "hello\x1b]0;unfinished", "hello"],
    ["DCS", "a\x1bPpayload\x1b\\b", "ab"],
    ["SOS", "a\x1bXpayload\x1b\\b", "ab"],
    ["PM", "a\x1b^payload\x1b\\b", "ab"],
    ["APC unterminated", "a\x1b_payload", "a"],
    ["C1 CSI", "a\x9b31mb", "ab"],
    ["C1 OSC", "a\x9d0;title\x9cb", "ab"],
    ["C1 DCS", "a\x90payload\x9cb", "ab"],
    ["stray C1 controls", "a\x80\x8f\x9cb", "ab"],
    ["lone ESC at end", "hello\x1b", "hello"],
    ["stray BEL", "be\x07ll", "bell"],
    ["tab becomes spaces", "a\tb", "a  b"],
    ["cursor home attack", "\x1b[Hboo", "boo"],
    ["escape-only line", "\x1bc\x1b[?25l\x1b]t\x07", ""],
  ] as const)("%s", (_name, input, expected) => {
    const result = sanitizeLine(input);
    expect(result).toBe(expected);
    expect(result).not.toMatch(UNSAFE);
  });
});
