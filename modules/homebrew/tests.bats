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

@test "homebrew: dry-run trusts taps before packages install" {
    export DRY_RUN=true
    run_homebrew_with_conf "mod_update"
    assert_success
    assert_output --partial 'brew trust owner/tap'
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

@test "homebrew: installs formulae with default parallelism capped at 3" {
    cat > "$TEST_CONF" <<'EOF'
[homebrew]
formulae =
    alpha
    bravo
    charlie
    delta
EOF
    export MOCK_BREW_CONCURRENCY_FILE="$TEST_HOME/brew-concurrency"
    export MOCK_BREW_SLEEP=0.15
    run_homebrew_with_conf "mod_update"
    assert_success
    run cat "${MOCK_BREW_CONCURRENCY_FILE}.max"
    assert_success
    [[ "$output" -eq 3 ]] || {
        echo "Expected default brew formula concurrency of 3, max concurrency was $output"; false
    }
}

@test "homebrew: retries transient formula cellar lock errors" {
    export MOCK_BREW_LOCK_ONCE_PACKAGES="alpha"
    export MOCK_BREW_LOCK_STATE_DIR="$TEST_HOME/locks"
    export PRIMER_HOMEBREW_LOCK_RETRY_DELAY=0.01
    run_homebrew_with_conf "mod_update"
    assert_success
    run grep "done:alpha" "$MOD_ITEMS_FILE"
    assert_success
}

@test "homebrew: retries formula install after transient untrusted tap warning" {
    export MOCK_BREW_UNTRUSTED_ONCE_PACKAGES="alpha"
    export MOCK_BREW_LOCK_STATE_DIR="$TEST_HOME/trust"
    run_homebrew_with_conf "mod_update"
    assert_success
    run grep "done:alpha" "$MOD_ITEMS_FILE"
    assert_success
    run grep -c "brew trust owner/tap" "$MOCK_LOG"
    assert_success
    [[ "$output" -ge 2 ]] || {
        echo "Expected tap to be trusted before install and again before retry"; false
    }
}

@test "homebrew: wet run calls brew tap for each tap" {
    run_homebrew_with_conf "mod_update"
    assert_success
    run grep "brew tap owner/tap" "$MOCK_LOG"
    assert_success
}

@test "homebrew: wet run trusts each tap" {
    run_homebrew_with_conf "mod_update"
    assert_success
    run grep "brew trust owner/tap" "$MOCK_LOG"
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

@test "homebrew: wet run still trusts tap when already tapped" {
    export MOCK_BREW_INSTALLED_TAPS="owner/tap"
    run_homebrew_with_conf "mod_update"
    assert_success
    run grep "brew trust owner/tap" "$MOCK_LOG"
    assert_success
}

# ── failure propagation ───────────────────────────────────────────────────────

@test "homebrew: mod_update fails when a formula install fails" {
    export MOCK_BREW_FAIL_PACKAGES="alpha"
    run_homebrew_with_conf "mod_update"
    assert_failure
}

@test "homebrew: failure output focuses on failed formula, not successful setup chatter" {
    export MOCK_BREW_VERBOSE_SETUP=1
    export MOCK_BREW_FAIL_PACKAGES="alpha"
    export MOCK_BREW_FAIL_OUTPUT="Error: dashlane-cli failed during install"
    run_homebrew_with_conf "mod_update"
    assert_failure
    assert_output --partial "Error while running: brew install alpha"
    assert_output --partial "Error: dashlane-cli failed during install"
    [[ "$output" != *"==> Updating Homebrew..."* ]] || {
        echo "Did not expect successful brew update output in failure log: $output"; false
    }
    [[ "$output" != *"Tapped noisy formulae"* ]] || {
        echo "Did not expect successful brew tap output in failure log: $output"; false
    }
    [[ "$output" != *"Trusted tap: owner/tap"* ]] || {
        echo "Did not expect successful brew trust output in failure log: $output"; false
    }
}

@test "homebrew: nonzero formula install is accepted when formula is installed afterward" {
    export MOCK_BREW_STATE_DIR="$TEST_HOME/brew-state"
    export MOCK_BREW_FAIL_AFTER_INSTALL_PACKAGES="alpha"
    export MOCK_BREW_FAIL_OUTPUT="Warning: brew reported failure after installing alpha"
    run_homebrew_with_conf "mod_update"
    assert_success
    run grep "done:alpha" "$MOD_ITEMS_FILE"
    assert_success
    refute_output --partial "Warning: brew reported failure after installing alpha"
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
