#!/usr/bin/env bats
# modules/kde-desktop-settings/tests.bats

load '../../tests/helpers/common'

setup() {
    export TEST_HOME="$(mktemp -d)"
    export TEST_CONFIG_DIR="$TEST_HOME/.config"
}

teardown() {
    rm -rf "$TEST_HOME"
}

@test "kde-desktop-settings: inserts managed Ghostty keybinding block" {
    mkdir -p "$TEST_CONFIG_DIR/ghostty"
    cat > "$TEST_CONFIG_DIR/ghostty/config" <<'EOF'
theme = Firewatch
quit-after-last-window-closed = true
EOF

    zsh_run_module kde-desktop-settings "_kde_desktop_settings::configure_ghostty"
    assert_success

    grep -F "theme = Firewatch" "$TEST_CONFIG_DIR/ghostty/config"
    grep -F "keybind = ctrl+alt+shift+d=new_split:right" "$TEST_CONFIG_DIR/ghostty/config"
    grep -F "keybind = ctrl+alt+shift+t=new_tab" "$TEST_CONFIG_DIR/ghostty/config"
    grep -F "keybind = shift+home=text:\\x15" "$TEST_CONFIG_DIR/ghostty/config"
}

@test "kde-desktop-settings: replaces existing managed Ghostty keybinding block" {
    mkdir -p "$TEST_CONFIG_DIR/ghostty"
    cat > "$TEST_CONFIG_DIR/ghostty/config" <<'EOF'
theme = Firewatch
# >>> PRIMER MANAGED START (modules/kde-desktop-settings/files/ghostty/keybinds.conf) >>>
keybind = stale=ignore
# <<< PRIMER MANAGED END (modules/kde-desktop-settings/files/ghostty/keybinds.conf) <<<
EOF

    zsh_run_module kde-desktop-settings "_kde_desktop_settings::configure_ghostty"
    assert_success

    ! grep -F "stale" "$TEST_CONFIG_DIR/ghostty/config"
    grep -F "keybind = ctrl+alt+shift+w=close_surface" "$TEST_CONFIG_DIR/ghostty/config"
}

@test "kde-desktop-settings: dry-run update avoids privileged writes" {
    export DRY_RUN=true

    zsh_run_module kde-desktop-settings "mod_update"
    assert_success
    assert_output --partial "[dry-run] install"
    assert_output --partial "[dry-run] configure KRunner"
    assert_output --partial "[dry-run] update managed Ghostty keybinding block"
}
