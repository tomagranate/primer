# primer

Modular, DAG-based machine setup for macOS, Ubuntu VPSs, and Ubuntu desktops. One command to install everything, with parallel execution and a rich terminal UI.

## Quick Start

```sh
curl -fsSL https://raw.githubusercontent.com/tomagranate/primer/main/setup.sh | sh
```

Preview what would happen without making changes:

```sh
curl -fsSL https://raw.githubusercontent.com/tomagranate/primer/main/setup.sh | sh -s -- --dry-run
```

## Commands and Options

After the initial setup, `primer` is installed to `~/bin/`:

```sh
primer <command> [options]
```

### Commands

- `update` - install/update all enabled modules (idempotent)
- `status` - check install/health status for all enabled modules
- `help` - show help text (same as `--help`/`-h`)

### Options

- `--dry-run` - preview changes without applying them (valid with `update`)
- `--skip <module>` - skip a module by name; repeatable (valid with `update`)
- `--only <module>` - run only one module; repeatable (valid with `update`)
- `--profile <name>` - force a profile (`mac`, `linux-vps`, `ubuntu-desktop`)
- `--tui` - force alternate-screen terminal UI (valid with `update`)
- `--log` - force plain log output
- `--help` - show help text
- `-h` - show help text

### Examples

```sh
primer update
primer update --dry-run
primer update --skip mac-app-store
primer update --profile linux-vps
primer update --profile ubuntu-desktop
primer status
primer --help
primer -h
primer help
```

## What It Does

Modules run in parallel as a DAG -- each starts as soon as its dependencies are met:

| Module | Depends On | What It Does |
| --- | --- | --- |
| **apt** | -- | Installs configured Debian/Ubuntu packages for VPS profiles |
| **flatpak** | apt | Installs explicitly configured Flatpak apps |
| **helium-browser** | apt | Installs Helium Browser from the official Linux apt repository |
| **npm-global** | mise | Installs configured global npm CLIs |
| **login-shell** | zsh | Changes the user's login shell to zsh when possible |
| **xcode-cli-tools** | -- | Installs Xcode Command Line Tools and waits for the installer dialog to be accepted |
| **shell-installers** | xcode-cli-tools | Installs configured tools from remote shell installers |
| **homebrew** | xcode-cli-tools | Installs Homebrew and configured formulae |
| **homebrew-apps** | homebrew | Installs configured Homebrew cask apps |
| **mac-app-store** | homebrew | Installs configured Mac App Store apps via `mas`, including Xcode |
| **xcode** | mac-app-store | Selects full Xcode, runs first launch setup, and installs configured simulator platforms |
| **macos** | homebrew-apps | Applies macOS defaults and configures the Dock |
| **zsh** | homebrew | Updates managed section in ~/.zshrc, manages ~/.zimrc, installs Zim |
| **starship** | homebrew | Deploys starship.toml to ~/.config/ |
| **mise** | homebrew | Installs language runtimes (Node, Python, Bun) |
| **ssh** | xcode-cli-tools | Creates an SSH key and configures macOS keychain-backed agent support |
| **touchid** | -- | Enables Touch ID for sudo |
| **git** | -- | Configures global Git CLI defaults and installs Git helper scripts to ~/bin/ |

## Architecture

Each module is a **self-contained folder** that owns its config files, scripts, and install logic. Profile config is split into `configs/common.conf` plus `configs/profiles/<profile>.conf`; `primer.conf` remains as a legacy macOS aggregate.

```
├── setup.sh                      # Bootstrap (curl-able, installs primer CLI)
├── primer.conf                   # Legacy macOS aggregate config
├── configs/
│   ├── common.conf               # Shared user-level config
│   └── profiles/                 # mac, linux-vps, ubuntu-desktop fragments
├── lib/
│   ├── engine.zsh                # Ready-queue DAG executor + INI parser
│   └── ui.zsh                    # Terminal UI (spinners, boxes, colors, helpers)
├── modules/
│   ├── xcode-cli-tools/
│   │   └── module.zsh
│   ├── xcode/
│   │   └── module.zsh
│   ├── shell-installers/
│   │   └── module.zsh
│   ├── homebrew/
│   │   └── module.zsh            # Generates Brewfile from config, runs brew bundle
│   ├── mac-app-store/
│   │   └── module.zsh
│   ├── homebrew-apps/
│   │   └── module.zsh
│   ├── zsh/
│   │   ├── module.zsh
│   │   └── files/                # .zshrc managed block + .zimrc
│   ├── starship/
│   │   ├── module.zsh
│   │   └── files/                # starship.toml
│   ├── mise/
│   │   └── module.zsh            # Installs tools from config via mise use --global
│   ├── touchid/
│   │   └── module.zsh
│   └── git/
│       ├── module.zsh
│       └── bin/                   # git-clean, git-uncommit, etc.
└── bin/
    └── primer                     # CLI entry point
```

## Adding a Module

### Simple module (config file deployment)

1. Create `modules/<name>/files/` with your config files
2. Write a 5-line `module.zsh`:

```zsh
mod_update() {
    deploy_files "$CONFIG_DIR/<name>"
    primer::status_msg "configured"
}
mod_status() {
    check_files "$CONFIG_DIR/<name>"
}
```

3. Add a section to `configs/common.conf` or a profile in `configs/profiles/`:

```ini
[name]
label = Display Name
depends_on = homebrew  # optional
```

### Complex module (custom logic)

Write `mod_update()` and `mod_status()` with whatever logic you need. Use `mod_config <key>` to read values from the active profile config.

## Profiles

Primer auto-detects the profile when it can:

- `mac` on macOS
- `linux-vps` on Debian/Ubuntu without a desktop session
- `ubuntu-desktop` on Ubuntu with a desktop session

For ambiguous Linux machines, interactive runs prompt and default to `linux-vps`. Non-interactive runs should pass `--profile` or set `PRIMER_PROFILE`.

```sh
primer update --profile linux-vps
PRIMER_PROFILE=ubuntu-desktop primer status
```

Linux profiles install Tailscale through a dedicated `tailscale` module using Tailscale's official Linux installer, because the `tailscale` package is not part of Ubuntu's default apt repositories.

## Configuration

Module settings live in `configs/common.conf` and `configs/profiles/*.conf`. Each `[section]` activates a module. Remove a section from the selected profile/common config to disable it. Indented lines continue the previous key's value.

```ini
[homebrew]
label = Homebrew
depends_on = xcode-cli-tools
taps =
    tomagranate/tap
formulae =
    mise
    starship
    fzf
    corsa

[shell-installers]
label = Shell installers
depends_on = xcode-cli-tools
installers =
    - name: example
      url: https://example.com/install.sh
      command: example
      check: example --version

[homebrew-apps]
label = Mac Apps
depends_on = homebrew
casks =
    google-chrome
    slack

[mac-app-store]
label = Mac App Store
depends_on = homebrew
mas =
    Xcode:497799835

[xcode]
label = Xcode app
depends_on = mac-app-store
app_path = /Applications/Xcode.app
simulator_platforms =
    iOS

[mise]
label = Mise languages
depends_on = homebrew
tools =
    node:lts
    python:3.12
    bun:latest

[npm-global]
label = Global npm CLIs
depends_on = mise
packages =
    - name: t3
      package: t3@latest
      command: t3
      check: t3 --version

[git]
label = Git CLI
settings =
    user.name:Your Name
    user.email:you@example.com
    user.useConfigOnly:true
    pull.rebase:false
    init.defaultBranch:master
    push.default:simple
    push.autoSetupRemote:true
    fetch.prune:true
    merge.conflictStyle:zdiff3
    diff.algorithm:histogram
```

Interactive logins are configured in `[logins]` and run after installation
finishes. `*_depends_on` names Primer modules that must complete first,
`*_requires` names commands that must exist, `*_status` detects whether the
account is already logged in, and `*_command` starts the login flow.

```ini
[logins]
order =
    github
github_label = GitHub CLI
github_default = yes
github_depends_on = ssh, git, homebrew
github_requires = gh
github_status =
    gh auth status --hostname github.com &&
    test "$(gh config get git_protocol --host github.com 2>/dev/null)" = ssh &&
    key_body="$(awk 'NF >= 2 { print $2; exit }' "$HOME/.ssh/id_ed25519.pub")" &&
    gh ssh-key list | grep -F "$key_body"
github_command =
    (gh auth status --hostname github.com >/dev/null 2>&1 && gh auth refresh --hostname github.com --scopes admin:public_key || gh auth login --hostname github.com --git-protocol ssh --scopes admin:public_key) &&
    gh config set git_protocol ssh --host github.com &&
    key_body="$(awk 'NF >= 2 { print $2; exit }' "$HOME/.ssh/id_ed25519.pub")" &&
    if gh ssh-key list | grep -F "$key_body" >/dev/null; then echo "SSH key already registered with GitHub."; else gh ssh-key add "$HOME/.ssh/id_ed25519.pub" --title "$(hostname -s 2>/dev/null || hostname 2>/dev/null || echo primer)"; fi
```

## Config Locations (on your Mac)

| What | Where |
| --- | --- |
| Zsh config | `~/.zshrc` (Primer-managed section) |
| Zim modules | `~/.zimrc` |
| Starship prompt | `~/.config/starship.toml` |
| SSH config | `~/.ssh/config` (Primer-managed section) |
| SSH key | `~/.ssh/id_ed25519` |
| Git config | `~/.gitconfig` |
| Custom scripts | `~/bin/` |

## Development

Use a local checkout instead of fetching from GitHub:

```sh
PRIMER_LOCAL=/path/to/primer primer update
PRIMER_LOCAL=/path/to/primer primer status
```

## Testing

Tests use [BATS-core](https://github.com/bats-core/bats-core). Unit tests live in `tests/unit/`, module tests are co-located in `modules/<name>/tests.bats`.

### Setup

```sh
brew install bats-core
git clone --depth 1 https://github.com/bats-core/bats-support.git tests/helpers/bats-support
git clone --depth 1 https://github.com/bats-core/bats-assert.git tests/helpers/bats-assert
```

### Running tests

```sh
# Everything (unit + module + dry-run smoke)
bats tests/unit/ tests/dry_run.bats modules/*/tests.bats

# Unit tests only
bats tests/unit/

# Single module
bats modules/starship/tests.bats

# Dry-run smoke test
bats tests/dry_run.bats
```

### Wet-run testing (macOS VM)

For full end-to-end validation on a clean macOS, use [Tart](https://github.com/cirruslabs/tart).
To test the current checkout before pushing, run Tart from this repo root and
mount the working tree into the VM:

```sh
brew install cirruslabs/cli/tart
tart clone ghcr.io/cirruslabs/macos-sequoia-base:latest primer-test
tart run --dir="primer:$PWD" primer-test
```

Inside the VM:

```sh
# The host checkout is mounted here by tart run --dir.
cd "/Volumes/My Shared Files/primer"

# Run against the mounted local checkout, including uncommitted host changes.
PRIMER_LOCAL=$PWD zsh ./bin/primer update
PRIMER_LOCAL=$PWD zsh ./bin/primer status
```

To test the published bootstrap flow instead of your local changes:

```sh
curl -fsSL https://raw.githubusercontent.com/tomagranate/primer/main/setup.sh | sh
```

Reset to a clean slate with `tart delete primer-test` and re-clone.
