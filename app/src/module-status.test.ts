import { afterEach, describe, expect, test } from "bun:test";
import { copyFileSync, mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import type { NodeDef } from "./config";
import { runModuleStatus } from "./module-status";

const temporaryRoots: string[] = [];

afterEach(() => {
  for (const root of temporaryRoots.splice(0)) {
    rmSync(root, { recursive: true, force: true });
  }
});

describe("module status", () => {
  test("passes the module's parsed configuration to mod_status", async () => {
    const primerDir = mkdtempSync(join(tmpdir(), "primer-status-test-"));
    temporaryRoots.push(primerDir);
    const workDir = join(primerDir, "work");
    const moduleDir = join(primerDir, "modules", "probe");
    mkdirSync(join(primerDir, "lib"), { recursive: true });
    mkdirSync(workDir, { recursive: true });
    mkdirSync(moduleDir, { recursive: true });
    copyFileSync(join(import.meta.dir, "..", "..", "lib", "module.zsh"), join(primerDir, "lib", "module.zsh"));
    writeFileSync(join(moduleDir, "module.zsh"), `
mod_status() {
    local value="$(mod_config expected)"
    primer::status_msg "$value"
    [[ "$value" == "configured value" ]]
}
`);

    const def: NodeDef = {
      id: "probe",
      kind: "module",
      label: "Probe",
      deps: [],
      config: { "probe.expected": "configured value" },
      needsSudo: false,
    };

    expect(await runModuleStatus(def, primerDir, workDir)).toMatchObject({
      ok: true,
      detail: "configured value",
    });
  });
});
