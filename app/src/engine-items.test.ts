import { describe, expect, test } from "bun:test";
import { inheritModuleFailure, parseItemRecords, type EngineItem } from "./engine";

describe("item protocol", () => {
  test("keeps the initial pending items in their published order", () => {
    expect(parseItemRecords("pending\tArc\npending\tGhostty\npending\tVisual Studio Code\n"))
      .toEqual([
        { name: "Arc", state: "pending", detail: "" },
        { name: "Ghostty", state: "pending", detail: "" },
        { name: "Visual Studio Code", state: "pending", detail: "" },
      ]);
  });

  test("preserves an optional result detail", () => {
    expect(parseItemRecords("skipped\tArc\talready installed outside brew cask\n"))
      .toEqual([{ name: "Arc", state: "skipped", detail: "already installed outside brew cask" }]);
  });

  test("ignores incomplete records", () => {
    expect(parseItemRecords("\tpending\nmissing-state\n\n"))
      .toEqual([]);
  });

  test("failed modules stamp leftover pending items with their logs", () => {
    const items: EngineItem[] = [
      { name: "service", state: "pending", detail: "", logs: [] },
      { name: "proxy", state: "done", detail: "ready", logs: ["ok"] },
    ];
    inheritModuleFailure(items, "t3 not found", ["starting...", "t3 not found"]);
    expect(items[0]).toMatchObject({
      name: "service",
      state: "failed",
      detail: "t3 not found",
      logs: ["starting...", "t3 not found"],
    });
    expect(items[1]).toMatchObject({ name: "proxy", state: "done", detail: "ready", logs: ["ok"] });
  });
});
