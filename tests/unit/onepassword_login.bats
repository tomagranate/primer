#!/usr/bin/env bats
# tests/unit/onepassword_login.bats -- 1Password login status must see an account

load '../helpers/common'

setup() {
    export MOCK_DIR="$(mktemp -d)"
}

teardown() {
    rm -rf "$MOCK_DIR"
}

run_account_status() {
    run zsh -c '
        op account list --format=json 2>/dev/null |
        jq -e "type == \"array\" and length > 0" >/dev/null
    '
}

@test "1Password login status fails when op reports no accounts" {
    cat > "$MOCK_DIR/op" <<'EOF'
#!/bin/sh
echo '[]'
exit 0
EOF
    chmod +x "$MOCK_DIR/op"
    PATH="$MOCK_DIR:$PATH" run_account_status
    assert_failure
}

@test "1Password login status fails when op cannot list accounts" {
    cat > "$MOCK_DIR/op" <<'EOF'
#!/bin/sh
echo "connecting to desktop app: cannot connect" >&2
exit 1
EOF
    chmod +x "$MOCK_DIR/op"
    PATH="$MOCK_DIR:$PATH" run_account_status
    assert_failure
}

@test "1Password login status succeeds when op reports an account" {
    cat > "$MOCK_DIR/op" <<'EOF'
#!/bin/sh
echo '[{"url":"https://my.1password.com","email":"tom@sunburst.io"}]'
exit 0
EOF
    chmod +x "$MOCK_DIR/op"
    PATH="$MOCK_DIR:$PATH" run_account_status
    assert_success
}
