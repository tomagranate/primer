import { describe, expect, test } from "bun:test";
import { parseItemRecords } from "./engine";

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
});
