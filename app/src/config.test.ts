import { describe, expect, test } from "bun:test";
import { readFile } from "node:fs/promises";
import { join } from "node:path";
import { buildNodes, detectLinuxProfile, parseConf, type RawConfig } from "./config";

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
    expect(result.find((node) => node.id === "interactive:github")?.deps)
      .toEqual(["ssh", "git", "dnf", "interactive:onepassword"]);
    expect(result.find((node) => node.id === "interactive:tailscale")?.deps)
      .toEqual(["tailscale", "interactive:onepassword"]);
    expect(result.find((node) => node.id === "kde-desktop-settings")?.needsSudo).toBe(true);
  });

  test("Ubuntu desktop profile keeps KDE settings on the sudo ticket", async () => {
    const primerDir = join(import.meta.dir, "..", "..");
    const config: RawConfig = { order: [], values: new Map() };
    parseConf(await readFile(join(primerDir, "configs", "common.conf"), "utf8"), config);
    parseConf(await readFile(join(primerDir, "configs", "profiles", "ubuntu-desktop.conf"), "utf8"), config);
    expect(buildNodes(config).find((node) => node.id === "kde-desktop-settings")?.needsSudo).toBe(true);
  });
});

describe("Linux profile detection", () => {
  test("selects Fedora KDE from the operating system ID", () => {
    expect(detectLinuxProfile("fedora", "", {})).toBe("fedora-kde");
  });

  test("preserves Ubuntu desktop and headless profiles", () => {
    expect(detectLinuxProfile("ubuntu", "debian", { XDG_CURRENT_DESKTOP: "KDE" })).toBe("ubuntu-desktop");
    expect(detectLinuxProfile("ubuntu", "debian", {})).toBe("linux-vps");
  });
});
