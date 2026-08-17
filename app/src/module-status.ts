import { readFile, writeFile } from "node:fs/promises";
import { join } from "node:path";
import { sanitizeLine } from "./ansi";
import type { NodeDef } from "./config";
import { renderModuleConfig } from "./module-config";

export interface ModuleStatusResult {
  def: NodeDef;
  ok: boolean;
  detail: string;
}

export async function runModuleStatus(
  def: NodeDef,
  primerDir: string,
  workDir: string,
): Promise<ModuleStatusResult> {
  const statusFile = join(workDir, `${def.id}.status`);
  const configFile = join(workDir, `${def.id}.config.zsh`);
  await writeFile(configFile, renderModuleConfig(def.config));

  const proc = Bun.spawn([
    "zsh",
    "-c",
    'source "${PRIMER_DIR}/lib/module.zsh"; ensure_mise; source "${MOD_CONFIG_FILE}"; source "${MOD_DIR}/module.zsh" || exit 1; mod_status',
  ], {
    stdout: "ignore",
    stderr: "ignore",
    env: {
      ...process.env,
      MOD_STATUS_FILE: statusFile,
      MOD_CONFIG_FILE: configFile,
      MOD_DIR: join(primerDir, "modules", def.id),
      MOD_NAME: def.id,
      PRIMER_DIR: primerDir,
    },
  });

  const code = await proc.exited;
  let detail = "";
  try {
    detail = sanitizeLine((await readFile(statusFile, "utf8")).trim());
  } catch { /* no status text */ }
  if (!detail) detail = code === 0 ? "up to date" : "not found";
  return { def, ok: code === 0, detail };
}
