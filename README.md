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

## Commands

After the initial setup, `primer` is installed to `~/bin/`:

```sh
primer update              # Re-run everything (idempotent)
primer update --dry-run    # Preview changes
primer status              # Check what's installed and healthy
primer --help              # Show all commands
```

## What It Does

Modules run in parallel as a DAG -- each starts as soon as its dependencies are met:

| Module | Depends On | What It Does |
| --- | --- | --- |
| **xcode** | -- | Installs Xcode Command Line Tools |
| **homebrew** | xcode | Installs Homebrew + all formulae, casks, and MAS apps |
| **zim** | homebrew | Deploys zsh configs, symlinks .zshenv, installs Zim |
| **starship** | homebrew | Deploys starship.toml to ~/.config/ |
| **mise** | homebrew | Installs language runtimes (Node, Python, Bun) |
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
│   ├── xcode/
│   │   └── module.zsh
│   ├── homebrew/
│   │   └── module.zsh            # Generates Brewfile from config, runs brew bundle
│   ├── zim/
│   │   ├── module.zsh
│   │   └── files/                # .zshenv, .zshrc, .zimrc
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
depends_on = xcode
formulae =
    mise
    starship
    fzf
casks =
    google-chrome
    slack
mas =
    Magnet:441258766

[mise]
label = Mise languages
depends_on = homebrew
tools =
    node:lts
    python:3.12
    bun:latest
```

## Config Locations (on your Mac)

| What | Where |
| --- | --- |
| Zsh config | `~/.config/zsh/.zshrc` |
| Zim modules | `~/.config/zsh/.zimrc` |
| Starship prompt | `~/.config/starship.toml` |
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

For full end-to-end validation on a clean macOS, use [Tart](https://github.com/cirruslabs/tart):

```sh
brew install cirruslabs/cli/tart
tart clone ghcr.io/cirruslabs/macos-sequoia-base:latest primer-test
tart run primer-test
```

Inside the VM:

```sh
# Test the bootstrap flow
curl -fsSL https://raw.githubusercontent.com/tomagranate/primer/main/setup.sh | sh

# Or test from a local checkout
git clone https://github.com/tomagranate/primer.git && cd primer
PRIMER_LOCAL=$PWD ./bin/primer update
./bin/primer status
```

Reset to a clean slate with `tart delete primer-test` and re-clone.

## Shell Stack

- **Zsh** with [Zim](https://zimfw.sh/) for plugin management
- **[Starship](https://starship.rs/)** prompt (via `joke/zim-starship` module)
- Plugins: autosuggestions, syntax highlighting, history substring search, git aliases
- **[mise](https://mise.jdx.dev/)** for managing Node, Python, and Bun versions
