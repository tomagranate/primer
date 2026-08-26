import type { AddonDef, NodeDef } from "./config";
import type { Selection } from "./selection";

export function profileSummary(selection: Selection, available: AddonDef[]): string {
  const applicable = available.filter((addon) => addon.profiles.includes(selection.profile));
  const lines = [
    `Profile: ${selection.profile}`,
    `Source: ${selection.source}`,
    `Addons: ${selection.addons.join(", ") || "none"}`,
    "Available addons:",
  ];
  if (applicable.length === 0) lines.push("  none");
  for (const addon of applicable) {
    const active = selection.addons.includes(addon.name) ? " (active)" : "";
    lines.push(`  ${addon.name}${active} — ${addon.label}: ${addon.description}`);
  }
  return lines.join("\n");
}

export function droppedModuleIds(oldNodes: NodeDef[], newNodes: NodeDef[]): string[] {
  const managed = new Set(newNodes.filter((node) => node.kind === "module").map((node) => node.id));
  return oldNodes
    .filter((node) => node.kind === "module" && !managed.has(node.id))
    .map((node) => node.id);
}

export function profileSetResult(
  profile: string,
  addons: string[],
  dropped: string[],
  comparedPrevious = true,
): string {
  const lines = [
    `Saved profile '${profile}' with addons: ${addons.join(", ") || "none"}.`,
  ];
  if (!comparedPrevious) {
    lines.push("The previous selection was invalid, so Primer could not compare managed modules.");
  } else if (dropped.length === 0) {
    lines.push("No modules leave Primer management.");
  } else {
    lines.push("Modules that leave Primer management:");
    for (const id of dropped) lines.push(`  ${id}`);
    lines.push("Primer does not uninstall these modules. Remove them manually if needed.");
  }
  return lines.join("\n");
}
