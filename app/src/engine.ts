/**
 * DAG engine: schedules module and interactive nodes as one graph.
 *
 * Module nodes spawn zsh through Primer's module contract:
 * MOD_* env vars, a generated config file, logs to a file, status text via
 * MOD_STATUS_FILE. The module.zsh files do not change.
 *
 * Interactive nodes wait for the user (state "needs-user"). The UI answers
 * them. Pane commands stream output into the TUI while other nodes run.
 */
import { mkdtempSync, rmSync } from "node:fs";
import { readFile, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { sanitizeLine } from "./ansi";
import type { NodeDef } from "./config";
import { boolDefault } from "./config";
import { LineParser } from "./line-parser";
import { signalProcessTree } from "./process-utils";

export type NodeState =
  | "pending"      // waiting on deps
  | "running"      // module subprocess active
  | "checking"     // interactive: probing status_cmd / requires
  | "needs-user"   // interactive: ready, waiting for the user
  | "interacting"  // interactive command is active
  | "done" | "failed" | "skipped";

export interface EngineNode extends NodeDef {
  state: NodeState;
  detail: string;
  logs: string[];
  items: EngineItem[];
  start?: number;
  end?: number;
  notified: boolean;
  defaultOn: boolean;   // interactive-step default from config
}

export interface EngineItem {
  name: string;
  state: string;
  detail: string;
  logs: string[];
}

export function parseItemRecords(text: string): Array<Omit<EngineItem, "logs">> {
  const records: Array<Omit<EngineItem, "logs">> = [];
  for (const record of text.split("\n")) {
    if (!record) continue;
    const [state = "", name = "", detail = ""] = record.split("\t");
    if (!name || !state) continue;
    records.push({ name, state, detail });
  }
  return records;
}

export interface EngineOptions {
  primerDir: string;
  dryRun: boolean;
  skip: string[];
  only: string[];
  /** Hand the terminal to an interactive command and take it back after. */
  suspendUI?: () => void;
  resumeUI?: () => void;
  /** Called when a node needs the user and the terminal may be unfocused. */
  notify?: (message: string) => void;
  /** State-change hook (headless mode prints from this). */
  onEvent?: (node: EngineNode, event: string) => void;
}

const SETTLED: NodeState[] = ["done", "failed", "skipped"];
const MAX_LOG_LINES = 10_000;

export class Engine {
  nodes: EngineNode[] = [];
  startedAt = Date.now();
  interrupted = false;
  private opts: EngineOptions;
  private tmp: string;
  private timer?: ReturnType<typeof setInterval>;
  private sudoTimer?: ReturnType<typeof setInterval>;
  private procs = new Map<string, Bun.Subprocess>();

  constructor(defs: NodeDef[], opts: EngineOptions) {
    this.opts = opts;
    this.tmp = mkdtempSync(join(tmpdir(), "primer-"));
    this.nodes = defs.map((d) => ({
      ...d,
      state: "pending",
      detail: "",
      logs: [],
      items: [],
      notified: false,
      defaultOn: d.kind === "interactive" ? boolDefault(d.config["default"]) : true,
    }));
    this.applyFilters();
  }

  node(id: string): EngineNode | undefined {
    return this.nodes.find((n) => n.id === id);
  }

  /* ── lifecycle ── */

  async start(): Promise<void> {
    if (!this.opts.dryRun && this.needsSudo()) await this.sudoPreauth();
    this.timer = setInterval(() => this.schedule(), 200);
    this.schedule();
  }

  /** True when every node reached a settled state. */
  finished(): boolean {
    return this.nodes.every((n) => SETTLED.includes(n.state));
  }

  async waitUntilFinished(): Promise<void> {
    while (!this.finished()) await Bun.sleep(150);
    this.stopTimers();
  }

  stopTimers(): void {
    if (this.timer) clearInterval(this.timer);
    if (this.sudoTimer) clearInterval(this.sudoTimer);
  }

  interrupt(): void {
    this.interrupted = true;
    for (const [id, proc] of this.procs) {
      signalProcessTree(proc.pid, "SIGTERM");
      const n = this.node(id);
      if (n && !SETTLED.includes(n.state)) this.settle(n, "failed", "interrupted");
    }
    for (const n of this.nodes) {
      if (n.state === "pending" || n.state === "needs-user" || n.state === "checking") {
        this.settle(n, "skipped", "interrupted");
      }
    }
    this.stopTimers();
  }

  cleanup(): void {
    this.stopTimers();
    for (const proc of this.procs.values()) signalProcessTree(proc.pid, "SIGKILL");
    this.procs.clear();
    try { rmSync(this.tmp, { recursive: true, force: true }); } catch { /* best effort */ }
  }

  exitCode(): number {
    if (this.interrupted) return 130;
    return this.nodes.some((n) => n.state === "failed") ? 1 : 0;
  }

  /* ── filters / sudo ── */

  private applyFilters(): void {
    const { skip, only } = this.opts;
    for (const n of this.nodes) {
      if (n.kind !== "module") continue;
      if (skip.includes(n.id)) this.settle(n, "skipped", "skipped via --skip");
      if (only.length && !only.includes(n.id)) this.settle(n, "skipped", "not in --only");
    }
  }

  private needsSudo(): boolean {
    if (process.getuid?.() === 0) return false;
    return this.nodes.some((n) => n.state !== "skipped" && n.needsSudo);
  }

  private async sudoPreauth(): Promise<void> {
    const proc = Bun.spawn(["sudo", "-p", "Primer setup needs admin access. Password: ", "-v"], {
      stdin: "inherit", stdout: "inherit", stderr: "inherit",
    });
    if ((await proc.exited) !== 0) throw new Error("sudo authentication failed");
    this.sudoTimer = setInterval(() => {
      Bun.spawn(["sudo", "-n", "true"], { stdout: "ignore", stderr: "ignore" });
    }, 60_000);
  }

  /* ── scheduling ── */

  private depState(n: EngineNode): "ready" | "blocked" | "waiting" {
    let waiting = false;
    for (const dep of n.deps) {
      const depNode = this.node(dep) ?? this.node(`interactive:${dep}`);
      if (!depNode) continue; // dep not in this profile — treat as met
      // A preview never blocks modules on interactive work it cannot perform.
      if (this.opts.dryRun && depNode.kind === "interactive") continue;
      if (depNode.state === "failed" || depNode.state === "skipped") return "blocked";
      if (depNode.state !== "done") waiting = true;
    }
    return waiting ? "waiting" : "ready";
  }

  private schedule(): void {
    if (this.interrupted) return;
    for (const n of this.nodes) {
      if (n.state !== "pending") continue;
      const ds = this.depState(n);
      if (ds === "blocked") { this.settle(n, "skipped", "dependency failed"); continue; }
      if (ds !== "ready") continue;
      if (n.kind === "interactive") {
        if (this.opts.dryRun) { this.settle(n, "skipped", "dry run"); continue; }
        void this.prepareInteractive(n);
      } else {
        void this.runModule(n);
      }
    }
  }

  private settle(n: EngineNode, state: NodeState, detail: string): void {
    n.state = state;
    n.detail = detail;
    n.end = Date.now();
    this.opts.onEvent?.(n, state);
  }

  private updateDetail(n: EngineNode, detail: string): void {
    if (!detail || detail === n.detail) return;
    n.detail = detail;
    this.appendLog(n.logs, detail);
  }

  private appendLog(logs: string[], line: string, replacePrevious = false): void {
    const clean = sanitizeLine(line);
    if (!clean) return;
    if (replacePrevious && logs.length) logs[logs.length - 1] = clean;
    else logs.push(clean);
    if (logs.length > MAX_LOG_LINES) logs.splice(0, logs.length - MAX_LOG_LINES);
  }

  private async readLogs(logs: string[], stream: ReadableStream<Uint8Array>): Promise<void> {
    const parser = new LineParser((line, replace) => this.appendLog(logs, line, replace));
    const reader = stream.getReader();
    try {
      while (true) {
        const { done, value } = await reader.read();
        if (done) break;
        parser.write(value);
      }
      parser.flush();
    } catch {
      // A killed process may close a stream while it is being read.
    } finally {
      reader.releaseLock();
    }
  }

  /* ── module execution ── */

  private zshQuote(v: string): string {
    return `"${v.replace(/[\\$"`]/g, (m) => `\\${m}`)}"`;
  }

  private async runModule(n: EngineNode): Promise<void> {
    n.state = "running";
    n.start = Date.now();
    n.detail = "";
    this.updateDetail(n, "starting...");
    this.opts.onEvent?.(n, "start");

    const modDir = join(this.opts.primerDir, "modules", n.id);
    const statusFile = join(this.tmp, `${n.id}.status`);
    const itemsFile = join(this.tmp, `${n.id}.items`);
    const itemLogDir = join(this.tmp, `${n.id}.item-logs`);
    const configFile = join(this.tmp, `${n.id}.config.zsh`);
    const runner = join(this.tmp, `${n.id}.runner.zsh`);

    const configLines = ["typeset -gA _mod_config=()"];
    for (const [k, v] of Object.entries(n.config)) {
      configLines.push(`_mod_config[${k}]=${this.zshQuote(v)}`);
    }
    await writeFile(configFile, configLines.join("\n") + "\n");
    await writeFile(runner, [
      "#!/bin/zsh",
      'source "${PRIMER_DIR}/lib/module.zsh"',
      'source "${MOD_CONFIG_FILE}"',
      'source "${MOD_DIR}/module.zsh" || { echo "Failed to load module: ${MOD_NAME}"; exit 1; }',
      '"mod_${MOD_ACTION}"',
      "",
    ].join("\n"));

    const proc = Bun.spawn(["zsh", runner], {
      stdin: "ignore", stdout: "pipe", stderr: "pipe",
      env: {
        ...process.env,
        MOD_STATUS_FILE: statusFile,
        MOD_ITEMS_FILE: itemsFile,
        MOD_ITEM_LOG_DIR: itemLogDir,
        MOD_CONFIG_FILE: configFile,
        MOD_DIR: modDir,
        MOD_NAME: n.id,
        MOD_ACTION: "update",
        PRIMER_DIR: this.opts.primerDir,
        DRY_RUN: this.opts.dryRun ? "true" : "false",
        HOMEBREW_NO_COLOR: "1",
        HOMEBREW_NO_EMOJI: "1",
        HOMEBREW_NO_ENV_HINTS: "1",
        CI: "1",
        CODEX_NON_INTERACTIVE: "1",
        NONINTERACTIVE: "1",
      },
    });
    this.procs.set(n.id, proc);

    const itemStates = new Map<string, string>();
    const pollModuleState = async () => {
      try {
        const text = sanitizeLine((await readFile(statusFile, "utf8")).trim());
        if (text) this.updateDetail(n, text);
      } catch { /* not written yet */ }
      try {
        const text = await readFile(itemsFile, "utf8");
        for (const { state, name, detail } of parseItemRecords(text)) {
          let item = n.items.find((candidate) => candidate.name === name);
          if (!item) {
            item = { name, state, detail, logs: [] };
            n.items.push(item);
          }
          const value = `${state}\t${detail}`;
          if (itemStates.get(name) === value) continue;
          itemStates.set(name, value);
          item.state = state;
          item.detail = detail;
          if (state !== "pending") {
            this.appendLog(n.logs, `${name}: ${state}${detail ? ` (${detail})` : ""}`);
          }
        }
      } catch { /* not written yet */ }
      try {
        const manifest = await readFile(join(itemLogDir, "manifest"), "utf8");
        for (const record of manifest.split("\n")) {
          if (!record) continue;
          const [slot = "", name = ""] = record.split("\t");
          if (!slot || !name) continue;
          let item = n.items.find((candidate) => candidate.name === name);
          if (!item) {
            item = { name, state: "running", detail: "", logs: [] };
            n.items.push(item);
          }
          const text = await readFile(join(itemLogDir, `${slot}.log`), "utf8").catch(() => "");
          item.logs = text.split(/[\r\n]/).map(sanitizeLine).filter(Boolean).slice(-MAX_LOG_LINES);
        }
      } catch { /* no parallel items */ }
    };
    const statusPoll = setInterval(() => void pollModuleState(), 250);

    const readers = [
      this.readLogs(n.logs, proc.stdout as ReadableStream<Uint8Array>),
      this.readLogs(n.logs, proc.stderr as ReadableStream<Uint8Array>),
    ];
    const code = await proc.exited;
    await Promise.all(readers);
    clearInterval(statusPoll);
    await pollModuleState();
    this.procs.delete(n.id);
    if (this.interrupted && SETTLED.includes(n.state)) return;

    try {
      const text = sanitizeLine((await readFile(statusFile, "utf8")).trim());
      if (text) this.updateDetail(n, text);
    } catch { /* keep last detail */ }
    this.settle(n, code === 0 ? "done" : "failed",
      n.detail || (code === 0 ? "done" : "failed"));
  }

  /* ── interactive execution ── */

  private async prepareInteractive(n: EngineNode): Promise<void> {
    n.state = "checking";
    n.start = Date.now();
    this.opts.onEvent?.(n, "checking");

    const missing = (n.config["requires"] ?? "")
      .split(/[,\s]+/).filter(Boolean)
      .filter((cmd) => !Bun.which(cmd));
    if (missing.length) {
      this.settle(n, "skipped", `missing: ${missing.join(", ")}`);
      return;
    }

    const statusCmd = n.config["status"];
    if (statusCmd) {
      const proc = Bun.spawn(["zsh", "-c", statusCmd], { stdout: "ignore", stderr: "ignore" });
      if ((await proc.exited) === 0) {
        this.settle(n, "done", `already ${n.config["done_detail"] ?? "logged in"}`);
        return;
      }
    }

    n.state = "needs-user";
    n.detail = n.defaultOn ? "waiting for you" : "waiting for you (default: skip)";
    n.notified = true;
    this.opts.notify?.(`primer: ${n.label} is waiting for your input`);
    this.opts.onEvent?.(n, "needs-user");
  }

  private async pipeLogs(n: EngineNode, stream: ReadableStream<Uint8Array>): Promise<void> {
    await this.readLogs(n.logs, stream);
  }

  /** UI answered: run the command in its configured display mode. */
  async answerInteractive(n: EngineNode): Promise<void> {
    if (n.state !== "needs-user") return;
    const command = n.config["command"];
    if (!command) { this.settle(n, "skipped", "no command configured"); return; }

    n.state = "interacting";
    n.detail = "signing in";
    this.opts.onEvent?.(n, "interacting");

    if (n.config["mode"] === "pane") {
      this.appendLog(n.logs, "Starting browser sign-in.");
      const proc = Bun.spawn(["zsh", "-c", command], {
        stdin: "ignore", stdout: "pipe", stderr: "pipe",
        env: { ...process.env, GH_PROMPT_DISABLED: "1", NO_COLOR: "1" },
      });
      this.procs.set(n.id, proc);
      const readers = [
        this.pipeLogs(n, proc.stdout as ReadableStream<Uint8Array>),
        this.pipeLogs(n, proc.stderr as ReadableStream<Uint8Array>),
      ];
      const code = await proc.exited;
      await Promise.all(readers);
      this.procs.delete(n.id);
      if (code === 0) this.settle(n, "done", "complete");
      else if (code === 130) this.settle(n, "skipped", "interrupted");
      else this.settle(n, "failed", `exit ${code}`);
      return;
    }

    this.opts.suspendUI?.();
    process.stdout.write(`\nPrimer paused for ${n.label}. Complete the prompt to return.\n\n`);
    let code = 1;
    // The terminal sends SIGINT to the complete foreground process group.
    // Keep Primer alive while the interactive child handles Ctrl-C.
    const holdSigint = () => {};
    process.on("SIGINT", holdSigint);
    try {
      // Keep all three streams attached to the terminal. GitHub CLI changes
      // behavior when stdout or stderr is a pipe.
      const proc = Bun.spawn(["zsh", "-c", command], {
        stdin: "inherit", stdout: "inherit", stderr: "inherit",
        env: { ...process.env },
      });
      code = await proc.exited;
    } finally {
      process.removeListener("SIGINT", holdSigint);
      this.opts.resumeUI?.();
    }

    if (code === 0) this.settle(n, "done", "complete");
    else if (code === 130) this.settle(n, "skipped", "interrupted");
    else this.settle(n, "failed", `exit ${code}`);
  }

  skipInteractive(n: EngineNode): void {
    if (n.state === "needs-user") this.settle(n, "skipped", "skipped by user");
  }

  /* ── summary ── */

  counts() {
    const c = { done: 0, failed: 0, skipped: 0, running: 0, settled: 0, total: this.nodes.length };
    for (const n of this.nodes) {
      if (n.state === "done") c.done++;
      if (n.state === "failed") c.failed++;
      if (n.state === "skipped") c.skipped++;
      if (n.state === "running" || n.state === "interacting") c.running++;
      if (SETTLED.includes(n.state)) c.settled++;
    }
    return c;
  }

  statusLine(): string {
    const c = this.counts();
    const failedNames = this.nodes.filter((n) => n.state === "failed").map((n) => n.label);
    const mark = this.interrupted ? "!" : c.failed ? "✗" : "✓";
    const parts = [`${this.nodes.filter((n) => n.state === "done" && n.kind === "module").length} modules done`];
    const interactiveDone = this.nodes.filter((n) => n.state === "done" && n.kind === "interactive").length;
    if (interactiveDone) parts.push(`${interactiveDone} interactive step${interactiveDone === 1 ? "" : "s"} done`);
    if (c.failed) parts.push(`${c.failed} failed (${failedNames.join(", ")})`);
    if (c.skipped) parts.push(`${c.skipped} skipped`);
    if (this.interrupted) parts.push("interrupted");
    const secs = ((Date.now() - this.startedAt) / 1000).toFixed(0);
    return `${mark} primer: ${parts.join(" · ")} · ${secs}s`;
  }
}
