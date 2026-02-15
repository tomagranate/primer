#!/usr/bin/env bats
# modules/starship/tests.bats

load '../../tests/helpers/common'

setup() {
    export TEST_HOME="$(mktemp -d)"
    export TEST_CONFIG_DIR="$TEST_HOME/.config"
}

teardown() {
    rm -rf "$TEST_HOME"
}

@test "starship: deploys starship.toml to config dir" {
    zsh_run_module starship "mod_update"
    assert_success
    [ -f "$TEST_CONFIG_DIR/starship.toml" ]
}

@test "starship: deployed file matches source" {
    zsh_run_module starship "mod_update"
    diff "$PRIMER_DIR/modules/starship/files/starship.toml" "$TEST_CONFIG_DIR/starship.toml"
}

@test "starship: mod_status succeeds after deploy" {
    zsh_run_module starship "mod_update"
    zsh_run_module starship "mod_status"
    assert_success
}

@test "starship: mod_status fails when file missing" {
    zsh_run_module starship "mod_status"
    assert_failure
}

@test "starship: dry-run does not create files" {
    export DRY_RUN=true
    zsh_run_module starship "mod_update"
    assert_success
    [ ! -f "$TEST_CONFIG_DIR/starship.toml" ]
}
