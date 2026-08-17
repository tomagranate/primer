import { describe, expect, test } from "bun:test";
import { ensureVisible, listWindow } from "./list-window";

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
});
