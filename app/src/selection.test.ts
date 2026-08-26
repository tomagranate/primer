import { afterEach, describe, expect, test } from "bun:test";
import { mkdir, mkdtemp, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { writeMachineConfig } from "./machine-config";
import { resolveSelection } from "./selection";

const roots: string[] = [];

afterEach(async () => {
  await Promise.all(roots.splice(0).map((root) => rm(root, { recursive: true, force: true })));
});

async function fixture() {
  const root = await mkdtemp(join(tmpdir(), "primer-selection-"));
  roots.push(root);
  await mkdir(join(root, "configs", "profiles"), { recursive: true });
  await mkdir(join(root, "configs", "addons"), { recursive: true });
  await writeFile(join(root, "configs", "common.conf"), "[common]\nlabel = Common\n");
  for (const profile of ["fedora-kde", "linux-vps", "mac"]) {
    await writeFile(join(root, "configs", "profiles", `${profile}.conf`), `[${profile}]\nlabel = ${profile}\n`);
  }
  await writeFile(join(root, "configs", "addons", "gaming.conf"), `
[addon]
label = Gaming
description = Games.
profiles = fedora-kde
[game]
label = Game
`);
  const osRelease = join(root, "os-release");
  await writeFile(osRelease, "ID=fedora\n");
  return {
    root,
    env: {
      PRIMER_MACHINE_CONF: join(root, "machine.conf"),
      PRIMER_OS_RELEASE_FILE: osRelease,
    } satisfies NodeJS.ProcessEnv,
  };
}

describe("selection resolution", () => {
  test("applies flag, environment, machine config, and detection precedence", async () => {
    const { root, env } = await fixture();
    await writeMachineConfig({ profile: "mac", addons: [] }, env);

    expect(await resolveSelection({
      primerDir: root,
      profile: "fedora-kde",
      addons: ["gaming"],
      env: { ...env, PRIMER_PROFILE: "linux-vps", PRIMER_ADDONS: "" },
    })).toMatchObject({ profile: "fedora-kde", addons: ["gaming"], source: "flag", firstRun: false });

    expect(await resolveSelection({
      primerDir: root,
      env: { ...env, PRIMER_PROFILE: "linux-vps", PRIMER_ADDONS: "" },
    })).toMatchObject({ profile: "linux-vps", addons: [], source: "env", firstRun: false });

    expect(await resolveSelection({ primerDir: root, env })).toMatchObject({
      profile: "mac", addons: [], source: "machine.conf", firstRun: false,
    });

    await rm(env.PRIMER_MACHINE_CONF!, { force: true });
    expect(await resolveSelection({ primerDir: root, env })).toMatchObject({
      profile: "fedora-kde", addons: [], source: "detected", firstRun: true,
    });
  });

  test("keeps CLI overrides transient", async () => {
    const { root, env } = await fixture();
    const selection = await resolveSelection({
      primerDir: root,
      profile: "fedora-kde",
      addons: ["gaming"],
      env,
    });
    expect(selection.firstRun).toBe(false);
    expect(await Bun.file(env.PRIMER_MACHINE_CONF!).exists()).toBe(false);
  });

  test("does not combine forced profiles with persisted addons", async () => {
    const { root, env } = await fixture();
    await writeMachineConfig({ profile: "fedora-kde", addons: ["gaming"] }, env);
    expect(await resolveSelection({ primerDir: root, profile: "mac", env })).toMatchObject({
      profile: "mac", addons: [], source: "flag",
    });
  });
});
