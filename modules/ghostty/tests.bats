#!/usr/bin/env bats
# modules/ghostty/tests.bats

load '../../tests/helpers/common'

setup() {
    export TEST_HOME="$(mktemp -d)"
    export TEST_CONFIG_DIR="$TEST_HOME/.config"
}

teardown() {
    rm -rf "$TEST_HOME"
}

@test "ghostty: mod_status succeeds after deploy" {
    zsh_run_module ghostty "mod_update"
    assert_success
    zsh_run_module ghostty "mod_status"
    assert_success
}

@test "ghostty: mod_status fails when config missing" {
    zsh_run_module ghostty "mod_status"
    assert_failure
}

@test "ghostty: mod_status fails when config drifted" {
    zsh_run_module ghostty "mod_update"
    assert_success
    printf '\n# drift\n' >> "$TEST_CONFIG_DIR/ghostty/config"

    zsh_run_module ghostty "mod_status"
    assert_failure
}
