#!/usr/bin/env bats

load '../../tests/helpers/common'

setup() {
    export TEST_HOME="$(mktemp -d)"
    export TEST_CONFIG_DIR="$TEST_HOME/.config"
    export TEST_BIN_DIR="$TEST_HOME/bin"
    export KDE_TASKBAR_CONFIG_FILE="$TEST_CONFIG_DIR/plasma-org.kde.plasma.desktop-appletsrc"
    mkdir -p "$TEST_CONFIG_DIR" "$TEST_BIN_DIR"
}

teardown() {
    rm -rf "$TEST_HOME"
}

write_taskbar_config() {
    cat > "$KDE_TASKBAR_CONFIG_FILE" <<'EOF'
[Containments][2][Applets][5]
plugin=org.kde.plasma.icontasks

[Containments][2][Applets][5][Configuration][General]
launchers=applications:systemsettings.desktop,applications:t3-code.desktop,applications:steam.desktop
EOF
}

@test "kde-taskbar-pins: reads the icon task manager launcher list" {
    write_taskbar_config

    zsh_run_module kde-taskbar-pins "_mod_config[kde-taskbar-pins.launchers]=\$'applications:systemsettings.desktop\\napplications:t3-code.desktop\\napplications:steam.desktop'; _kde_taskbar_pins::matches"

    assert_success
}

@test "kde-taskbar-pins: reports launcher order drift" {
    write_taskbar_config

    zsh_run_module kde-taskbar-pins "_mod_config[kde-taskbar-pins.launchers]=\$'applications:t3-code.desktop\\napplications:systemsettings.desktop\\napplications:steam.desktop'; _kde_taskbar_pins::matches"

    assert_failure
}

@test "kde-taskbar-pins: sends a JavaScript array to Plasma" {
    cat > "$TEST_BIN_DIR/qdbus-test" <<'EOF'
#!/bin/sh
if [ "$#" -eq 1 ]; then
    exit 0
fi
printf '%s\n' "$4" > "$TEST_HOME/plasma-script"
sed -i 's|^launchers=.*|launchers=applications:systemsettings.desktop,applications:t3-code.desktop,applications:steam.desktop|' "$KDE_TASKBAR_CONFIG_FILE"
EOF
    chmod +x "$TEST_BIN_DIR/qdbus-test"
    write_taskbar_config
    sed -i 's|^launchers=.*|launchers=applications:steam.desktop|' "$KDE_TASKBAR_CONFIG_FILE"

    zsh_run_module kde-taskbar-pins "_mod_config[kde-taskbar-pins.qdbus_command]='${TEST_BIN_DIR}/qdbus-test'; _mod_config[kde-taskbar-pins.launchers]=\$'applications:systemsettings.desktop\\napplications:t3-code.desktop\\napplications:steam.desktop'; mod_update"

    assert_success
    grep -F 'var desired=["applications:systemsettings.desktop","applications:t3-code.desktop","applications:steam.desktop"]' "$TEST_HOME/plasma-script"
}

@test "kde-taskbar-pins: dry-run does not require a Plasma session" {
    export DRY_RUN=true

    zsh_run_module kde-taskbar-pins "_mod_config[kde-taskbar-pins.launchers]=\$'applications:systemsettings.desktop\\napplications:t3-code.desktop'; mod_update"

    assert_success
    assert_output --partial "set KDE taskbar launchers"
}
