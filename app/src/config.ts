/**
 * Config loading: parses primer's INI-style .conf files into a unified node
 * graph. Modules and interactive steps are the same thing here — nodes; an
 * interactive step is a node that needs the user and the terminal.
 *
 * The on-disk format calls interactive steps "logins" ([logins],
 * logins.<name>_*, depends_on_logins).
 *
 * Format:
 *   [section]            starts a module section ("logins" is special)
 *   key = value          sets <section>.<key>
 *   <indented line>      continues the previous key (multi-line value)
 *   # comment            ignored
 */
import { existsSync, readdirSync } from "node:fs";
import { readFile } from "node:fs/promises";
import { homedir } from "node:os";
import { basename, join } from "node:path";

export interface RawConfig {
  order: string[];                    // module sections in config order
  values: Map<string, string>;        // "section.key" -> value
}

export interface NodeDef {
  id: string;                         // module name, or "interactive:<name>"
  kind: "module" | "interactive";
  label: string;
  deps: string[];                     // node ids this depends on
  config: Record<string, string>;     // own config (module keys, or interactive-step keys)
  needsSudo: boolean;
}

export function parseConf(text: string, into: RawConfig): void {
  let section = "";
  let key = "";
  for (const line of text.split("\n")) {
    if (/^\s*#/.test(line)) continue;
    if (line.trim() === "") continue;

    const sec = line.match(/^\[([a-z_-]+)\]/);
    if (sec) {
      section = sec[1]!;
      if (section !== "logins" && !into.order.includes(section)) into.order.push(section);
      key = "";
      continue;
    }

    const cont = line.match(/^\s+(.+)/);
    if (cont && key && section) {
      const k = `${section}.${key}`;
      into.values.set(k, `${into.values.get(k) ?? ""}\n${cont[1]}`);
      continue;
    }

    const kv = line.match(/^([a-z_-]+)\s*=\s*(.*)/);
    if (kv && section) {
      key = kv[1]!;
      into.values.set(`${section}.${key}`, kv[2]!);
    }
  }
}

export function configLines(raw: string | undefined): string[] {
  if (!raw) return [];
  return raw.split("\n").map((l) => l.trim()).filter(Boolean);
}

export function boolDefault(value: string | undefined): boolean {
  switch ((value ?? "").toLowerCase().trim()) {
    case "no": case "n": case "false": case "0": case "off": return false;
    default: return true;
  }
}

const splitList = (v: string | undefined) =>
  (v ?? "").split(",").map((s) => s.trim()).filter(Boolean);

function moduleNeedsSudo(mod: string, cfg: RawConfig): boolean {
  const declared = cfg.values.get(`${mod}.needs_sudo`);
  if (declared !== undefined && boolDefault(declared)) return true;
  for (const [k, v] of cfg.values) {
    if (k.startsWith(`${mod}.`) && v.includes("privileged: true")) return true;
  }
  return false;
}

/** Build the unified node list: modules first (config order), then interactive steps. */
export function buildNodes(cfg: RawConfig): NodeDef[] {
  const nodes: NodeDef[] = [];

  const interactiveIds = configLines(cfg.values.get("logins.order"));
  const interactiveId = (name: string) => `interactive:${name}`;

  for (const mod of cfg.order) {
    const config: Record<string, string> = {};
    for (const [k, v] of cfg.values) {
      if (k.startsWith(`${mod}.`)) config[k] = v;
    }
    const deps = [
      ...splitList(cfg.values.get(`${mod}.depends_on`)),
      ...splitList(cfg.values.get(`${mod}.depends_on_logins`)).map(interactiveId),
    ];
    nodes.push({
      id: mod,
      kind: "module",
      label: cfg.values.get(`${mod}.label`) ?? mod,
      deps,
      config,
      needsSudo: moduleNeedsSudo(mod, cfg),
    });
  }

  for (const name of interactiveIds) {
    const get = (suffix: string) => cfg.values.get(`logins.${name}_${suffix}`);
    const config: Record<string, string> = {};
    for (const [k, v] of cfg.values) {
      if (k.startsWith(`logins.${name}_`)) config[k.replace(`logins.${name}_`, "")] = v;
    }
    nodes.push({
      id: interactiveId(name),
      kind: "interactive",
      label: get("label") ?? name,
      deps: splitList(get("depends_on")),
      config,
      needsSudo: false,
    });
  }

  return nodes;
}

/* ── Profile detection (port of primer::detect_profile) ─────────────────── */

export function availableProfiles(primerDir: string): string[] {
  const dir = join(primerDir, "configs", "profiles");
  if (!existsSync(dir)) return [];
  return readdirSync(dir)
    .filter((f) => f.endsWith(".conf"))
    .map((f) => basename(f, ".conf"))
    .sort();
}

async function osReleaseValue(key: string): Promise<string> {
  const file = process.env.PRIMER_OS_RELEASE_FILE ?? "/etc/os-release";
  try {
    const text = await readFile(file, "utf8");
    for (const line of text.split("\n")) {
      const [k, ...rest] = line.split("=");
      if (k === key) return rest.join("=").replace(/^"|"$/g, "");
    }
  } catch { /* no os-release */ }
  return "";
}

export function detectLinuxProfile(
  id: string,
  idLike: string,
  env: NodeJS.ProcessEnv = process.env,
): string {
  id = id.toLowerCase();
  idLike = idLike.toLowerCase();
  const hasDesktop = !!(env.XDG_CURRENT_DESKTOP || env.DESKTOP_SESSION);
  if (id === "fedora") return "fedora-kde";
  if (id === "ubuntu" && hasDesktop) return "ubuntu-desktop";
  const debianish = id === "debian" || id === "ubuntu" || idLike.includes("debian") || idLike.includes("ubuntu");
  const headless = !env.DISPLAY && !env.WAYLAND_DISPLAY && !env.XDG_CURRENT_DESKTOP;
  if (debianish && headless) return "linux-vps";
  if (hasDesktop || env.DISPLAY) return "ubuntu-desktop";
  return "linux-vps";
}

export async function detectProfile(primerDir: string, forced?: string): Promise<string> {
  if (forced) {
    if (availableProfiles(primerDir).includes(forced)) return forced;
    throw new Error(
      `Unknown profile: ${forced}\nValid profiles: ${availableProfiles(primerDir).join(", ")}`,
    );
  }
  if (process.platform === "darwin") return "mac";
  if (process.platform === "linux") {
    const id = await osReleaseValue("ID");
    const idLike = await osReleaseValue("ID_LIKE");
    return detectLinuxProfile(id, idLike);
  }
  throw new Error(`Unsupported OS: ${process.platform}`);
}

/* ── Loading ────────────────────────────────────────────────────────────── */

export function resolvePrimerDir(): string {
  if (process.env.PRIMER_LOCAL) return process.env.PRIMER_LOCAL;
  if (process.env.PRIMER_DIR) return process.env.PRIMER_DIR;
  if (existsSync(join(process.cwd(), "configs", "common.conf"))) return process.cwd();
  return join(homedir(), ".cache", "primer");
}

export async function loadNodes(primerDir: string, profile: string): Promise<NodeDef[]> {
  const files = [
    join(primerDir, "configs", "common.conf"),
    join(primerDir, "configs", "profiles", `${profile}.conf`),
  ];
  const cfg: RawConfig = { order: [], values: new Map() };
  for (const file of files) {
    if (!existsSync(file)) throw new Error(`Missing config file: ${file}`);
    parseConf(await readFile(file, "utf8"), cfg);
  }
  return buildNodes(cfg);
}
