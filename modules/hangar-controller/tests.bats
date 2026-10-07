#!/usr/bin/env bats

load '../../tests/helpers/common'

setup() {
    export TEST_HOME="$(mktemp -d)"
    export TEST_CONF="$(mktemp)"
    export MOCK_DIR="$TEST_HOME/mock"
    export MOCK_LOG="$TEST_HOME/calls"
    export ROOT="$TEST_HOME/root"
    mkdir -p "$MOCK_DIR"
    : > "$MOCK_LOG"

    cat > "$TEST_CONF" <<'EOF'
[hangar-controller]
owner = tomagranate
github_app_id_ref = op://Dev/hangar/github-app-id
github_private_key_ref = op://Dev/hangar/github-private-key
webhook_secret_ref = op://Dev/hangar/webhook-secret
cell_token_ref = op://Dev/hangar/cell-token
funnel_port = 10000
EOF

    cat > "$MOCK_DIR/op" <<'EOF'
#!/bin/sh
echo "op $* (token=$OP_SERVICE_ACCOUNT_TOKEN)" >> "$MOCK_LOG"
case "$2" in
  */github-app-id) echo 4242 ;;
  */github-private-key) printf -- '-----BEGIN RSA PRIVATE KEY-----\nabc\n-----END RSA PRIVATE KEY-----\n' ;;
  */webhook-secret) echo hook-secret ;;
  */cell-token) echo cell-secret ;;
esac
EOF
    cat > "$MOCK_DIR/tailscale" <<'EOF'
#!/bin/sh
echo "tailscale $*" >> "$MOCK_LOG"
if [ "$1 $2" = "funnel status" ] && [ -f "$TEST_HOME/.funnel" ]; then
  echo "https://tombook-linux.example.ts.net:10000 (Funnel on)"
  echo "|-- /github/webhook proxy http://127.0.0.1:8781/github/webhook"
fi
[ "$1 $2" = "funnel --bg" ] && touch "$TEST_HOME/.funnel"
exit 0
EOF
    cat > "$MOCK_DIR/systemctl" <<'EOF'
#!/bin/sh
echo "systemctl $*" >> "$MOCK_LOG"
EOF
    chmod +x "$MOCK_DIR"/*
}

teardown() {
    rm -rf "$TEST_HOME" "$TEST_CONF"
}

run_module() {
    run zsh -c "
        export PRIMER_DIR='${PRIMER_DIR}'
        export DRY_RUN='${DRY_RUN:-false}'
        export MOD_DIR='${PRIMER_DIR}/modules/hangar-controller'
        export MOD_NAME='hangar-controller'
        export MOD_STATUS_FILE='$(mktemp)'
        export HOME='${TEST_HOME}'
        export PATH='${MOCK_DIR}:/usr/bin:/bin'
        export MOCK_LOG='${MOCK_LOG}' TEST_HOME='${TEST_HOME}'
        ${OP_UNSET:+unset OP_SERVICE_ACCOUNT_TOKEN}
        ${OP_UNSET:-export OP_SERVICE_ACCOUNT_TOKEN=ticket}
        export PRIMER_OP_TICKET='${TEST_HOME}/op-ticket'
        export HANGAR_SYSTEMD_DIR='${ROOT}/etc/systemd/system'
        export HANGAR_ETC_DIR='${ROOT}/etc/hangar'
        export HANGAR_TAILNET_IP=100.64.0.7
        source \"\$PRIMER_DIR/lib/module.zsh\"
        source \"\$PRIMER_DIR/tests/helpers/module-config.zsh\"
        test::load_module_config '${TEST_CONF}'
        source \"\$MOD_DIR/module.zsh\"
        $1
    "
}

@test "hangar-controller: secrets, config, and unit from one run" {
    run_module "mod_update"
    assert_success

    local secrets="$ROOT/etc/hangar/secrets"
    grep -F "BEGIN RSA PRIVATE KEY" "$secrets/github-app.pem"
    [ "$(cat "$secrets/webhook-secret")" = hook-secret ]
    [ "$(cat "$secrets/cell-token")" = cell-secret ]
    for f in github-app.pem webhook-secret cell-token github-app-id; do
        [ "$(stat -c %a "$secrets/$f")" = 600 ]
    done

    local cfg="$ROOT/etc/hangar/controller.toml"
    grep -Fx 'webhook_listen = "127.0.0.1:8781"' "$cfg"
    grep -Fx 'tailnet_listen = "100.64.0.7:8782"' "$cfg"
    grep -Fx 'github_app_id = 4242' "$cfg"
    grep -Fx 'owner = "tomagranate"' "$cfg"
    grep -Fx 'ci-container = "medium"' "$cfg"
    grep -Fx '[sizes.large]' "$cfg"
    [ -f "$ROOT/etc/systemd/system/hangar-controller.service" ]
    grep -Fx "systemctl restart hangar-controller.service" "$MOCK_LOG"

    # Only /github/webhook is public, on the configured Funnel port.
    grep -Fx "tailscale funnel --bg --yes --https=10000 --set-path=/github/webhook http://127.0.0.1:8781/github/webhook" "$MOCK_LOG"
    [ "$(grep -c "tailscale funnel --bg" "$MOCK_LOG")" = 1 ]

    # A second run reads no secrets and leaves Funnel as it is.
    : > "$MOCK_LOG"
    run_module "mod_update"
    assert_success
    if grep -E "^op |funnel --bg|restart" "$MOCK_LOG"; then
        echo "second run must change nothing" >&2
        return 1
    fi

    run_module 'mod_status; rc=$?; cat "$MOD_STATUS_FILE"; exit $rc'
    assert_success
}

@test "hangar-controller: a missing app ID stops before writing a config" {
    sed -i 's|^github_app_id_ref = .*|github_app_id_ref = op://Dev/hangar/nothing|' "$TEST_CONF"
    run_module "mod_update"
    assert_failure
    [ ! -e "$ROOT/etc/hangar/controller.toml" ]
}

@test "hangar-controller: dry-run changes nothing" {
    export DRY_RUN=true
    run_module "mod_update"
    assert_success
    [ ! -e "$ROOT/etc/hangar" ]
    if grep -E "^op |funnel --bg|systemctl (enable|start|restart)" "$MOCK_LOG"; then
        echo "dry-run must not change the machine" >&2
        return 1
    fi
}

@test "hangar-controller: reads secrets with the agents sudo ticket" {
    export OP_UNSET=1
    run_module "mod_update"
    assert_failure
    assert_output --partial "Run agents sudo"

    echo from-ticket > "$TEST_HOME/op-ticket"
    run_module "mod_update"
    assert_success
    grep -F "op read op://Dev/hangar/github-private-key (token=from-ticket)" "$MOCK_LOG"
}
