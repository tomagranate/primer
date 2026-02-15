#!/usr/bin/env bats
# modules/zim/tests.bats

load '../../tests/helpers/common'

setup() {
    export TEST_HOME="$(mktemp -d)"
    export TEST_CONFIG_DIR="$TEST_HOME/.config"
    export MOCK_DIR="$PRIMER_DIR/tests/helpers/mocks"
    export MOCK_LOG="$(mktemp)"
    export PATH="$MOCK_DIR:$PATH"
}

teardown() {
    rm -rf "$TEST_HOME" "$MOCK_LOG"
}

@test "zim: dry-run does not crash" {
    export DRY_RUN=true
    zsh_run_module zim "mod_update"
    assert_success
}

@test "zim: dry-run prints deploy message" {
    export DRY_RUN=true
    zsh_run_module zim "mod_update"
    assert_output --partial "dry-run"
}

@test "zim: deploys config files to ZSH_CONFIG_DIR" {
    # Use dry-run for the Zim install part but test deploy_files separately
    # We can't test the full wet path without real Zim, but we CAN test file deployment
    zsh_run_module zim '
        deploy_files "$ZSH_CONFIG_DIR"
    '
    assert_success
    [ -f "$TEST_CONFIG_DIR/zsh/.zshrc" ]
    [ -f "$TEST_CONFIG_DIR/zsh/.zshenv" ]
    [ -f "$TEST_CONFIG_DIR/zsh/.zimrc" ]
}

@test "zim: deployed .zshenv sets ZDOTDIR" {
    zsh_run_module zim '
        deploy_files "$ZSH_CONFIG_DIR"
    '
    run grep "ZDOTDIR" "$TEST_CONFIG_DIR/zsh/.zshenv"
    assert_success
}

@test "zim: mod_status reports not installed when Zim is missing" {
    zsh_run_module zim "mod_status"
    assert_failure
}
