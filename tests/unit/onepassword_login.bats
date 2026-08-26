#!/usr/bin/env bats
# tests/unit/onepassword_login.bats -- 1Password setup needs both integrations and vault access

load '../helpers/common'

setup() {
    export MOCK_DIR="$(mktemp -d)"
    export TEST_SETTINGS="$(mktemp)"
}

teardown() {
    rm -rf "$MOCK_DIR"
    rm -f "$TEST_SETTINGS"
}

write_settings() {
    local cli="$1" mcp="$2"
    printf '{"developers.cliSharedLockState.enabled":%s,"developers.mcpIntegration.enabled":%s}\n' \
        "$cli" "$mcp" > "$TEST_SETTINGS"
}

run_integration_status() {
    run zsh -c '
        settings="$TEST_SETTINGS" &&
        jq -e '\''
          .["developers.cliSharedLockState.enabled"] == true and
          .["developers.mcpIntegration.enabled"] == true
        '\'' "$settings" >/dev/null &&
        env -u OP_SERVICE_ACCOUNT_TOKEN -u OP_CONNECT_HOST -u OP_CONNECT_TOKEN \
          OP_BIOMETRIC_UNLOCK_ENABLED=true op vault list --format=json 2>/dev/null |
        jq -e "type == \"array\" and length > 0" >/dev/null
    '
}

@test "1Password login status fails until both desktop integrations are enabled" {
    write_settings true false
    cat > "$MOCK_DIR/op" <<'EOF'
#!/bin/sh
echo '[{"id":"vault"}]'
exit 0
EOF
    chmod +x "$MOCK_DIR/op"
    PATH="$MOCK_DIR:$PATH" run_integration_status
    assert_failure
}

@test "1Password login status fails when CLI vault access is unavailable" {
    write_settings true true
    cat > "$MOCK_DIR/op" <<'EOF'
#!/bin/sh
echo "connecting to desktop app: cannot connect" >&2
exit 1
EOF
    chmod +x "$MOCK_DIR/op"
    PATH="$MOCK_DIR:$PATH" run_integration_status
    assert_failure
}

@test "1Password login status succeeds with both integrations and vault access" {
    write_settings true true
    cat > "$MOCK_DIR/op" <<'EOF'
#!/bin/sh
echo '[{"id":"vault"}]'
exit 0
EOF
    chmod +x "$MOCK_DIR/op"
    PATH="$MOCK_DIR:$PATH" run_integration_status
    assert_success
}
