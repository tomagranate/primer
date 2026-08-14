import {
  closeSync,
  existsSync,
  mkdirSync,
  mkdtempSync,
  openSync,
  readdirSync,
  readFileSync,
  rmSync,
  statSync,
  writeSync,
  writeFileSync,
} from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";

export const DEFAULT_RUN_LOG_MAX_BYTES = 100 * 1024 * 1024;

function safeName(value: string): string {
  return value.replace(/[^a-zA-Z0-9._-]+/g, "-") || "unknown";
}

function directorySize(path: string): number {
  let total = 0;
  for (const entry of readdirSync(path, { withFileTypes: true })) {
    const child = join(path, entry.name);
    if (entry.isDirectory()) total += directorySize(child);
    else if (entry.isFile()) total += statSync(child).size;
  }
  return total;
}

export function configuredRunLogMaxBytes(value = process.env.PRIMER_LOG_MAX_BYTES): number {
  if (!value) return DEFAULT_RUN_LOG_MAX_BYTES;
  const parsed = Number(value);
  return Number.isFinite(parsed) && parsed > 0 ? Math.floor(parsed) : DEFAULT_RUN_LOG_MAX_BYTES;
}

export function pruneRunLogs(root: string, maxBytes: number, keep?: string): void {
  if (maxBytes <= 0) return;
  let entries;
  try {
    entries = readdirSync(root, { withFileTypes: true })
      .filter((entry) => entry.isDirectory())
      .map((entry) => {
        const path = join(root, entry.name);
        return { path, size: directorySize(path), modified: statSync(path).mtimeMs };
      })
      .sort((a, b) => a.modified - b.modified);
  } catch {
    return;
  }

  let total = entries.reduce((sum, entry) => sum + entry.size, 0);
  for (const entry of entries) {
    if (total <= maxBytes) break;
    if (entry.path === keep) continue;
    const activeMarker = join(entry.path, ".active");
    if (existsSync(activeMarker)) {
      const pid = Number(readFileSync(activeMarker, "utf8").trim());
      try {
        process.kill(pid, 0);
        continue;
      } catch {
        try { rmSync(activeMarker, { force: true }); } catch { /* best effort */ }
      }
    }
    try {
      rmSync(entry.path, { recursive: true, force: true });
      total -= entry.size;
    } catch {
      // Cleanup is best effort. A failed cleanup must not stop Primer.
    }
  }
}

export interface RunLogStoreOptions {
  root?: string;
  maxBytes?: number;
  now?: Date;
  pid?: number;
}

export class RunLogStore {
  readonly root: string;
  readonly runDir: string;
  readonly maxBytes: number;
  private finalized = false;
  private aggregateFd?: number;
  private moduleFds = new Map<string, number>();

  constructor(options: RunLogStoreOptions = {}) {
    const stateHome = process.env.XDG_STATE_HOME
      || join(process.env.HOME || homedir(), ".local", "state");
    this.root = options.root || join(stateHome, "primer", "runs");
    this.maxBytes = options.maxBytes ?? configuredRunLogMaxBytes();
    mkdirSync(this.root, { recursive: true, mode: 0o700 });
    pruneRunLogs(this.root, this.maxBytes);

    const now = options.now ?? new Date();
    const stamp = now.toISOString().replace(/[-:]/g, "").replace(/\.\d{3}Z$/, "Z");
    this.runDir = mkdtempSync(join(this.root, `${stamp}-${options.pid ?? process.pid}-`));
    writeFileSync(join(this.runDir, ".active"), `${options.pid ?? process.pid}\n`, "utf8");
  }

  moduleLogPath(nodeId: string): string {
    return join(this.runDir, `${safeName(nodeId)}.log`);
  }

  itemLogDir(nodeId: string): string {
    const path = join(this.runDir, "items", safeName(nodeId));
    mkdirSync(path, { recursive: true });
    return path;
  }

  append(nodeId: string, line: string): void {
    try {
      let moduleFd = this.moduleFds.get(nodeId);
      if (moduleFd == null) {
        moduleFd = openSync(this.moduleLogPath(nodeId), "a", 0o600);
        this.moduleFds.set(nodeId, moduleFd);
      }
      this.aggregateFd ??= openSync(join(this.runDir, "run.log"), "a", 0o600);
      writeSync(moduleFd, `${line}\n`);
      writeSync(this.aggregateFd, `[${nodeId}] ${line}\n`);
    } catch {
      // In-memory logs remain available if the disk becomes unavailable.
    }
  }

  finalize(summary: unknown): void {
    if (this.finalized) return;
    this.finalized = true;
    for (const fd of this.moduleFds.values()) {
      try { closeSync(fd); } catch { /* best effort */ }
    }
    this.moduleFds.clear();
    if (this.aggregateFd != null) {
      try { closeSync(this.aggregateFd); } catch { /* best effort */ }
      this.aggregateFd = undefined;
    }
    try {
      writeFileSync(join(this.runDir, "summary.json"), `${JSON.stringify(summary, null, 2)}\n`, "utf8");
    } catch {
      // Keep the command result even if summary persistence fails.
    }
    try { rmSync(join(this.runDir, ".active"), { force: true }); } catch { /* best effort */ }
    pruneRunLogs(this.root, this.maxBytes, this.runDir);
  }
}
