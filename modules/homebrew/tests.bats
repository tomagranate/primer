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

@test "homebrew: mod_status uses mock brew --version" {
    run_homebrew_with_conf "mod_status"
    assert_success
}
