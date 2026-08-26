import type { AddonDef } from "./config";
import { createTerminalRestorer, shutdownRenderer } from "./terminal-lifecycle";

/** Run the first-run/profile-set picker and restore the terminal before return. */
export async function runAddonPicker(
  profile: string,
  addons: AddonDef[],
  initial: string[],
): Promise<string[] | null> {
  const { createCliRenderer } = await import("@opentui/core");
  const { createRoot } = await import("@opentui/react");
  const { createElement } = await import("react");
  const { AddonPicker } = await import("./addon-picker");
  const renderer = await createCliRenderer({ exitOnCtrlC: false, exitSignals: [] });
  const root = createRoot(renderer);
  const restoreTerminal = createTerminalRestorer();

  return new Promise((resolve) => {
    let finished = false;
    const finish = async (result: string[] | null) => {
      if (finished) return;
      finished = true;
      await shutdownRenderer(renderer);
      restoreTerminal();
      resolve(result);
    };
    root.render(createElement(AddonPicker, {
      profile,
      addons,
      initial,
      onConfirm: (selected: string[]) => void finish(selected),
      onCancel: () => void finish(null),
    }));
  });
}
