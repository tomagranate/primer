import { describe, expect, test } from "bun:test";
import { ensureVisible, isScrolledToEnd, listWindow } from "./list-window";

describe("listWindow", () => {
  test("returns the full range when the list fits", () => {
    expect(listWindow(0, 3, 10)).toEqual({ start: 0, count: 10 });
    expect(listWindow(2, 3, 10)).toEqual({ start: 0, count: 10 });
  });

  test("keeps the selection visible near the top", () => {
    expect(listWindow(0, 20, 5)).toEqual({ start: 0, count: 5 });
    expect(listWindow(1, 20, 5)).toEqual({ start: 0, count: 5 });
  });

  test("centers the selection when possible", () => {
    expect(listWindow(10, 20, 5)).toEqual({ start: 8, count: 5 });
  });

  test("clamps at the bottom", () => {
    expect(listWindow(19, 20, 5)).toEqual({ start: 15, count: 5 });
    expect(listWindow(18, 20, 5)).toEqual({ start: 15, count: 5 });
  });

  test("handles empty lists and tiny heights", () => {
    expect(listWindow(0, 0, 5)).toEqual({ start: 0, count: 5 });
    expect(listWindow(3, 10, 0)).toEqual({ start: 3, count: 1 });
    expect(listWindow(3, 10, -2)).toEqual({ start: 3, count: 1 });
  });

  test("clamps an out-of-range selection", () => {
    expect(listWindow(-5, 20, 5)).toEqual({ start: 0, count: 5 });
    expect(listWindow(99, 20, 5)).toEqual({ start: 15, count: 5 });
  });
});

describe("ensureVisible", () => {
  test("does not move while the selection stays in view", () => {
    expect(ensureVisible(3, 4, 20, 5)).toBe(3);
    expect(ensureVisible(3, 7, 20, 5)).toBe(3);
  });

  test("scrolls up when the selection moves above the window", () => {
    expect(ensureVisible(5, 2, 20, 5)).toBe(2);
    expect(ensureVisible(5, 0, 20, 5)).toBe(0);
  });

  test("scrolls down when the selection moves below the window", () => {
    expect(ensureVisible(0, 5, 20, 5)).toBe(1);
    expect(ensureVisible(0, 10, 20, 5)).toBe(6);
  });

  test("clamps when the list shrinks or selection wraps to the end", () => {
    expect(ensureVisible(10, 0, 5, 5)).toBe(0);
    expect(ensureVisible(0, 19, 20, 5)).toBe(15);
    expect(ensureVisible(100, 19, 20, 5)).toBe(15);
  });

  test("with end pad, selecting the last item scrolls to show the pad", () => {
    // 20 items + 1 pad, height 5 → maxStart = 16
    expect(ensureVisible(0, 19, 20, 5, 1)).toBe(16);
    expect(isScrolledToEnd(16, 20, 5, 1)).toBe(true);
  });

  test("with end pad and height 1, keeps the last item (pad cannot fit)", () => {
    expect(ensureVisible(0, 19, 20, 1, 1)).toBe(19);
  });

  test("with end pad, mid-list selection does not force the pad into view", () => {
    expect(ensureVisible(0, 5, 20, 5, 1)).toBe(1);
    expect(isScrolledToEnd(1, 20, 5, 1)).toBe(false);
  });
});

describe("isScrolledToEnd", () => {
  test("is true when content fits or start is at max", () => {
    expect(isScrolledToEnd(0, 3, 10)).toBe(true);
    expect(isScrolledToEnd(15, 20, 5)).toBe(true);
    expect(isScrolledToEnd(0, 20, 5)).toBe(false);
  });
});
