import { expect, test } from "bun:test";
import { createTerminalRestorer, shutdownRenderer, TERMINAL_RESET_SEQUENCE } from "./terminal-lifecycle";

test("renderer shutdown waits for the active frame before destroy", async () => {
  const events: string[] = [];
  let finishFrame!: () => void;
  const frame = new Promise<void>((resolve) => { finishFrame = resolve; });
  const renderer = {
    stop: () => events.push("stop"),
    idle: async () => { events.push("idle"); await frame; events.push("frame-finished"); },
    destroy: () => events.push("destroy"),
  };

  const shutdown = shutdownRenderer(renderer);
  await Promise.resolve();
  expect(events).toEqual(["stop", "idle"]);

  finishFrame();
  await shutdown;
  expect(events).toEqual(["stop", "idle", "frame-finished", "destroy"]);
});

test("terminal reset disables synchronized output before leaving the alternate screen", () => {
  expect(TERMINAL_RESET_SEQUENCE.indexOf("\x1b[?2026l")).toBeLessThan(
    TERMINAL_RESET_SEQUENCE.indexOf("\x1b[?1049l"),
  );
});

test("terminal reset ends on a new line after leaving the alternate screen", () => {
  expect(TERMINAL_RESET_SEQUENCE.endsWith("\x1b[?1049l\x1b[?25h\x1b[0m\r\n")).toBe(true);
});

test("terminal restorer leaves the alternate screen only once", () => {
  const writes: number[] = [];
  const restore = createTerminalRestorer(() => writes.push(1));
  expect(restore()).toBe(true);
  expect(restore()).toBe(false);
  expect(writes).toEqual([1]);
});
