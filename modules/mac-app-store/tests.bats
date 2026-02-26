#!/usr/bin/env bats
# modules/mac-app-store/tests.bats

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
[mac-app-store]
mas =
    FakeApp:123456789
    OtherApp:987654321
EOF
}

teardown() {
    rm -rf "$TEST_HOME" "$MOCK_LOG" "$TEST_CONF" "$MOD_ITEMS_FILE"
}

run_mac_app_store_with_conf() {
    local action="$1"
    run zsh -c "
        export PRIMER_DIR='${PRIMER_DIR}'
        export DRY_RUN='${DRY_RUN:-false}'
        export MOD_DIR='${PRIMER_DIR}/modules/mac-app-store'
        export MOD_NAME='mac-app-store'
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

@test "mac-app-store: dry-run calls mas install for each app" {
    export DRY_RUN=true
    run_mac_app_store_with_conf "mod_update"
    assert_success
    assert_output --partial 'mas install 123456789'
    assert_output --partial 'mas install 987654321'
}

@test "mac-app-store: dry-run does not use brew bundle" {
    export DRY_RUN=true
    run_mac_app_store_with_conf "mod_update"
    assert_success
    refute_output --partial 'brew bundle'
}

@test "mac-app-store: wet run calls mas install for each app" {
    run_mac_app_store_with_conf "mod_update"
    assert_success
    run grep "mas install 123456789" "$MOCK_LOG"
    assert_success
    run grep "mas install 987654321" "$MOCK_LOG"
    assert_success
}

@test "mac-app-store: items file contains app names as done after wet run" {
    run_mac_app_store_with_conf "mod_update"
    assert_success
    run grep "done:FakeApp" "$MOD_ITEMS_FILE"
    assert_success
    run grep "done:OtherApp" "$MOD_ITEMS_FILE"
    assert_success
}

@test "mac-app-store: mod_status succeeds when configured apps are installed" {
    export MOCK_MAS_INSTALLED_IDS="123456789 987654321"
    run_mac_app_store_with_conf "mod_status"
    assert_success
}

@test "mac-app-store: mod_status fails when apps are missing" {
    export MOCK_MAS_INSTALLED_IDS="123456789"
    run_mac_app_store_with_conf "mod_status"
    assert_failure
    run grep "1 missing" "$TEST_HOME/mod-status"
    assert_success
}

@test "mac-app-store: dry-run shows brew install mas when mas not on PATH" {
    # Build a PATH that has the brew mock but no mas
    local no_mas_dir
    no_mas_dir="$(mktemp -d)"
    cp "$MOCK_DIR/brew" "$no_mas_dir/brew"
    chmod +x "$no_mas_dir/brew"

    export DRY_RUN=true
    run zsh -c "
        export PRIMER_DIR='${PRIMER_DIR}'
        export DRY_RUN=true
        export MOD_DIR='${PRIMER_DIR}/modules/mac-app-store'
        export MOD_NAME='mac-app-store'
        export MOD_STATUS_FILE='${TEST_HOME}/mod-status'
        export MOD_ITEMS_FILE='${MOD_ITEMS_FILE}'
        export HOME='${TEST_HOME}'
        export PATH='${no_mas_dir}:/usr/bin:/bin:/usr/sbin:/sbin'
        source \"\$PRIMER_DIR/lib/ui.zsh\"
        source \"\$PRIMER_DIR/lib/engine.zsh\"
        engine::load_config '${TEST_CONF}'
        source \"\$MOD_DIR/module.zsh\"
        mod_update
    "
    rm -rf "$no_mas_dir"
    assert_success
    assert_output --partial '[dry-run] brew install mas'
}

