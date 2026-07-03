#!/usr/bin/env bats
# modules/git/tests.bats

load '../../tests/helpers/common'

setup() {
    export TEST_HOME="$(mktemp -d)"
    export TEST_BIN_DIR="$TEST_HOME/bin"
    export GIT_CONFIG_GLOBAL="$TEST_HOME/.gitconfig"
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

@test "git: mod_update writes configured global settings" {
    zsh_run_module git "mod_update"
    assert_success

    run git config --global --get user.name
    assert_success
    assert_output "Tom Grant"

    run git config --global --get user.email
    assert_success
    assert_output "tom@sunburst.io"

    run git config --global --get pull.rebase
    assert_success
    assert_output "false"

    run git config --global --get user.useConfigOnly
    assert_success
    assert_output "true"

    run git config --global --get init.defaultBranch
    assert_success
    assert_output "master"

    run git config --global --get push.autoSetupRemote
    assert_success
    assert_output "true"
}

@test "git: mod_status fails when global setting drifted" {
    zsh_run_module git "mod_update"
    assert_success
    git config --global pull.rebase true

    zsh_run_module git "mod_status"
    assert_failure
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
