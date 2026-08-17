#!/usr/bin/env bats
# modules/ghostty/tests.bats

load '../../tests/helpers/common'

setup() {
    export TEST_HOME="$(mktemp -d)"
    export TEST_CONFIG_DIR="$TEST_HOME/.config"
}

teardown() {
    rm -rf "$TEST_HOME"
}

@test "ghostty: Linux config starts an interactive zsh" {
    run grep -Fx 'command = zsh' "$PRIMER_DIR/modules/ghostty/linux.conf"
    assert_success
    run grep -F 'command = zsh' "$PRIMER_DIR/modules/ghostty/files/ghostty/config"
    assert_failure
}

@test "ghostty: mod_status succeeds after deploy" {
    zsh_run_module ghostty "mod_update"
    assert_success
    zsh_run_module ghostty "mod_status"
    assert_success
}

@test "ghostty: mod_status fails when config missing" {
    zsh_run_module ghostty "mod_status"
    assert_failure
}

@test "ghostty: mod_status fails when config drifted" {
    zsh_run_module ghostty "mod_update"
    assert_success
    printf '\n# drift\n' >> "$TEST_CONFIG_DIR/ghostty/config"

    zsh_run_module ghostty "mod_status"
    assert_failure
}

@test "ghostty: Linux update writes command = zsh" {
    [[ "$(uname -s)" == Linux ]] || skip "Linux only"
    zsh_run_module ghostty "mod_update"
    assert_success
    run grep -Fx 'command = zsh' "$TEST_CONFIG_DIR/ghostty/config"
    assert_success
}

@test "ghostty: mod_status accepts the managed KDE keybinding block" {
    zsh_run_module ghostty "mod_update"
    assert_success
    cat >> "$TEST_CONFIG_DIR/ghostty/config" <<'EOF'

# >>> PRIMER MANAGED START (modules/kde-desktop-settings/files/ghostty/keybinds.conf) >>>
keybind = ctrl+alt+shift+t=new_tab
# <<< PRIMER MANAGED END (modules/kde-desktop-settings/files/ghostty/keybinds.conf) <<<
EOF

    zsh_run_module ghostty "mod_status"
    assert_success
}
