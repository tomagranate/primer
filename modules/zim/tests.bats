#!/usr/bin/env bats
# modules/zim/tests.bats

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

@test "zim: dry-run does not crash" {
    export DRY_RUN=true
    zsh_run_module zim "mod_update"
    assert_success
}

@test "zim: dry-run prints deploy message" {
    export DRY_RUN=true
    zsh_run_module zim "mod_update"
    assert_output --partial "dry-run"
}

@test "zim: dry-run plans creating hushlogin" {
    export DRY_RUN=true
    zsh_run_module zim "mod_update"
    assert_success
    assert_output --partial "[dry-run] touch"
    assert_output --partial ".hushlogin"
}

@test "zim: update removes stale compiled managed configs" {
    mkdir -p "$TEST_CONFIG_DIR/zsh"
    touch "$TEST_CONFIG_DIR/zsh/.zshrc.zwc" "$TEST_CONFIG_DIR/zsh/.zimrc.zwc"

    zsh_run_module zim "mod_update"
    assert_success
    [ ! -e "$TEST_CONFIG_DIR/zsh/.zshrc.zwc" ]
    [ ! -e "$TEST_CONFIG_DIR/zsh/.zimrc.zwc" ]
}

@test "zim: deploys config files to ZSH_CONFIG_DIR" {
    # Use dry-run for the Zim install part but test deploy_files separately
    # We can't test the full wet path without real Zim, but we CAN test file deployment
    zsh_run_module zim '
        deploy_files "$ZSH_CONFIG_DIR"
    '
    assert_success
    [ -f "$TEST_CONFIG_DIR/zsh/.zshrc" ]
    [ -f "$TEST_CONFIG_DIR/zsh/.zshenv" ]
    [ -f "$TEST_CONFIG_DIR/zsh/.zimrc" ]
}

@test "zim: deployed .zshenv sets ZDOTDIR" {
    zsh_run_module zim '
        deploy_files "$ZSH_CONFIG_DIR"
    '
    run grep "ZDOTDIR" "$TEST_CONFIG_DIR/zsh/.zshenv"
    assert_success
}

@test "zim: mod_status reports not installed when Zim is missing" {
    zsh_run_module zim "mod_status"
    assert_failure
}

@test "zim: deployed files include primer-managed markers" {
    zsh_run_module zim '
        deploy_files "$ZSH_CONFIG_DIR"
    '
    assert_success

    run grep -q "PRIMER MANAGED START" "$TEST_CONFIG_DIR/zsh/.zshrc"
    assert_success
    run grep -q "PRIMER MANAGED START" "$TEST_CONFIG_DIR/zsh/.zimrc"
    assert_success
    run grep -q "PRIMER MANAGED START" "$TEST_CONFIG_DIR/zsh/.zshenv"
    assert_success
}

@test "zim: install path bootstraps zimfw and avoids install script" {
    local fakebin
    fakebin="$(mktemp -d)"

    cat > "${fakebin}/curl" <<'EOF'
#!/bin/sh
echo "curl $*" >> "${MOCK_LOG:-/dev/null}"
out=""
prev=""
for arg in "$@"; do
    if [ "$prev" = "-o" ]; then
        out="$arg"
        break
    fi
    prev="$arg"
done
if [ -n "$out" ]; then
    mkdir -p "$(dirname "$out")"
    cat > "$out" <<'ZEOF'
zimfw() { return 0; }
ZEOF
fi
exit 0
EOF
    chmod +x "${fakebin}/curl"

    export PATH="${fakebin}:$PATH"
    zsh_run_module zim "mod_update"
    assert_success

    run grep -q "install/master/install.zsh" "$MOCK_LOG"
    assert_failure
    run grep -q "releases/latest/download/zimfw.zsh" "$MOCK_LOG"
    assert_success
}

@test "zim: zshrc uses zimfw init command after sourcing" {
    zsh_run_module zim '
        deploy_files "$ZSH_CONFIG_DIR"
    '
    assert_success

    run grep -qE "source .*zimfw\\.zsh init -q" "$TEST_CONFIG_DIR/zsh/.zshrc"
    assert_failure

    run grep -qE "source .*zimfw\\.zsh" "$TEST_CONFIG_DIR/zsh/.zshrc"
    assert_success
    run grep -q "zimfw init -q" "$TEST_CONFIG_DIR/zsh/.zshrc"
    assert_success
}

@test "zim: docker alias defers command substitution to invocation" {
    zsh_run_module zim '
        deploy_files "$ZSH_CONFIG_DIR"
    '
    assert_success

    run grep -q 'alias docker-kill-all="docker stop \$(docker ps -q) && docker rm \$(docker ps -aq)"' "$TEST_CONFIG_DIR/zsh/.zshrc"
    assert_failure

    run grep -q "alias docker-kill-all='docker stop \$(docker ps -q) && docker rm \$(docker ps -aq)'" "$TEST_CONFIG_DIR/zsh/.zshrc"
    assert_success
}
