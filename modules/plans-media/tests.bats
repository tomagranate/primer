#!/usr/bin/env bats

load '../../tests/helpers/common'

setup() {
    export TEST_ROOT="$(mktemp -d)"
    export TEST_CONF="$(mktemp)"
    export MOCK_DIR="$(mktemp -d)"
    export MOCK_LOG="$(mktemp)"
    export PLANS_MEDIA_ROOT_DIR="$TEST_ROOT"
    export PLANS_MEDIA_TEST_ROOT=1
    export CADDY_ROUTE_HELPER="$MOCK_DIR/primer-caddy-route"
    export SYSTEMCTL_BIN="$MOCK_DIR/systemctl"
    cat > "$TEST_CONF" <<EOF
[plans-media]
host = plans.tomagranate.com
worker_host = agents-infra.sunburst-d5c.workers.dev
legacy_secrets_file = $TEST_ROOT/legacy.env
EOF
    cat > "$CADDY_ROUTE_HELPER" <<'EOF'
#!/bin/sh
printf 'route %s\n' "$*" >> "$MOCK_LOG"
if [ "$1" = install ]; then cp "$3" "$TEST_ROOT/installed.caddy"; fi
EOF
    chmod +x "$CADDY_ROUTE_HELPER"
    cat > "$SYSTEMCTL_BIN" <<'EOF'
#!/bin/sh
printf 'systemctl %s\n' "$*" >> "$MOCK_LOG"
EOF
    chmod +x "$SYSTEMCTL_BIN"
}

teardown() { rm -rf "$TEST_ROOT" "$MOCK_DIR"; rm -f "$TEST_CONF" "$MOCK_LOG"; }

run_module() {
    run zsh -c "
        export PRIMER_DIR='$PRIMER_DIR' DRY_RUN='${DRY_RUN:-false}' MOD_DIR='$PRIMER_DIR/modules/plans-media'
        export MOD_NAME=plans-media MOD_STATUS_FILE='$(mktemp)' MOD_ITEMS_FILE='$(mktemp)'
        export PLANS_MEDIA_ROOT_DIR='$PLANS_MEDIA_ROOT_DIR' PLANS_MEDIA_TEST_ROOT=1
        export CADDY_ROUTE_HELPER='$CADDY_ROUTE_HELPER' SYSTEMCTL_BIN='$SYSTEMCTL_BIN'
        export PLANS_MEDIA_EXPECTED_OWNER='${PLANS_MEDIA_EXPECTED_OWNER:-}'
        export MOCK_LOG='$MOCK_LOG' TEST_ROOT='$TEST_ROOT'
        source '$PRIMER_DIR/lib/module.zsh'
        source '$PRIMER_DIR/tests/helpers/module-config.zsh'
        test::load_module_config '$TEST_CONF'
        source '$PRIMER_DIR/modules/plans-media/module.zsh'
        $1
    "
}

@test "plans-media: dry-run does not require or expose secrets" {
    export DRY_RUN=true
    run_module mod_update
    assert_success
    assert_output --partial "root-owned mode 0600 Plans secret environment"
    refute_output --partial "GATE_SECRET="
}

@test "plans-media: migrates the existing secret file without printing it" {
    printf 'GATE_SECRET=private\nCLOUDFLARE_API_TOKEN=private\n' > "$TEST_ROOT/legacy.env"
    run_module mod_update
    assert_success
    [ "$(stat -c %a "$TEST_ROOT/etc/caddy/env.d/plans-media.env")" = 600 ]
    [ "$(cat "$TEST_ROOT/etc/caddy/env.d/plans-media.env")" = 'GATE_SECRET="private"' ]
    refute_output --partial "private"
    grep -F 'import tailnet-bind' "$TEST_ROOT/installed.caddy"
    grep -F 'header_up Authorization "Bearer {env.GATE_SECRET}"' "$TEST_ROOT/installed.caddy"
    grep -Fx 'systemctl restart caddy.service' "$MOCK_LOG"
}

@test "plans-media: missing secret configuration is explicit" {
    run_module mod_update
    assert_failure
    assert_output --partial "Set plans-media.gate_secret_ref"
    [ ! -e "$TEST_ROOT/installed.caddy" ]
}

@test "plans-media: refreshes an installed secret from the legacy source" {
    mkdir -p "$TEST_ROOT/etc/caddy/env.d"
    printf 'GATE_SECRET=old-private\n' > "$TEST_ROOT/etc/caddy/env.d/plans-media.env"
    printf 'GATE_SECRET=new-private\n' > "$TEST_ROOT/legacy.env"

    run_module _plans_media::install_secrets

    assert_success
    [ "$(cat "$TEST_ROOT/etc/caddy/env.d/plans-media.env")" = 'GATE_SECRET="new-private"' ]
    refute_output --partial private
}

@test "plans-media: restarts Caddy after rotating the secret" {
    mkdir -p "$TEST_ROOT/etc/caddy/env.d"
    printf 'GATE_SECRET=old-private\n' > "$TEST_ROOT/etc/caddy/env.d/plans-media.env"
    printf 'GATE_SECRET=new-private\n' > "$TEST_ROOT/legacy.env"

    run_module mod_update

    assert_success
    [ "$(cat "$TEST_ROOT/etc/caddy/env.d/plans-media.env")" = 'GATE_SECRET="new-private"' ]
    grep -Fx 'systemctl restart caddy.service' "$MOCK_LOG"
    refute_output --partial private
}

@test "plans-media: quotes systemd environment metacharacters" {
    printf '%s\n' 'GATE_SECRET=slash\quote"private' > "$TEST_ROOT/legacy.env"

    run_module _plans_media::install_secrets

    assert_success
    [ "$(cat "$TEST_ROOT/etc/caddy/env.d/plans-media.env")" = 'GATE_SECRET="slash\\quote\"private"' ]
    refute_output --partial private
}

@test "plans-media: status does not require root" {
    mkdir -p "$TEST_ROOT/etc/caddy/env.d"
    printf 'GATE_SECRET=private\n' > "$TEST_ROOT/etc/caddy/env.d/plans-media.env"
    chmod 0600 "$TEST_ROOT/etc/caddy/env.d/plans-media.env"

    run_module '_plans_media::root() { return 99; }; mod_status'

    assert_success

    export PLANS_MEDIA_EXPECTED_OWNER=__not_the_owner__
    run_module '_plans_media::root() { return 99; }; mod_status'
    assert_failure
}
