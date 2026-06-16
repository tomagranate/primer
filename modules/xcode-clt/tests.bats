#!/usr/bin/env bats
# modules/xcode-clt/tests.bats

load '../../tests/helpers/common'

setup() {
    export TEST_HOME="$(mktemp -d)"
    export MOCK_DIR="$TEST_HOME/mocks"
    mkdir -p "$MOCK_DIR"
    export MOCK_LOG="$(mktemp)"
    export PATH="$PRIMER_DIR/tests/helpers/mocks:$PATH"
}

teardown() {
    rm -rf "$TEST_HOME" "$MOCK_LOG"
}

@test "xcode-clt: mod_status succeeds when command line tools are selected" {
    zsh_run_module xcode-clt "mod_status; cat \"\$MOD_STATUS_FILE\""
    assert_success
    assert_output --partial "installed"
}

@test "xcode-clt: mod_update installs command line tools when missing" {
    export MOCK_XCODE_MISSING=1
    export DRY_RUN=true
    zsh_run_module xcode-clt "mod_update"
    assert_success
    assert_output --partial "[dry-run] xcode-select --install"
}

@test "xcode-clt: mod_status fails when command line tools are missing" {
    export MOCK_XCODE_MISSING=1
    zsh_run_module xcode-clt "mod_status; rc=\$?; cat \"\$MOD_STATUS_FILE\"; exit \$rc"
    assert_failure
    assert_output --partial "missing"
}
