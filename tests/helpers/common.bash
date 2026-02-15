#!/usr/bin/env bash
# tests/helpers/common.bash -- shared BATS setup for primer tests
#
# Usage: load this from any .bats file (unit or module):
#   load '../../tests/helpers/common'   # from modules/<name>/tests.bats
#   load '../helpers/common'            # from tests/unit/*.bats

# ── Resolve PRIMER_DIR to repo root ──────────────────────────────────────────

export PRIMER_DIR
PRIMER_DIR="$(cd "${BATS_TEST_DIRNAME}" && git rev-parse --show-toplevel)"

# ── Load bats-support and bats-assert ────────────────────────────────────────

load "${PRIMER_DIR}/tests/helpers/bats-support/load"
load "${PRIMER_DIR}/tests/helpers/bats-assert/load"

# ── Helpers ──────────────────────────────────────────────────────────────────

# Run a zsh snippet with engine + ui sourced.
# The snippet is passed as the first argument.
zsh_run() {
    run zsh -c "
        export PRIMER_DIR='${PRIMER_DIR}'
        export DRY_RUN='${DRY_RUN:-false}'
        source \"\$PRIMER_DIR/lib/ui.zsh\"
        source \"\$PRIMER_DIR/lib/engine.zsh\"
        $1
    "
}

# Run a zsh snippet inside a module context.
# First arg is the module name, second is the zsh code to execute.
# Expects TEST_HOME / TEST_CONFIG_DIR / TEST_BIN_DIR to be set by the caller.
zsh_run_module() {
    local mod="$1"; shift
    local status_file
    status_file="$(mktemp)"

    run zsh -c "
        export PRIMER_DIR='${PRIMER_DIR}'
        export DRY_RUN='${DRY_RUN:-false}'
        export MOD_DIR='${PRIMER_DIR}/modules/${mod}'
        export MOD_NAME='${mod}'
        export MOD_STATUS_FILE='${status_file}'
        export CONFIG_DIR='${TEST_CONFIG_DIR:-/tmp/primer-test-config}'
        export ZSH_CONFIG_DIR='${TEST_CONFIG_DIR:-/tmp/primer-test-config}/zsh'
        export BIN_DIR='${TEST_BIN_DIR:-/tmp/primer-test-bin}'
        export HOME='${TEST_HOME:-$HOME}'
        source \"\$PRIMER_DIR/lib/ui.zsh\"
        source \"\$PRIMER_DIR/lib/engine.zsh\"
        engine::load_config \"\$PRIMER_DIR/primer.conf\"
        source \"\$MOD_DIR/module.zsh\"
        $1
    "
}
