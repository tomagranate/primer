#!/bin/sh
# primer -- https://github.com/tomagranate/primer
#
# Bootstrap: installs the primer CLI, then runs `primer update`.
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/tomagranate/primer/main/setup.sh | sh
#   curl -fsSL https://raw.githubusercontent.com/tomagranate/primer/main/setup.sh | sh -s -- --dry-run
set -e

REPO_RAW="https://raw.githubusercontent.com/tomagranate/primer/main"
BIN_DIR="$HOME/bin"

run_as_root() {
    if [ "$(id -u)" -eq 0 ]; then
        "$@"
    elif command -v sudo >/dev/null 2>&1; then
        sudo "$@"
    else
        printf "sudo is required to install zsh on this system\n" >&2
        return 1
    fi
}

ensure_zsh() {
    if command -v zsh >/dev/null 2>&1; then
        return 0
    fi

    case "$(uname -s 2>/dev/null || printf unknown)" in
        Darwin)
            printf "zsh is required but was not found\n" >&2
            return 1
            ;;
        Linux)
            if command -v apt-get >/dev/null 2>&1; then
                printf "\033[1;34m==>\033[0m Installing zsh with apt\n"
                run_as_root apt-get update
                run_as_root env DEBIAN_FRONTEND=noninteractive apt-get install -y zsh curl tar
                return 0
            fi
            printf "zsh is required and no supported package manager was found\n" >&2
            return 1
            ;;
        *)
            printf "zsh is required on this system\n" >&2
            return 1
            ;;
    esac
}

# ── Install primer CLI ────────────────────────────────────────────────────────

printf "\033[1;34m==>\033[0m Installing primer CLI to %s\n" "$BIN_DIR"
mkdir -p "$BIN_DIR"
curl -fsSL "$REPO_RAW/bin/primer" -o "$BIN_DIR/primer"
chmod +x "$BIN_DIR/primer"
printf "\033[1;32m  ✓\033[0m primer installed\n"

# ── Ensure ~/bin is on PATH ──────────────────────────────────────────────────

case ":$PATH:" in
    *":$BIN_DIR:"*) ;;
    *) export PATH="$BIN_DIR:$PATH" ;;
esac

# ── Run primer update ─────────────────────────────────────────────────────────

ensure_zsh
exec "$(command -v zsh)" "$BIN_DIR/primer" update "$@"
