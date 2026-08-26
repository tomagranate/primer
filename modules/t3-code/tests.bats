#!/usr/bin/env bats

load '../../tests/helpers/common'

setup() {
    export TEST_HOME="$(mktemp -d)"
    export TEST_CONF="$(mktemp)"
    export MOCK_DIR="$(mktemp -d)"
    export MOCK_LOG="$(mktemp)"
    export MOD_ITEMS_FILE="$(mktemp)"
    export T3_CODE_SYSTEMD_USER_DIR="$TEST_HOME/systemd/user"
    export T3_CODE_APPLICATIONS_DIR="$TEST_HOME/applications"
    export T3_CODE_ICON_PATH="$TEST_HOME/icons/t3-code.png"
    export CADDY_ROUTE_HELPER="$MOCK_DIR/primer-caddy-route"
    export T3_CODE_TEST_ROOT=1
    export T3_CODE_MACHINE_NAME=Tombook-Linux

    cat > "$TEST_CONF" <<'EOF'
[t3-code]
local_port = 3773
domain_suffix = tomagranate.com
browser_command = google-chrome-stable
window_size = 1400,900
window_position = 324,110
EOF

    mkdir -p "$TEST_HOME/.t3/runtime/versions/0.0.33/node_modules/t3/dist/client"
    printf 'icon' > "$TEST_HOME/.t3/runtime/versions/0.0.33/node_modules/t3/dist/client/apple-touch-icon.png"

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
    cat > "$MOCK_DIR/primer-caddy-route" <<'EOF'
#!/bin/sh
printf 'primer-caddy-route %s\n' "$*" >> "$MOCK_LOG"
exit 0
EOF
    cat > "$MOCK_DIR/google-chrome-stable" <<'EOF'
#!/bin/sh
exit 0
EOF
    chmod +x "$MOCK_DIR/t3" "$MOCK_DIR/systemctl" "$MOCK_DIR/primer-caddy-route" "$MOCK_DIR/google-chrome-stable"
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
        export T3_CODE_APPLICATIONS_DIR='${T3_CODE_APPLICATIONS_DIR}'
        export T3_CODE_ICON_PATH='${T3_CODE_ICON_PATH}'
        export CADDY_ROUTE_HELPER='${CADDY_ROUTE_HELPER}'
        export T3_CODE_TEST_ROOT='${T3_CODE_TEST_ROOT}'
        export T3_CODE_MACHINE_NAME='${T3_CODE_MACHINE_NAME}'
        source \"\$PRIMER_DIR/lib/module.zsh\"
        source \"\$PRIMER_DIR/tests/helpers/module-config.zsh\"
        test::load_module_config '${TEST_CONF}'
        source \"\$MOD_DIR/module.zsh\"
        ${code}
    "
}

@test "t3-code: dry-run shows service and shared Caddy route" {
    export DRY_RUN=true
    run_t3_code_module "mod_update"
    assert_success
    assert_output --partial "t3 service install"
    assert_output --partial "install Caddy route t3-code -> http://127.0.0.1:3773"
    refute_output --partial "tailscale serve"
    [ ! -s "$MOCK_LOG" ]
}

@test "t3-code: installs the service and custom-host Caddy route" {
    run_t3_code_module "mod_update"
    assert_success
    grep -Fx "t3 service install" "$MOCK_LOG"
    grep -Fx "systemctl --user daemon-reload" "$MOCK_LOG"
    grep -Fx "systemctl --user restart t3code.service" "$MOCK_LOG"
    grep -F "primer-caddy-route install t3-code" "$MOCK_LOG"
    grep -Fx "Environment=T3CODE_PORT=3773" \
        "$T3_CODE_SYSTEMD_USER_DIR/t3code.service.d/primer.conf"
    grep -F -- "--ozone-platform=x11" "$T3_CODE_APPLICATIONS_DIR/t3-code.desktop"
    grep -F -- "--window-size=1400,900" "$T3_CODE_APPLICATIONS_DIR/t3-code.desktop"
    grep -F -- "--app=http://127.0.0.1:3773" "$T3_CODE_APPLICATIONS_DIR/t3-code.desktop"
    grep -Fx "StartupWMClass=T3Code" "$T3_CODE_APPLICATIONS_DIR/t3-code.desktop"
    cmp -s "$TEST_HOME/.t3/runtime/versions/0.0.33/node_modules/t3/dist/client/apple-touch-icon.png" "$T3_CODE_ICON_PATH"
}

@test "t3-code: status succeeds when the service and route are ready" {
    mkdir -p "$T3_CODE_SYSTEMD_USER_DIR/t3code.service.d"
    cat > "$T3_CODE_SYSTEMD_USER_DIR/t3code.service.d/primer.conf" <<'EOF'
[Service]
Environment=T3CODE_MODE=web
Environment=T3CODE_HOST=127.0.0.1
Environment=T3CODE_PORT=3773
EOF
    run_t3_code_module "_t3_code::install_launcher"
    assert_success
    run_t3_code_module "_t3_code::root() { return 99; }; mod_status"
    assert_success
    grep -E 'primer-caddy-route status t3-code /tmp/' "$MOCK_LOG"
}

@test "t3-code: status fails without the managed service settings" {
    run_t3_code_module "mod_status"
    assert_failure
}

@test "t3-code: missing t3 fails every item with a visible log" {
    rm -f "$MOCK_DIR/t3"
    run_t3_code_module "mod_update"
    assert_failure
    assert_output --partial "t3 not found"
    run grep "$(printf 'failed\tservice\tt3 not found')" "$MOD_ITEMS_FILE"
    assert_success
    run grep "$(printf 'failed\tcaddy-route\tt3 not found')" "$MOD_ITEMS_FILE"
    assert_success
}

@test "t3-code: never manages Tailscale Serve" {
    run grep -F "tailscale serve" "$PRIMER_DIR/modules/t3-code/module.zsh"
    assert_failure
    run grep -F "t3 pair --tailscale" "$PRIMER_DIR/README.md"
    assert_failure
    run_t3_code_module "_t3_code::route_contents 3773"
    assert_success
    assert_output --partial 'https://t3.tombook-linux.tomagranate.com:443 {'
    assert_output --partial 'import tailnet-bind'
    assert_output --partial 'dns cloudflare {env.CLOUDFLARE_API_TOKEN}'
    assert_output --partial 'reverse_proxy http://127.0.0.1:3773'
    refute_output --partial "handle_path"
}

@test "t3-code: rejects an invalid short machine name" {
    export T3_CODE_MACHINE_NAME='not.a.short.name'
    run_t3_code_module "_t3_code::route_contents 3773"
    assert_failure
}
