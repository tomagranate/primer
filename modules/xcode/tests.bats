#!/usr/bin/env bats
# modules/xcode/tests.bats

load '../../tests/helpers/common'

setup() {
    export TEST_HOME="$(mktemp -d)"
    export MOCK_DIR="$TEST_HOME/mocks"
    mkdir -p "$MOCK_DIR"
    export MOCK_LOG="$(mktemp)"
    export PRIMER_XCODE_APP_PATH="$TEST_HOME/Applications/Xcode.app"
    export PATH="$MOCK_DIR:$PRIMER_DIR/tests/helpers/mocks:$PATH"
    mkdir -p "$PRIMER_XCODE_APP_PATH/Contents/Developer"

    cat > "$MOCK_DIR/xcodebuild" <<'EOF'
#!/bin/sh
echo "xcodebuild $*" >> "${MOCK_LOG:-/dev/null}"
case "$1" in
    -license)
        [ "$2" = "check" ] && [ "${MOCK_XCODE_LICENSE_NEEDED:-0}" = "1" ] && exit 1
        exit 0
        ;;
    -checkFirstLaunchStatus)
        [ "${MOCK_XCODE_FIRST_LAUNCH_NEEDED:-0}" = "1" ] && exit 1
        exit 0
        ;;
esac
exit 0
EOF
    chmod +x "$MOCK_DIR/xcodebuild"

    cat > "$MOCK_DIR/xcrun" <<'EOF'
#!/bin/sh
echo "xcrun $*" >> "${MOCK_LOG:-/dev/null}"
if [ "$1" = "simctl" ] && [ "$2" = "runtime" ] && [ "$3" = "list" ]; then
    printf '== Runtimes ==\n'
    if [ "${MOCK_IOS_RUNTIME_MISSING:-0}" != "1" ]; then
        printf 'iOS 26.5 (26.5 - 23F50) - com.apple.CoreSimulator.SimRuntime.iOS-26-5\n'
    fi
fi
exit 0
EOF
    chmod +x "$MOCK_DIR/xcrun"

    cat > "$MOCK_DIR/sudo" <<'EOF'
#!/bin/sh
echo "sudo $*" >> "${MOCK_LOG:-/dev/null}"
"$@"
EOF
    chmod +x "$MOCK_DIR/sudo"
}

teardown() {
    rm -rf "$TEST_HOME" "$MOCK_LOG"
}

@test "xcode: configures first launch and simulator platforms when already installed" {
    export MOCK_XCODE_FULL=1
    zsh_run_module xcode "mod_update"
    assert_success
    run grep "xcodebuild -checkFirstLaunchStatus" "$MOCK_LOG"
    assert_success
    run grep "xcrun simctl runtime list" "$MOCK_LOG"
    assert_success
    run grep "xcodebuild -downloadPlatform iOS" "$MOCK_LOG"
    assert_failure
}

@test "xcode: runs first launch and downloads missing iOS simulator" {
    export MOCK_XCODE_FULL=1
    export MOCK_XCODE_FIRST_LAUNCH_NEEDED=1
    export MOCK_IOS_RUNTIME_MISSING=1
    zsh_run_module xcode "mod_update"
    assert_success
    run grep "sudo xcodebuild -license accept" "$MOCK_LOG"
    assert_success
    run grep "sudo xcodebuild -runFirstLaunch -checkForNewerComponents" "$MOCK_LOG"
    assert_success
    run grep "xcodebuild -downloadPlatform iOS" "$MOCK_LOG"
    assert_success
}

@test "xcode: accepts the license when first launch is otherwise complete" {
    export MOCK_XCODE_FULL=1
    export MOCK_XCODE_LICENSE_NEEDED=1
    zsh_run_module xcode "mod_update"
    assert_success
    run grep "sudo xcodebuild -license accept" "$MOCK_LOG"
    assert_success
}

@test "xcode: dry-run prints first launch and simulator download" {
    export MOCK_XCODE_FULL=1
    export DRY_RUN=true
    export MOCK_XCODE_FIRST_LAUNCH_NEEDED=1
    export MOCK_IOS_RUNTIME_MISSING=1
    zsh_run_module xcode "mod_update"
    assert_success
    assert_output --partial "[dry-run] sudo xcodebuild -license accept"
    assert_output --partial "[dry-run] sudo xcodebuild -runFirstLaunch -checkForNewerComponents"
    assert_output --partial "[dry-run] xcodebuild -downloadPlatform iOS"
}

@test "xcode: selects full Xcode when app is installed but CLT is active" {
    export MOCK_XCODE_FIRST_LAUNCH_NEEDED=1
    export MOCK_IOS_RUNTIME_MISSING=1
    zsh_run_module xcode "mod_update"
    assert_success
    run grep "sudo xcode-select -s ${PRIMER_XCODE_APP_PATH}/Contents/Developer" "$MOCK_LOG"
    assert_success
}

@test "xcode: update fails when Xcode app is missing" {
    rm -rf "$PRIMER_XCODE_APP_PATH"

    zsh_run_module xcode "mod_update"
    assert_failure
}

@test "xcode: mod_status succeeds when configured" {
    export MOCK_XCODE_FULL=1
    zsh_run_module xcode "mod_status"
    assert_success
}

@test "xcode: mod_status fails when full Xcode is not selected" {
    zsh_run_module xcode "mod_status"
    assert_failure
}

@test "xcode: mod_status fails when Xcode app is missing" {
    rm -rf "$PRIMER_XCODE_APP_PATH"

    zsh_run_module xcode "mod_status"
    assert_failure
}

@test "xcode: mod_status fails when first launch is incomplete" {
    export MOCK_XCODE_FULL=1
    export MOCK_XCODE_FIRST_LAUNCH_NEEDED=1
    zsh_run_module xcode "mod_status"
    assert_failure
}

@test "xcode: mod_status fails when iOS runtime is missing" {
    export MOCK_XCODE_FULL=1
    export MOCK_IOS_RUNTIME_MISSING=1
    zsh_run_module xcode "mod_status"
    assert_failure
}
