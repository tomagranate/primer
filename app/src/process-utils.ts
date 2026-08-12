/** Process-tree helpers adapted from Corsa's process supervisor. */
export function signalProcessGroupOrPid(pid: number, signal: NodeJS.Signals): boolean {
  if (pid <= 0) return false;
  try {
    process.kill(-pid, signal);
    return true;
  } catch {
    try {
      process.kill(pid, signal);
      return true;
    } catch {
      return false;
    }
  }
}

export function parseProcessTree(lines: string[]): Map<number, number[]> {
  const children = new Map<number, number[]>();
  for (const line of lines) {
    const [pidText, parentText] = line.trim().split(/\s+/);
    const pid = Number(pidText);
    const parent = Number(parentText);
    if (!Number.isInteger(pid) || !Number.isInteger(parent)) continue;
    const entries = children.get(parent) ?? [];
    entries.push(pid);
    children.set(parent, entries);
  }
  return children;
}

export function descendantPids(rootPid: number): number[] {
  if (rootPid <= 0 || process.platform === "win32") return [];
  const result = Bun.spawnSync(["ps", "-axo", "pid=,ppid="], {
    stdout: "pipe", stderr: "ignore",
  });
  if (result.exitCode !== 0) return [];
  const tree = parseProcessTree(new TextDecoder().decode(result.stdout).split("\n"));
  const resultPids: number[] = [];
  const seen = new Set<number>();
  const visit = (pid: number) => {
    if (seen.has(pid)) return;
    seen.add(pid);
    for (const child of tree.get(pid) ?? []) {
      visit(child);
      resultPids.push(child);
    }
  };
  visit(rootPid);
  return resultPids;
}

export function signalProcessTree(pid: number, signal: NodeJS.Signals): void {
  for (const child of descendantPids(pid)) {
    try { process.kill(child, signal); } catch { /* already gone */ }
  }
  signalProcessGroupOrPid(pid, signal);
}
