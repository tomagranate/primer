import { afterEach, describe, expect, test } from "bun:test";
import { mkdirSync, mkdtempSync, readdirSync, utimesSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { rmSync } from "node:fs";
import { RunLogStore, configuredRunLogMaxBytes, pruneRunLogs } from "./run-logs";

const roots: string[] = [];

afterEach(() => {
  for (const root of roots.splice(0)) rmSync(root, { recursive: true, force: true });
});

function tempRoot(): string {
  const root = mkdtempSync(join(tmpdir(), "primer-run-logs-test-"));
  roots.push(root);
  return root;
}

describe("persistent run logs", () => {
  test("writes module, aggregate, item, and summary logs", () => {
    const root = tempRoot();
    const store = new RunLogStore({ root, now: new Date("2026-08-14T12:00:00Z"), pid: 42 });

    store.append("dnf", "Installing cowsay");
    const itemDir = store.itemLogDir("dnf");
    store.finalize({ exitCode: 0 });

    expect(Bun.file(store.moduleLogPath("dnf")).text()).resolves.toContain("Installing cowsay");
    expect(Bun.file(join(store.runDir, "run.log")).text()).resolves.toContain("[dnf] Installing cowsay");
    expect(Bun.file(join(store.runDir, "summary.json")).text()).resolves.toContain('"exitCode": 0');
    expect(itemDir).toBe(join(store.runDir, "items", "dnf"));
  });

  test("removes the oldest runs after the size limit is exceeded", () => {
    const root = tempRoot();
    const oldRun = join(root, "old");
    const newRun = join(root, "new");
    mkdirSync(oldRun);
    mkdirSync(newRun);
    writeFileSync(join(oldRun, "run.log"), "a".repeat(80));
    writeFileSync(join(newRun, "run.log"), "b".repeat(80));
    utimesSync(oldRun, new Date(1_000), new Date(1_000));
    utimesSync(newRun, new Date(2_000), new Date(2_000));

    pruneRunLogs(root, 100);

    expect(readdirSync(root)).toEqual(["new"]);
  });

  test("keeps the active run during cleanup", () => {
    const root = tempRoot();
    const oldRun = join(root, "old");
    const activeRun = join(root, "active");
    mkdirSync(oldRun);
    mkdirSync(activeRun);
    writeFileSync(join(oldRun, "run.log"), "a".repeat(80));
    writeFileSync(join(activeRun, "run.log"), "b".repeat(80));
    utimesSync(oldRun, new Date(1_000), new Date(1_000));
    utimesSync(activeRun, new Date(2_000), new Date(2_000));

    pruneRunLogs(root, 50, activeRun);

    expect(readdirSync(root)).toEqual(["active"]);
  });

  test("does not remove another live Primer run", () => {
    const root = tempRoot();
    const oldRun = join(root, "old");
    const liveRun = join(root, "live");
    mkdirSync(oldRun);
    mkdirSync(liveRun);
    writeFileSync(join(oldRun, "run.log"), "a".repeat(80));
    writeFileSync(join(liveRun, "run.log"), "b".repeat(80));
    writeFileSync(join(liveRun, ".active"), `${process.pid}\n`);
    utimesSync(oldRun, new Date(1_000), new Date(1_000));
    utimesSync(liveRun, new Date(2_000), new Date(2_000));

    pruneRunLogs(root, 50);

    expect(readdirSync(root)).toEqual(["live"]);
  });

  test("uses the default for invalid size settings", () => {
    expect(configuredRunLogMaxBytes("invalid")).toBe(100 * 1024 * 1024);
  });
});
