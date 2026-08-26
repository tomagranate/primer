import { randomUUID } from "node:crypto";
import { existsSync } from "node:fs";
import { mkdir, readFile, rename, unlink, writeFile } from "node:fs/promises";
import { homedir } from "node:os";
import { dirname, join } from "node:path";
import { parseConf, type RawConfig } from "./config";

export interface MachineConfig {
  profile: string;
  addons: string[];
}

export function machineConfigPath(env: NodeJS.ProcessEnv = process.env): string {
  const home = env.HOME || homedir();
  return env.PRIMER_MACHINE_CONF
    ?? join(env.XDG_CONFIG_HOME || join(home, ".config"), "primer", "machine.conf");
}

export async function readMachineConfig(
  env: NodeJS.ProcessEnv = process.env,
): Promise<MachineConfig | null> {
  const path = machineConfigPath(env);
  if (!existsSync(path)) return null;

  const raw: RawConfig = { order: [], values: new Map() };
  parseConf(await readFile(path, "utf8"), raw);
  const profile = raw.values.get("machine.profile")?.trim();
  const addonsValue = raw.values.get("machine.addons");
  if (!profile || addonsValue === undefined) {
    throw new Error(
      `Malformed machine config: ${path}\nRun 'primer profile set' to replace it.`,
    );
  }
  return {
    profile,
    addons: addonsValue.split(",").map((item) => item.trim()).filter(Boolean),
  };
}

export async function writeMachineConfig(
  config: MachineConfig,
  env: NodeJS.ProcessEnv = process.env,
): Promise<void> {
  const path = machineConfigPath(env);
  const directory = dirname(path);
  const temp = join(directory, `.machine.conf.${process.pid}.${randomUUID()}.tmp`);
  const text = [
    "# Written by primer. Edit by hand or run: primer profile set",
    "[machine]",
    `profile = ${config.profile}`,
    `addons = ${config.addons.join(", ")}`,
    "",
  ].join("\n");

  await mkdir(directory, { recursive: true });
  try {
    await writeFile(temp, text, { encoding: "utf8", flag: "wx", mode: 0o600 });
    await rename(temp, path);
  } catch (error) {
    await unlink(temp).catch(() => undefined);
    throw error;
  }
}
