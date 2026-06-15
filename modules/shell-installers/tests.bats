#!/usr/bin/env bats
# modules/shell-installers/tests.bats

load '../../tests/helpers/common'

setup() {
    export TEST_HOME="$(mktemp -d)"
    export TEST_CONFIG_DIR="$TEST_HOME/.config"
    export TEST_CONF="$(mktemp)"
    export MOCK_DIR="$TEST_HOME/mocks"
    mkdir -p "$MOCK_DIR"
    export MOCK_LOG="$(mktemp)"
    export MOD_ITEMS_FILE="$(mktemp)"
    export PATH="$MOCK_DIR:$PRIMER_DIR/tests/helpers/mocks:$PATH"

    cat > "$MOCK_DIR/darkbloom" <<'EOF'
#!/bin/sh
echo "darkbloom $*" >> "${MOCK_LOG:-/dev/null}"
exit 1
EOF
    chmod +x "$MOCK_DIR/darkbloom"

    cat > "$TEST_CONF" <<'EOF'
[shell-installers]
installers =
    - name: darkbloom
      url: https://api.darkbloom.dev/install.sh
      command: darkbloom
      check: darkbloom --version
EOF
}

teardown() {
    rm -rf "$TEST_HOME" "$MOCK_LOG" "$TEST_CONF" "$MOD_ITEMS_FILE"
}

make_darkbloom_mock() {
    cat > "$MOCK_DIR/darkbloom" <<'EOF'
#!/bin/sh
echo "darkbloom $*" >> "${MOCK_LOG:-/dev/null}"
case "$1" in
    --version) echo "0.6.9"; exit 0 ;;
esac
exit 0
EOF
    chmod +x "$MOCK_DIR/darkbloom"
}

run_shell_installers_with_conf() {
    local action="$1"
    run zsh -c "
        export PRIMER_DIR='${PRIMER_DIR}'
        export DRY_RUN='${DRY_RUN:-false}'
        export MOD_DIR='${PRIMER_DIR}/modules/shell-installers'
        export MOD_NAME='shell-installers'
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

@test "shell-installers: dry-run prints installer command when missing" {
    export DRY_RUN=true
    run_shell_installers_with_conf "mod_update"
    assert_success
    assert_output --partial "[dry-run] curl -fsSL https://api.darkbloom.dev/install.sh | bash"
}

@test "shell-installers: wet run calls configured installer when missing" {
    run_shell_installers_with_conf "mod_update"
    assert_failure
    run grep "curl -fsSL https://api.darkbloom.dev/install.sh" "$MOCK_LOG"
    assert_success
    run grep "failed:darkbloom:check failed" "$MOD_ITEMS_FILE"
    assert_success
}

@test "shell-installers: wet run skips installer when already installed" {
    make_darkbloom_mock
    run_shell_installers_with_conf "mod_update"
    assert_success
    run grep "curl -fsSL https://api.darkbloom.dev/install.sh" "$MOCK_LOG"
    assert_failure
}

@test "shell-installers: supports multiple installer entries" {
    cat > "$MOCK_DIR/example" <<'EOF'
#!/bin/sh
exit 1
EOF
    chmod +x "$MOCK_DIR/example"
    cat > "$TEST_CONF" <<'EOF'
[shell-installers]
installers =
    - name: darkbloom
      url: https://api.darkbloom.dev/install.sh
      command: darkbloom
      check: darkbloom --version
    - name: example
      url: https://example.com/install.sh
      command: example
      check: example --version
EOF
    export DRY_RUN=true
    run_shell_installers_with_conf "mod_update"
    assert_success
    assert_output --partial "[dry-run] curl -fsSL https://api.darkbloom.dev/install.sh | bash"
    assert_output --partial "[dry-run] curl -fsSL https://example.com/install.sh | bash"
}

@test "shell-installers: mod_status succeeds when installed" {
    make_darkbloom_mock
    run_shell_installers_with_conf "mod_status"
    assert_success
}

@test "shell-installers: mod_status fails when missing" {
    run_shell_installers_with_conf "mod_status"
    assert_failure
}
