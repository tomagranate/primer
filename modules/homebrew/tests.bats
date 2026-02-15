#!/usr/bin/env bats
# modules/homebrew/tests.bats

load '../../tests/helpers/common'

setup() {
    export TEST_HOME="$(mktemp -d)"
    export TEST_CONFIG_DIR="$TEST_HOME/.config"
    export MOCK_DIR="$PRIMER_DIR/tests/helpers/mocks"
    export MOCK_LOG="$(mktemp)"
    export TEST_CONF="$(mktemp)"
    export PATH="$MOCK_DIR:$PATH"

    cat > "$TEST_CONF" <<'EOF'
[homebrew]
taps =
    owner/tap
formulae =
    alpha
    bravo
casks =
    fake-app
mas =
    FakeApp:123456789
EOF
}

teardown() {
    rm -rf "$TEST_HOME" "$MOCK_LOG" "$TEST_CONF"
}

run_homebrew_with_conf() {
    local action="$1"
    run zsh -c "
        export PRIMER_DIR='${PRIMER_DIR}'
        export DRY_RUN='${DRY_RUN:-false}'
        export SKIP_APP_STORE='${SKIP_APP_STORE:-false}'
        export MOD_DIR='${PRIMER_DIR}/modules/homebrew'
        export MOD_NAME='homebrew'
        export MOD_STATUS_FILE='${TEST_HOME}/mod-status'
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

@test "homebrew: dry-run generates Brewfile with formulae" {
    export DRY_RUN=true
    run_homebrew_with_conf "mod_update"
    assert_success
    assert_output --partial 'brew "alpha"'
    assert_output --partial 'brew "bravo"'
}

@test "homebrew: dry-run generates Brewfile with taps" {
    export DRY_RUN=true
    run_homebrew_with_conf "mod_update"
    assert_success
    assert_output --partial 'tap "owner/tap"'
}

@test "homebrew: dry-run generates Brewfile with casks" {
    export DRY_RUN=true
    run_homebrew_with_conf "mod_update"
    assert_success
    assert_output --partial 'cask "fake-app"'
}

@test "homebrew: dry-run generates Brewfile with mas entries" {
    export DRY_RUN=true
    run_homebrew_with_conf "mod_update"
    assert_success
    assert_output --partial 'mas "FakeApp", id: 123456789'
}

@test "homebrew: dry-run skips mas entries when skip flag set" {
    export DRY_RUN=true
    export SKIP_APP_STORE=true
    run_homebrew_with_conf "mod_update"
    assert_success
    refute_output --partial 'mas "FakeApp", id: 123456789'
}

@test "homebrew: wet run calls brew bundle" {
    run_homebrew_with_conf "mod_update"
    assert_success
    run grep "brew bundle" "$MOCK_LOG"
    assert_success
}

@test "homebrew: mod_status uses mock brew --version" {
    run_homebrew_with_conf "mod_status"
    assert_success
}
