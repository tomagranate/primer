/**
 * Strip every terminal escape sequence and control byte from a log line.
 *
 * OpenTUI paints text verbatim. A raw sequence in a rendered log line goes
 * straight to the user's terminal: cursor moves corrupt the frame, and
 * query sequences (OSC 4/10/11, DECRQM, DA) make the terminal send
 * responses back on every diff repaint. Corsa hit the same bug
 * (tomagranate/corsa@38d2ba1); primer renders logs unstyled, so unlike
 * corsa we drop SGR color sequences too.
 *
 * Handles: CSI (with private prefixes and intermediates), OSC/DCS/SOS/PM/APC
 * strings (BEL or ST terminated, or unterminated at line end), ESC+finals
 * (RIS, charset selection, save/restore), C1 CSI (0x9b), and C0 controls.
 */
export function sanitizeLine(line: string): string {
  let out = "";
  for (let i = 0; i < line.length; i++) {
    const c = line.charCodeAt(i);

    if (c === 0x1b) {
      const next = line[i + 1];
      if (next === "[") {
        // CSI: ESC [ <params/intermediates 0x20-0x3f>* <final 0x40-0x7e>
        i += 2;
        while (i < line.length && line.charCodeAt(i) >= 0x20 && line.charCodeAt(i) <= 0x3f) i++;
        continue; // loop increment consumes the final byte
      }
      if (next === "]" || next === "P" || next === "X" || next === "^" || next === "_") {
        // String sequence: consume until BEL or ST (ESC \), or line end.
        i += 2;
        while (i < line.length) {
          const s = line.charCodeAt(i);
          if (s === 0x07) break;
          if (s === 0x1b && line[i + 1] === "\\") { i++; break; }
          i++;
        }
        continue;
      }
      // ESC + intermediates (0x20-0x2f)* + one final byte
      let j = i + 1;
      while (j < line.length && line.charCodeAt(j) >= 0x20 && line.charCodeAt(j) <= 0x2f) j++;
      i = j; // loop increment consumes the final byte (or ends at line end)
      continue;
    }

    if (c === 0x9b) {
      // C1 CSI
      i++;
      while (i < line.length && line.charCodeAt(i) >= 0x20 && line.charCodeAt(i) <= 0x3f) i++;
      continue;
    }

    if (c === 0x09) { out += "  "; continue; }
    if (c < 0x20 || c === 0x7f) continue;
    out += line[i];
  }
  return out;
}
