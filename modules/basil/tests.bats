#!/usr/bin/env bats

load '../../tests/helpers/common'

setup() {
    export TEST_HOME="$(mktemp -d)"
    export TEST_CONF="$(mktemp)"
    export MOCK_DIR="$(mktemp -d)"
    export MOCK_LOG="$(mktemp)"
    export BASIL_ROOT_LOG="$(mktemp)"
    export BASIL_TEST_ROOT=1
    export PATH="$MOCK_DIR:$PATH"
    cat > "$MOCK_DIR/systemctl" <<'EOF'
#!/bin/sh
printf 'systemctl %s\n' "$*" >> "$MOCK_LOG"
[ "$1 $2 $3" = "is-enabled --quiet docker.service" ] && [ -e "$TEST_HOME/docker-disabled" ] && exit 1
exit 0
EOF
    cat > "$MOCK_DIR/loginctl" <<'EOF'
#!/bin/sh
[ -e "$TEST_HOME/linger-disabled" ] && printf '%s\n' no || printf '%s\n' yes
EOF
    cat > "$MOCK_DIR/docker" <<'EOF'
#!/bin/sh
printf 'docker %s\n' "$*" >> "$MOCK_LOG"
case "$*" in
    *" ps --status running --services") printf 'ntfy\nuptime-kuma\n' ;;
esac
exit 0
EOF
    cat > "$MOCK_DIR/curl" <<'EOF'
#!/bin/sh
printf 'curl %s\n' "$*" >> "$MOCK_LOG"
case "$*" in
    *"http://127.0.0.1:18090/v1/health"*|*"http://127.0.0.1:18091/"*) exit 0 ;;
esac
while [ "$#" -gt 0 ]; do
    if [ "$1" = -o ]; then
        output="$2"
        break
    fi
    shift
done
cat > "$output" <<'SCRIPT'
#!/bin/sh
printf '%s\n' 'cloudflared version 2026.8.2 (built test)'
SCRIPT
EOF
    cat > "$MOCK_DIR/primer-caddy-route" <<'EOF'
#!/bin/sh
printf 'primer-caddy-route %s\n' "$*" >> "$MOCK_LOG"
EOF
    chmod +x "$MOCK_DIR/systemctl" "$MOCK_DIR/loginctl" "$MOCK_DIR/docker" "$MOCK_DIR/curl" "$MOCK_DIR/primer-caddy-route"
    cat > "$TEST_CONF" <<EOF
[basil]
repo_path = $TEST_HOME/code/basil
cloudflared_version = 2026.8.2
ntfy_gateway_port = 8090
kuma_gateway_port = 8443
EOF
}

teardown() {
    rm -rf "$TEST_HOME" "$MOCK_DIR"
    rm -f "$TEST_CONF" "$MOCK_LOG" "$BASIL_ROOT_LOG"
}

run_module() {
    run zsh -c "
        export PRIMER_DIR='$PRIMER_DIR' DRY_RUN='${DRY_RUN:-false}' MOD_DIR='$PRIMER_DIR/modules/basil'
        export MOD_NAME=basil MOD_STATUS_FILE='$(mktemp)' MOD_ITEMS_FILE='$(mktemp)' HOME='$TEST_HOME'
        export CADDY_TAILSCALE_HOSTNAME=tombook-linux.example.ts.net
        export CADDY_ROUTE_HELPER='$MOCK_DIR/primer-caddy-route'
        export BASIL_TEST_ROOT='$BASIL_TEST_ROOT' BASIL_ROOT_LOG='$BASIL_ROOT_LOG' MOCK_LOG='$MOCK_LOG'
        export PATH='$MOCK_DIR':/usr/bin:/bin:/usr/sbin:/sbin
        source '$PRIMER_DIR/lib/module.zsh'
        source '$PRIMER_DIR/tests/helpers/module-config.zsh'
        test::load_module_config '$TEST_CONF'
        source '$PRIMER_DIR/modules/basil/module.zsh'
        $1
    "
}

@test "basil: dry-run plans services, containers, and route without credentials" {
    export DRY_RUN=true
    run_module mod_update
    assert_success
    assert_output --partial "install Hermes, cloudflared, tunnel, webhook, and brain-sync user services"
    assert_output --partial "systemctl enable --now docker.service"
    assert_output --partial "docker compose --project-name basil up -d"
}

@test "basil: route keeps ntfy ingress on loopback and Kuma on the tailnet" {
    run_module _basil::route_contents
    assert_success
    assert_output --partial "http://127.0.0.1:8090"
    assert_output --partial 'https://tombook-linux.example.ts.net:8443'
    assert_output --partial "reverse_proxy http://127.0.0.1:18091"
}

@test "basil: missing repository files are explicit" {
    run_module _basil::required_sources
    assert_failure
    assert_output --partial "Basil source is missing"
}

@test "basil: installs its pinned cloudflared executable" {
    run_module _basil::install_cloudflared
    assert_success
    [ -x "$TEST_HOME/.local/bin/cloudflared" ]
    grep -F "/2026.8.2/cloudflared-linux-amd64" "$MOCK_LOG"
    grep -Fx "systemctl --user restart basil-tunnel.service" "$MOCK_LOG"
}

@test "basil: enables Docker and routes update commands through root" {
    run_module '_basil::enable_docker && _basil::install_compose'
    assert_success
    grep -Fx "systemctl enable --now docker.service" "$BASIL_ROOT_LOG"
    [ "$(grep -c ' docker ' "$BASIL_ROOT_LOG")" -eq 2 ]
    grep -F "docker inspect" "$MOCK_LOG"
    grep -F "docker compose --project-name basil" "$MOCK_LOG"
}

@test "basil: status checks services without root" {
    repo="$TEST_HOME/code/basil"
    unit_dir="$TEST_HOME/.config/systemd/user"
    config_dir="$TEST_HOME/.config/primer/basil"
    mkdir -p "$repo/deploy" "$unit_dir" "$config_dir"
    for unit in basil-tunnel.service basil-webhook-shim.service basil-brain-sync.service basil-brain-sync.timer; do
        printf 'unit=%s\n' "$unit" > "$repo/deploy/$unit"
        cp "$repo/deploy/$unit" "$unit_dir/$unit"
    done
    mkdir -p "$repo/deploy/infra"
    printf 'script\n' > "$repo/deploy/brain-sync.sh"
    printf 'script\n' > "$repo/deploy/infra/kuma-webhook-shim.py"
    cp "$PRIMER_DIR/modules/basil/files/compose.yaml" "$config_dir/compose.yaml"
    printf 'credential\n' > "$repo/deploy/infra/tunnel.env"
    printf 'credential\n' > "$repo/deploy/infra/webhook-shim.env"
    chmod 0600 "$repo/deploy/infra/tunnel.env" "$repo/deploy/infra/webhook-shim.env"
    run_module _basil::install_cloudflared
    assert_success
    run_module _basil::reconcile_credentials
    assert_success
    run_module _basil::install_compose
    assert_success
    : > "$BASIL_ROOT_LOG"

    run_module '_basil::root() { return 99; }; mod_status'

    assert_success
    [ ! -s "$BASIL_ROOT_LOG" ]
    grep -F 'curl -fsS --max-time 5 http://127.0.0.1:18090/v1/health' "$MOCK_LOG"
    grep -F 'primer-caddy-route status basil' "$MOCK_LOG"

    rm "$TEST_HOME/.local/bin/cloudflared"
    run_module '_basil::root() { return 99; }; mod_status'
    assert_failure

    run_module _basil::install_cloudflared
    assert_success
    rm "$repo/deploy/infra/tunnel.env"
    run_module '_basil::root() { return 99; }; mod_status'
    assert_failure

    printf 'credential\n' > "$repo/deploy/infra/tunnel.env"
    chmod 0600 "$repo/deploy/infra/tunnel.env"
    rm "$repo/deploy/brain-sync.sh"
    run_module '_basil::root() { return 99; }; mod_status'
    assert_failure
}

@test "basil: detects deployed unit and compose drift" {
    repo="$TEST_HOME/code/basil"
    unit_dir="$TEST_HOME/.config/systemd/user"
    config_dir="$TEST_HOME/.config/primer/basil"
    mkdir -p "$repo/deploy" "$unit_dir" "$config_dir"
    for unit in basil-tunnel.service basil-webhook-shim.service basil-brain-sync.service basil-brain-sync.timer; do
        printf 'unit=%s\n' "$unit" > "$repo/deploy/$unit"
        cp "$repo/deploy/$unit" "$unit_dir/$unit"
    done
    cp "$PRIMER_DIR/modules/basil/files/compose.yaml" "$config_dir/compose.yaml"

    run_module _basil::definitions_match
    assert_success

    printf 'drift\n' >> "$unit_dir/basil-tunnel.service"
    run_module _basil::definitions_match
    assert_failure
}

@test "basil: detects a Compose file that was not activated" {
    config_dir="$TEST_HOME/.config/primer/basil"
    mkdir -p "$config_dir"
    cp "$PRIMER_DIR/modules/basil/files/compose.yaml" "$config_dir/compose.yaml"
    printf 'stale\n' > "$config_dir/compose.sha256"

    run_module _basil::compose_active
    assert_failure

    run_module _basil::install_compose
    assert_success
    run_module _basil::compose_active
    assert_success
}

@test "basil: restarts an active service when its unit changes" {
    repo="$TEST_HOME/code/basil"
    unit_dir="$TEST_HOME/.config/systemd/user"
    mkdir -p "$repo/deploy" "$unit_dir"
    for unit in basil-tunnel.service basil-webhook-shim.service basil-brain-sync.service basil-brain-sync.timer; do
        printf 'unit=%s\n' "$unit" > "$repo/deploy/$unit"
        cp "$repo/deploy/$unit" "$unit_dir/$unit"
    done
    printf 'changed=true\n' >> "$repo/deploy/basil-tunnel.service"

    run_module _basil::install_units

    assert_success
    grep -Fx "systemctl --user restart basil-tunnel.service" "$MOCK_LOG"
}

@test "basil: restarts an active service when its credential changes" {
    repo="$TEST_HOME/code/basil"
    mkdir -p "$repo/deploy/infra"
    printf 'tunnel-one\n' > "$repo/deploy/infra/tunnel.env"
    printf 'webhook-one\n' > "$repo/deploy/infra/webhook-shim.env"
    chmod 0600 "$repo/deploy/infra/tunnel.env" "$repo/deploy/infra/webhook-shim.env"
    run_module _basil::reconcile_credentials
    assert_success
    : > "$MOCK_LOG"

    printf 'tunnel-two\n' > "$repo/deploy/infra/tunnel.env"
    run_module _basil::reconcile_credentials

    assert_success
    grep -Fx "systemctl --user restart basil-tunnel.service" "$MOCK_LOG"
    run grep -Fx "systemctl --user restart basil-webhook-shim.service" "$MOCK_LOG"
    assert_failure
}

@test "basil: verifies linger and Docker boot settings" {
    run_module _basil::boot_ready
    assert_success

    touch "$TEST_HOME/linger-disabled"
    run_module _basil::boot_ready
    assert_failure
    rm "$TEST_HOME/linger-disabled"

    touch "$TEST_HOME/docker-disabled"
    run_module _basil::boot_ready
    assert_failure
}
