import { describe, expect, test } from "bun:test";
import { parseArgs } from "./cli";

describe("CLI arguments", () => {
  test("collects repeatable transient addons", () => {
    expect(parseArgs(["update", "--addon", "gaming", "--addon", "streaming"]))
      .toMatchObject({ command: "update", addons: ["gaming", "streaming"] });
  });

  test("parses profile set positional names", () => {
    expect(parseArgs(["profile", "set", "fedora-kde", "gaming"]))
      .toMatchObject({
        command: "profile",
        profileAction: "set",
        profileSetArgs: ["fedora-kde", "gaming"],
      });
  });

  test("treats command words after profile set as names", () => {
    expect(parseArgs(["profile", "set", "status", "update"]))
      .toMatchObject({
        command: "profile",
        profileAction: "set",
        profileSetArgs: ["status", "update"],
      });
  });

  test("accepts profile show explicitly", () => {
    expect(parseArgs(["profile", "show"]))
      .toMatchObject({ command: "profile", profileAction: "show" });
  });

  test("rejects a missing addon name", () => {
    expect(() => parseArgs(["update", "--addon"])).toThrow("Missing argument for --addon");
  });
});
