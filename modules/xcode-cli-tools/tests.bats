#!/usr/bin/env bats
# modules/xcode-cli-tools/tests.bats

load '../../tests/helpers/common'

setup() {
    export TEST_HOME="$(mktemp -d)"
    export MOCK_LOG="$(mktemp)"
    export MOCK_XCODE_INSTALL_MARKER="$TEST_HOME/xcode-installed"
    export PATH="$PRIMER_DIR/tests/helpers/mocks:$PATH"
}

teardown() {
    rm -rf "$TEST_HOME" "$MOCK_LOG"
}

@test "xcode-cli-tools: status succeeds when installed" {
    zsh_run_module xcode-cli-tools "mod_status"
    assert_success
}

@test "xcode-cli-tools: status fails when missing" {
    export MOCK_XCODE_MISSING=1
    zsh_run_module xcode-cli-tools "mod_status"
    assert_failure
}

@test "xcode-cli-tools: dry-run requests install without waiting" {
    export DRY_RUN=true
    export MOCK_XCODE_MISSING=1
    zsh_run_module xcode-cli-tools "mod_update"
    assert_success
    assert_output --partial "[dry-run] xcode-select --install"
}

@test "xcode-cli-tools: update opens installer and waits for acceptance" {
    export MOCK_XCODE_MISSING=1
    zsh_run_module xcode-cli-tools "mod_update"
    assert_success
    run grep "xcode-select --install" "$MOCK_LOG"
    assert_success
}
