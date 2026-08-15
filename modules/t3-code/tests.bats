#!/usr/bin/env bats

load '../../tests/helpers/common'

setup() {
    export TEST_HOME="$(mktemp -d)"
    export TEST_CONF="$(mktemp)"
    export MOCK_DIR="$(mktemp -d)"
    export MOCK_LOG="$(mktemp)"
    export MOD_ITEMS_FILE="$(mktemp)"
    export T3_CODE_SYSTEMD_USER_DIR="$TEST_HOME/systemd/user"

    cat > "$TEST_CONF" <<'EOF'
[t3-code]
local_port = 3773
tailscale_serve_port = 443
EOF

    cat > "$MOCK_DIR/t3" <<'EOF'
#!/bin/sh
printf 't3 %s\n' "$*" >> "$MOCK_LOG"
case "$*" in
    "service status") printf 'T3 Code service\n  Status: installed · t3@test\n' ;;
esac
EOF
    cat > "$MOCK_DIR/systemctl" <<'EOF'
#!/bin/sh
printf 'systemctl %s\n' "$*" >> "$MOCK_LOG"
exit 0
EOF
    cat > "$MOCK_DIR/tailscale" <<'EOF'
#!/bin/sh
printf 'tailscale %s\n' "$*" >> "$MOCK_LOG"
if [ "$1" = "serve" ] && [ "$2" = "status" ]; then
    printf '%s\n' '{"TCP":{"443":{"HTTPS":true}},"Web":{"host:443":{"Handlers":{"/":{"Proxy":"http://127.0.0.1:3773"}}}}}'
fi
EOF
    chmod +x "$MOCK_DIR/t3" "$MOCK_DIR/systemctl" "$MOCK_DIR/tailscale"
}

teardown() {
    rm -rf "$TEST_HOME" "$MOCK_DIR"
    rm -f "$TEST_CONF" "$MOCK_LOG" "$MOD_ITEMS_FILE"
}

run_t3_code_module() {
    local code="$1"
    run zsh -c "
        export PRIMER_DIR='${PRIMER_DIR}'
        export DRY_RUN='${DRY_RUN:-false}'
        export MOD_DIR='${PRIMER_DIR}/modules/t3-code'
        export MOD_NAME='t3-code'
        export MOD_STATUS_FILE='$(mktemp)'
        export MOD_ITEMS_FILE='${MOD_ITEMS_FILE}'
        export HOME='${TEST_HOME}'
        export PATH='${MOCK_DIR}:/usr/bin:/bin'
        export MOCK_LOG='${MOCK_LOG}'
        export T3_CODE_SYSTEMD_USER_DIR='${T3_CODE_SYSTEMD_USER_DIR}'
        source \"\$PRIMER_DIR/lib/module.zsh\"
        source \"\$PRIMER_DIR/tests/helpers/module-config.zsh\"
        test::load_module_config '${TEST_CONF}'
        source \"\$MOD_DIR/module.zsh\"
        ${code}
    "
}

@test "t3-code: dry-run shows service and proxy commands" {
    export DRY_RUN=true
    run_t3_code_module "mod_update"
    assert_success
    assert_output --partial "t3 service install"
    assert_output --partial "tailscale serve --bg --https=443 http://127.0.0.1:3773"
    [ ! -s "$MOCK_LOG" ]
}

@test "t3-code: installs the service and persistent Tailscale proxy" {
    run_t3_code_module "mod_update"
    assert_success
    grep -Fx "t3 service install" "$MOCK_LOG"
    grep -Fx "systemctl --user daemon-reload" "$MOCK_LOG"
    grep -Fx "systemctl --user restart t3code.service" "$MOCK_LOG"
    grep -Fx "tailscale serve --bg --https=443 http://127.0.0.1:3773" "$MOCK_LOG"
    grep -Fx "Environment=T3CODE_PORT=3773" \
        "$T3_CODE_SYSTEMD_USER_DIR/t3code.service.d/primer.conf"
}

@test "t3-code: status succeeds when the service and proxy are ready" {
    mkdir -p "$T3_CODE_SYSTEMD_USER_DIR/t3code.service.d"
    cat > "$T3_CODE_SYSTEMD_USER_DIR/t3code.service.d/primer.conf" <<'EOF'
[Service]
Environment=T3CODE_MODE=web
Environment=T3CODE_HOST=127.0.0.1
Environment=T3CODE_PORT=3773
EOF
    run_t3_code_module "mod_status"
    assert_success
}

@test "t3-code: status fails without the managed service settings" {
    run_t3_code_module "mod_status"
    assert_failure
}
