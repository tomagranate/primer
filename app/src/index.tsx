/**
 * primer (TypeScript app) — machine setup manager.
 *
 * Commands:
 *   update    install/update all enabled modules (TUI when on a terminal)
 *   status    check install/health status for all enabled modules
 *
 * With no TTY, update runs headless and prints one line per state change.
 */
import { join } from "node:path";
import { sanitizeLine } from "./ansi";
import { detectProfile, loadNodes, resolvePrimerDir } from "./config";
import { Engine, type EngineNode } from "./engine";
import { shouldPrintLogs } from "./headless-output";

interface Args {
  command: string;
  dryRun: boolean;
  skip: string[];
  only: string[];
  profile?: string;
  headless: boolean;
}

function parseArgs(argv: string[]): Args {
  const args: Args = { command: "", dryRun: false, skip: [], only: [], headless: false };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i]!;
    switch (a) {
      case "update": case "status": args.command = a; break;
      case "--dry-run": args.dryRun = true; break;
      case "--log": args.headless = true; break;
      case "--skip": args.skip.push(need(argv, ++i, a)); break;
      case "--only": args.only.push(need(argv, ++i, a)); break;
      case "--profile": args.profile = need(argv, ++i, a); break;
      case "--help": case "-h": case "help": args.command = "help"; break;
      default: fail(`Unknown argument: ${a}\nRun 'primer --help' for usage.`);
    }
  }
  if (args.skip.length && args.only.length) fail("--skip and --only cannot be used together.");
  if (args.command && (args.skip.length || args.only.length || args.dryRun) && args.command !== "update") {
    fail("--dry-run, --skip, and --only are only valid with 'update'.");
  }
  return args;
}

function need(argv: string[], i: number, flag: string): string {
  const v = argv[i];
  if (!v || v.startsWith("--")) fail(`Missing argument for ${flag}`);
  return v!;
}

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

Flags:
  --dry-run         Preview changes without applying them (update only)
  --skip <module>   Skip a module by name; repeatable (update only)
  --only <module>   Run only this module; repeatable (update only)
  --profile <name>  Force profile: mac, linux-vps, ubuntu-desktop, fedora-kde
  --log             Plain line output instead of the TUI
  --help            Show this help message`);
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

/** Last-resort terminal restoration. Safe to call repeatedly and during exit. */
function resetTerminal(): void {
  try { process.stdin.setRawMode?.(false); } catch { /* stdin may be gone */ }
  try {
    process.stdout.write(
      "\x1b[?1000l\x1b[?1002l\x1b[?1003l\x1b[?1006l" +
      "\x1b[?2027l\x1b[?1049l\x1b[?25h\x1b[0m",
    );
  } catch { /* stdout may be gone */ }
}

/* ── update ── */

async function runUpdate(args: Args): Promise<never> {
  const primerDir = resolvePrimerDir();
  const profile = await detectProfile(primerDir, args.profile ?? process.env.PRIMER_PROFILE);
  const defs = await loadNodes(primerDir, profile);

  // A piped installer can keep stdout on the terminal while stdin is a pipe.
  // Do not start OpenTUI in that state. Terminal query replies would reach the
  // parent shell and appear as text after Primer exits.
  const useTui = !args.headless && process.stdout.isTTY && process.stdin.isTTY;

  if (!useTui) {
    const engine = new Engine(defs, {
      primerDir, dryRun: args.dryRun, skip: args.skip, only: args.only,
      onEvent: (n: EngineNode, event: string) => {
        const label = n.kind === "interactive" ? `interactive: ${n.label}` : n.label;
        if (event === "start") console.log(`==> ${label}`);
        else if (event === "needs-user") {
          console.log(`--> ${label}: needs interactive input — skipped (no terminal)`);
          engine.skipInteractive(n);
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

  let quitting = false;
  const quit = () => {
    if (quitting) return;
    quitting = true;
    engine.stopTimers();
    renderer.stop();
    renderer.destroy();
    // Belt and braces: reset every mode the renderer uses, including ones
    // its own teardown covers, plus grapheme clustering (2027) which it
    // leaves set. Then drain in-flight terminal query responses for a beat
    // so they land here, not in the shell after we exit.
    resetTerminal();
    const discard = () => { /* swallow stray query responses */ };
    try { process.stdin.on("data", discard); process.stdin.resume(); } catch { /* ok */ }
    setTimeout(() => {
      console.log(engine.statusLine());
      console.log(`Logs: ${engine.logDirectory}`);
      const code = engine.exitCode();
      engine.cleanup();
      process.exit(code);
    }, 75);
  };

  const handleSignal = () => {
    engine.interrupt();
    quit();
  };
  process.once("SIGINT", handleSignal);
  process.once("SIGTERM", handleSignal);
  process.once("SIGQUIT", handleSignal);
  process.once("exit", () => {
    resetTerminal();
    engine.cleanup();
  });

  root.render(createElement(App, { engine, dryRun: args.dryRun, onQuit: quit }));
  return new Promise(() => {}) as Promise<never>; // quit() exits the process
}

/* ── status ── */

async function runStatus(args: Args): Promise<never> {
  const primerDir = resolvePrimerDir();
  const profile = await detectProfile(primerDir, args.profile ?? process.env.PRIMER_PROFILE);
  const defs = (await loadNodes(primerDir, profile)).filter((d) => d.kind === "module");

  const results = await Promise.all(defs.map(async (d) => {
    const statusFile = join(process.env.TMPDIR ?? "/tmp", `primer-status-${d.id}-${process.pid}`);
    const proc = Bun.spawn(["zsh", "-c",
      `source "\${PRIMER_DIR}/lib/module.zsh"; source "\${MOD_DIR}/module.zsh" || exit 1; mod_status`,
    ], {
      stdout: "ignore", stderr: "ignore",
      env: {
        ...process.env,
        MOD_STATUS_FILE: statusFile,
        MOD_DIR: join(primerDir, "modules", d.id),
        MOD_NAME: d.id,
        PRIMER_DIR: primerDir,
      },
    });
    const code = await proc.exited;
    let detail = "";
    try { detail = sanitizeLine((await Bun.file(statusFile).text()).trim()); } catch { /* none */ }
    try { await Bun.file(statusFile).delete(); } catch { /* best effort */ }
    if (!detail) detail = code === 0 ? "up to date" : "not found";
    return { def: d, ok: code === 0, detail };
  }));

  let issues = 0;
  for (const r of results) {
    const mark = r.ok ? "✓" : "✗";
    if (!r.ok) issues++;
    console.log(`  ${mark}  ${r.def.label.padEnd(20)} ${r.detail}`);
  }
  console.log(issues ? `\n${issues} issue${issues === 1 ? "" : "s"} found` : "\nall healthy");
  process.exit(issues ? 1 : 0);
}

/* ── main ── */

const args = parseArgs(process.argv.slice(2));
if (args.command === "" || args.command === "help") {
  help();
  process.exit(0);
}
if (args.command === "update") await runUpdate(args);
if (args.command === "status") await runStatus(args);
