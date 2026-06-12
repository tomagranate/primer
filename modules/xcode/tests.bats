#!/usr/bin/env bats
# modules/xcode/tests.bats

load '../../tests/helpers/common'

setup() {
    export TEST_HOME="$(mktemp -d)"
    export MOCK_DIR="$TEST_HOME/mocks"
    mkdir -p "$MOCK_DIR"
    export MOCK_LOG="$(mktemp)"
    export PATH="$MOCK_DIR:$PRIMER_DIR/tests/helpers/mocks:$PATH"

    cat > "$MOCK_DIR/xcodebuild" <<'EOF'
#!/bin/sh
echo "xcodebuild $*" >> "${MOCK_LOG:-/dev/null}"
case "$1" in
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
    export MOCK_XCODE_FIRST_LAUNCH_NEEDED=1
    export MOCK_IOS_RUNTIME_MISSING=1
    zsh_run_module xcode "mod_update"
    assert_success
    run grep "sudo xcodebuild -runFirstLaunch -checkForNewerComponents" "$MOCK_LOG"
    assert_success
    run grep "xcodebuild -downloadPlatform iOS" "$MOCK_LOG"
    assert_success
}

@test "xcode: dry-run prints first launch and simulator download" {
    export DRY_RUN=true
    export MOCK_XCODE_FIRST_LAUNCH_NEEDED=1
    export MOCK_IOS_RUNTIME_MISSING=1
    zsh_run_module xcode "mod_update"
    assert_success
    assert_output --partial "[dry-run] sudo xcodebuild -runFirstLaunch -checkForNewerComponents"
    assert_output --partial "[dry-run] xcodebuild -downloadPlatform iOS"
}

@test "xcode: mod_status succeeds when configured" {
    zsh_run_module xcode "mod_status"
    assert_success
}

@test "xcode: mod_status fails when not installed" {
    export MOCK_XCODE_MISSING=1
    zsh_run_module xcode "mod_status"
    assert_failure
}

@test "xcode: mod_status fails when first launch is incomplete" {
    export MOCK_XCODE_FIRST_LAUNCH_NEEDED=1
    zsh_run_module xcode "mod_status"
    assert_failure
}

@test "xcode: mod_status fails when iOS runtime is missing" {
    export MOCK_IOS_RUNTIME_MISSING=1
    zsh_run_module xcode "mod_status"
    assert_failure
}
