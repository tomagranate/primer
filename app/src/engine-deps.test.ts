import { describe, expect, test } from "bun:test";
import { existsSync } from "node:fs";
import { mkdir, mkdtemp, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import type { NodeDef } from "./config";
import { Engine, type EngineNode } from "./engine";

function moduleNode(id: string, deps: string[] = []): NodeDef {
  return { id, kind: "module", label: id, deps, needsSudo: false, config: {} };
}

function login(id: string, status: string, deps: string[] = [], requires = ""): NodeDef {
  return { id: `interactive:${id}`, kind: "interactive", label: id, deps, needsSudo: false, config: { status, requires } };
}

/** A primer folder whose modules each touch "<id>.ran" in the folder, after `delay` seconds. */
async function primerDir(ids: string[], delay = 0): Promise<string> {
  const root = await mkdtemp(join(tmpdir(), "primer-deps-"));
  await mkdir(join(root, "lib"));
  await writeFile(join(root, "lib", "module.zsh"), "ensure_mise() { :; }\n");
  for (const id of ids) {
    await mkdir(join(root, "modules", id), { recursive: true });
    await writeFile(join(root, "modules", id, "module.zsh"), `mod_update() { sleep ${delay}; touch ${JSON.stringify(join(root, `${id}.ran`))}; }\n`);
  }
  return root;
}

/** Runs the engine the way a run without a terminal does: it skips each login that needs the user. */
async function runHeadless(defs: NodeDef[], root: string, opts: { only?: string[]; skip?: string[] } = {}): Promise<Engine> {
  const engine: Engine = new Engine(defs, {
    primerDir: root,
    dryRun: false,
    skip: opts.skip ?? [],
    only: opts.only ?? [],
    runLogRoot: join(root, "logs"),
    onEvent: (n: EngineNode, event: string) => {
      if (event === "needs-user") engine.skipInteractive(n, true);
    },
  });
  await engine.start();
  await engine.waitUntilFinished();
  engine.cleanup();
  return engine;
}

describe("dependencies", () => {
  test("a module left out with --only or --skip does not block its dependents", async () => {
    const root = await primerDir(["base", "app", "tool"]);
    try {
      const only = await runHeadless([moduleNode("base"), moduleNode("app", ["base"])], root, { only: ["app"] });
      expect(only.node("base")?.state).toBe("skipped");
      expect(only.node("app")?.state).toBe("done");
      expect(existsSync(join(root, "base.ran"))).toBe(false);
      expect(existsSync(join(root, "app.ran"))).toBe(true);

      const skip = await runHeadless([moduleNode("base"), moduleNode("tool", ["base"])], root, { skip: ["base"] });
      expect(skip.node("tool")?.state).toBe("done");
      expect(existsSync(join(root, "tool.ran"))).toBe(true);
    } finally {
      await rm(root, { recursive: true, force: true });
    }
  });

  test("a login that is already done counts, even when its own dependency did not finish", async () => {
    const root = await primerDir(["cell"]);
    try {
      const engine = await runHeadless([
        login("vault", "false"),
        login("github", "true", ["interactive:vault"]),
        login("ticket", "false", ["interactive:vault"]),
        moduleNode("cell", ["interactive:github"]),
      ], root);
      expect(engine.node("interactive:vault")?.state).toBe("skipped");
      expect(engine.node("interactive:github")).toMatchObject({ state: "done", detail: "already logged in" });
      expect(engine.node("interactive:ticket")).toMatchObject({ state: "skipped", detail: "dependency failed" });
      expect(engine.node("cell")?.state).toBe("done");
      expect(existsSync(join(root, "cell.ran"))).toBe(true);
    } finally {
      await rm(root, { recursive: true, force: true });
    }
  });

  test("a login with a missing required command is not done, even when its status passes", async () => {
    const root = await primerDir(["cell"]);
    try {
      const engine = await runHeadless([
        login("vault", "false"),
        login("mcp", "true", ["interactive:vault"], "primer-test-no-such-command"),
        moduleNode("cell", ["interactive:mcp"]),
      ], root);
      expect(engine.node("interactive:mcp")).toMatchObject({ state: "skipped", detail: "dependency failed" });
      expect(engine.node("cell")?.state).toBe("skipped");
    } finally {
      await rm(root, { recursive: true, force: true });
    }
  });

  test("a login checks its status only after its other dependencies finish", async () => {
    const root = await primerDir(["maker", "cell"], 0.3);
    try {
      const engine = await runHeadless([
        login("vault", "false"),
        moduleNode("maker"),
        login("made", `test -f ${JSON.stringify(join(root, "maker.ran"))}`, ["interactive:vault", "maker"]),
        moduleNode("cell", ["interactive:made"]),
      ], root);
      expect(engine.node("interactive:made")?.state).toBe("done");
      expect(engine.node("cell")?.state).toBe("done");
    } finally {
      await rm(root, { recursive: true, force: true });
    }
  });

  test("a dry run does not run the status check of a blocked login", async () => {
    const root = await primerDir([]);
    const ran = join(root, "status.ran");
    try {
      await mkdir(join(root, "modules", "broken"), { recursive: true });
      await writeFile(join(root, "modules", "broken", "module.zsh"), "mod_update() { return 1; }\n");
      const engine = new Engine([moduleNode("broken"), login("after", `touch ${JSON.stringify(ran)}`, ["broken"])], {
        primerDir: root, dryRun: true, skip: [], only: [], runLogRoot: join(root, "logs"),
      });
      await engine.start();
      await engine.waitUntilFinished();
      engine.cleanup();
      expect(engine.node("broken")?.state).toBe("failed");
      expect(engine.node("interactive:after")).toMatchObject({ state: "skipped", detail: "dependency failed" });
      expect(existsSync(ran)).toBe(false);
    } finally {
      await rm(root, { recursive: true, force: true });
    }
  });

  test("a module whose dependency failed still does not run", async () => {
    const root = await primerDir(["cell"]);
    try {
      const engine = await runHeadless([login("ticket", "false"), moduleNode("cell", ["interactive:ticket"])], root);
      expect(engine.node("cell")).toMatchObject({ state: "skipped", detail: "dependency failed" });
      expect(existsSync(join(root, "cell.ran"))).toBe(false);
    } finally {
      await rm(root, { recursive: true, force: true });
    }
  });
});
