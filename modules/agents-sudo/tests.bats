#!/usr/bin/env bats

load '../../tests/helpers/common'

setup() {
    export TEST_HOME="$(mktemp -d)"
    export TEST_BIN_DIR="$TEST_HOME/bin"
    export AGENTS_SUDO_CALLS="$TEST_HOME/sudo.calls"
    export AGENTS_SUDO_RULE_PATH="$TEST_HOME/etc/sudoers.d/agents-session"
    export AGENTS_SUDO_SUDOERS_PATH="$TEST_HOME/etc/sudoers"
    export AGENTS_SUDO_USER="testuser"
    export AGENTS_SUDO_TESTING=1
    export AGENTS_SUDO_SUDO="$TEST_HOME/fake-sudo"
    export AGENTS_SUDO_INSTALL="$TEST_HOME/fake-install"

    mkdir -p "$TEST_HOME/etc/sudoers.d"
    printf '# test sudoers\n' > "$AGENTS_SUDO_SUDOERS_PATH"
    cat > "$AGENTS_SUDO_SUDO" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "$AGENTS_SUDO_CALLS"
case "${1:-}" in
    -v|-K) exit 0 ;;
    -n) shift; exec "$@" ;;
    *) exec "$@" ;;
esac
EOF
    chmod +x "$AGENTS_SUDO_SUDO"

    cat > "$AGENTS_SUDO_INSTALL" <<'EOF'
#!/bin/sh
[ "$1" = "-o" ] && shift 2
[ "$1" = "-g" ] && shift 2
exec /usr/bin/install "$@"
EOF
    chmod +x "$AGENTS_SUDO_INSTALL"
}

teardown() {
    rm -rf "$TEST_HOME"
}

run_helper() {
    run env \
        AGENTS_SUDO_TESTING="$AGENTS_SUDO_TESTING" \
        AGENTS_SUDO_SUDO="$AGENTS_SUDO_SUDO" \
        AGENTS_SUDO_INSTALL="$AGENTS_SUDO_INSTALL" \
        AGENTS_SUDO_RULE_PATH="$AGENTS_SUDO_RULE_PATH" \
        AGENTS_SUDO_SUDOERS_PATH="$AGENTS_SUDO_SUDOERS_PATH" \
        AGENTS_SUDO_USER="$AGENTS_SUDO_USER" \
        AGENTS_SUDO_CALLS="$AGENTS_SUDO_CALLS" \
        "$PRIMER_DIR/modules/agents-sudo/bin/agents-sudo" "$@"
}

@test "agents-sudo: installs a validated 12-hour global policy" {
    run_helper
    assert_success
    assert_output --partial "global sudo ticket active for 12 hours"
    assert_equal "$(cat "$AGENTS_SUDO_RULE_PATH")" \
        "Defaults:testuser timestamp_type=global, timestamp_timeout=720"
    assert_equal "$(stat -c '%a' "$AGENTS_SUDO_RULE_PATH")" "440"
    grep -F -- "-n true" "$AGENTS_SUDO_CALLS"
}

@test "agents-sudo: status reports an active non-interactive ticket" {
    run_helper --status
    assert_success
    assert_output --partial "non-interactive sudo is available"
}

@test "agents-sudo: revoke invalidates the ticket" {
    run_helper --revoke
    assert_success
    grep -Fx -- "-K" "$AGENTS_SUDO_CALLS"
}

@test "agents-sudo: remove deletes the fixed policy and revokes the ticket" {
    run_helper
    assert_success
    run_helper --remove
    assert_success
    [ ! -e "$AGENTS_SUDO_RULE_PATH" ]
    grep -Fx -- "-K" "$AGENTS_SUDO_CALLS"
}

@test "agents-sudo: refuses non-Linux systems" {
    run env AGENTS_SUDO_OS=Darwin "$PRIMER_DIR/modules/agents-sudo/bin/agents-sudo" --status
    assert_failure
    assert_output --partial "Linux is required"
}

@test "agents-sudo module: installs the command" {
    zsh_run_module agents-sudo "mod_update"
    assert_success
    [ -x "$TEST_BIN_DIR/agents-sudo" ]
    zsh_run_module agents-sudo "mod_status"
    assert_success
}

@test "agents-sudo module: reports a missing command" {
    zsh_run_module agents-sudo "mod_status"
    assert_failure
}
