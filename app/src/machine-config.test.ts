import { afterEach, describe, expect, test } from "bun:test";
import { mkdir, mkdtemp, readFile, readdir, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { machineConfigPath, readMachineConfig, writeMachineConfig } from "./machine-config";

const roots: string[] = [];

afterEach(async () => {
  await Promise.all(roots.splice(0).map((root) => rm(root, { recursive: true, force: true })));
});

async function testEnv() {
  const root = await mkdtemp(join(tmpdir(), "primer-machine-"));
  roots.push(root);
  return {
    root,
    env: { PRIMER_MACHINE_CONF: join(root, "nested", "machine.conf") },
  };
}

describe("machine config", () => {
  test("uses XDG config and HOME fallbacks", () => {
    expect(machineConfigPath({ HOME: "/machine-home" })).toBe("/machine-home/.config/primer/machine.conf");
    expect(machineConfigPath({ HOME: "/machine-home", XDG_CONFIG_HOME: "/xdg" }))
      .toBe("/xdg/primer/machine.conf");
  });

  test("returns null when the file is missing", async () => {
    const { env } = await testEnv();
    expect(await readMachineConfig(env)).toBeNull();
  });

  test("writes atomically and round-trips profile and addons", async () => {
    const { root, env } = await testEnv();
    await writeMachineConfig({ profile: "fedora-kde", addons: ["gaming", "work"] }, env);
    expect(await readMachineConfig(env)).toEqual({
      profile: "fedora-kde",
      addons: ["gaming", "work"],
    });
    expect(await readFile(env.PRIMER_MACHINE_CONF!, "utf8")).toContain("addons = gaming, work");
    expect(await readdir(join(root, "nested"))).toEqual(["machine.conf"]);
  });

  test("rejects malformed files", async () => {
    const { env } = await testEnv();
    await mkdir(dirname(env.PRIMER_MACHINE_CONF!), { recursive: true });
    await writeFile(env.PRIMER_MACHINE_CONF!, "[machine]\nprofile = mac\n");
    await expect(readMachineConfig(env)).rejects.toThrow("Malformed machine config");
  });
});
