#!/usr/bin/env bats
# modules/homebrew-apps/tests.bats

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
[homebrew-apps]
casks =
    fake-app
    another-app
EOF
}

teardown() {
    rm -rf "$TEST_HOME" "$MOCK_LOG" "$TEST_CONF" "$MOD_ITEMS_FILE"
}

run_homebrew_apps_with_conf() {
    local action="$1"
    run zsh -c "
        export PRIMER_DIR='${PRIMER_DIR}'
        export DRY_RUN='${DRY_RUN:-false}'
        export MOD_DIR='${PRIMER_DIR}/modules/homebrew-apps'
        export MOD_NAME='homebrew-apps'
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

@test "homebrew-apps: dry-run installs each cask individually" {
    export DRY_RUN=true
    run_homebrew_apps_with_conf "mod_update"
    assert_success
    assert_output --partial 'brew install --cask fake-app'
    assert_output --partial 'brew install --cask another-app'
}

@test "homebrew-apps: dry-run does not use brew bundle" {
    export DRY_RUN=true
    run_homebrew_apps_with_conf "mod_update"
    assert_success
    refute_output --partial 'brew bundle'
}

# ── wet run: not installed (default mock state) ───────────────────────────────

@test "homebrew-apps: wet run calls brew install --cask for each app" {
    run_homebrew_apps_with_conf "mod_update"
    assert_success
    run grep "brew install --cask fake-app" "$MOCK_LOG"
    assert_success
    run grep "brew install --cask another-app" "$MOCK_LOG"
    assert_success
}

@test "homebrew-apps: items file contains all casks as done after wet run" {
    run_homebrew_apps_with_conf "mod_update"
    assert_success
    run grep "done:fake-app" "$MOD_ITEMS_FILE"
    assert_success
    run grep "done:another-app" "$MOD_ITEMS_FILE"
    assert_success
}

# ── wet run: already installed and outdated → upgrade ─────────────────────────

@test "homebrew-apps: wet run upgrades cask when installed and outdated" {
    export MOCK_BREW_INSTALLED_CASKS="fake-app another-app"
    export MOCK_BREW_OUTDATED_CASKS="fake-app"
    run_homebrew_apps_with_conf "mod_update"
    assert_success
    run grep "brew upgrade --cask fake-app" "$MOCK_LOG"
    assert_success
}

@test "homebrew-apps: wet run does not reinstall cask when upgrading" {
    export MOCK_BREW_INSTALLED_CASKS="fake-app another-app"
    export MOCK_BREW_OUTDATED_CASKS="fake-app"
    run_homebrew_apps_with_conf "mod_update"
    assert_success
    run grep "brew install --cask fake-app" "$MOCK_LOG"
    assert_failure
}

# ── wet run: already installed and up to date → skip ─────────────────────────

@test "homebrew-apps: wet run skips cask when already up to date" {
    export MOCK_BREW_INSTALLED_CASKS="fake-app another-app"
    run_homebrew_apps_with_conf "mod_update"
    assert_success
    run grep -E "brew (install|upgrade) .* fake-app" "$MOCK_LOG"
    assert_failure
    run grep -E "brew (install|upgrade) .* another-app" "$MOCK_LOG"
    assert_failure
}

@test "homebrew-apps: items file marks up-to-date casks as done" {
    export MOCK_BREW_INSTALLED_CASKS="fake-app another-app"
    run_homebrew_apps_with_conf "mod_update"
    assert_success
    run grep "done:fake-app" "$MOD_ITEMS_FILE"
    assert_success
    run grep "done:another-app" "$MOD_ITEMS_FILE"
    assert_success
}

# ── failure propagation ───────────────────────────────────────────────────────

@test "homebrew-apps: mod_update fails when a cask install fails" {
    export MOCK_BREW_FAIL_PACKAGES="fake-app"
    run_homebrew_apps_with_conf "mod_update"
    assert_failure
}

@test "homebrew-apps: items file marks failed cask as failed" {
    export MOCK_BREW_FAIL_PACKAGES="fake-app"
    run_homebrew_apps_with_conf "mod_update"
    assert_failure
    run grep "failed:fake-app" "$MOD_ITEMS_FILE"
    assert_success
}

@test "homebrew-apps: mod_update fails when a cask upgrade fails" {
    export MOCK_BREW_INSTALLED_CASKS="fake-app"
    export MOCK_BREW_OUTDATED_CASKS="fake-app"
    export MOCK_BREW_FAIL_PACKAGES="fake-app"
    run_homebrew_apps_with_conf "mod_update"
    assert_failure
    run grep "failed:fake-app" "$MOD_ITEMS_FILE"
    assert_success
}

# ── status ────────────────────────────────────────────────────────────────────

@test "homebrew-apps: mod_status succeeds with mock brew" {
    run_homebrew_apps_with_conf "mod_status"
    assert_success
}
