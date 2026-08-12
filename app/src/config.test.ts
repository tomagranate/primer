import { describe, expect, test } from "bun:test";
import { buildNodes, parseConf, type RawConfig } from "./config";

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
});
