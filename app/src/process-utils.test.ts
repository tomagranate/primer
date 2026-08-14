import { describe, expect, test } from "bun:test";
import { MODULE_PROCESS_ISOLATION, moduleProcessIsolation } from "./engine";
import { parseProcessTree } from "./process-utils";

describe("parseProcessTree", () => {
  test("groups children by parent and ignores malformed records", () => {
    expect(parseProcessTree([" 20 10", "21 10", "30 20", "nope", ""])).toEqual(
      new Map([
        [10, [20, 21]],
        [20, [30]],
      ]),
    );
  });
});

describe("detached process isolation", () => {
  test("module processes are detached with no stdin", () => {
    expect(MODULE_PROCESS_ISOLATION).toEqual({ detached: true, stdin: "ignore" });
  });

  test("sudo modules retain the terminal ticket without receiving stdin", () => {
    expect(moduleProcessIsolation(true)).toEqual({ detached: false, stdin: "ignore" });
    expect(moduleProcessIsolation(false)).toEqual(MODULE_PROCESS_ISOLATION);
  });

  test("a detached module cannot open Primer's controlling terminal", async () => {
    if (process.platform === "win32" || !process.stdin.isTTY) return;

    const proc = Bun.spawn(["sh", "-c", "test ! -r /dev/tty"], {
      detached: true,
      stdin: "ignore",
      stdout: "ignore",
      stderr: "ignore",
    });

    expect(await proc.exited).toBe(0);
  });
});
