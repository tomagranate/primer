import { describe, expect, test } from "bun:test";
import { ensureRowRangeVisible, wrapSegments, wrapText } from "./text-layout";

describe("terminal text layout", () => {
  test("wraps words and long tokens to the requested display width", () => {
    expect(wrapText("Steam, GameMode, and MangoHud", 12))
      .toEqual(["Steam,", "GameMode,", "and MangoHud"]);
    expect(wrapText("abcdefgh", 3)).toEqual(["abc", "def", "gh"]);
  });

  test("keeps fitting metadata segments together and moves whole trailing segments", () => {
    expect(wrapSegments(["runtimes installed", "4 items", "0.1s"], 40))
      .toEqual(["runtimes installed  4 items  0.1s"]);
    expect(wrapSegments(["runtimes installed", "4 items", "0.1s"], 22))
      .toEqual(["runtimes installed", "4 items  0.1s"]);
  });

  test("keeps all selected rows visible and preserves an end gutter", () => {
    expect(ensureRowRangeVisible(0, 6, 7, 12, 5)).toBe(3);
    expect(ensureRowRangeVisible(3, 1, 2, 12, 5)).toBe(1);
    expect(ensureRowRangeVisible(0, 10, 10, 11, 5, 1)).toBe(7);
  });
});
