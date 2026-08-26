/**
 * primer (TypeScript app) — machine setup manager.
 *
 * Commands:
 *   update    install/update all enabled modules (TUI when on a terminal)
 *   status    check install/health status for all enabled modules
 *
 * With no TTY, update runs headless and prints one line per state change.
 */
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { parseArgs, type Args, CliError } from "./cli";
import { availableAddons, loadNodes, resolvePrimerDir, type NodeDef } from "./config";
import { Engine, type EngineNode } from "./engine";
import { shouldPrintLogs } from "./headless-output";
import { writeMachineConfig } from "./machine-config";
import { runModuleStatus } from "./module-status";
import { droppedModuleIds, profileSetResult, profileSummary } from "./profile-command";
import { resolveSelection, type Selection } from "./selection";
import { createTerminalRestorer, shutdownRenderer } from "./terminal-lifecycle";

function fail(msg: string): never {
  console.error(msg);
  process.exit(1);
}

function help(): void {
  console.log(`primer -- machine setup manager

Usage:
  primer <command> [flags]

Commands:
  update      Install/update everything (idempotent)
  status      Check what's installed and healthy
  profile     Show the selected profile and addons
  profile set [profile] [addon ...]
              Persist a profile and its addons

Flags:
  --dry-run         Preview changes without applying them (update only)
  --skip <module>   Skip a module by name; repeatable (update only)
  --only <module>   Run only this module; repeatable (update only)
  --profile <name>  Force profile: mac, linux-vps, fedora-kde
  --addon <name>    Force an addon for this run; repeatable
  --log             Plain line output instead of the TUI
  --help            Show this help message`);
}

const canUseTui = (args: Args) =>
  !args.headless && process.stdout.isTTY === true && process.stdin.isTTY === true;

async function selectionFor(args: Args, primerDir: string): Promise<Selection> {
  return resolveSelection({
    primerDir,
    profile: args.profile,
    addons: args.addons,
  });
}

async function prepareUpdateSelection(args: Args, primerDir: string): Promise<Selection> {
  const selection = await selectionFor(args, primerDir);
  if (!selection.firstRun) return selection;
  if (!canUseTui(args)) {
    console.log("Run 'primer profile set' to choose addons.");
    return selection;
  }

  const applicable = (await availableAddons(primerDir))
    .filter((addon) => addon.profiles.includes(selection.profile));
  let selected: string[] = [];
  if (applicable.length > 0) {
    const { runAddonPicker } = await import("./addon-picker-runner");
    const result = await runAddonPicker(selection.profile, applicable, []);
    if (result === null) fail("Addon selection cancelled.");
    selected = result;
  }
  await writeMachineConfig({ profile: selection.profile, addons: selected });
  return { ...selection, addons: selected, source: "machine.conf", firstRun: false };
}

function notify(message: string): void {
  // Do not write notification escape sequences while OpenTUI owns stdout.
  // Use the operating system service so the renderer is the only terminal
  // writer.
  if (process.platform === "darwin" && Bun.which("osascript")) {
    const escaped = message.replace(/\\/g, "\\\\").replace(/"/g, '\\"');
    Bun.spawn(["osascript", "-e", `display notification "${escaped}" with title "Primer"`], {
      stdout: "ignore", stderr: "ignore",
    });
  } else if (Bun.which("notify-send")) {
    Bun.spawn(["notify-send", "Primer", message], { stdout: "ignore", stderr: "ignore" });
  }
}

function printShellActivationHint(engine: Engine): void {
  const loginShell = engine.node("login-shell");
  if (loginShell?.state !== "done" || /(?:^|\/)zsh$/.test(process.env.SHELL ?? "")) return;
  console.log("Zsh is configured. Open a new terminal or run 'exec zsh' to use it now.");
}

/* ── update ── */

async function runUpdate(args: Args): Promise<never> {
  const primerDir = resolvePrimerDir();
  const selection = await prepareUpdateSelection(args, primerDir);
  const defs = await loadNodes(primerDir, selection.profile, selection.addons);

  // A piped installer can keep stdout on the terminal while stdin is a pipe.
  // Do not start OpenTUI in that state. Terminal query replies would reach the
  // parent shell and appear as text after Primer exits.
  const useTui = canUseTui(args);

  if (!useTui) {
    const engine = new Engine(defs, {
      primerDir, dryRun: args.dryRun, skip: args.skip, only: args.only,
      onEvent: (n: EngineNode, event: string) => {
        const label = n.kind === "interactive" ? `interactive: ${n.label}` : n.label;
        if (event === "start") console.log(`==> ${label}`);
        else if (event === "needs-user") {
          console.log(`--> ${label}: needs interactive input — skipped (no terminal)`);
          engine.skipInteractive(n, true);
        } else if (["done", "failed", "skipped"].includes(event)) {
          if (shouldPrintLogs(args.dryRun, event) && n.logs.length) {
            for (const line of n.logs) console.log(line);
          }
          console.log(`--> ${label}: ${n.state}${n.detail ? ` (${n.detail})` : ""}`);
        }
      },
    });
    await engine.start();
    await engine.waitUntilFinished();
    console.log(engine.statusLine());
    console.log(`Logs: ${engine.logDirectory}`);
    printShellActivationHint(engine);
    const code = engine.exitCode();
    engine.cleanup();
    process.exit(code);
  }

  // TUI mode. Sudo pre-auth happens inside engine.start() before first paint
  // matters, so create the engine first, then the renderer.
  const engine = new Engine(defs, {
    primerDir, dryRun: args.dryRun, skip: args.skip, only: args.only,
    notify: (msg) => notify(msg),
  });
  await engine.start();

  const { createCliRenderer } = await import("@opentui/core");
  const { createRoot } = await import("@opentui/react");
  const { createElement } = await import("react");
  const { App } = await import("./ui");

  const renderer = await createCliRenderer({ exitOnCtrlC: false, exitSignals: [] });
  engine["opts"].suspendUI = () => renderer.suspend();
  engine["opts"].resumeUI = () => renderer.resume();

  const root = createRoot(renderer);
  const restoreTerminal = createTerminalRestorer();

  let quitting = false;
  const quit = async () => {
    if (quitting) return;
    quitting = true;
    engine.stopTimers();
    // Linux renders on the main thread. Wait for the current frame before
    // destroy(), or deferred teardown can paint on the restored main screen.
    await shutdownRenderer(renderer);
    // Belt and braces: reset every mode the renderer uses, including ones
    // its own teardown covers, plus grapheme clustering (2027) which it
    // leaves set. Then drain in-flight terminal query responses for a beat
    // so they land here, not in the shell after we exit.
    restoreTerminal();
    const discard = () => { /* swallow stray query responses */ };
    try { process.stdin.on("data", discard); process.stdin.resume(); } catch { /* ok */ }
    setTimeout(() => {
      console.log(engine.statusLine());
      console.log(`Logs: ${engine.logDirectory}`);
      printShellActivationHint(engine);
      const code = engine.exitCode();
      engine.cleanup();
      process.exit(code);
    }, 75);
  };

  const handleSignal = () => {
    engine.interrupt();
    void quit();
  };
  process.once("SIGINT", handleSignal);
  process.once("SIGTERM", handleSignal);
  process.once("SIGQUIT", handleSignal);
  process.once("exit", () => {
    restoreTerminal();
    engine.cleanup();
  });

  root.render(createElement(App, { engine, dryRun: args.dryRun, onQuit: quit }));
  return new Promise(() => {}) as Promise<never>; // quit() exits the process
}

/* ── status ── */

async function runStatus(args: Args): Promise<never> {
  const primerDir = resolvePrimerDir();
  const selection = await selectionFor(args, primerDir);
  if (selection.firstRun) console.log("Run 'primer profile set' to choose addons.");
  const defs = (await loadNodes(primerDir, selection.profile, selection.addons))
    .filter((d) => d.kind === "module");
  const workDir = mkdtempSync(join(tmpdir(), "primer-status-"));
  let results;
  try {
    results = await Promise.all(defs.map((def) => runModuleStatus(def, primerDir, workDir)));
  } finally {
    rmSync(workDir, { recursive: true, force: true });
  }

  let issues = 0;
  for (const r of results) {
    const mark = r.ok ? "✓" : "✗";
    if (!r.ok) issues++;
    console.log(`  ${mark}  ${r.def.label.padEnd(20)} ${r.detail}`);
  }
  console.log(issues ? `\n${issues} issue${issues === 1 ? "" : "s"} found` : "\nall healthy");
  process.exit(issues ? 1 : 0);
}

/* ── profile ── */

async function runProfile(args: Args): Promise<never> {
  const primerDir = resolvePrimerDir();
  if (args.profileAction === "show") {
    const selection = await selectionFor(args, primerDir);
    console.log(profileSummary(selection, await availableAddons(primerDir)));
    if (selection.firstRun) console.log("Run 'primer profile set' to choose addons.");
    process.exit(0);
  }

  const explicit = args.profileSetArgs.length > 0;
  let current: Selection | null = null;
  let oldNodes: NodeDef[] = [];
  let comparedPrevious = true;
  try {
    current = await selectionFor(args, primerDir);
    oldNodes = await loadNodes(primerDir, current.profile, current.addons);
  } catch (error) {
    if (!explicit) throw error;
    comparedPrevious = false;
  }

  let profile: string;
  let addons: string[];
  if (explicit) {
    profile = args.profileSetArgs[0]!;
    addons = [...new Set(args.profileSetArgs.slice(1))];
  } else {
    if (!current) throw new Error("Could not resolve the current profile.");
    if (!canUseTui(args)) {
      throw new Error("'primer profile set' needs a terminal when no profile is given.");
    }
    profile = current.profile;
    const applicable = (await availableAddons(primerDir))
      .filter((addon) => addon.profiles.includes(profile));
    if (applicable.length === 0) {
      addons = [];
    } else {
      const { runAddonPicker } = await import("./addon-picker-runner");
      const result = await runAddonPicker(profile, applicable, current.addons);
      if (result === null) fail("Profile selection cancelled.");
      addons = result;
    }
  }

  const newNodes = await loadNodes(primerDir, profile, addons);
  const dropped = droppedModuleIds(oldNodes, newNodes);
  await writeMachineConfig({ profile, addons });
  console.log(profileSetResult(profile, addons, dropped, comparedPrevious));
  process.exit(0);
}

/* ── main ── */

async function main(): Promise<void> {
  const args = parseArgs(process.argv.slice(2));
  if (args.command === "" || args.command === "help") {
    help();
    return;
  }
  if (args.command === "update") await runUpdate(args);
  if (args.command === "status") await runStatus(args);
  if (args.command === "profile") await runProfile(args);
}

try {
  await main();
} catch (error) {
  if (error instanceof CliError || error instanceof Error) fail(error.message);
  fail(String(error));
}
