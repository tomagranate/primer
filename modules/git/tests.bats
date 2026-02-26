#!/usr/bin/env bats
# modules/git/tests.bats

load '../../tests/helpers/common'

setup() {
    export TEST_HOME="$(mktemp -d)"
    export TEST_BIN_DIR="$TEST_HOME/bin"
}

teardown() {
    rm -rf "$TEST_HOME"
}

@test "git: mod_status succeeds after deploy" {
    zsh_run_module git "mod_update"
    assert_success
    zsh_run_module git "mod_status"
    assert_success
}

@test "git: mod_status fails when script missing" {
    zsh_run_module git "mod_status"
    assert_failure
}

@test "git: mod_status fails when deployed script drifted" {
    zsh_run_module git "mod_update"
    assert_success
    printf '\n# drift\n' >> "$TEST_BIN_DIR/git-clean"

    zsh_run_module git "mod_status"
    assert_failure
}
