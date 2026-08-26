import { describe, expect, test } from "bun:test";
import { mkdtemp, mkdir, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import {
  availableAddons,
  buildNodes,
  detectLinuxProfile,
  loadNodes,
  parseConf,
  type RawConfig,
} from "./config";

function nodes(text: string) {
  const config: RawConfig = { order: [], values: new Map() };
  parseConf(text, config);
  return buildNodes(config);
}

describe("configuration graph", () => {
  test("preserves module order and multiline values", () => {
    const result = nodes(`
[alpha]
label = Alpha
items =
  one
  two

[beta]
depends_on = alpha
`);
    expect(result.map((node) => node.id)).toEqual(["alpha", "beta"]);
    expect(result[0]?.config["alpha.items"]).toBe("\none\ntwo");
    expect(result[1]?.deps).toEqual(["alpha"]);
  });

  test("defaults interactive steps to pane mode", () => {
    const result = nodes(`
[logins]
order =
  github
github_command = gh auth login
`);
    expect(result[0]?.config.mode).toBe("pane");
  });

  test("keeps an explicit terminal login mode", () => {
    const result = nodes(`
[logins]
order =
  github
github_mode = terminal
github_command = gh auth login
`);
    expect(result[0]?.config.mode).toBe("terminal");
  });

  test("turns login dependencies into interactive graph nodes", () => {
    const result = nodes(`
[tool]
depends_on_logins = github

[logins]
order =
  github
github_label = GitHub
github_command = gh auth login
`);
    expect(result[0]?.deps).toEqual(["interactive:github"]);
    expect(result[1]).toMatchObject({
      id: "interactive:github",
      kind: "interactive",
      label: "GitHub",
      config: { command: "gh auth login" },
    });
  });

  test("profile values override common values", () => {
    const config: RawConfig = { order: [], values: new Map() };
    parseConf("[tool]\nlabel = Common\n", config);
    parseConf("[tool]\nlabel = Profile\n", config);
    expect(buildNodes(config)[0]?.label).toBe("Profile");
  });

  test("appends fresh, existing, and multiline values with +=", () => {
    const config: RawConfig = { order: [], values: new Map() };
    parseConf("[tool]\nfresh += first\nitems = one\n", config);
    parseConf("[tool]\nitems += two\nitems +=\n  three\n  four\n", config);
    expect(config.values.get("tool.fresh")).toBe("first");
    expect(config.values.get("tool.items")).toBe("one\ntwo\nthree\nfour");
  });

  test("accepts digits in module names", () => {
    const result = nodes("[t3-code]\nlabel = T3 Code server\n");
    expect(result[0]).toMatchObject({ id: "t3-code", label: "T3 Code server" });
  });

  test("lets one login wait for another login by name", () => {
    const result = nodes(`
[1password]
label = 1Password

[logins]
order =
  onepassword
  github
onepassword_label = 1Password
onepassword_depends_on = 1password
onepassword_command = op signin
github_depends_on = ssh, git
github_depends_on_logins = onepassword
github_command = gh auth login
`);
    expect(result.find((node) => node.id === "1password")).toMatchObject({
      kind: "module",
      label: "1Password",
    });
    expect(result.find((node) => node.id === "interactive:onepassword")).toMatchObject({
      kind: "interactive",
      label: "1Password",
      deps: ["1password"],
      config: { command: "op signin" },
    });
    expect(result.find((node) => node.id === "interactive:github")?.deps)
      .toEqual(["ssh", "git", "interactive:onepassword"]);
  });

  test("fedora KDE profile makes GitHub and Tailscale logins wait for 1Password", async () => {
    const primerDir = join(import.meta.dir, "..", "..");
    const config: RawConfig = { order: [], values: new Map() };
    parseConf(await readFile(join(primerDir, "configs", "common.conf"), "utf8"), config);
    parseConf(await readFile(join(primerDir, "configs", "profiles", "fedora-kde.conf"), "utf8"), config);
    const result = buildNodes(config);
    expect(result.find((node) => node.id === "1password")).toMatchObject({
      kind: "module",
      label: "1Password",
      deps: ["dnf"],
      needsSudo: true,
    });
    expect(result.find((node) => node.id === "interactive:onepassword")).toMatchObject({
      kind: "interactive",
      label: "1Password",
      deps: ["1password"],
    });
    expect(result.find((node) => node.id === "interactive:onepassword")?.config.status)
      .toContain("length > 0");
    expect(result.find((node) => node.id === "interactive:onepassword")?.config.mode).toBe("pane");
    expect(result.find((node) => node.id === "interactive:onepassword")?.config.command)
      .not.toContain("read -r");
    expect(result.find((node) => node.id === "interactive:github")?.config.mode).toBe("pane");
    expect(result.find((node) => node.id === "interactive:github")?.deps)
      .toEqual(["ssh", "git", "dnf", "interactive:onepassword"]);
    expect(result.find((node) => node.id === "interactive:tailscale")?.config.mode).toBe("pane");
    expect(result.find((node) => node.id === "interactive:tailscale")?.deps)
      .toEqual(["tailscale", "interactive:onepassword"]);
    expect(result.find((node) => node.id === "kde-desktop-settings")?.needsSudo).toBe(true);
  });

  test("keeps desktop hardware in the base and gaming behind the addon", async () => {
    const primerDir = join(import.meta.dir, "..", "..");
    const base = await loadNodes(primerDir, "fedora-kde");
    const gaming = await loadNodes(primerDir, "fedora-kde", ["gaming"]);
    expect(base.some((node) => node.id === "fedora-desktop-hardware")).toBe(true);
    expect(base.some((node) => node.id === "fedora-gaming")).toBe(false);
    expect(base.find((node) => node.id === "kde-taskbar-pins")?.config["kde-taskbar-pins.launchers"])
      .not.toContain("steam.desktop");
    expect(gaming.some((node) => node.id === "fedora-desktop-hardware")).toBe(true);
    expect(gaming.some((node) => node.id === "fedora-gaming")).toBe(true);
    expect(gaming.find((node) => node.id === "kde-taskbar-pins")?.config["kde-taskbar-pins.launchers"])
      .toContain("steam.desktop");
  });

});

describe("addons", () => {
  async function fixture(): Promise<string> {
    const root = await mkdtemp(join(tmpdir(), "primer-config-"));
    await mkdir(join(root, "configs", "profiles"), { recursive: true });
    await mkdir(join(root, "configs", "addons"), { recursive: true });
    await writeFile(join(root, "configs", "common.conf"), "[task]\nitems = common\n");
    await writeFile(join(root, "configs", "profiles", "desktop.conf"), "[task]\nitems += profile\n");
    await writeFile(join(root, "configs", "profiles", "server.conf"), "[server]\nlabel = Server\n");
    await writeFile(join(root, "configs", "addons", "extras.conf"), `
[addon]
label = Extras
description = Extra tasks.
profiles = desktop

[task]
items +=
  addon

[extra]
label = Extra
depends_on = task
`);
    return root;
  }

  test("discovers metadata and merges applicable addons after the profile", async () => {
    const root = await fixture();
    try {
      expect(await availableAddons(root)).toEqual([{
        name: "extras",
        label: "Extras",
        description: "Extra tasks.",
        profiles: ["desktop"],
      }]);
      const result = await loadNodes(root, "desktop", ["extras"]);
      expect(result.map((node) => node.id)).toEqual(["task", "extra"]);
      expect(result[0]?.config["task.items"]).toBe("common\nprofile\naddon");
      expect(result[1]?.deps).toEqual(["task"]);
    } finally {
      await rm(root, { recursive: true, force: true });
    }
  });

  test("rejects unknown and inapplicable addons", async () => {
    const root = await fixture();
    try {
      await expect(loadNodes(root, "desktop", ["missing"])).rejects.toThrow("Unknown addon");
      await expect(loadNodes(root, "server", ["extras"])).rejects.toThrow("not available");
    } finally {
      await rm(root, { recursive: true, force: true });
    }
  });
});

describe("Linux profile detection", () => {
  test("selects Fedora KDE from the operating system ID", () => {
    expect(detectLinuxProfile("fedora", "", {})).toBe("fedora-kde");
  });

  test("selects the VPS profile for headless Ubuntu", () => {
    expect(detectLinuxProfile("ubuntu", "debian", {})).toBe("linux-vps");
  });

  test("rejects unsupported Linux desktops", () => {
    expect(() => detectLinuxProfile("ubuntu", "debian", { XDG_CURRENT_DESKTOP: "KDE" })).toThrow();
  });
});
