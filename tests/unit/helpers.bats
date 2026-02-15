#!/usr/bin/env bats
# tests/unit/helpers.bats -- tests for deploy_files, check_files, deploy_scripts, mod_config

load '../helpers/common'

setup() {
    export TEST_HOME="$(mktemp -d)"
    export TEST_CONFIG_DIR="$TEST_HOME/.config"
    export TEST_BIN_DIR="$TEST_HOME/bin"
}

teardown() {
    rm -rf "$TEST_HOME"
}

# ── deploy_files ─────────────────────────────────────────────────────────────

@test "deploy_files: copies files preserving structure" {
    zsh_run_module starship "mod_update"
    assert_success
    [ -f "$TEST_CONFIG_DIR/starship.toml" ]
}

@test "deploy_files: dry-run does not copy files" {
    export DRY_RUN=true
    zsh_run_module starship "mod_update"
    assert_success
    [ ! -f "$TEST_CONFIG_DIR/starship.toml" ]
}

@test "deploy_files: dry-run prints message" {
    export DRY_RUN=true
    zsh_run_module starship "mod_update"
    assert_success
    assert_output --partial "dry-run"
}

# ── check_files ──────────────────────────────────────────────────────────────

@test "check_files: returns 0 when all files present" {
    # Deploy first, then check
    zsh_run_module starship "mod_update"
    assert_success
    zsh_run_module starship "mod_status"
    assert_success
}

@test "check_files: returns 1 when files missing" {
    # Don't deploy, just check
    zsh_run_module starship "mod_status"
    assert_failure
}

# ── deploy_scripts ───────────────────────────────────────────────────────────

@test "deploy_scripts: copies scripts and makes executable" {
    zsh_run_module scripts "mod_update"
    assert_success
    [ -x "$TEST_BIN_DIR/rgf" ]
}

@test "deploy_scripts: dry-run does not copy scripts" {
    export DRY_RUN=true
    zsh_run_module scripts "mod_update"
    assert_success
    [ ! -f "$TEST_BIN_DIR/rgf" ]
}

@test "deploy_scripts: dry-run prints message" {
    export DRY_RUN=true
    zsh_run_module scripts "mod_update"
    assert_success
    assert_output --partial "dry-run"
}

# ── mod_config ───────────────────────────────────────────────────────────────

@test "mod_config: reads single-line value" {
    zsh_run_module homebrew '
        result=$(mod_config depends_on)
        echo "$result"
    '
    assert_output "xcode"
}

@test "mod_config: reads multi-line value as separate lines" {
    zsh_run_module mise '
        mod_config tools
    '
    assert_output --partial "node:lts"
    assert_output --partial "python:3.12"
    assert_output --partial "bun:latest"
}

@test "mod_config: returns empty for nonexistent key" {
    zsh_run_module xcode '
        result=$(mod_config nonexistent)
        echo "result=[$result]"
    '
    assert_output "result=[]"
}
