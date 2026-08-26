export type Command = "" | "update" | "status" | "profile" | "help";

export interface Args {
  command: Command;
  dryRun: boolean;
  skip: string[];
  only: string[];
  profile?: string;
  addons: string[];
  headless: boolean;
  profileAction: "show" | "set";
  profileSetArgs: string[];
}

export class CliError extends Error {}

function need(argv: string[], i: number, flag: string): string {
  const value = argv[i];
  if (!value || value.startsWith("--")) throw new CliError(`Missing argument for ${flag}`);
  return value;
}

export function parseArgs(argv: string[]): Args {
  const args: Args = {
    command: "",
    dryRun: false,
    skip: [],
    only: [],
    addons: [],
    headless: false,
    profileAction: "show",
    profileSetArgs: [],
  };
  let profileActionSeen = false;

  for (let i = 0; i < argv.length; i++) {
    const arg = argv[i]!;
    if (
      args.command === "profile"
      && args.profileAction === "set"
      && profileActionSeen
      && !arg.startsWith("-")
    ) {
      args.profileSetArgs.push(arg);
      continue;
    }
    switch (arg) {
      case "update":
      case "status":
        if (args.command && args.command !== arg) throw new CliError(`Unknown argument: ${arg}`);
        args.command = arg;
        break;
      case "profile":
        if (args.command && args.command !== "profile") throw new CliError(`Unknown argument: ${arg}`);
        args.command = "profile";
        break;
      case "set":
        if (args.command !== "profile" || profileActionSeen) {
          throw new CliError(`Unknown argument: ${arg}`);
        }
        args.profileAction = "set";
        profileActionSeen = true;
        break;
      case "show":
        if (args.command !== "profile" || profileActionSeen) {
          throw new CliError(`Unknown argument: ${arg}`);
        }
        profileActionSeen = true;
        break;
      case "--dry-run": args.dryRun = true; break;
      case "--log": args.headless = true; break;
      case "--skip": args.skip.push(need(argv, ++i, arg)); break;
      case "--only": args.only.push(need(argv, ++i, arg)); break;
      case "--profile": args.profile = need(argv, ++i, arg); break;
      case "--addon": args.addons.push(need(argv, ++i, arg)); break;
      case "--help":
      case "-h":
      case "help": args.command = "help"; break;
      default:
        throw new CliError(`Unknown argument: ${arg}\nRun 'primer --help' for usage.`);
    }
  }

  if (args.skip.length && args.only.length) {
    throw new CliError("--skip and --only cannot be used together.");
  }
  if (args.command && (args.skip.length || args.only.length || args.dryRun) && args.command !== "update") {
    throw new CliError("--dry-run, --skip, and --only are only valid with 'update'.");
  }
  if (args.command === "profile" && args.profileAction === "set" && (args.profile || args.addons.length)) {
    throw new CliError("Use positional profile and addon names with 'primer profile set'.");
  }
  return args;
}
