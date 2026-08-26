/** Wrap terminal text by display width. Long words split only when required. */
export function wrapText(text: string, width: number): string[] {
  const limit = Math.max(1, Math.floor(width));
  const words = text.trim().split(/\s+/).filter(Boolean);
  if (words.length === 0) return [""];

  const lines: string[] = [];
  let current = "";
  for (const word of words) {
    const candidate = current ? `${current} ${word}` : word;
    if (Bun.stringWidth(candidate) <= limit) {
      current = candidate;
      continue;
    }
    if (current) lines.push(current);
    const chunks = splitByWidth(word, limit);
    lines.push(...chunks.slice(0, -1));
    current = chunks.at(-1) ?? "";
  }
  if (current) lines.push(current);
  return lines.length ? lines : [""];
}

/** Wrap related text segments without splitting a segment that fits by itself. */
export function wrapSegments(segments: string[], width: number): string[] {
  const limit = Math.max(1, Math.floor(width));
  const lines: string[] = [];
  let current = "";

  for (const segment of segments.map((value) => value.trim()).filter(Boolean)) {
    const candidate = current ? `${current}  ${segment}` : segment;
    if (Bun.stringWidth(candidate) <= limit) {
      current = candidate;
      continue;
    }
    if (current) {
      lines.push(current);
      current = "";
    }
    const wrapped = wrapText(segment, limit);
    lines.push(...wrapped.slice(0, -1));
    current = wrapped.at(-1) ?? "";
  }
  if (current) lines.push(current);
  return lines.length ? lines : [""];
}

/** Keep every row for the selected item visible inside a fixed-height viewport. */
export function ensureRowRangeVisible(
  scrollStart: number,
  selectedStart: number,
  selectedEnd: number,
  totalRows: number,
  height: number,
  endPad = 0,
): number {
  const count = Math.max(1, Math.floor(height));
  const total = Math.max(0, Math.floor(totalRows));
  if (total === 0) return 0;

  const first = Math.min(Math.max(0, Math.floor(selectedStart)), total - 1);
  const last = Math.min(Math.max(first, Math.floor(selectedEnd)), total - 1);
  const pad = Math.max(0, Math.floor(endPad));
  const maxStart = Math.max(0, total + pad - count);
  let start = Math.min(Math.max(0, Math.floor(scrollStart)), maxStart);

  if (last - first + 1 >= count) start = first;
  else if (first < start) start = first;
  else if (last >= start + count) start = last - count + 1;

  if (pad > 0 && last === total - 1 && first >= maxStart && last < maxStart + count) {
    start = maxStart;
  }
  return Math.min(Math.max(0, start), maxStart);
}

function splitByWidth(text: string, width: number): string[] {
  const graphemes = [...new Intl.Segmenter(undefined, { granularity: "grapheme" }).segment(text)]
    .map((part) => part.segment);
  const chunks: string[] = [];
  let current = "";
  for (const grapheme of graphemes) {
    if (current && Bun.stringWidth(`${current}${grapheme}`) > width) {
      chunks.push(current);
      current = "";
    }
    current += grapheme;
  }
  if (current) chunks.push(current);
  return chunks.length ? chunks : [""];
}
