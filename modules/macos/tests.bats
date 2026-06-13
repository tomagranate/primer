#!/usr/bin/env bats
# modules/macos/tests.bats

load '../../tests/helpers/common'

setup() {
    export TEST_HOME="$(mktemp -d)"
    export MOCK_DIR="$TEST_HOME/mocks"
    mkdir -p "$MOCK_DIR"
    export MOCK_LOG="$(mktemp)"
    export PATH="$MOCK_DIR:$PATH"

    mkdir -p "$TEST_HOME/Applications"
    export PRIMER_TEST_APPLICATIONS="$TEST_HOME/Applications"
    mkdir -p \
        "$PRIMER_TEST_APPLICATIONS/Apps.app" \
        "$PRIMER_TEST_APPLICATIONS/Helium.app" \
        "$PRIMER_TEST_APPLICATIONS/Codex.app" \
        "$PRIMER_TEST_APPLICATIONS/Ghostty.app" \
        "$PRIMER_TEST_APPLICATIONS/Cursor.app" \
        "$PRIMER_TEST_APPLICATIONS/Spotify.app" \
        "$PRIMER_TEST_APPLICATIONS/Notes.app" \
        "$PRIMER_TEST_APPLICATIONS/System Settings.app"

    cat > "$MOCK_DIR/defaults" <<'EOF'
#!/bin/sh
echo "defaults $*" >> "${MOCK_LOG:-/dev/null}"
if [ "$1" = "read" ]; then
    case "$2:$3" in
        NSGlobalDomain:AppleShowAllExtensions) echo 1 ;;
        NSGlobalDomain:ApplePressAndHoldEnabled) echo 0 ;;
        com.apple.dock:tilesize) echo 41 ;;
        com.apple.dock:mineffect) echo scale ;;
        com.apple.dock:launchanim) echo 0 ;;
        com.apple.dock:autohide) echo 1 ;;
        com.apple.dock:show-recents) echo 0 ;;
        com.apple.dock:mru-spaces) echo 0 ;;
        com.apple.Spotlight:MenuItemHidden) echo 1 ;;
        com.apple.screencapture:location) echo "$HOME/Desktop/Screenshots" ;;
    esac
fi
exit 0
EOF
    chmod +x "$MOCK_DIR/defaults"

    cat > "$MOCK_DIR/dockutil" <<'EOF'
#!/bin/sh
echo "dockutil $*" >> "${MOCK_LOG:-/dev/null}"
if [ "$1" = "--find" ] && [ "${MOCK_DOCKUTIL_FIND_MISSING:-}" = "true" ]; then
    exit 1
fi
exit 0
EOF
    chmod +x "$MOCK_DIR/dockutil"

    cat > "$MOCK_DIR/killall" <<'EOF'
#!/bin/sh
echo "killall $*" >> "${MOCK_LOG:-/dev/null}"
exit 0
EOF
    chmod +x "$MOCK_DIR/killall"

    cat > "$MOCK_DIR/networksetup" <<'EOF'
#!/bin/sh
echo "networksetup $*" >> "${MOCK_LOG:-/dev/null}"
case "$1" in
    -listallnetworkservices)
        printf 'An asterisk (*) denotes that a network service is disabled.\n'
        printf 'Wi-Fi\n'
        printf 'Thunderbolt Bridge\n'
        ;;
    -getdnsservers)
        printf '1.1.1.1\n1.0.0.1\n'
        ;;
esac
exit 0
EOF
    chmod +x "$MOCK_DIR/networksetup"

    cat > "$MOCK_DIR/defaultbrowser" <<'EOF'
#!/bin/sh
echo "defaultbrowser $*" >> "${MOCK_LOG:-/dev/null}"
if [ $# -eq 0 ]; then
    echo "helium"
fi
exit 0
EOF
    chmod +x "$MOCK_DIR/defaultbrowser"
}

teardown() {
    rm -rf "$TEST_HOME" "$MOCK_LOG"
}

@test "macos: dry-run prints defaults and dock changes" {
    export DRY_RUN=true
    zsh_run_module macos "
        _mod_config[macos.dock_apps]=\$'${PRIMER_TEST_APPLICATIONS}/Codex.app\n/System/Applications/Notes.app\n/System/Applications/System Settings.app\n${PRIMER_TEST_APPLICATIONS}/Missing.app'
        mod_update
    "
    assert_success
    assert_output --partial "defaults write NSGlobalDomain:AppleShowAllExtensions:bool:true"
    assert_output --partial "defaults write com.apple.dock:tilesize:int:41"
    assert_output --partial "defaults write com.apple.dock:mru-spaces:bool:false"
    assert_output --partial "mkdir -p ${TEST_HOME}/Desktop/Screenshots"
    assert_output --partial "defaults write com.apple.screencapture location -string ${TEST_HOME}/Desktop/Screenshots"
    assert_output --partial "dockutil --remove Safari --no-restart"
    assert_output --partial "dockutil --add ${PRIMER_TEST_APPLICATIONS}/Codex.app --no-restart"
    assert_output --partial "skip missing Dock app ${PRIMER_TEST_APPLICATIONS}/Missing.app"
    refute_output --partial "dockutil --remove Notes --no-restart"
    refute_output --partial "dockutil --remove System Settings --no-restart"
    assert_output --partial "networksetup -setdnsservers Wi-Fi 1.1.1.1 1.0.0.1"
    assert_output --partial "defaultbrowser helium"
}

@test "macos: mod_update writes defaults and configures dock" {
    export MOCK_DOCKUTIL_FIND_MISSING=true
    zsh_run_module macos "
        _mod_config[macos.dock_apps]=\$'${PRIMER_TEST_APPLICATIONS}/Codex.app\n/System/Applications/Notes.app\n/System/Applications/System Settings.app\n${PRIMER_TEST_APPLICATIONS}/Missing.app'
        mod_update
    "
    assert_success
    run grep "defaults write NSGlobalDomain AppleShowAllExtensions -bool true" "$MOCK_LOG"
    assert_success
    run grep "defaults write com.apple.dock tilesize -int 41" "$MOCK_LOG"
    assert_success
    run grep "defaults write com.apple.dock mru-spaces -bool false" "$MOCK_LOG"
    assert_success
    run test -d "${TEST_HOME}/Desktop/Screenshots"
    assert_success
    run grep "defaults write com.apple.screencapture location -string ${TEST_HOME}/Desktop/Screenshots" "$MOCK_LOG"
    assert_success
    run grep "dockutil --remove Safari --no-restart" "$MOCK_LOG"
    assert_success
    run grep "dockutil --add ${PRIMER_TEST_APPLICATIONS}/Codex.app --no-restart" "$MOCK_LOG"
    assert_success
    run grep "dockutil --add ${PRIMER_TEST_APPLICATIONS}/Missing.app --no-restart" "$MOCK_LOG"
    assert_failure
    run grep "dockutil --remove Notes --no-restart" "$MOCK_LOG"
    assert_failure
    run grep "dockutil --remove System Settings --no-restart" "$MOCK_LOG"
    assert_failure
    run grep "dockutil --remove Google Chrome" "$MOCK_LOG"
    assert_failure
    run grep "killall Dock" "$MOCK_LOG"
    assert_success
    run grep "networksetup -setdnsservers Wi-Fi 1.1.1.1 1.0.0.1" "$MOCK_LOG"
    assert_success
    run grep "networksetup -setdnsservers Thunderbolt Bridge 1.1.1.1 1.0.0.1" "$MOCK_LOG"
    assert_success
    run grep "defaultbrowser helium" "$MOCK_LOG"
    assert_success
    run grep "killall SystemUIServer" "$MOCK_LOG"
    assert_success
}

@test "macos: mod_status checks configured defaults and dock apps" {
    zsh_run_module macos "
        _mod_config[macos.dock_apps]=\$'${PRIMER_TEST_APPLICATIONS}/Codex.app\n${PRIMER_TEST_APPLICATIONS}/Missing.app'
        mkdir -p '${TEST_HOME}/Desktop/Screenshots'
        mod_status
    "
    assert_success
    run grep "defaults read NSGlobalDomain AppleShowAllExtensions" "$MOCK_LOG"
    assert_success
    run grep "defaults read com.apple.dock mru-spaces" "$MOCK_LOG"
    assert_success
    run grep "defaults read com.apple.screencapture location" "$MOCK_LOG"
    assert_success
    run grep "dockutil --find Codex" "$MOCK_LOG"
    assert_success
    run grep "dockutil --find Missing" "$MOCK_LOG"
    assert_failure
    run grep "networksetup -getdnsservers Wi-Fi" "$MOCK_LOG"
    assert_success
    run grep "^defaultbrowser $" "$MOCK_LOG"
    assert_success
}
