import { describe, expect, test } from "bun:test";
import { addonPickerLines, summaryLines } from "./ui-layout";

describe("responsive terminal rows", () => {
  test("wraps addon descriptions instead of truncating them", () => {
    expect(addonPickerLines("Gaming", "Steam, GameMode, MangoHud, and NVIDIA drivers.", 28))
      .toEqual([
        { kind: "label", text: "Gaming", first: true },
        { kind: "description", text: "Steam, GameMode,", first: false },
        { kind: "description", text: "MangoHud, and NVIDIA", first: false },
        { kind: "description", text: "drivers.", first: false },
      ]);
  });

  test("keeps summary metadata aligned when it fits", () => {
    const layout = summaryLines("Mise languages", "runtimes installed", 4, "0.1s", 88);
    expect(layout.lines).toEqual([{
      label: "Mise languages",
      metadata: "runtimes installed  4 items  0.1s",
      first: true,
      stacked: false,
    }]);
  });

  test("stacks summary detail at narrow widths", () => {
    const layout = summaryLines("Mise languages", "runtimes installed", 4, "0.1s", 36);
    expect(layout.lines).toEqual([
      { label: "Mise languages", metadata: "", first: true, stacked: true },
      { label: "", metadata: "runtimes installed  4 items", first: false, stacked: true },
      { label: "", metadata: "0.1s", first: false, stacked: true },
    ]);
  });
});
