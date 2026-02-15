#!/usr/bin/env bats
# modules/homebrew/tests.bats

load '../../tests/helpers/common'

setup() {
    export TEST_HOME="$(mktemp -d)"
    export TEST_CONFIG_DIR="$TEST_HOME/.config"
    export MOCK_DIR="$PRIMER_DIR/tests/helpers/mocks"
    export MOCK_LOG="$(mktemp)"
    export PATH="$MOCK_DIR:$PATH"
}

teardown() {
    rm -rf "$TEST_HOME" "$MOCK_LOG"
}

@test "homebrew: dry-run generates Brewfile with formulae" {
    export DRY_RUN=true
    zsh_run_module homebrew "mod_update"
    assert_success
    assert_output --partial 'brew "fzf"'
    assert_output --partial 'brew "ripgrep"'
    assert_output --partial 'brew "mise"'
}

@test "homebrew: dry-run generates Brewfile with casks" {
    export DRY_RUN=true
    zsh_run_module homebrew "mod_update"
    assert_success
    assert_output --partial 'cask "google-chrome"'
    assert_output --partial 'cask "visual-studio-code"'
}

@test "homebrew: dry-run generates Brewfile with mas entries" {
    export DRY_RUN=true
    zsh_run_module homebrew "mod_update"
    assert_success
    assert_output --partial 'mas "Magnet"'
    assert_output --partial 'mas "Tailscale"'
}

@test "homebrew: wet run calls brew bundle" {
    zsh_run_module homebrew "mod_update"
    assert_success
    run grep "brew bundle" "$MOCK_LOG"
    assert_success
}

@test "homebrew: mod_status uses mock brew --version" {
    zsh_run_module homebrew "mod_status"
    assert_success
}
