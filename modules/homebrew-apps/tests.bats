#!/usr/bin/env bats
# modules/homebrew-apps/tests.bats

load '../../tests/helpers/common'

setup() {
    export TEST_HOME="$(mktemp -d)"
    export TEST_CONFIG_DIR="$TEST_HOME/.config"
    export MOCK_DIR="$PRIMER_DIR/tests/helpers/mocks"
    export MOCK_LOG="$(mktemp)"
    export TEST_CONF="$(mktemp)"
    export MOD_ITEMS_FILE="$(mktemp)"
    export PATH="$MOCK_DIR:$PATH"

    cat > "$TEST_CONF" <<'EOF'
[homebrew-apps]
casks =
    fake-app
    another-app
EOF
}

teardown() {
    rm -rf "$TEST_HOME" "$MOCK_LOG" "$TEST_CONF" "$MOD_ITEMS_FILE"
}

run_homebrew_apps_with_conf() {
    local action="$1"
    run zsh -c "
        export PRIMER_DIR='${PRIMER_DIR}'
        export DRY_RUN='${DRY_RUN:-false}'
        export MOD_DIR='${PRIMER_DIR}/modules/homebrew-apps'
        export MOD_NAME='homebrew-apps'
        export MOD_STATUS_FILE='${TEST_HOME}/mod-status'
        export MOD_ITEMS_FILE='${MOD_ITEMS_FILE}'
        export CONFIG_DIR='${TEST_CONFIG_DIR:-/tmp/primer-test-config}'
        export ZSH_CONFIG_DIR='${TEST_CONFIG_DIR:-/tmp/primer-test-config}/zsh'
        export BIN_DIR='${TEST_BIN_DIR:-/tmp/primer-test-bin}'
        export HOME='${TEST_HOME:-$HOME}'
        source \"\$PRIMER_DIR/lib/ui.zsh\"
        source \"\$PRIMER_DIR/lib/engine.zsh\"
        engine::load_config '${TEST_CONF}'
        source \"\$MOD_DIR/module.zsh\"
        ${action}
    "
}

@test "homebrew-apps: dry-run installs each cask individually" {
    export DRY_RUN=true
    run_homebrew_apps_with_conf "mod_update"
    assert_success
    assert_output --partial 'brew install --cask fake-app'
    assert_output --partial 'brew install --cask another-app'
}

@test "homebrew-apps: dry-run does not use brew bundle" {
    export DRY_RUN=true
    run_homebrew_apps_with_conf "mod_update"
    assert_success
    refute_output --partial 'brew bundle'
}

@test "homebrew-apps: wet run calls brew install --cask for each app" {
    run_homebrew_apps_with_conf "mod_update"
    assert_success
    run grep "brew install --cask fake-app" "$MOCK_LOG"
    assert_success
    run grep "brew install --cask another-app" "$MOCK_LOG"
    assert_success
}

@test "homebrew-apps: items file contains all casks as done after wet run" {
    run_homebrew_apps_with_conf "mod_update"
    assert_success
    run grep "done:fake-app" "$MOD_ITEMS_FILE"
    assert_success
    run grep "done:another-app" "$MOD_ITEMS_FILE"
    assert_success
}

@test "homebrew-apps: mod_status succeeds with mock brew" {
    run_homebrew_apps_with_conf "mod_status"
    assert_success
}
