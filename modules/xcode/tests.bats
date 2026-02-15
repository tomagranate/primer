#!/usr/bin/env bats
# modules/xcode/tests.bats

load '../../tests/helpers/common'

setup() {
    export MOCK_DIR="$PRIMER_DIR/tests/helpers/mocks"
    export MOCK_LOG="$(mktemp)"
    export PATH="$MOCK_DIR:$PATH"
}

teardown() {
    rm -f "$MOCK_LOG"
}

@test "xcode: reports already installed when xcode-select -p succeeds" {
    zsh_run_module xcode "mod_update"
    assert_success
}

@test "xcode: mod_status succeeds when installed" {
    zsh_run_module xcode "mod_status"
    assert_success
}

@test "xcode: mod_status fails when not installed" {
    export MOCK_XCODE_MISSING=1
    zsh_run_module xcode "mod_status"
    assert_failure
}
