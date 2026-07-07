#!/usr/bin/env bats
# modules/npm-global/tests.bats

load '../../tests/helpers/common'

setup() {
    export TEST_HOME="$(mktemp -d)"
    export TEST_CONFIG_DIR="$TEST_HOME/.config"
    export TEST_CONF="$(mktemp)"
    export MOCK_DIR="$TEST_HOME/mocks"
    mkdir -p "$MOCK_DIR"
    export MOCK_LOG="$(mktemp)"
    export MOD_ITEMS_FILE="$(mktemp)"
    export PATH="${MOCK_DIR}:/usr/bin:/bin:/usr/sbin:/sbin"

    cat > "$TEST_CONF" <<'EOF'
[npm-global]
packages =
    - name: t3
      package: t3@latest
      command: t3
      check: t3 --version
EOF
}

teardown() {
    rm -rf "$TEST_HOME" "$MOCK_LOG" "$TEST_CONF" "$MOD_ITEMS_FILE"
}

run_npm_global_with_conf() {
    local action="$1"
    run zsh -c "
        export PRIMER_DIR='${PRIMER_DIR}'
        export DRY_RUN='${DRY_RUN:-false}'
        export MOD_DIR='${PRIMER_DIR}/modules/npm-global'
        export MOD_NAME='npm-global'
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

make_t3_mock() {
    cat > "$MOCK_DIR/t3" <<'EOF'
#!/bin/sh
echo "t3 $*" >> "${MOCK_LOG:-/dev/null}"
case "$1" in
    --version) echo "0.0.28"; exit 0 ;;
esac
exit 0
EOF
    chmod +x "$MOCK_DIR/t3"
}

@test "npm-global: dry-run prints npm install command" {
    export DRY_RUN=true
    run_npm_global_with_conf "mod_update"
    assert_success
    assert_output --partial "[dry-run] npm install -g t3@latest"
}

@test "npm-global: wet run installs missing package" {
    cat > "$MOCK_DIR/npm" <<'EOF'
#!/bin/sh
echo "npm $*" >> "$MOCK_LOG"
if [ "$1" = "install" ] && [ "$2" = "-g" ]; then
    cat > "$HOME/mocks/t3" <<'T3'
#!/bin/sh
case "$1" in
    --version) echo "0.0.28"; exit 0 ;;
esac
exit 0
T3
    chmod +x "$HOME/mocks/t3"
    exit 0
fi
exit 1
EOF
    chmod +x "$MOCK_DIR/npm"

    run_npm_global_with_conf "mod_update"
    assert_success
    run grep "npm install -g t3@latest" "$MOCK_LOG"
    assert_success
}

@test "npm-global: wet run skips package when command is installed" {
    make_t3_mock
    cat > "$MOCK_DIR/npm" <<'EOF'
#!/bin/sh
echo "npm $*" >> "$MOCK_LOG"
exit 1
EOF
    chmod +x "$MOCK_DIR/npm"

    run_npm_global_with_conf "mod_update"
    assert_success
    run grep "npm install -g t3@latest" "$MOCK_LOG"
    assert_failure
}

@test "npm-global: mod_status succeeds when installed" {
    make_t3_mock
    run_npm_global_with_conf "mod_status"
    assert_success
}

@test "npm-global: mod_status fails when missing" {
    run_npm_global_with_conf "mod_status"
    assert_failure
}
