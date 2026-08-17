export const TERMINAL_RESET_SEQUENCE =
  "\x1b[?1000l\x1b[?1002l\x1b[?1003l\x1b[?1006l" +
  "\x1b[?2026l\x1b[?2027l\x1b[?1049l\x1b[?25h\x1b[0m\r\n";

interface RendererLifecycle {
  stop(): void;
  idle(): Promise<void>;
  destroy(): void;
}

export async function shutdownRenderer(renderer: RendererLifecycle): Promise<void> {
  renderer.stop();
  await renderer.idle();
  renderer.destroy();
}

/** Last-resort terminal restoration. Safe to call repeatedly and during exit. */
export function resetTerminal(): void {
  try { process.stdin.setRawMode?.(false); } catch { /* stdin may be gone */ }
  try { process.stdout.write(TERMINAL_RESET_SEQUENCE); } catch { /* stdout may be gone */ }
}

/** Leave the alternate screen once. A second 1049l can restore the old cursor
 *  on top of the final status lines, so later typing overwrites them. */
export function createTerminalRestorer(write = resetTerminal) {
  let restored = false;
  return () => {
    if (restored) return false;
    restored = true;
    write();
    return true;
  };
}
