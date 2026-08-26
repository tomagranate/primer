import { detectProfile, loadNodes } from "./config";
import { readMachineConfig } from "./machine-config";

export type SelectionSource = "flag" | "env" | "machine.conf" | "detected";

export interface Selection {
  profile: string;
  addons: string[];
  source: SelectionSource;
  firstRun: boolean;
}

export interface SelectionArgs {
  primerDir: string;
  profile?: string;
  addons?: string[];
  env?: NodeJS.ProcessEnv;
}

function envAddons(value: string | undefined): string[] | undefined {
  if (value === undefined) return undefined;
  return [...new Set(value.split(",").map((item) => item.trim()).filter(Boolean))];
}

/** Resolve transient overrides before persisted machine identity and detection. */
export async function resolveSelection(args: SelectionArgs): Promise<Selection> {
  const env = args.env ?? process.env;
  const cliAddons = [...new Set(args.addons ?? [])];
  const profileFromEnv = env.PRIMER_PROFILE?.trim() || undefined;
  const addonsFromEnv = envAddons(env.PRIMER_ADDONS);
  const forcedProfile = args.profile ?? profileFromEnv;
  // Do not parse lower-precedence local state when a transient profile wins.
  // This also lets an explicit profile repair or bypass a malformed file.
  const machine = forcedProfile ? null : await readMachineConfig(env);

  let profile: string;
  let source: SelectionSource;
  if (args.profile) {
    profile = args.profile;
    source = "flag";
  } else if (profileFromEnv) {
    profile = profileFromEnv;
    source = "env";
  } else if (machine) {
    profile = machine.profile;
    source = "machine.conf";
  } else {
    profile = await detectProfile(args.primerDir, undefined, env);
    source = "detected";
  }

  let addons: string[];
  if (cliAddons.length > 0) {
    addons = cliAddons;
  } else if (addonsFromEnv !== undefined) {
    addons = addonsFromEnv;
  } else if (args.profile || profileFromEnv) {
    // A forced profile is a complete transient profile choice. Do not combine
    // it with addons persisted for a different machine profile.
    addons = [];
  } else {
    addons = [...new Set(machine?.addons ?? [])];
  }

  const firstRun = !machine
    && !args.profile
    && cliAddons.length === 0
    && !profileFromEnv
    && addonsFromEnv === undefined;

  // Validate both names and addon applicability before the caller starts work.
  await loadNodes(args.primerDir, profile, addons);
  return { profile, addons, source, firstRun };
}
