#!/usr/bin/env bats
# modules/homebrew/tests.bats

load '../../tests/helpers/common'

setup() {
    export TEST_HOME="$(mktemp -d)"
    export TEST_CONFIG_DIR="$TEST_HOME/.config"
    export MOCK_DIR="$PRIMER_DIR/tests/helpers/mocks"
    export MOCK_LOG="$(mktemp)"
    export TEST_CONF="$(mktemp)"
    export MOD_ITEMS_FILE="$(mktemp)"
    export PATH="$MOCK_DIR:$PATH"

    cat > "$TEST_CONF" <<'EOF'
[homebrew]
taps =
    owner/tap
formulae =
    alpha
    bravo
EOF
}

teardown() {
    rm -rf "$TEST_HOME" "$MOCK_LOG" "$TEST_CONF" "$MOD_ITEMS_FILE"
}

run_homebrew_with_conf() {
    local action="$1"
    run zsh -c "
        export PRIMER_DIR='${PRIMER_DIR}'
        export DRY_RUN='${DRY_RUN:-false}'
        export MOD_DIR='${PRIMER_DIR}/modules/homebrew'
        export MOD_NAME='homebrew'
        export MOD_STATUS_FILE='${TEST_HOME}/mod-status'
        export MOD_ITEMS_FILE='${MOD_ITEMS_FILE}'
        export CONFIG_DIR='${TEST_CONFIG_DIR:-/tmp/primer-test-config}'
        export ZSH_CONFIG_DIR='${TEST_CONFIG_DIR:-/tmp/primer-test-config}/zsh'
        export BIN_DIR='${TEST_BIN_DIR:-/tmp/primer-test-bin}'
        export HOME='${TEST_HOME:-$HOME}'
        source \"\$PRIMER_DIR/lib/ui.zsh\"
        source \"\$PRIMER_DIR/lib/engine.zsh\"
        engine::load_config '${TEST_CONF}'
        source \"\$MOD_DIR/module.zsh\"
        ${action}
    "
}

# ── dry-run ───────────────────────────────────────────────────────────────────

@test "homebrew: calls brew update before installing" {
    export DRY_RUN=true
    run_homebrew_with_conf "mod_update"
    assert_success
    assert_output --partial 'brew update'
}

@test "homebrew: dry-run installs formulae individually" {
    export DRY_RUN=true
    run_homebrew_with_conf "mod_update"
    assert_success
    assert_output --partial 'brew install alpha'
    assert_output --partial 'brew install bravo'
}

@test "homebrew: dry-run taps repos individually" {
    export DRY_RUN=true
    run_homebrew_with_conf "mod_update"
    assert_success
    assert_output --partial 'brew tap owner/tap'
}

@test "homebrew: dry-run does not use brew bundle" {
    export DRY_RUN=true
    run_homebrew_with_conf "mod_update"
    assert_success
    refute_output --partial 'brew bundle'
}

# ── wet run: not installed (default mock state) ───────────────────────────────

@test "homebrew: wet run calls brew install for each formula" {
    run_homebrew_with_conf "mod_update"
    assert_success
    run grep "brew install alpha" "$MOCK_LOG"
    assert_success
    run grep "brew install bravo" "$MOCK_LOG"
    assert_success
}

@test "homebrew: wet run calls brew tap for each tap" {
    run_homebrew_with_conf "mod_update"
    assert_success
    run grep "brew tap owner/tap" "$MOCK_LOG"
    assert_success
}

@test "homebrew: items file contains all packages as done after wet run" {
    run_homebrew_with_conf "mod_update"
    assert_success
    run grep "done:alpha" "$MOD_ITEMS_FILE"
    assert_success
    run grep "done:bravo" "$MOD_ITEMS_FILE"
    assert_success
    run grep "done:owner/tap" "$MOD_ITEMS_FILE"
    assert_success
}

# ── wet run: already installed and outdated → upgrade ─────────────────────────

@test "homebrew: wet run upgrades formula when installed and outdated" {
    export MOCK_BREW_INSTALLED_FORMULAE="alpha bravo"
    export MOCK_BREW_OUTDATED_FORMULAE="alpha"
    run_homebrew_with_conf "mod_update"
    assert_success
    run grep "brew upgrade alpha" "$MOCK_LOG"
    assert_success
}

@test "homebrew: wet run does not reinstall formula when upgrading" {
    export MOCK_BREW_INSTALLED_FORMULAE="alpha bravo"
    export MOCK_BREW_OUTDATED_FORMULAE="alpha"
    run_homebrew_with_conf "mod_update"
    assert_success
    run grep "brew install alpha" "$MOCK_LOG"
    assert_failure
}

# ── wet run: already installed and up to date → skip ─────────────────────────

@test "homebrew: wet run skips formula when already up to date" {
    export MOCK_BREW_INSTALLED_FORMULAE="alpha bravo"
    run_homebrew_with_conf "mod_update"
    assert_success
    run grep -E "brew (install|upgrade) alpha" "$MOCK_LOG"
    assert_failure
    run grep -E "brew (install|upgrade) bravo" "$MOCK_LOG"
    assert_failure
}

@test "homebrew: items file marks up-to-date formulae as done" {
    export MOCK_BREW_INSTALLED_FORMULAE="alpha bravo"
    run_homebrew_with_conf "mod_update"
    assert_success
    run grep "done:alpha" "$MOD_ITEMS_FILE"
    assert_success
    run grep "done:bravo" "$MOD_ITEMS_FILE"
    assert_success
}

@test "homebrew: wet run skips tap when already tapped" {
    export MOCK_BREW_INSTALLED_TAPS="owner/tap"
    run_homebrew_with_conf "mod_update"
    assert_success
    run grep "brew tap owner/tap" "$MOCK_LOG"
    assert_failure
}

# ── failure propagation ───────────────────────────────────────────────────────

@test "homebrew: mod_update fails when a formula install fails" {
    export MOCK_BREW_FAIL_PACKAGES="alpha"
    run_homebrew_with_conf "mod_update"
    assert_failure
}

@test "homebrew: items file marks failed formula as failed" {
    export MOCK_BREW_FAIL_PACKAGES="alpha"
    run_homebrew_with_conf "mod_update"
    assert_failure
    run grep "failed:alpha" "$MOD_ITEMS_FILE"
    assert_success
}

@test "homebrew: mod_update fails when a formula upgrade fails" {
    export MOCK_BREW_INSTALLED_FORMULAE="alpha"
    export MOCK_BREW_OUTDATED_FORMULAE="alpha"
    export MOCK_BREW_FAIL_PACKAGES="alpha"
    run_homebrew_with_conf "mod_update"
    assert_failure
    run grep "failed:alpha" "$MOD_ITEMS_FILE"
    assert_success
}

# ── status ────────────────────────────────────────────────────────────────────

@test "homebrew: mod_status succeeds when configured packages are up to date" {
    export MOCK_BREW_INSTALLED_TAPS="owner/tap"
    export MOCK_BREW_INSTALLED_FORMULAE="alpha bravo"
    run_homebrew_with_conf "mod_status"
    assert_success
    run grep "up to date" "$TEST_HOME/mod-status"
    assert_success
}

@test "homebrew: mod_status fails with counts when packages are missing or outdated" {
    export MOCK_BREW_INSTALLED_TAPS="owner/tap"
    export MOCK_BREW_INSTALLED_FORMULAE="alpha"
    export MOCK_BREW_OUTDATED_FORMULAE="alpha"
    run_homebrew_with_conf "mod_status"
    assert_failure
    run grep "1 missing" "$TEST_HOME/mod-status"
    assert_success
    run grep "1 outdated" "$TEST_HOME/mod-status"
    assert_success
}
