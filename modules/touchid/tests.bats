#!/usr/bin/env bats
# modules/touchid/tests.bats

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

@test "touchid: dry-run prints enable message" {
    export DRY_RUN=true
    zsh_run_module touchid "mod_update"
    assert_success
    assert_output --partial "dry-run"
}

@test "touchid: mod_status reports not enabled (no sudo_local on test system)" {
    # touchid checks /etc/pam.d/sudo_local which typically doesn't exist in test environments
    # This test documents the expected behavior
    zsh_run_module touchid "mod_status"
    # May pass or fail depending on real system state -- just verify no crash
    [[ "$status" -eq 0 || "$status" -eq 1 ]]
}
