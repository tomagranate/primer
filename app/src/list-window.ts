/**
 * Choose a fixed-height window into a list so the selected row stays visible.
 * Centers the selection when there is room; clamps at the ends.
 */
export function listWindow(selected: number, total: number, height: number): {
  start: number;
  count: number;
} {
  const count = Math.max(1, Math.floor(height));
  if (total <= 0) return { start: 0, count };
  const sel = Math.min(Math.max(0, Math.floor(selected)), total - 1);
  const maxStart = Math.max(0, total - count);
  const start = Math.min(maxStart, Math.max(0, sel - Math.floor(count / 2)));
  return { start, count };
}

/**
 * Adjust a sticky scroll offset so `selected` stays inside the viewport.
 * Only moves when the selection would leave the window (or the list shrank).
 *
 * `endPad` adds virtual rows after the last item (e.g. a trailing blank line).
 * Selection indices still refer to real items only; the pad is for scroll range.
 */
export function ensureVisible(
  scrollStart: number,
  selected: number,
  total: number,
  height: number,
  endPad = 0,
): number {
  const count = Math.max(1, Math.floor(height));
  if (total <= 0) return 0;
  const sel = Math.min(Math.max(0, Math.floor(selected)), total - 1);
  const pad = Math.max(0, Math.floor(endPad));
  const content = total + pad;
  const maxStart = Math.max(0, content - count);
  let start = Math.min(Math.max(0, Math.floor(scrollStart)), maxStart);
  if (sel < start) start = sel;
  else if (sel >= start + count) start = sel - count + 1;
  // On the last item, prefer the end of the scroll range so the pad is visible —
  // but only when the last item still fits in that window.
  if (pad > 0 && sel === total - 1 && sel >= maxStart && sel < maxStart + count) {
    start = maxStart;
  }
  return Math.min(Math.max(0, start), maxStart);
}

/** True when the viewport is scrolled to the end of content (including end pad). */
export function isScrolledToEnd(scrollStart: number, total: number, height: number, endPad = 0): boolean {
  const count = Math.max(1, Math.floor(height));
  const content = Math.max(0, total) + Math.max(0, Math.floor(endPad));
  if (content <= count) return true;
  const maxStart = content - count;
  return Math.min(Math.max(0, Math.floor(scrollStart)), maxStart) >= maxStart;
}
