# primer

Modular, DAG-based machine setup for macOS, Ubuntu, and Fedora KDE. One command installs everything in parallel with a rich terminal UI.

## Quick Start

```sh
curl -fsSL https://raw.githubusercontent.com/tomagranate/primer/master/setup.sh | sh
```

The piped setup cannot replace its parent shell. Open a new terminal after setup,
or run `exec zsh` to start the configured Zsh and Starship prompt immediately.

Preview what would happen without making changes:

```sh
curl -fsSL https://raw.githubusercontent.com/tomagranate/primer/master/setup.sh | sh -s -- --dry-run
```

## Commands and Options

After the initial setup, `primer` is installed to `~/bin/`:

```sh
primer <command> [options]
```

After `primer update`, open a new terminal or run `source ~/.zshrc` so PATH,
functions, and aliases pick up any managed config changes.

### Commands

- `update` - install/update all enabled modules (idempotent)
- `status` - check install/health status for all enabled modules
- `help` - show help text (same as `--help`/`-h`)

### Options

- `--dry-run` - preview changes without applying them (valid with `update`)
- `--skip <module>` - skip a module by name; repeatable (valid with `update`)
- `--only <module>` - run only one module; repeatable (valid with `update`)
- `--profile <name>` - force a profile; any name with a file in `configs/profiles/`, such as `mac`, `linux-vps`, or `fedora-kde`
- `--log` - force plain log output
- `--help` - show help text
- `-h` - show help text

### Examples

```sh
primer update
primer update --dry-run
primer update --skip mac-app-store
primer update --profile linux-vps
primer update --profile fedora-kde
primer status
primer --help
primer -h
primer help
```

### Linux agent sudo sessions

Linux profiles install `agents-sudo` in `~/bin`.
Run it in an interactive terminal before privileged agent work:

```sh
agents-sudo
```

The command installs `/etc/sudoers.d/agents-session`.
It creates a global sudo ticket with a 12-hour timeout.

Check or end the session with these commands:

```sh
agents-sudo --status
agents-sudo --revoke
agents-sudo --remove
```

`--revoke` ends the ticket. `--remove` also deletes the shared sudo policy.

### Run logs

Primer saves each update run under `~/.local/state/primer/runs/`.
Each run contains one log per module, item logs, an aggregate log, and `summary.json`.

Primer limits this directory to 100 MiB by default.
It removes the oldest runs when the directory exceeds that limit.
Set `PRIMER_LOG_MAX_BYTES` to change the limit.

## What It Does

Modules run in parallel as a DAG -- each starts as soon as its dependencies are met:

| Module | Depends On | What It Does |
| --- | --- | --- |
| **apt** | -- | Installs configured Debian/Ubuntu packages for VPS profiles |
| **agents-sudo** | -- | Installs the Linux `agents-sudo` command for shared 12-hour sudo sessions |
| **dnf** | -- | Installs Fedora packages in DNF5 batches and publishes live package results |
| **fedora-desktop-hardware** | dnf | Configures NVIDIA, `s2idle`, USB wake rules, sleep diagnostics, and the Xwayland Video Bridge workaround for Fedora KDE |
| **fedora-gaming** | fedora-desktop-hardware | Installs native Steam, controller rules, GameMode, MangoHud, Gamescope, and Vulkan tools |
| **flatpak** | apt / dnf | Installs explicitly configured Flatpak apps |
| **chatgpt** | apt / dnf | Installs the ChatGPT desktop app from OpenAI's native Linux package |
| **1password** | dnf | Installs 1Password and 1Password CLI from 1Password's official RPM repository |
| **google-chrome** | apt / dnf | Installs Google Chrome from Google's native Linux package |
| **github-cli** | apt | Installs GitHub CLI from GitHub's official apt repository |
| **npm-global** | mise | Installs configured global npm CLIs |
| **t3-code** | npm-global + Tailscale login | Runs T3 Code at boot and exposes it through Tailscale Serve |
| **managed-settings** | shell-installers/homebrew-apps | Applies configured JSON/TOML user settings, including AI CLI permission defaults |
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
| **agents** | homebrew / apt / dnf + github login | Initializes the `agents` CLI, private `agents-home` in ~/.agents, and private `chat-archive` in ~/.agents-archive, then runs `agents sync` |
| **mise** | homebrew | Installs language runtimes (Node, Python, Bun) |
| **ssh** | xcode-cli-tools | Creates an SSH key and configures macOS keychain-backed agent support |
| **touchid** | -- | Enables Touch ID for sudo |
| **git** | -- | Configures global Git CLI defaults and installs Git helper scripts to ~/bin/ |

### Fedora desktop hardware

The `fedora-desktop-hardware` module does nothing without NVIDIA hardware.
It does not enroll Secure Boot keys, update BIOS firmware, or restart the computer.
Its USB wake rules target AMD B550 controller `1022:43ee` and Logitech receiver `046d:c548`.

### Fedora gaming

The Fedora profile installs native Steam from RPM Fusion. It also installs
32-bit GameMode and MangoHud libraries for older games. Primer tests GameMode
and hardware Vulkan before it reports the gaming stack as ready. Primer adds
the desktop user to Fedora's `gamemode` group for privileged tuning.

Use Valve's Steam-provided Proton by default. Apply GameMode, MangoHud, or
Gamescope per game. Do not force these wrappers globally.

Example Steam launch options:

```text
gamemoderun %command%
mangohud gamemoderun %command%
```

Keep Proton game libraries on a native Linux filesystem. The Fedora profile
does not configure shared NTFS libraries, Steam accounts, or BIOS settings.

### 1Password

The Fedora profile installs the 1Password desktop app and CLI from 1Password's
official RPM repository. A later interactive step launches the app and waits
in the Primer pane until you sign in and enable **Settings > Developer >
Integrate with 1Password CLI**. GitHub CLI login and Tailscale login wait
until that step finishes. Those logins stay in the Primer pane. They do not
pause the terminal.

### T3 Code remote access

The Fedora profile installs T3 Code as a persistent systemd user service.
User lingering starts the service during boot, before the user logs in.
Tailscale Serve proxies HTTPS port 443 to the loopback T3 Code server.

Open the server from another device on the same tailnet:

```text
https://<machine>.<tailnet>.ts.net/
```

Create a pairing link when a new client needs access:

```sh
t3 pair --tailscale
```

## Architecture

Each module is a **self-contained folder** that owns its config files, scripts, and install logic. Profile config is split into `configs/common.conf` plus `configs/profiles/<profile>.conf`. Primer loads the common file first, then the profile file. A profile file holds only the keys that differ from the common file.

Each module process loads the current mise environment before it runs. A later
module can therefore find tools that an earlier module just installed with mise,
including global npm CLIs such as `t3`, without opening a new shell.

The compiled TypeScript app in `app/` is the sole command and scheduling engine. CI publishes native standalone executables for macOS and Linux on ARM64 and x64; Bun is a build-time dependency and is not required on managed machines. The launcher downloads and verifies the appropriate release binary. On a terminal it renders the OpenTUI sidebar; without a TTY, or with `--log`, the same engine emits plain line output. Zsh remains only at the module boundary: the TypeScript engine runs each `modules/*/module.zsh` with helpers from `lib/module.zsh`.

```
├── setup.sh                      # Bootstrap (installs the Primer launcher)
├── app/
│   └── src/
│       ├── index.tsx             # Sole command entry point + TTY/headless selection
│       ├── engine.ts             # Unified module and interactive-step DAG
│       └── ui.tsx                # OpenTUI sidebar, logs, and summary screens
├── configs/
│   ├── common.conf               # Shared user-level config
│   └── profiles/                 # mac, linux-vps, and fedora-kde fragments
├── lib/
│   └── module.zsh                # Shell module runtime and status protocol
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
│   ├── agents/
│   │   └── module.zsh            # agents CLI + private home and archive repos
│   ├── mise/
│   │   └── module.zsh            # Installs tools from config via mise use --global
│   ├── touchid/
│   │   └── module.zsh
│   └── git/
│       ├── module.zsh
│       └── bin/                   # git-clean, git-uncommit, etc.
└── bin/
    └── primer                     # Self-updating launcher; execs app/src/index.tsx
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
depends_on = homebrew  # optional module deps
depends_on_logins = github  # optional login deps
needs_sudo = true  # optional; ask for sudo before the run
```

Set `needs_sudo = true` when the module runs `sudo`. Primer then asks for the
password once, before it starts any module. Primer also sets this flag for you
when a config value of the module contains a `privileged: true` line, such as a
privileged entry in `installers`.

### Complex module (custom logic)

Write `mod_update()` and `mod_status()` with whatever logic you need. Use `mod_config <key>` to read values from the active profile config.

Use the item protocol for commands that manage many named objects:

```zsh
primer::items_init "${items[@]}"
primer::item_update "$item" running "installing"
primer::item_log "$item" "command output"
primer::item_update "$item" done "installed"
```

Primer shows these states and logs while the command runs.
The same item logs remain available after the run.

## Profiles

A profile is a config file in `configs/profiles/`. Primer accepts any profile
name that has a `configs/profiles/<name>.conf` file. Add a file to add a
profile. Primer ships three profiles.

Primer auto-detects the profile when it can:

- `mac` on macOS
- `linux-vps` on Debian/Ubuntu without a desktop session
- `fedora-kde` on Fedora

For other Linux systems, pass `--profile` or set `PRIMER_PROFILE`.

```sh
primer update --profile linux-vps
PRIMER_PROFILE=fedora-kde primer status
```

Linux profiles install Tailscale through its official Linux installer. The VPS profile uses GitHub's official APT repository for GitHub CLI. Fedora uses its `gh` package. The Fedora KDE profile enables the COPR repositories for Ghostty, keyd, Helium, and Sunshine. That profile also installs 1Password and 1Password CLI from 1Password's official RPM repository. GitHub CLI login and Tailscale login wait until the 1Password login finishes.

## Configuration

Module settings live in `configs/common.conf` and `configs/profiles/*.conf`. Each `[section]` activates a module. Remove a section from the selected profile/common config to disable it. Indented lines continue the previous key's value.

```ini
[homebrew]
label = Homebrew
depends_on = xcode-cli-tools
needs_sudo = true
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
needs_sudo = true
app_path = /Applications/Xcode.app
simulator_platforms =
    iOS

[git]
depends_on = xcode-cli-tools

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

Interactive logins are configured in `[logins]`. Logins that modules list in
`depends_on_logins` run as soon as their module deps finish, so later modules
can use the account. Other logins run after installation finishes.
`*_depends_on` names Primer modules that must complete first, `*_depends_on_logins`
names other logins that must complete first, `*_requires` names commands that
must exist, `*_status` detects whether the account is already logged in,
`*_command` starts the login flow. Interactive steps stay in the Primer pane
by default. Set `*_mode = terminal` to pause Primer and use the terminal.
Linux profiles also use this flow for Tailscale. After the Tailscale module
installs the client, Primer runs `sudo -n tailscale up --ssh` when the machine
is not connected and then `sudo -n tailscale set --operator="$USER" --ssh`.
That enables Tailscale SSH on the box and lets local tools such as T3 Code
configure Tailscale Serve without requiring sudo.

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
curl -fsSL https://raw.githubusercontent.com/tomagranate/primer/master/setup.sh | sh
```

Reset to a clean slate with `tart delete primer-test` and re-clone.
