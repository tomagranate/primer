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
    run grep "$(printf 'failed\tdarkbloom\tcheck failed')" "$MOD_ITEMS_FILE"
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

@test "shell-installers: supports POSIX sh installer shell" {
    cat > "$TEST_CONF" <<'EOF'
[shell-installers]
installers =
    - name: starship
      url: https://starship.rs/install.sh
      command: starship
      check: starship --version
      shell: sh
      args: -y -b $HOME/.local/bin
EOF
    export DRY_RUN=true
    run_shell_installers_with_conf "mod_update"
    assert_success
    assert_output --partial "[dry-run] curl -fsSL https://starship.rs/install.sh | sh -s -- -y -b $TEST_HOME/.local/bin"
}

@test "shell-installers: supports privileged bash installer" {
    cat > "$TEST_CONF" <<'EOF'
[shell-installers]
installers =
    - name: ghostty
      url: https://raw.githubusercontent.com/mkasberg/ghostty-ubuntu/HEAD/install.sh
      command: ghostty
      check: ghostty --version
      shell: bash
      privileged: true
EOF
    export DRY_RUN=true
    run_shell_installers_with_conf "mod_update"
    assert_success
    assert_output --partial "[dry-run] curl -fsSL https://raw.githubusercontent.com/mkasberg/ghostty-ubuntu/HEAD/install.sh | sudo -n bash"
}

@test "shell-installers: wet run pipes privileged installer through sudo" {
    cat > "$TEST_CONF" <<'EOF'
[shell-installers]
installers =
    - name: ghostty
      url: https://example.com/ghostty.sh
      command: ghostty-test
      check: ghostty-test --version
      shell: bash
      privileged: true
EOF
    cat > "$MOCK_DIR/curl" <<'EOF'
#!/bin/sh
echo "curl $*" >> "$MOCK_LOG"
cat <<'SCRIPT'
#!/bin/sh
mkdir -p "$HOME/bin"
cat > "$HOME/bin/ghostty-test" <<'GHOSTTY'
#!/bin/sh
if [ "$1" = "--version" ]; then
    echo "1.0.0"
    exit 0
fi
exit 0
GHOSTTY
chmod +x "$HOME/bin/ghostty-test"
SCRIPT
EOF
    chmod +x "$MOCK_DIR/curl"
    cat > "$MOCK_DIR/sudo" <<'EOF'
#!/bin/sh
echo "sudo $*" >> "$MOCK_LOG"
if [ "$1" = "-n" ] && [ "$2" = "true" ]; then
    exit 0
fi
if [ "$1" = "-n" ]; then
    shift
fi
exec "$@"
EOF
    chmod +x "$MOCK_DIR/sudo"

    run_shell_installers_with_conf "mod_update"
    assert_success
    run grep "curl -fsSL https://example.com/ghostty.sh" "$MOCK_LOG"
    assert_success
    run grep "sudo -n bash" "$MOCK_LOG"
    assert_success
}

@test "shell-installers: mod_status succeeds when installed" {
    make_darkbloom_mock
    run_shell_installers_with_conf "mod_status"
    assert_success
}

@test "shell-installers: mod_status accepts tool installed under dotdir bin" {
    mkdir -p "$TEST_HOME/.darkbloom/bin"
    cat > "$TEST_HOME/.darkbloom/bin/darkbloom" <<'EOF'
#!/bin/sh
case "$1" in
    --version) echo "0.6.10"; exit 0 ;;
esac
exit 0
EOF
    chmod +x "$TEST_HOME/.darkbloom/bin/darkbloom"

    run_shell_installers_with_conf "mod_status"
    assert_success
}

@test "shell-installers: mod_status fails when missing" {
    run_shell_installers_with_conf "mod_status"
    assert_failure
}
