/**
 * primer update TUI — split panes ("option B" from prototype/tui-prototype.html).
 *
 * Left: task list. Right: live log tail of the focused node.
 * Follow-along mode is the default; arrows take manual control; esc returns.
 * Interactive nodes show a framed prompt. Pane commands show live output.
 */
import { useEffect, useState } from "react";
import { useKeyboard, useTerminalDimensions } from "@opentui/react";
import type { Engine, EngineNode } from "./engine";

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

export function App({ engine, dryRun, onQuit }: AppProps) {
  const dims = useTerminalDimensions();
  const [, setTick] = useState(0);
  const [follow, setFollow] = useState(true);
  const [cursor, setCursor] = useState(0);
  const [screen, setScreen] = useState<"run" | "logs" | "summary">("run");
  const [logScroll, setLogScroll] = useState(-1); // -1 = follow tail
  const [logNode, setLogNode] = useState<EngineNode | null>(null);
  const [itemTabs, setItemTabs] = useState<Record<string, number>>({});

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

  useKeyboard((key) => {
    const name = key.name ?? key.sequence;

    if (screen === "logs" && logNode) {
      const bodyH = dims.height - 2;
      const maxStart = Math.max(0, logNode.logs.length - bodyH);
      if (name === "escape" || name === "q") { setScreen(engine.finished() ? "summary" : "run"); setLogScroll(-1); }
      if (name === "up") setLogScroll((s) => Math.max(0, (s === -1 ? maxStart : s) - 1));
      if (name === "down") setLogScroll((s) => (s === -1 ? -1 : s + 1 >= maxStart ? -1 : s + 1));
      return;
    }

    const isSpace = name === "space" || key.sequence === " ";
    const openLogs = (target: EngineNode | undefined) => {
      if (target && (target.logs.length || target.state !== "pending")) {
        setLogNode(target); setLogScroll(-1); setScreen("logs");
      }
    };

    if (screen === "summary") {
      if (name === "up" || name === "down") {
        setCursor((c) => (c + (name === "up" ? nodes.length - 1 : 1)) % nodes.length);
      } else if (isSpace) {
        openLogs(nodes[cursor]);
      } else if (name === "return" || name === "escape" || name === "q" || (name === "c" && key.ctrl)) {
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
    } else if ((name === "left" || name === "right" || name === "tab") && focus.items.length) {
      const tabCount = focus.items.length + 1;
      const step = name === "left" ? tabCount - 1 : 1;
      setItemTabs((tabs) => ({
        ...tabs,
        [focus.id]: ((tabs[focus.id] ?? 0) + step) % tabCount,
      }));
    } else if (name === "return") {
      if (engine.finished()) { onQuit(); return; }
      const target = follow ? nodes.find((n) => n.state === "needs-user") ?? focus : focus;
      if (target.state === "needs-user") { void engine.answerInteractive(target); return; }
      openLogs(target);
    } else if (isSpace) {
      openLogs(focus);
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
  if (screen === "logs" && logNode) {
    const bodyH = dims.height - 2;
    const total = logNode.logs.length;
    let startLine = logScroll === -1 ? Math.max(0, total - bodyH) : Math.min(logScroll, Math.max(0, total - bodyH));
    const lines = logNode.logs.slice(startLine, startLine + bodyH);
    return (
      <box style={{ width: "100%", height: "100%", flexDirection: "column", backgroundColor: C.surface0 }}>
        <box style={{ height: 1, backgroundColor: C.surface1, paddingLeft: 1, flexDirection: "row" }}>
          <text fg={C.bold}>logs · {logNode.label}</text>
          <text fg={icon(logNode).fg}>{`  ${icon(logNode).ch} `}</text>
          <text fg={C.dim}>{`${logNode.state} · ${elapsed(logNode)}`}</text>
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

  /* ── summary ── */
  if (screen === "summary") {
    const c = engine.counts();
    const ok = c.failed === 0 && !engine.interrupted;
    return (
      <box style={{ width: "100%", height: "100%", flexDirection: "column", backgroundColor: C.surface0 }}>
        <box style={{ height: 1, backgroundColor: C.surface1, paddingLeft: 1, flexDirection: "row" }}>
          <text fg={ok ? C.green : C.red}>
            {ok ? "✓ primer update complete" : engine.interrupted ? "! primer update interrupted" : "✗ primer update finished with issues"}
          </text>
          <text fg={C.dim}>{`  ${((Date.now() - engine.startedAt) / 1000).toFixed(0)}s${dryRun ? " · dry run" : ""}`}</text>
        </box>
        <box style={{ height: 1 }} />
        <box style={{ height: 1, flexDirection: "row", paddingLeft: 2 }}>
          <text fg={C.green}>{`✓ ${c.done} done`}</text>
          {c.failed > 0 && <text fg={C.red}>{`   ✗ ${c.failed} failed`}</text>}
          {c.skipped > 0 && <text fg={C.yellow}>{`   ○ ${c.skipped} skipped`}</text>}
        </box>
        <box style={{ height: 1 }} />
        <box style={{ flexGrow: 1, flexDirection: "column" }}>
          {nodes.map((n, i) => {
            const sel = i === cursor;
            const ic = icon(n);
            return (
              <box key={n.id} style={{ height: 1, flexDirection: "row" }}>
                <text fg={sel ? C.green : C.dim}>{sel ? " › " : "   "}</text>
                <text fg={ic.fg}>{ic.ch}</text>
                <text fg={sel ? C.bold : C.text}>{` ${n.label.padEnd(20).slice(0, 20)}`}</text>
                <text fg={n.state === "failed" ? C.red : C.dim}>{` ${n.detail}`.slice(0, Math.max(10, dims.width - 36))}</text>
                <text fg={C.dim}>{`  ${elapsed(n)}`}</text>
              </box>
            );
          })}
        </box>
        <box style={{ height: 1, backgroundColor: C.surface1, paddingLeft: 1 }}>
          <text fg={C.dim}>↑↓ move · space logs · ⏎ quit</text>
        </box>
      </box>
    );
  }

  /* ── run screen ── */
  const c = engine.counts();
  const interactivePane = focus.kind === "interactive" && (focus.state === "needs-user" || focus.state === "interacting");
  const tailCount = Math.max(3, dims.height - (attention ? 7 : 6));
  const instruction = focus.kind === "interactive" ? focus.config["instruction"] : undefined;
  const itemTab = focus.items.length ? Math.min(itemTabs[focus.id] ?? 0, focus.items.length) : 0;
  const selectedItem = itemTab > 0 ? focus.items[itemTab - 1] : undefined;
  const paneLogs = selectedItem ? selectedItem.logs : focus.logs;

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
            {focus.items.length > 0 && (
              <box style={{ height: 1, flexDirection: "row" }}>
                <text fg={itemTab === 0 ? C.bold : C.dim}>{`  ${itemTab === 0 ? "[module]" : " module "}  `}</text>
                {focus.items.map((item, i) => (
                  <text key={item.name} fg={i + 1 === itemTab ? C.bold : C.dim}>
                    {`${i + 1 === itemTab ? "[" : " "}${item.name}${i + 1 === itemTab ? "]" : " "} `}
                  </text>
                ))}
              </box>
            )}
            {paneLogs.slice(-tailCount).map((line, i) => (
              <text key={i} fg={/error|failed/i.test(line) ? C.red : C.dim}>{`  ${line}`}</text>
            ))}
            {paneLogs.length === 0 && <text fg={C.dim}>  waiting for command output</text>}
          </box>
        )}
      </box>

      <box style={{ height: 1, backgroundColor: C.surface1, paddingLeft: 1 }}>
        <text fg={C.dim}>
          {engine.finished()
            ? "finished — ⏎ quit"
            : follow
              ? `following (▸) · ↑↓ take control · ←→ item logs${attention ? " · ⏎ answer input · s skip" : ""} · space logs`
              : "manual (›) · ↑↓ module · ←→ item logs · space logs · esc follow"}
        </text>
      </box>
    </box>
  );
}
