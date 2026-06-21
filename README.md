# primer

Modular, DAG-based Mac setup. One command to install everything, with parallel execution and a rich terminal UI.

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
- `--skip-app-store` - skip App Store (`mas`) installs (valid with `update`)
- `--help` - show help text
- `-h` - show help text

### Examples

```sh
primer update
primer update --dry-run
primer update --skip-app-store
primer status
primer --help
primer -h
primer help
```

## What It Does

Modules run in parallel as a DAG -- each starts as soon as its dependencies are met:

| Module | Depends On | What It Does |
| --- | --- | --- |
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
| **scripts** | -- | Installs custom scripts to ~/bin/ |

## Architecture

Each module is a **self-contained folder** that owns its config files, scripts, and install logic. `primer.conf` is an INI-style config that activates modules and holds their data (brew packages, mise tools, etc.).

```
├── setup.sh                      # Bootstrap (curl-able, installs primer CLI)
├── primer.conf                   # INI config (modules + deps + per-module settings)
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
│   └── scripts/
│       ├── module.zsh
│       └── bin/                   # rgf, etc.
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

3. Add a section to `primer.conf`:

```ini
[name]
label = Display Name
depends_on = homebrew  # optional
```

### Complex module (custom logic)

Write `mod_update()` and `mod_status()` with whatever logic you need. Use `mod_config <key>` to read values from `primer.conf`.

## Configuration

All module settings live in `primer.conf`. Each `[section]` activates a module. Remove a section to disable it. Indented lines continue the previous key's value.

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
github_depends_on = ssh, homebrew
github_requires = gh
github_status = gh auth status
github_command = gh auth login
```

## Config Locations (on your Mac)

| What | Where |
| --- | --- |
| Zsh config | `~/.zshrc` (Primer-managed section) |
| Zim modules | `~/.zimrc` |
| Starship prompt | `~/.config/starship.toml` |
| SSH config | `~/.ssh/config` (Primer-managed section) |
| SSH key | `~/.ssh/id_ed25519` |
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
