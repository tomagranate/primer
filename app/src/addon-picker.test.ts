import { describe, expect, test } from "bun:test";
import { moveAddonCursor, normalizeAddonSelection, toggleAddon } from "./addon-picker";

const addons = [
  { name: "gaming", label: "Gaming", description: "Games.", profiles: ["fedora-kde"] },
  { name: "work", label: "Work", description: "Work.", profiles: ["fedora-kde"] },
];

describe("addon picker selection", () => {
  test("toggles selections and keeps addon file order", () => {
    expect(toggleAddon(["gaming"], "gaming")).toEqual([]);
    expect(toggleAddon(["gaming"], "work")).toEqual(["gaming", "work"]);
    expect(normalizeAddonSelection(addons, ["work", "unknown", "gaming"]))
      .toEqual(["gaming", "work"]);
  });

  test("wraps keyboard cursor movement", () => {
    expect(moveAddonCursor(0, -1, 2)).toBe(1);
    expect(moveAddonCursor(1, 1, 2)).toBe(0);
  });
});
