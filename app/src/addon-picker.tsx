import { useState } from "react";
import { useKeyboard, useTerminalDimensions } from "@opentui/react";
import type { AddonDef } from "./config";
import { ensureRowRangeVisible } from "./text-layout";
import { addonPickerLines } from "./ui-layout";

const C = {
  surface0: "#0f1214",
  surface1: "#1a1f22",
  text: "#c8d0d8",
  dim: "#8a9ba5",
  muted: "#4a5860",
  green: "#5cb885",
  bold: "#e8eef2",
  selection: "#2a3a35",
};

export function normalizeAddonSelection(addons: AddonDef[], selected: string[]): string[] {
  const selectedSet = new Set(selected);
  return addons.map((addon) => addon.name).filter((name) => selectedSet.has(name));
}

export function toggleAddon(selected: string[], name: string): string[] {
  return selected.includes(name)
    ? selected.filter((item) => item !== name)
    : [...selected, name];
}

export function moveAddonCursor(cursor: number, offset: number, count: number): number {
  if (count === 0) return 0;
  return (cursor + offset + count) % count;
}

interface AddonPickerProps {
  profile: string;
  addons: AddonDef[];
  initial: string[];
  onConfirm: (selected: string[]) => void;
  onCancel: () => void;
}

export function AddonPicker({ profile, addons, initial, onConfirm, onCancel }: AddonPickerProps) {
  const dims = useTerminalDimensions();
  const [cursor, setCursor] = useState(0);
  const [selected, setSelected] = useState(() => normalizeAddonSelection(addons, initial));
  const topPadding = dims.height < 9 ? 0 : 1;
  const bodyHeight = Math.max(1, dims.height - 2 - topPadding);
  const rows = addons.flatMap((addon, addonIndex) =>
    addonPickerLines(addon.label, addon.description, dims.width).map((line, lineIndex) => ({
      addon,
      addonIndex,
      line,
      lineIndex,
    })),
  );
  const selectedStart = Math.max(0, rows.findIndex((row) => row.addonIndex === cursor));
  const selectedEnd = Math.max(selectedStart, rows.findLastIndex((row) => row.addonIndex === cursor));
  const start = ensureRowRangeVisible(0, selectedStart, selectedEnd, rows.length, bodyHeight);
  const visible = rows.slice(start, start + bodyHeight);
  const help = dims.width >= 55
    ? "↑↓ move · space toggle · enter save · esc cancel"
    : dims.width >= 35
      ? "↑↓ move · space toggle · enter save"
      : "↑↓ · space · enter";

  useKeyboard((key) => {
    const name = key.name ?? key.sequence;
    if (name === "up" || name === "down") {
      setCursor((value) => moveAddonCursor(value, name === "up" ? -1 : 1, addons.length));
      return;
    }
    if (name === "space" || key.sequence === " ") {
      const addon = addons[cursor];
      if (addon) setSelected((value) => toggleAddon(value, addon.name));
      return;
    }
    if (name === "return") {
      onConfirm(normalizeAddonSelection(addons, selected));
      return;
    }
    if (name === "escape" || name === "q" || (name === "c" && key.ctrl)) onCancel();
  });

  return (
    <box style={{ width: "100%", height: "100%", flexDirection: "column", backgroundColor: C.surface0 }}>
      <box style={{ height: 1, backgroundColor: C.surface1, paddingLeft: 1 }}>
        <text fg={C.bold}>{`Primer addons · ${profile}`}</text>
      </box>
      <box style={{ flexGrow: 1, flexDirection: "column", paddingTop: topPadding }}>
        {visible.map(({ addon, addonIndex, line, lineIndex }) => {
          const focused = addonIndex === cursor;
          const checked = selected.includes(addon.name);
          return (
            <box
              key={`${addon.name}:${lineIndex}`}
              style={{
                height: 1,
                flexDirection: "row",
                backgroundColor: focused ? C.selection : C.surface0,
              }}
            >
              <text fg={focused ? C.bold : C.text}>
                {line.first ? `${focused ? "›" : " "} ${checked ? "[x]" : "[ ]"} ` : "      "}
              </text>
              <text fg={line.kind === "description" ? C.dim : focused ? C.bold : C.text}>
                {line.text}
              </text>
            </box>
          );
        })}
      </box>
      <box style={{ height: 1, backgroundColor: C.surface1, paddingLeft: 1 }}>
        <text fg={C.muted}>{help}</text>
      </box>
    </box>
  );
}
