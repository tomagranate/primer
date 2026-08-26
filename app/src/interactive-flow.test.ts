import { describe, expect, test } from "bun:test";
import { existsSync } from "node:fs";
import { mkdtemp, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import type { NodeDef } from "./config";
import { Engine, type NodeState } from "./engine";

function interactive(config: Record<string, string>, id = "setup", deps: string[] = []): NodeDef {
  return {
    id: `interactive:${id}`,
    kind: "interactive",
    label: id,
    deps,
    needsSudo: false,
    config,
  };
}

async function waitForState(engine: Engine, state: NodeState, id = "setup"): Promise<void> {
  const deadline = Date.now() + 2_000;
  while (engine.node(`interactive:${id}`)?.state !== state) {
    if (Date.now() >= deadline) throw new Error(`Interactive step did not reach ${state}`);
    await Bun.sleep(20);
  }
}

describe("interactive setup verification", () => {
  test("shows instructions again until a verify-only setup passes", async () => {
    const root = await mkdtemp(join(tmpdir(), "primer-interactive-"));
    const prepared = join(root, "prepared");
    const ready = join(root, "ready");
    const engine = new Engine([
      interactive({
        prepare: `touch ${JSON.stringify(prepared)}`,
        status: `test -f ${JSON.stringify(ready)}`,
        instruction: "Complete setup.",
        done_detail: "verified",
      }),
      interactive({ status: "false" }, "dependent", ["interactive:setup"]),
    ], {
      primerDir: root,
      dryRun: false,
      skip: [],
      only: [],
      runLogRoot: join(root, "logs"),
    });

    try {
      await engine.start();
      await waitForState(engine, "needs-user");
      expect(existsSync(prepared)).toBe(true);

      const node = engine.node("interactive:setup")!;
      await engine.answerInteractive(node);
      expect(node.state).toBe("needs-user");
      expect(node.detail).toContain("Setup not verified");
      expect(node.logs.at(-1)).toContain("verification failed");
      expect(engine.node("interactive:dependent")?.state).toBe("pending");

      await writeFile(ready, "ready\n");
      await engine.answerInteractive(node);
      expect(node.state).toBe("done");
      expect(node.detail).toBe("verified");
      await waitForState(engine, "needs-user", "dependent");
    } finally {
      engine.cleanup();
      await rm(root, { recursive: true, force: true });
    }
  });

  test("retries a setup command and verifies its result before completion", async () => {
    const root = await mkdtemp(join(tmpdir(), "primer-interactive-"));
    const allowed = join(root, "allowed");
    const ready = join(root, "ready");
    const engine = new Engine([interactive({
      command: `test -f ${JSON.stringify(allowed)} && touch ${JSON.stringify(ready)}`,
      status: `test -f ${JSON.stringify(ready)}`,
    })], {
      primerDir: root,
      dryRun: false,
      skip: [],
      only: [],
      runLogRoot: join(root, "logs"),
    });

    try {
      await engine.start();
      await waitForState(engine, "needs-user");

      const node = engine.node("interactive:setup")!;
      await engine.answerInteractive(node);
      expect(node.state).toBe("needs-user");
      expect(node.logs.at(-1)).toContain("exited with code");

      await writeFile(allowed, "allowed\n");
      await engine.answerInteractive(node);
      expect(node.state).toBe("done");
    } finally {
      engine.cleanup();
      await rm(root, { recursive: true, force: true });
    }
  });

  test("allows skipping only default-off interactive setup", async () => {
    const root = await mkdtemp(join(tmpdir(), "primer-interactive-"));
    const engine = new Engine([
      interactive({ default: "yes", status: "false" }, "required"),
      interactive({ default: "no", status: "false" }, "optional"),
    ], {
      primerDir: root,
      dryRun: false,
      skip: [],
      only: [],
      runLogRoot: join(root, "logs"),
    });

    try {
      await engine.start();
      await waitForState(engine, "needs-user", "required");
      await waitForState(engine, "needs-user", "optional");

      const required = engine.node("interactive:required")!;
      const optional = engine.node("interactive:optional")!;
      engine.skipInteractive(required);
      engine.skipInteractive(optional);

      expect(required.state).toBe("needs-user");
      expect(optional.state).toBe("skipped");
      expect(optional.detail).toBe("optional setup skipped");
    } finally {
      engine.cleanup();
      await rm(root, { recursive: true, force: true });
    }
  });
});
