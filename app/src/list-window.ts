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
 */
export function ensureVisible(
  scrollStart: number,
  selected: number,
  total: number,
  height: number,
): number {
  const count = Math.max(1, Math.floor(height));
  if (total <= 0) return 0;
  const sel = Math.min(Math.max(0, Math.floor(selected)), total - 1);
  const maxStart = Math.max(0, total - count);
  let start = Math.min(Math.max(0, Math.floor(scrollStart)), maxStart);
  if (sel < start) start = sel;
  else if (sel >= start + count) start = sel - count + 1;
  return Math.min(Math.max(0, start), maxStart);
}
