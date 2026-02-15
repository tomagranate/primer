#!/usr/bin/env bats
# modules/mise/tests.bats

load '../../tests/helpers/common'

setup() {
    export TEST_HOME="$(mktemp -d)"
    export MOCK_DIR="$PRIMER_DIR/tests/helpers/mocks"
    export MOCK_LOG="$(mktemp)"
    export PATH="$MOCK_DIR:$PATH"
}

teardown() {
    rm -rf "$TEST_HOME" "$MOCK_LOG"
}

@test "mise: dry-run prints mise use for each tool" {
    export DRY_RUN=true
    zsh_run_module mise "mod_update"
    assert_success
    assert_output --partial "mise use --global node@lts"
    assert_output --partial "mise use --global python@3.12"
    assert_output --partial "mise use --global bun@latest"
}

@test "mise: wet run calls mise use for each tool" {
    zsh_run_module mise "mod_update"
    assert_success
    run grep "mise use" "$MOCK_LOG"
    assert_success
}

@test "mise: mod_status succeeds with mock mise" {
    zsh_run_module mise "mod_status"
    assert_success
}
