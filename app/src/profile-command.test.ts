import { describe, expect, test } from "bun:test";
import type { NodeDef } from "./config";
import { droppedModuleIds, profileSetResult, profileSummary } from "./profile-command";

const node = (id: string): NodeDef => ({
  id,
  kind: "module",
  label: id,
  deps: [],
  config: {},
  needsSudo: false,
});

describe("profile command output", () => {
  test("shows source, active addons, and applicable addons", () => {
    const text = profileSummary(
      { profile: "fedora-kde", addons: ["gaming"], source: "machine.conf", firstRun: false },
      [
        { name: "gaming", label: "Gaming", description: "Games.", profiles: ["fedora-kde"] },
        { name: "server", label: "Server", description: "Server.", profiles: ["linux-vps"] },
      ],
    );
    expect(text).toContain("Source: machine.conf");
    expect(text).toContain("gaming (active)");
    expect(text).not.toContain("server —");
  });

  test("reports only module nodes dropped by a selection change", () => {
    const interactive: NodeDef = { ...node("interactive:login"), kind: "interactive" };
    const dropped = droppedModuleIds([node("base"), node("gaming"), interactive], [node("base")]);
    expect(dropped).toEqual(["gaming"]);
    expect(profileSetResult("fedora-kde", [], dropped)).toContain("Primer does not uninstall");
  });
});
