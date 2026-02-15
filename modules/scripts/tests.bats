#!/usr/bin/env bats
# modules/scripts/tests.bats

load '../../tests/helpers/common'

setup() {
    export TEST_HOME="$(mktemp -d)"
    export TEST_BIN_DIR="$TEST_HOME/bin"
}

teardown() {
    rm -rf "$TEST_HOME"
}

@test "scripts: deploys rgf to bin dir" {
    zsh_run_module scripts "mod_update"
    assert_success
    [ -f "$TEST_BIN_DIR/rgf" ]
}

@test "scripts: rgf is executable" {
    zsh_run_module scripts "mod_update"
    [ -x "$TEST_BIN_DIR/rgf" ]
}

@test "scripts: mod_status reports all installed after deploy" {
    zsh_run_module scripts "mod_update"
    zsh_run_module scripts "mod_status"
    assert_success
}

@test "scripts: mod_status fails when scripts missing" {
    zsh_run_module scripts "mod_status"
    assert_failure
}

@test "scripts: dry-run does not deploy" {
    export DRY_RUN=true
    zsh_run_module scripts "mod_update"
    assert_success
    [ ! -f "$TEST_BIN_DIR/rgf" ]
}
