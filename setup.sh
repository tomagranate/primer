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

exec /bin/zsh "$BIN_DIR/primer" update "$@"
