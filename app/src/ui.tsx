/**
 * Primer update TUI: task list, focused logs, interactive prompts, and summary.
 *
 * Left: task list. Right: live log tail of the focused node.
 * Follow-along mode is the default; arrows take manual control; esc returns.
 * Interactive nodes show a framed prompt. Pane commands show live output.
 */
import { useEffect, useState } from "react";
import { useKeyboard, useTerminalDimensions } from "@opentui/react";
import type { Engine, EngineItem, EngineNode } from "./engine";
import { ensureVisible, listWindow } from "./list-window";

// Moss theme, copied from corsa (src/lib/theme/themes.ts): deep greens with
// a British racing green accent. Sidebar sits on surface1, content on
// surface0, chrome bars on surface1 — corsa's surface hierarchy.
const C = {
  surface0: "#0f1214",   // base — content pane
  surface1: "#1a1f22",   // elevated — sidebar, header, help bar
  surface2: "#262d31",   // overlay — in-progress banner
  text: "#c8d0d8",
  dim: "#8a9ba5",        // textDim
  muted: "#4a5860",      // textMuted — borders, separators
  accent: "#2d6b52",
  green: "#5cb885",      // success
  red: "#c75f5f",        // error
  yellow: "#d4a645",     // warning — also the needs-you color
  warningFg: "#0f1214",  // text ON warning background
  bold: "#e8eef2",
  selection: "#2a3a35",
};
const SPIN = "⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏";
const spin = () => SPIN[Math.floor(Date.now() / 90) % SPIN.length];

function icon(n: EngineNode): { ch: string; fg: string } {
  switch (n.state) {
    case "pending": return { ch: "◔", fg: C.muted };
    case "running": return { ch: spin()!, fg: C.green };
    case "checking": return { ch: spin()!, fg: C.dim };
    case "done": return { ch: "✓", fg: C.green };
    case "failed": return { ch: "✗", fg: C.red };
    case "skipped": return { ch: "○", fg: C.yellow };
    case "needs-user": return { ch: "◆", fg: C.yellow };
    case "interacting": return { ch: spin()!, fg: C.yellow };
  }
}

function itemIcon(item: Pick<EngineItem, "state">): { ch: string; fg: string } {
  switch (item.state) {
    case "running": return { ch: spin()!, fg: C.yellow };
    case "done": return { ch: "✓", fg: C.green };
    case "failed": return { ch: "✗", fg: C.red };
    case "skipped": return { ch: "○", fg: C.dim };
    default: return { ch: "·", fg: C.muted };
  }
}

function itemDetail(item: EngineItem): string {
  if (item.detail) return item.detail;
  switch (item.state) {
    case "pending": return "waiting";
    case "running": return "in progress";
    case "done": return "complete";
    case "failed": return "failed";
    case "skipped": return "skipped";
    default: return item.state;
  }
}

function activeItemIndex(items: EngineItem[]): number {
  const running = items.findIndex((item) => item.state === "running");
  if (running >= 0) return running;
  const failed = items.findIndex((item) => item.state === "failed");
  if (failed >= 0) return failed;
  for (let i = items.length - 1; i >= 0; i--) {
    if (items[i]!.state !== "pending") return i;
  }
  return 0;
}

const elapsed = (n: EngineNode) =>
  n.start == null ? "" : `${(((n.end ?? Date.now()) - n.start) / 1000).toFixed(1)}s`;

function followIndex(nodes: EngineNode[]): number {
  const needing = nodes.findIndex((n) => n.state === "needs-user" || n.state === "interacting");
  if (needing >= 0) return needing;
  let best = -1, bestStart = -1, bestEnd = -1;
  nodes.forEach((n, i) => {
    if (n.state === "running" && (n.start ?? 0) > bestStart) { best = i; bestStart = n.start ?? 0; }
  });
  if (best >= 0) return best;
  nodes.forEach((n, i) => { if (n.end != null && n.end > bestEnd) { best = i; bestEnd = n.end; } });
  return Math.max(best, 0);
}

interface AppProps {
  engine: Engine;
  dryRun: boolean;
  onQuit: () => void;
}

type Screen = "run" | "logs" | "summary" | "summary-items";

interface LogTarget {
  target: EngineNode | EngineItem;
  returnScreen: Exclude<Screen, "logs">;
}

export function App({ engine, dryRun, onQuit }: AppProps) {
  const dims = useTerminalDimensions();
  const [, setTick] = useState(0);
  const [follow, setFollow] = useState(true);
  const [cursor, setCursor] = useState(0);
  const [screen, setScreen] = useState<Screen>("run");
  const [logScroll, setLogScroll] = useState(-1); // -1 = follow tail
  const [logTarget, setLogTarget] = useState<LogTarget | null>(null);
  const [itemMode, setItemMode] = useState(false);
  const [itemCursors, setItemCursors] = useState<Record<string, number>>({});
  const [expandedItems, setExpandedItems] = useState<Record<string, string[]>>({});
  const [summaryScroll, setSummaryScroll] = useState(0);

  useEffect(() => {
    const iv = setInterval(() => {
      setTick((n) => n + 1);
      if (engine.finished()) setScreen((s) => (s === "run" ? "summary" : s));
    }, 100);
    return () => clearInterval(iv);
  }, [engine]);

  const nodes = engine.nodes;
  const waiting = nodes.filter((n) => n.state === "needs-user");
  const inTerminal = nodes.find((n) => n.state === "interacting");
  const attention = waiting.length > 0 || !!inTerminal;
  const focusIdx = follow ? followIndex(nodes) : cursor;
  const focus = nodes[focusIdx] ?? nodes[0]!;

  // Summary chrome: header + counts + footer + gutter (+ spacers when tall enough).
  const summaryCompact = dims.height < 12;
  const summaryListHeight = Math.max(1, dims.height - (summaryCompact ? 4 : 6));

  // Keep the selected module on-screen as the cursor moves or the terminal resizes.
  useEffect(() => {
    if (screen !== "summary") return;
    setSummaryScroll((start) => ensureVisible(start, cursor, nodes.length, summaryListHeight));
  }, [screen, cursor, nodes.length, summaryListHeight]);

  useKeyboard((key) => {
    const name = key.name ?? key.sequence;

    if (screen === "logs" && logTarget) {
      const bodyH = dims.height - 2;
      const maxStart = Math.max(0, logTarget.target.logs.length - bodyH);
      if (name === "escape" || name === "q") { setScreen(logTarget.returnScreen); setLogScroll(-1); }
      if (name === "up") setLogScroll((s) => Math.max(0, (s === -1 ? maxStart : s) - 1));
      if (name === "down") setLogScroll((s) => (s === -1 ? -1 : s + 1 >= maxStart ? -1 : s + 1));
      return;
    }

    const isSpace = name === "space" || key.sequence === " ";
    const openLogs = (target: EngineNode | EngineItem | undefined, returnScreen: LogTarget["returnScreen"]) => {
      if (!target) return;
      setLogTarget({
        target,
        returnScreen,
      });
      setLogScroll(-1);
      setScreen("logs");
    };

    if (screen === "summary-items") {
      const node = nodes[cursor];
      if (!node?.items.length) { setScreen("summary"); return; }
      const current = Math.min(itemCursors[node.id] ?? 0, node.items.length - 1);
      if (name === "up" || name === "down") {
        const step = name === "up" ? node.items.length - 1 : 1;
        setItemCursors((cursors) => ({ ...cursors, [node.id]: (current + step) % node.items.length }));
      } else if (name === "return" || isSpace) {
        openLogs(node.items[current], "summary-items");
      } else if (name === "l") {
        openLogs(node, "summary-items");
      } else if (name === "escape" || name === "left") {
        setScreen("summary");
      } else if (name === "q" || (name === "c" && key.ctrl)) {
        onQuit();
      }
      return;
    }

    if (screen === "summary") {
      if (name === "up" || name === "down") {
        setCursor((c) => (c + (name === "up" ? nodes.length - 1 : 1)) % nodes.length);
      } else if (name === "return") {
        const node = nodes[cursor];
        if (node?.items.length) {
          setItemCursors((cursors) => ({ ...cursors, [node.id]: cursors[node.id] ?? 0 }));
          setScreen("summary-items");
        } else {
          openLogs(node, "summary");
        }
      } else if (isSpace) {
        openLogs(nodes[cursor], "summary");
      } else if (name === "escape" || name === "q" || (name === "c" && key.ctrl)) {
        onQuit();
      }
      return;
    }

    if (itemMode && focus.items.length) {
      const current = Math.min(itemCursors[focus.id] ?? activeItemIndex(focus.items), focus.items.length - 1);
      if (name === "up" || name === "down") {
        const step = name === "up" ? focus.items.length - 1 : 1;
        setItemCursors((cursors) => ({ ...cursors, [focus.id]: (current + step) % focus.items.length }));
      } else if (name === "return") {
        const item = focus.items[current]!;
        setExpandedItems((expanded) => {
          const names = expanded[focus.id] ?? [];
          return {
            ...expanded,
            [focus.id]: names.includes(item.name) ? names.filter((name) => name !== item.name) : [...names, item.name],
          };
        });
      } else if (name === "escape" || name === "left") {
        setItemMode(false);
      } else if (isSpace) {
        openLogs(focus.items[current], "run");
      } else if (name === "c" && key.ctrl) {
        engine.interrupt();
        onQuit();
      }
      return;
    }

    if (name === "up" || name === "down") {
      const base = follow ? followIndex(nodes) : cursor;
      setFollow(false);
      setCursor((base + (name === "up" ? nodes.length - 1 : 1)) % nodes.length);
    } else if (name === "escape") {
      setFollow(true);
    } else if ((name === "right" || name === "tab") && focus.items.length) {
      const active = activeItemIndex(focus.items);
      setFollow(false);
      setCursor(focusIdx);
      setItemCursors((cursors) => ({ ...cursors, [focus.id]: cursors[focus.id] ?? active }));
      setItemMode(true);
    } else if (name === "return") {
      if (engine.finished()) { onQuit(); return; }
      const target = follow ? nodes.find((n) => n.state === "needs-user") ?? focus : focus;
      if (target.state === "needs-user") { void engine.answerInteractive(target); return; }
      if (target.items.length) {
        const active = activeItemIndex(target.items);
        setFollow(false);
        setCursor(nodes.indexOf(target));
        setItemCursors((cursors) => ({ ...cursors, [target.id]: cursors[target.id] ?? active }));
        setItemMode(true);
        return;
      }
      openLogs(target, "run");
    } else if (isSpace) {
      openLogs(focus, "run");
    } else if (name === "s") {
      const target = focus.state === "needs-user" ? focus : nodes.find((n) => n.state === "needs-user");
      if (target) engine.skipInteractive(target);
    } else if (name === "q") {
      if (engine.finished()) onQuit();
    } else if (name === "c" && key.ctrl) {
      engine.interrupt();
      onQuit();
    }
  });

  /* ── fullscreen logs ── */
  if (screen === "logs" && logTarget) {
    const target = logTarget.target;
    const bodyH = dims.height - 2;
    const total = target.logs.length;
    let startLine = logScroll === -1 ? Math.max(0, total - bodyH) : Math.min(logScroll, Math.max(0, total - bodyH));
    const lines = target.logs.slice(startLine, startLine + bodyH);
    return (
      <box style={{ width: "100%", height: "100%", flexDirection: "column", backgroundColor: C.surface0 }}>
        <box style={{ height: 1, backgroundColor: C.surface1, paddingLeft: 1, flexDirection: "row" }}>
          <text fg={C.bold}>logs · {"label" in target ? target.label : target.name}</text>
          <text fg={itemIcon(target).fg}>{`  ${itemIcon(target).ch} `}</text>
          <text fg={C.dim}>{`${target.state}${target.detail ? ` · ${target.detail}` : ""}`}</text>
        </box>
        <box style={{ flexGrow: 1, flexDirection: "column", paddingLeft: 1 }}>
          {lines.map((line, i) => (
            <text key={startLine + i} fg={/error|failed/i.test(line) ? C.red : C.text}>{line || " "}</text>
          ))}
          {total === 0 && <text fg={C.dim}>no output</text>}
        </box>
        <box style={{ height: 1, backgroundColor: C.surface1, paddingLeft: 1 }}>
          <text fg={C.dim}>{`esc back · ↑↓ scroll · ${logScroll === -1 ? "following" : `line ${startLine + 1}/${total}`}`}</text>
        </box>
      </box>
    );
  }

  if (screen === "summary-items") {
    const node = nodes[cursor] ?? nodes[0]!;
    const selectedIndex = Math.min(itemCursors[node.id] ?? 0, Math.max(0, node.items.length - 1));
    const bodyHeight = Math.max(3, dims.height - 2);
    const showModuleLogs = node.logs.length > 0 || node.state === "failed";
    const logHeight = showModuleLogs ? Math.min(8, Math.max(3, Math.floor(bodyHeight / 3))) : 0;
    return (
      <box style={{ width: "100%", height: "100%", flexDirection: "column", backgroundColor: C.surface0 }}>
        <box style={{ height: 1, backgroundColor: C.surface1, paddingLeft: 1, flexDirection: "row" }}>
          <text fg={C.bold}>{`summary · ${node.label}`}</text>
          <text fg={C.dim}>{`  ${node.items.length} items · ${node.detail}`}</text>
        </box>
        <box style={{ flexGrow: 1, flexDirection: "column", paddingLeft: 1 }}>
          <ItemLedger
            items={node.items}
            selectedIndex={selectedIndex}
            expandedNames={node.items.filter((item) => item.state === "failed" || item.state === "running").map((item) => item.name)}
            active
            height={Math.max(3, bodyHeight - logHeight)}
            width={Math.max(20, dims.width - 1)}
          />
          {logHeight > 0 && <ModuleLogTail logs={node.logs} height={logHeight} />}
        </box>
        <box style={{ height: 1, backgroundColor: C.surface1, paddingLeft: 1 }}>
          <text fg={C.dim}>↑↓ move · ⏎/space item logs · l module logs · ←/esc modules · q quit</text>
        </box>
      </box>
    );
  }

  /* ── summary ── */
  if (screen === "summary") {
    const c = engine.counts();
    const ok = c.failed === 0 && !engine.interrupted;
    const listStart = ensureVisible(summaryScroll, cursor, nodes.length, summaryListHeight);
    const visibleNodes = nodes.slice(listStart, listStart + summaryListHeight);
    const scrolled = nodes.length > summaryListHeight;
    const rangeHint = scrolled
      ? ` · ${listStart + 1}–${Math.min(nodes.length, listStart + summaryListHeight)}/${nodes.length}`
      : "";
    return (
      <box style={{ width: "100%", height: "100%", flexDirection: "column", backgroundColor: C.surface0 }}>
        <box style={{ height: 1, backgroundColor: C.surface1, paddingLeft: 1, flexDirection: "row" }}>
          <text fg={ok ? C.green : C.red}>
            {ok ? "✓ primer update complete" : engine.interrupted ? "! primer update interrupted" : "✗ primer update finished with issues"}
          </text>
          <text fg={C.dim}>{`  ${((Date.now() - engine.startedAt) / 1000).toFixed(0)}s${dryRun ? " · dry run" : ""}`}</text>
        </box>
        {!summaryCompact && <box style={{ height: 1 }} />}
        <box style={{ height: 1, flexDirection: "row", paddingLeft: 2 }}>
          <text fg={C.green}>{`✓ ${c.done} done`}</text>
          {c.failed > 0 && <text fg={C.red}>{`   ✗ ${c.failed} failed`}</text>}
          {c.skipped > 0 && <text fg={C.yellow}>{`   ○ ${c.skipped} skipped`}</text>}
        </box>
        {!summaryCompact && <box style={{ height: 1 }} />}
        <box style={{ height: summaryListHeight, flexDirection: "column" }}>
          {visibleNodes.map((n, offset) => {
            const i = listStart + offset;
            const sel = i === cursor;
            const ic = icon(n);
            return (
              <box key={n.id} style={{ height: 1, flexDirection: "row" }}>
                <text fg={sel ? C.green : C.dim}>{sel ? " › " : "   "}</text>
                <text fg={ic.fg}>{ic.ch}</text>
                <text fg={sel ? C.bold : C.text}>{` ${n.label.padEnd(20).slice(0, 20)}`}</text>
                <text fg={n.state === "failed" ? C.red : C.dim}>{` ${n.detail}`.slice(0, Math.max(10, dims.width - 36))}</text>
                {n.items.length > 0 && <text fg={C.muted}>{`  ${n.items.length} items`}</text>}
                <text fg={C.dim}>{`  ${elapsed(n)}`}</text>
              </box>
            );
          })}
        </box>
        {/* Gutter between the last list row and the help bar */}
        <box style={{ height: 1 }} />
        <box style={{ height: 1, backgroundColor: C.surface1, paddingLeft: 1 }}>
          <text fg={C.dim}>{`↑↓ move${rangeHint} · ⏎ inspect · space logs · q quit · logs ${engine.logDirectory}`}</text>
        </box>
      </box>
    );
  }

  /* ── run screen ── */
  const c = engine.counts();
  const interactivePane = focus.kind === "interactive" && (focus.state === "needs-user" || focus.state === "interacting");
  const tailCount = Math.max(3, dims.height - (attention ? 7 : 6));
  const paneBodyHeight = Math.max(3, dims.height - (attention ? 5 : 4));
  const showModuleLogs = focus.logs.length > 0 || focus.state === "failed";
  const moduleLogHeight = showModuleLogs ? Math.min(8, Math.max(3, Math.floor(paneBodyHeight / 3))) : 0;
  const instruction = focus.kind === "interactive" ? focus.config["instruction"] : undefined;
  const selectedItemIndex = focus.items.length
    ? Math.min(itemMode ? (itemCursors[focus.id] ?? activeItemIndex(focus.items)) : activeItemIndex(focus.items), focus.items.length - 1)
    : 0;
  const selectedItem = focus.items[selectedItemIndex];
  const automaticExpanded = selectedItem && (selectedItem.state === "running" || selectedItem.state === "failed")
    ? [selectedItem.name]
    : [];
  const expandedNames = Object.hasOwn(expandedItems, focus.id) ? expandedItems[focus.id]! : automaticExpanded;

  return (
    <box style={{ width: "100%", height: "100%", flexDirection: "column", backgroundColor: C.surface0 }}>
      <box style={{ height: 1, backgroundColor: C.surface1, paddingLeft: 1, flexDirection: "row" }}>
        <text fg={C.bold}>{dryRun ? "primer update (dry run)" : "primer update"}</text>
        <text fg={C.dim}>{`  ${c.settled}/${c.total} · ${((Date.now() - engine.startedAt) / 1000).toFixed(0)}s · ${c.running} running`}</text>
      </box>

      {attention && (waiting.length > 0 ? (
        <box style={{ height: 1, backgroundColor: C.yellow, paddingLeft: 1 }}>
          <text fg={C.warningFg}>
            {`◆ waiting for your input: ${waiting.map((n) => n.label).join(" · ")}${waiting.some((n) => n.notified) ? "   · desktop notification sent" : ""}`}
          </text>
        </box>
      ) : (
        <box style={{ height: 1, backgroundColor: C.surface2, paddingLeft: 1 }}>
          <text fg={C.dim}>{`${spin()} ${inTerminal!.label} — signing in`}</text>
        </box>
      ))}

      <box style={{ flexGrow: 1, flexDirection: "row" }}>
        <box style={{ width: 33, flexDirection: "column", paddingLeft: 1, backgroundColor: C.surface1, border: ["right"], borderColor: C.muted }}>
          {nodes.map((n, i) => {
            const marked = i === focusIdx;
            const ptr = follow ? (marked ? "▸ " : "  ") : (marked ? "› " : "  ");
            const ic = icon(n);
            return (
              <box key={n.id} style={{ height: 1, flexDirection: "row", backgroundColor: marked ? C.selection : C.surface1 }}>
                <text fg={C.green}>{marked ? ptr : "  "}</text>
                <text fg={ic.fg}>{ic.ch}</text>
                <text fg={marked ? C.bold : n.state === "pending" ? C.dim : C.text}>{` ${n.label.padEnd(18).slice(0, 18)}`}</text>
                <text fg={C.dim}>{elapsed(n)}</text>
              </box>
            );
          })}
        </box>

        {interactivePane ? (
          <box
            style={{ flexGrow: 1, flexDirection: "column", padding: 1, marginRight: 1, backgroundColor: C.surface0, border: true, borderColor: focus.state === "needs-user" ? C.yellow : C.accent }}
            title={focus.state === "needs-user" ? ` ◆ ${focus.label} — waiting for you ` : ` ${focus.label} — in progress `}
          >
            {focus.state === "needs-user" ? (
              <>
                {instruction && <text fg={C.dim}>{instruction}</text>}
                {instruction && <text fg={C.dim}> </text>}
                <text fg={C.text}>⏎ start · s skip</text>
                {!focus.defaultOn && <text fg={C.dim}>config default: skip</text>}
              </>
            ) : (
              <>
                <text fg={C.yellow}>{`${spin()} signing in…`}</text>
                {focus.logs.slice(-tailCount).map((line, i) => (
                  <text key={i} fg={/error|failed/i.test(line) ? C.red : C.text}>{line}</text>
                ))}
                {focus.logs.length === 0 && <text fg={C.dim}>waiting for command output</text>}
              </>
            )}
          </box>
        ) : (
          <box style={{ flexGrow: 1, flexDirection: "column", paddingLeft: 1, backgroundColor: C.surface0 }}>
            <box style={{ height: 1, flexDirection: "row" }}>
              <text fg={icon(focus).fg}>{icon(focus).ch}</text>
              <text fg={C.bold}>{` ${focus.label}  `}</text>
              <text fg={C.dim}>{`${focus.detail || focus.state}  ${elapsed(focus)}`}</text>
            </box>
            {focus.items.length > 0 ? (
              <>
                <ItemLedger
                  items={focus.items}
                  selectedIndex={selectedItemIndex}
                  expandedNames={expandedNames}
                  active={itemMode}
                  height={Math.max(3, paneBodyHeight - moduleLogHeight)}
                  width={Math.max(20, dims.width - 34)}
                />
                {moduleLogHeight > 0 && <ModuleLogTail logs={focus.logs} height={moduleLogHeight} />}
              </>
            ) : (
              <>
                {focus.logs.slice(-tailCount).map((line, i) => (
                  <text key={i} fg={/error|failed/i.test(line) ? C.red : C.dim}>{`  ${line}`}</text>
                ))}
                {focus.logs.length === 0 && <text fg={C.dim}>  waiting for command output</text>}
              </>
            )}
          </box>
        )}
      </box>

      <box style={{ height: 1, backgroundColor: C.surface1, paddingLeft: 1 }}>
        <text fg={C.dim}>
          {engine.finished()
            ? "finished — ⏎ quit"
            : itemMode
              ? "items (›) · ↑↓ move · ⏎ toggle output · space full item logs · ←/esc modules"
            : follow
              ? `following (▸) · ↑↓ take control · →/tab items${attention ? " · ⏎ answer input · s skip" : ""} · space logs`
              : "manual (›) · ↑↓ module · →/tab items · space logs · esc follow"}
        </text>
      </box>
    </box>
  );
}

function ModuleLogTail({ logs, height }: { logs: string[]; height: number }) {
  const lines = logs.slice(-Math.max(1, height));
  return (
    <box style={{ height, flexDirection: "column", paddingLeft: 1, border: ["top"], borderColor: C.muted }}>
      {lines.map((line, i) => (
        <text key={i} fg={/error|failed|not found/i.test(line) ? C.red : C.dim}>{line || " "}</text>
      ))}
      {logs.length === 0 && <text fg={C.dim}>no module output</text>}
    </box>
  );
}

function ItemLedger({ items, selectedIndex, expandedNames, active, height, width }: {
  items: EngineItem[];
  selectedIndex: number;
  expandedNames: string[];
  active: boolean;
  height: number;
  width: number;
}) {
  type LedgerLine =
    | { kind: "item"; item: EngineItem; itemIndex: number }
    | { kind: "log"; item: EngineItem; text: string; key: string };
  const lines: LedgerLine[] = [];
  for (const [itemIndex, item] of items.entries()) {
    lines.push({ kind: "item", item, itemIndex });
    if (!expandedNames.includes(item.name)) continue;
    if (!item.logs.length) {
      lines.push({ kind: "log", item, text: "no command output · status is the complete result", key: `${item.name}:empty` });
      continue;
    }
    const inlineLogs = item.logs.slice(-5);
    if (item.logs.length > inlineLogs.length) {
      lines.push({ kind: "log", item, text: `… ${item.logs.length - inlineLogs.length} earlier lines · space opens full log`, key: `${item.name}:more` });
    }
    inlineLogs.forEach((text, index) => lines.push({ kind: "log", item, text, key: `${item.name}:${index}` }));
  }
  const selectedLine = Math.max(0, lines.findIndex((line) => line.kind === "item" && line.itemIndex === selectedIndex));
  const bodyHeight = Math.max(1, height - 1);
  const { start, count } = listWindow(selectedLine, lines.length, bodyHeight);
  const visible = lines.slice(start, start + count);
  const nameWidth = Math.max(10, Math.min(24, Math.floor(width * 0.38)));
  const detailWidth = Math.max(8, width - nameWidth - 9);
  const settled = items.filter((item) => item.state !== "pending" && item.state !== "running").length;

  return (
    <box style={{ flexGrow: 1, flexDirection: "column" }}>
      <box style={{ height: 1, flexDirection: "row", border: ["bottom"], borderColor: C.muted }}>
        <text fg={C.dim}>{`  ${settled}/${items.length} checked`}</text>
        <text fg={C.muted}>{active ? "  ·  item navigation" : "  ·  ⏎ inspect items"}</text>
      </box>
      {visible.map((line) => {
        if (line.kind === "log") {
          return (
            <box key={line.key} style={{ height: 1, flexDirection: "row", paddingLeft: 5, border: ["left"], borderColor: itemIcon(line.item).fg }}>
              <text fg={/error|failed/i.test(line.text) ? C.red : C.dim}>{line.text}</text>
            </box>
          );
        }
        const { item, itemIndex } = line;
        const selected = active && itemIndex === selectedIndex;
        const ic = itemIcon(item);
        const detail = itemDetail(item);
        return (
          <box key={item.name} style={{ height: 1, flexDirection: "row", backgroundColor: selected ? C.selection : C.surface0 }}>
            <text fg={selected ? C.green : C.muted}>{selected ? " ›" : "  "}</text>
            <text fg={ic.fg}>{` ${ic.ch} `}</text>
            <text fg={selected ? C.bold : item.state === "pending" ? C.dim : C.text}>
              {item.name.padEnd(nameWidth).slice(0, nameWidth)}
            </text>
            <text fg={item.state === "failed" ? C.red : C.dim}>{`  ${detail}`.slice(0, detailWidth)}</text>
          </box>
        );
      })}
    </box>
  );
}
