#!/usr/bin/env bats

load '../../tests/helpers/common'

setup() {
    export TEST_ROOT="$(mktemp -d)"
    export TEST_CONF="$(mktemp)"
    export MOCK_DIR="$(mktemp -d)"
    export MOCK_LOG="$(mktemp)"
    export MOCK_CF_BODY="$(mktemp)"
    export CADDY_CONFIG_DIR="$TEST_ROOT/etc/caddy"
    export CADDY_APPS_DIR="$CADDY_CONFIG_DIR/apps.d"
    export CADDY_ROUTE_MANIFEST="$CADDY_CONFIG_DIR/primer-routes"
    export CADDY_ROUTE_LOCK="$TEST_ROOT/route.lock"
    export SYSTEMCTL_BIN="$MOCK_DIR/systemctl"
    mkdir -p "$CADDY_APPS_DIR"
    printf '{}\n' > "$CADDY_CONFIG_DIR/Caddyfile"
    printf 'expected legacy Plans listener\n' > "$CADDY_CONFIG_DIR/plans.Caddyfile"
    mkdir -p "$TEST_ROOT/etc/systemd/system"
    printf 'expected legacy Plans unit\n' > "$TEST_ROOT/etc/systemd/system/plans.service"
    cat > "$MOCK_DIR/systemctl" <<'EOF'
#!/bin/sh
printf 'systemctl %s\n' "$*" >> "$MOCK_LOG"
if { [ "$1" = "is-active" ] || [ "$1" = "is-enabled" ]; } && [ -e "$TEST_ROOT/plans-disabled" ]; then
    exit 1
fi
if [ "$1 $2 $3" = "is-active --quiet caddy.service" ] && [ -e "$TEST_ROOT/reject-health" ]; then
    exit 1
fi
if [ "$1 $2" = "start --wait" ] && { [ -e "$TEST_ROOT/reject" ] || grep -Rqs INVALID "$CADDY_APPS_DIR"; }; then
    exit 1
fi
if [ "$1 $2" = "reload caddy.service" ] && [ -e "$TEST_ROOT/reject-reload" ]; then
    rm -f "$TEST_ROOT/reject-reload"
    exit 1
fi
if [ "$1 $2" = "restart caddy.service" ] && [ -e "$TEST_ROOT/reject-activation" ]; then
    exit 1
fi
if [ "$1 $2 $3" = "disable --now plans.service" ] && [ -e "$TEST_ROOT/reject-plans-stop" ]; then
    exit 1
fi
if [ "$*" = "show plans.service --property=ExecStart --value" ]; then
    printf '%s\n' '{ path=/usr/local/bin/caddy ; argv[]=/usr/local/bin/caddy run --config /etc/caddy/plans.Caddyfile ; ignore_errors=no ; }'
fi
if [ "$*" = "show plans.service --property=ExecReload --value" ]; then
    printf '%s\n' '{ path=/usr/local/bin/caddy ; argv[]=/usr/local/bin/caddy reload --config /etc/caddy/plans.Caddyfile --force ; ignore_errors=no ; }'
fi
if [ "$*" = "show plans.service --property=EnvironmentFiles --value" ]; then
    printf '%s\n' '/etc/agents-infra/plans.env (ignore_errors=no)'
fi
if [ "$*" = "show plans.service --property=FragmentPath --value" ]; then
    printf '%s\n' '/etc/systemd/system/plans.service'
fi
if [ "$*" = "show plans.service --property=User --value" ] || [ "$*" = "show plans.service --property=Group --value" ]; then
    printf '%s\n' caddy
fi
if [ "$*" = "show plans.service --property=ExecStartPost --value" ] && [ -e "$TEST_ROOT/plans-extra-command" ]; then
    printf '%s\n' '{ path=/usr/bin/custom ; argv[]=/usr/bin/custom ; }'
fi
exit 0
EOF
    chmod +x "$MOCK_DIR/systemctl"
    cat > "$TEST_CONF" <<EOF
[caddy]
caddy_version = v2.11.4
xcaddy_version = v0.4.5
cloudflare_module = github.com/caddy-dns/cloudflare@v0.2.4
cloudflare_token_required = true
cloudflare_zone = tomagranate.com
cloudflare_reader_ref = op://Agents/Cloudflare Reader/credential
cloudflare_minter_ref = op://Agents/Cloudflare Token Minter/credential
cloudflare_account_id_ref = op://Agents/Cloudflare Token Minter/account id
legacy_cloudflare_env = $TEST_ROOT/legacy.env
migrate_tailscale_serve_port = 443
migrate_tailscale_serve_target = http://127.0.0.1:3773
migrate_tailscale_serve_route = t3-code
migrate_tailscale_serve_host = t3.{machine}.tomagranate.com
migrate_plans_config_digest = $(sha256sum "$CADDY_CONFIG_DIR/plans.Caddyfile" | cut -d ' ' -f1)
migrate_plans_unit_digest = $(sha256sum "$TEST_ROOT/etc/systemd/system/plans.service" | cut -d ' ' -f1)
dns_names =
    t3.{machine}.tomagranate.com
routes =
    t3-code
EOF

    cat > "$MOCK_DIR/op" <<'EOF'
#!/bin/sh
case "$*" in
    *"account id"*) printf '%s\n' aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa ;;
    *"Cloudflare Reader"*) printf '%s\n' reader-private ;;
    *"Cloudflare Token Minter"*) printf '%s\n' minter-private ;;
    *) exit 1 ;;
esac
EOF
    cat > "$MOCK_DIR/tailscale" <<'EOF'
#!/bin/sh
printf '%s\n' '{"Self":{"DNSName":"host.tailnet.ts.net.","TailscaleIPs":["100.64.0.7","fd7a:115c:a1e0::7"]}}'
EOF
    cat > "$MOCK_DIR/getent" <<'EOF'
#!/bin/sh
case "$1" in
    ahostsv4)
        printf '%s STREAM %s\n' 100.64.0.7 "$2"
        [ -z "${MOCK_RESOLVED_EXTRA:-}" ] || printf '%s STREAM %s\n' 100.64.0.99 "$2"
        ;;
    ahostsv6)
        printf '%s STREAM %s\n' fd7a:115c:a1e0::7 "$2"
        [ -z "${MOCK_RESOLVED_EXTRA:-}" ] || printf '%s STREAM %s\n' fd7a:115c:a1e0::99 "$2"
        ;;
    *) exit 1 ;;
esac
EOF
    cat > "$MOCK_DIR/sudo" <<'EOF'
#!/bin/sh
printf 'sudo %s\n' "$*" >> "$MOCK_LOG"
exit 99
EOF
cat > "$MOCK_DIR/curl" <<'EOF'
#!/bin/sh
printf 'curl-args %s\n' "$*" >> "$MOCK_LOG"
method=GET
explicit=false
output=
body=
url=
name=
type=
write_out=
response_code=200
while [ "$#" -gt 0 ]; do
    case "$1" in
        -X) method="$2"; explicit=true; shift ;;
        -o) output="$2"; shift ;;
        -w|--write-out) write_out="$2"; shift ;;
        --data)
            body="$2"
            $explicit || method=POST
            shift
            ;;
        --data-urlencode)
            case "$2" in name=*) name="${2#name=}" ;; type=*) type="${2#type=}" ;; esac
            shift
            ;;
        -H) shift ;;
        --get|-fsS) ;;
        http*) url="$1" ;;
    esac
    shift
done
printf '%s %s\n' "$method" "$url" >> "$MOCK_LOG"
case "$url" in
    */tokens/permission_groups)
        response='{"success":true,"result":[{"id":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","name":"DNS Write","scopes":["com.cloudflare.api.account.zone"]},{"id":"ffffffffffffffffffffffffffffffff","name":"Zone Read","scopes":["com.cloudflare.api.account.zone"]}]}'
        ;;
    */accounts/*/tokens/*)
        if [ "${MOCK_DELETE_MODE:-success}" = fail ]; then
            response_code=500
            response='{"success":false,"errors":[{"message":"temporary failure"}]}'
        elif [ "${MOCK_DELETE_MODE:-success}" = missing ]; then
            response_code=404
            response='{"success":false,"errors":[{"message":"not found"}]}'
        else
            response='{"success":true,"result":{}}'
        fi
        ;;
    */accounts/*/tokens)
        printf '%s' "$body" > "$MOCK_CF_BODY"
        response='{"success":true,"result":{"id":"cccccccccccccccccccccccccccccccc","value":"minted-dns-private"}}'
        ;;
    */zones)
        response='{"success":true,"result":[{"id":"dddddddddddddddddddddddddddddddd","name":"tomagranate.com","account":{"id":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}}]}'
        ;;
    */dns_records|*/dns_records/*)
        if [ "$method" != GET ]; then
            printf '%s' "$body" > "$MOCK_CF_BODY"
            response='{"success":true,"result":{"id":"eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee"}}'
        elif [ "${MOCK_DNS_MODE:-empty}" = duplicate ]; then
            response='{"success":true,"result":[{"id":"one"},{"id":"two"}]}'
        elif [ "${MOCK_DNS_MODE:-empty}" = empty ]; then
            response='{"success":true,"result":[]}'
        else
            if [ "$type" = A ]; then content=100.64.0.7; else content=fd7a:115c:a1e0::7; fi
            [ "${MOCK_DNS_MODE:-current}" = stale ] && content=100.64.0.99
            response="{\"success\":true,\"result\":[{\"id\":\"eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee\",\"name\":\"$name\",\"type\":\"$type\",\"content\":\"$content\",\"proxied\":false,\"ttl\":1}]}"
        fi
        ;;
    */zones/*)
        if [ "${MOCK_STORED_TOKEN_MODE:-current}" = invalid ]; then
            response='{"success":false,"errors":[{"message":"invalid token"}]}'
        else
            response='{"success":true,"result":{"id":"dddddddddddddddddddddddddddddddd","name":"tomagranate.com"}}'
        fi
        ;;
    *) exit 1 ;;
esac
if [ -n "$output" ]; then printf '%s\n' "$response" > "$output"; else printf '%s\n' "$response"; fi
[ -z "$write_out" ] || printf '%s' "$response_code"
EOF
    chmod +x "$MOCK_DIR/op" "$MOCK_DIR/tailscale" "$MOCK_DIR/getent" "$MOCK_DIR/sudo" "$MOCK_DIR/curl"
    printf '%s\n' ticket-private > "$TEST_ROOT/op-ticket"
}

teardown() {
    rm -rf "$TEST_ROOT" "$MOCK_DIR"
    rm -f "$TEST_CONF" "$MOCK_LOG" "$MOCK_CF_BODY"
}

route_helper() {
    run env \
        CADDY_CONFIG_DIR="$CADDY_CONFIG_DIR" \
        CADDY_APPS_DIR="$CADDY_APPS_DIR" \
        CADDY_ROUTE_MANIFEST="$CADDY_ROUTE_MANIFEST" \
        CADDY_ROUTE_LOCK="$CADDY_ROUTE_LOCK" \
        CADDY_EXPECTED_OWNER="$(id -un)" \
        CADDY_EXPECTED_GROUP="$(id -gn)" \
        SYSTEMCTL_BIN="$SYSTEMCTL_BIN" \
        TEST_ROOT="$TEST_ROOT" \
        MOCK_LOG="$MOCK_LOG" \
        "$PRIMER_DIR/modules/caddy/files/usr/local/libexec/primer-caddy-route" "$@"
}

run_caddy_function() {
    run zsh -c "
        export PRIMER_DIR='$PRIMER_DIR' DRY_RUN=false MOD_DIR='$PRIMER_DIR/modules/caddy'
        export MOD_NAME=caddy MOD_STATUS_FILE='$(mktemp)' MOD_ITEMS_FILE='$(mktemp)'
        export CADDY_TEST_ROOT=1 CADDY_ROOT_DIR='$TEST_ROOT' CADDY_MACHINE_NAME=tombook-linux
        export CADDY_ROUTE_HELPER='$PRIMER_DIR/modules/caddy/files/usr/local/libexec/primer-caddy-route'
        export CADDY_ROUTE_LOCK='$CADDY_ROUTE_LOCK'
        export PRIMER_OP_TICKET='$TEST_ROOT/op-ticket' PATH='$MOCK_DIR':\"\$PATH\"
        export MOCK_LOG='$MOCK_LOG' MOCK_CF_BODY='$MOCK_CF_BODY' MOCK_DNS_MODE='${MOCK_DNS_MODE:-empty}'
        export MOCK_RESOLVED_EXTRA='${MOCK_RESOLVED_EXTRA:-}'
        export MOCK_STORED_TOKEN_MODE='${MOCK_STORED_TOKEN_MODE:-current}'
        export MOCK_DELETE_MODE='${MOCK_DELETE_MODE:-success}'
        source '$PRIMER_DIR/lib/module.zsh'
        source '$PRIMER_DIR/tests/helpers/module-config.zsh'
        test::load_module_config '$TEST_CONF'
        source '$PRIMER_DIR/modules/caddy/module.zsh'
        $1
    "
}

@test "caddy: replaces a legacy token with a scoped per-machine token" {
    printf 'GATE_SECRET=gate-private\nCLOUDFLARE_API_TOKEN=dns-private\n' > "$TEST_ROOT/legacy.env"
    run_caddy_function _caddy::install_cloudflare_token
    assert_success
    refute_output --partial private
    [ "$(stat -c %a "$TEST_ROOT/etc/caddy/env.d/cloudflare.env")" = 600 ]
    grep -Fx 'CLOUDFLARE_API_TOKEN=minted-dns-private' "$TEST_ROOT/etc/caddy/env.d/cloudflare.env"
    grep -Fx 'CLOUDFLARE_API_TOKEN_ID=cccccccccccccccccccccccccccccccc' "$TEST_ROOT/etc/caddy/env.d/cloudflare.env"
    grep -Fx 'CLOUDFLARE_ZONE_ID=dddddddddddddddddddddddddddddddd' "$TEST_ROOT/etc/caddy/env.d/cloudflare.env"
    [ -s "$TEST_ROOT/etc/caddy/env.d/cloudflare.env.valid" ]
}

@test "caddy: mints one per-machine token with only zone DNS access" {
    run_caddy_function _caddy::install_cloudflare_token
    assert_success
    refute_output --partial private
    grep -Fx 'CLOUDFLARE_API_TOKEN=minted-dns-private' "$TEST_ROOT/etc/caddy/env.d/cloudflare.env"
    grep -Fx 'CLOUDFLARE_API_TOKEN_ID=cccccccccccccccccccccccccccccccc' "$TEST_ROOT/etc/caddy/env.d/cloudflare.env"
    jq -e '.name == "env-primer-caddy-tombook-linux-dns" and
        .policies == [{
          effect: "allow",
          resources: {"com.cloudflare.api.account.zone.dddddddddddddddddddddddddddddddd": "*"},
          permission_groups: [
            {id: "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb", name: "DNS Write"},
            {id: "ffffffffffffffffffffffffffffffff", name: "Zone Read"}
          ]
        }]' "$MOCK_CF_BODY"
    run grep -F private "$MOCK_LOG"
    assert_failure
}

@test "caddy: replaces a revoked stored Cloudflare token" {
    mkdir -p "$TEST_ROOT/etc/caddy/env.d"
    printf '%s\n' \
        'CLOUDFLARE_API_TOKEN=revoked-private' \
        'CLOUDFLARE_API_TOKEN_ID=old-token-id' \
        'CLOUDFLARE_ZONE_ID=dddddddddddddddddddddddddddddddd' \
        > "$TEST_ROOT/etc/caddy/env.d/cloudflare.env"
    export MOCK_STORED_TOKEN_MODE=invalid

    run_caddy_function _caddy::install_cloudflare_token

    assert_success
    grep -Fx 'CLOUDFLARE_API_TOKEN=minted-dns-private' "$TEST_ROOT/etc/caddy/env.d/cloudflare.env"
    grep -E '^DELETE.*/tokens/old-token-id$' "$MOCK_LOG"
}

@test "caddy: activates an externally replaced valid Cloudflare token" {
    mkdir -p "$TEST_ROOT/etc/caddy/env.d"
    printf '%s\n' \
        'CLOUDFLARE_API_TOKEN=old-private' \
        'CLOUDFLARE_API_TOKEN_ID=cccccccccccccccccccccccccccccccc' \
        'CLOUDFLARE_ZONE_ID=dddddddddddddddddddddddddddddddd' \
        > "$TEST_ROOT/etc/caddy/env.d/cloudflare.env"
    chmod 0600 "$TEST_ROOT/etc/caddy/env.d/cloudflare.env"
    run_caddy_function _caddy::record_cloudflare_validity
    assert_success

    sed -i 's/old-private/replacement-private/' "$TEST_ROOT/etc/caddy/env.d/cloudflare.env"
    run_caddy_function _caddy::install_cloudflare_token

    assert_success
    [ -f "$TEST_ROOT/var/lib/primer/caddy/gateway-restart-required" ]
    run_caddy_function _caddy::cloudflare_file_ready
    assert_success
}

@test "caddy: retries cleanup of a replaced Cloudflare token" {
    mkdir -p "$TEST_ROOT/etc/caddy/env.d"
    printf '%s\n' \
        'CLOUDFLARE_API_TOKEN=revoked-private' \
        'CLOUDFLARE_API_TOKEN_ID=old-token-id' \
        'CLOUDFLARE_ZONE_ID=dddddddddddddddddddddddddddddddd' \
        > "$TEST_ROOT/etc/caddy/env.d/cloudflare.env"
    export MOCK_STORED_TOKEN_MODE=invalid
    export MOCK_DELETE_MODE=fail

    run_caddy_function _caddy::install_cloudflare_token

    assert_failure
    [ "$(cat "$TEST_ROOT/var/lib/primer/caddy/cloudflare-token-cleanup")" = old-token-id ]
    grep -Fx 'CLOUDFLARE_API_TOKEN_ID=cccccccccccccccccccccccccccccccc' \
        "$TEST_ROOT/etc/caddy/env.d/cloudflare.env"
    run_caddy_function _caddy::cloudflare_file_ready
    assert_failure

    export MOCK_STORED_TOKEN_MODE=current
    export MOCK_DELETE_MODE=missing
    : > "$MOCK_LOG"
    run_caddy_function _caddy::install_cloudflare_token

    assert_success
    [ ! -e "$TEST_ROOT/var/lib/primer/caddy/cloudflare-token-cleanup" ]
    grep -E '^DELETE.*/tokens/old-token-id$' "$MOCK_LOG"
    run grep -E '^POST .*/tokens$' "$MOCK_LOG"
    assert_failure
}

@test "caddy: clears abandoned cleanup when the current token validates" {
    mkdir -p "$TEST_ROOT/etc/caddy/env.d" "$TEST_ROOT/var/lib/primer/caddy"
    printf '%s\n' \
        'CLOUDFLARE_API_TOKEN=current-private' \
        'CLOUDFLARE_API_TOKEN_ID=current-token-id' \
        'CLOUDFLARE_ZONE_ID=dddddddddddddddddddddddddddddddd' \
        > "$TEST_ROOT/etc/caddy/env.d/cloudflare.env"
    printf 'current-token-id\n' > "$TEST_ROOT/var/lib/primer/caddy/cloudflare-token-cleanup"

    run_caddy_function _caddy::install_cloudflare_token

    assert_success
    [ ! -e "$TEST_ROOT/var/lib/primer/caddy/cloudflare-token-cleanup" ]
    run grep -E '^(POST|DELETE) ' "$MOCK_LOG"
    assert_failure
}

@test "caddy: replaces a readable stored token without proven DNS Write access" {
    mkdir -p "$TEST_ROOT/etc/caddy/env.d"
    printf '%s\n' \
        'CLOUDFLARE_API_TOKEN=read-only-private' \
        'CLOUDFLARE_ZONE_ID=dddddddddddddddddddddddddddddddd' \
        > "$TEST_ROOT/etc/caddy/env.d/cloudflare.env"

    run_caddy_function _caddy::install_cloudflare_token

    assert_success
    grep -Fx 'CLOUDFLARE_API_TOKEN=minted-dns-private' "$TEST_ROOT/etc/caddy/env.d/cloudflare.env"
    grep -Fx 'CLOUDFLARE_API_TOKEN_ID=cccccccccccccccccccccccccccccccc' "$TEST_ROOT/etc/caddy/env.d/cloudflare.env"
    refute_output --partial private
}

@test "caddy: restarts the gateway after replacing its token" {
    mkdir -p "$TEST_ROOT/etc/caddy/env.d"
    printf '%s\n' \
        'CLOUDFLARE_API_TOKEN=read-only-private' \
        'CLOUDFLARE_ZONE_ID=dddddddddddddddddddddddddddddddd' \
        > "$TEST_ROOT/etc/caddy/env.d/cloudflare.env"

    run_caddy_function '_caddy::install_cloudflare_token && _caddy::restart_pending gateway && _caddy::activate_gateway true'

    assert_success
    grep -Fx 'systemctl restart caddy.service' "$MOCK_LOG"
    run grep -Fx 'systemctl reload caddy.service' "$MOCK_LOG"
    assert_failure
}

@test "caddy: restart requirements survive failed update processes" {
    run_caddy_function '_caddy::mark_restart gateway && _caddy::mark_restart tailscale'
    assert_success

    run_caddy_function '_caddy::restart_pending gateway && _caddy::restart_pending tailscale'
    assert_success

    run_caddy_function '_caddy::clear_restart gateway && _caddy::clear_restart tailscale'
    assert_success
    run_caddy_function '_caddy::restart_pending gateway || _caddy::restart_pending tailscale'
    assert_failure
}

@test "caddy: marks a changed base Caddyfile before deployment" {
    mkdir -p "$TEST_ROOT/etc/caddy" "$TEST_ROOT/etc/systemd/system"
    printf 'old base configuration\n' > "$TEST_ROOT/etc/caddy/Caddyfile"
    cp "$PRIMER_DIR/modules/caddy/files/etc/systemd/system/caddy.service" \
        "$TEST_ROOT/etc/systemd/system/caddy.service"

    run_caddy_function '_caddy::custom_binary_ready() { return 0; }; _caddy::install_binary() { return 0; }; _caddy::ensure_user() { return 0; }; _caddy::deploy() { return 1; }; mod_update'

    assert_failure
    [ -f "$TEST_ROOT/var/lib/primer/caddy/gateway-restart-required" ]
}

@test "caddy: tailnet changes preserve a gateway restart requirement" {
    mkdir -p "$TEST_ROOT/usr/local/libexec"
    cat > "$TEST_ROOT/usr/local/libexec/primer-caddy-tailnet" <<'EOF'
#!/bin/sh
mkdir -p "$TEST_ROOT/etc/caddy" "$TEST_ROOT/run/caddy"
printf 'new binding\n' > "$TEST_ROOT/etc/caddy/tailnet.caddy"
printf 'TAILSCALE_HOSTNAME=new.example.ts.net\n' > "$TEST_ROOT/run/caddy/tailnet.env"
EOF
    chmod +x "$TEST_ROOT/usr/local/libexec/primer-caddy-tailnet"

    run_caddy_function '_caddy::tailnet_ready() { return 1; }; _caddy::refresh_tailnet'

    assert_success
    [ -f "$TEST_ROOT/var/lib/primer/caddy/gateway-restart-required" ]
}

@test "caddy: unchanged tailnet bindings preserve only prior restart requirements" {
    mkdir -p "$TEST_ROOT/usr/local/libexec"
    printf '#!/bin/sh\n' > "$TEST_ROOT/usr/local/libexec/primer-caddy-tailnet"
    chmod +x "$TEST_ROOT/usr/local/libexec/primer-caddy-tailnet"

    run_caddy_function _caddy::refresh_tailnet
    assert_success
    [ ! -e "$TEST_ROOT/var/lib/primer/caddy/gateway-restart-required" ]

    run_caddy_function '_caddy::mark_restart gateway && _caddy::refresh_tailnet'
    assert_success
    [ -f "$TEST_ROOT/var/lib/primer/caddy/gateway-restart-required" ]
}

@test "caddy: creates DNS-only A and AAAA records for each private host" {
    mkdir -p "$TEST_ROOT/etc/caddy/env.d"
    printf '%s\n' \
        'CLOUDFLARE_API_TOKEN=dns-private' \
        'CLOUDFLARE_ZONE_ID=dddddddddddddddddddddddddddddddd' \
        > "$TEST_ROOT/etc/caddy/env.d/cloudflare.env"

    run_caddy_function _caddy::reconcile_dns

    assert_success
    [ "$(grep -c 'POST.*/dns_records$' "$MOCK_LOG")" -eq 2 ]
    refute_output --partial private
}

@test "caddy: updates stale records and accepts current records" {
    mkdir -p "$TEST_ROOT/etc/caddy/env.d"
    printf '%s\n' \
        'CLOUDFLARE_API_TOKEN=dns-private' \
        'CLOUDFLARE_ZONE_ID=dddddddddddddddddddddddddddddddd' \
        > "$TEST_ROOT/etc/caddy/env.d/cloudflare.env"
    export MOCK_DNS_MODE=stale
    run_caddy_function _caddy::reconcile_dns
    assert_success
    [ "$(grep -c '^PATCH.*/dns_records/' "$MOCK_LOG")" -eq 2 ]

    : > "$MOCK_LOG"
    export MOCK_DNS_MODE=current
    run_caddy_function _caddy::dns_ready
    assert_success
    run grep -E 'POST|PATCH' "$MOCK_LOG"
    assert_failure
}

@test "caddy: refuses to overwrite duplicate DNS records" {
    mkdir -p "$TEST_ROOT/etc/caddy/env.d"
    printf '%s\n' \
        'CLOUDFLARE_API_TOKEN=dns-private' \
        'CLOUDFLARE_ZONE_ID=dddddddddddddddddddddddddddddddd' \
        > "$TEST_ROOT/etc/caddy/env.d/cloudflare.env"
    export MOCK_DNS_MODE=duplicate

    run_caddy_function _caddy::reconcile_dns

    assert_failure
    assert_output --partial "duplicate A records"
    run grep -E 'POST|PATCH' "$MOCK_LOG"
    assert_failure
}

@test "caddy: DNS status rejects extra resolved addresses" {
    run_caddy_function _caddy::dns_resolves
    assert_success

    export MOCK_RESOLVED_EXTRA=1
    run_caddy_function _caddy::dns_resolves
    assert_failure
}

@test "caddy: dry-run plans the custom binary, service, and routes" {
    run zsh -c "
        export PRIMER_DIR='$PRIMER_DIR' DRY_RUN=true MOD_DIR='$PRIMER_DIR/modules/caddy'
        export MOD_NAME=caddy MOD_STATUS_FILE='$(mktemp)' MOD_ITEMS_FILE='$(mktemp)'
        export CADDY_MACHINE_NAME=tombook-linux
        source '$PRIMER_DIR/lib/module.zsh'
        source '$PRIMER_DIR/tests/helpers/module-config.zsh'
        test::load_module_config '$TEST_CONF'
        source '$PRIMER_DIR/modules/caddy/module.zsh'
        mod_update
    "
    assert_success
    assert_output --partial "build custom Caddy v2.11.4"
    assert_output --partial "validate caddy-validate.service before reload"
    assert_output --partial "reconcile Primer routes: t3-code"
}

@test "caddy: status detects definition drift without requiring sudo" {
    for path in \
        /etc/caddy/Caddyfile \
        /etc/systemd/system/caddy.service \
        /etc/systemd/system/caddy-validate.service \
        /etc/systemd/system/tailscaled.service.d/primer-caddy.conf \
        /usr/local/libexec/primer-caddy-tailnet \
        /usr/local/libexec/primer-caddy-route \
        /usr/local/libexec/primer-caddy-fragment; do
        mkdir -p "$TEST_ROOT${path%/*}"
        cp "$PRIMER_DIR/modules/caddy/files$path" "$TEST_ROOT$path"
    done
    mkdir -p \
        "$TEST_ROOT/etc/caddy/apps.d" \
        "$TEST_ROOT/usr/local/bin" \
        "$TEST_ROOT/var/lib/primer/caddy"
    cat > "$TEST_ROOT/usr/local/bin/caddy" <<'EOF'
#!/bin/sh
case "$1" in
    version) printf '%s\n' 'v2.11.4' ;;
    list-modules) printf '%s\n' dns.providers.cloudflare tls.get_certificate.tailscale ;;
    *) exit 1 ;;
esac
EOF
    chmod +x "$TEST_ROOT/usr/local/bin/caddy"
    printf 't3-code\n' > "$TEST_ROOT/etc/caddy/primer-routes"
    printf 'route\n' > "$TEST_ROOT/etc/caddy/apps.d/t3-code.caddy"
    mkdir -p "$TEST_ROOT/etc/caddy/env.d"
    printf '%s\n' \
        'CLOUDFLARE_API_TOKEN=dns-private' \
        'CLOUDFLARE_API_TOKEN_ID=cccccccccccccccccccccccccccccccc' \
        'CLOUDFLARE_ZONE_ID=dddddddddddddddddddddddddddddddd' \
        > "$TEST_ROOT/etc/caddy/env.d/cloudflare.env"
    chmod 0600 "$TEST_ROOT/etc/caddy/env.d/cloudflare.env"
    run_caddy_function _caddy::record_cloudflare_validity
    assert_success
    CADDY_CONFIG_DIR="$TEST_ROOT/etc/caddy" \
    CADDY_RUNTIME_DIR="$TEST_ROOT/run/caddy" \
    TAILSCALE_BIN="$MOCK_DIR/tailscale" \
        "$TEST_ROOT/usr/local/libexec/primer-caddy-tailnet"

    run_caddy_function mod_status
    assert_success
    run grep -F 'sudo ' "$MOCK_LOG"
    assert_failure

    fingerprint="$(head -1 "$TEST_ROOT/etc/caddy/env.d/cloudflare.env.valid")"
    printf '%s\n0\n' "$fingerprint" > "$TEST_ROOT/etc/caddy/env.d/cloudflare.env.valid"
    run_caddy_function mod_status
    assert_failure
    run_caddy_function _caddy::record_cloudflare_validity
    assert_success

    printf 'stale-addon\n' >> "$TEST_ROOT/etc/caddy/primer-routes"
    printf 'stale route\n' > "$TEST_ROOT/etc/caddy/apps.d/stale-addon.caddy"
    run_caddy_function mod_status
    assert_failure
    printf 't3-code\n' > "$TEST_ROOT/etc/caddy/primer-routes"

    chmod 0666 "$TEST_ROOT/etc/caddy/primer-routes"
    run_caddy_function mod_status
    assert_failure
    chmod 0644 "$TEST_ROOT/etc/caddy/primer-routes"

    chmod 0644 "$TEST_ROOT/etc/caddy/env.d/cloudflare.env"
    run_caddy_function mod_status
    assert_failure
    chmod 0600 "$TEST_ROOT/etc/caddy/env.d/cloudflare.env"

    printf 'CORRUPTED=1\n' >> "$TEST_ROOT/etc/caddy/env.d/cloudflare.env"
    run_caddy_function mod_status
    assert_failure
    sed -i '$d' "$TEST_ROOT/etc/caddy/env.d/cloudflare.env"
    run_caddy_function _caddy::record_cloudflare_validity
    assert_success

    printf 'TAILSCALE_HOSTNAME=old.tailnet.ts.net\n' > "$TEST_ROOT/run/caddy/tailnet.env"
    run_caddy_function mod_status
    assert_failure
    printf 'TAILSCALE_HOSTNAME=host.tailnet.ts.net\n' > "$TEST_ROOT/run/caddy/tailnet.env"

    chmod 0664 "$TEST_ROOT/etc/caddy/tailnet.caddy"
    run_caddy_function mod_status
    assert_failure
    chmod 0644 "$TEST_ROOT/etc/caddy/tailnet.caddy"

    chmod 0775 "$TEST_ROOT/etc/caddy/apps.d"
    run_caddy_function mod_status
    assert_failure
    chmod 0755 "$TEST_ROOT/etc/caddy/apps.d"

    chmod 0775 "$TEST_ROOT/usr/local/libexec/primer-caddy-tailnet"
    run_caddy_function mod_status
    assert_failure
    chmod 0755 "$TEST_ROOT/usr/local/libexec/primer-caddy-tailnet"

    printf 'drift\n' >> "$TEST_ROOT/etc/systemd/system/caddy.service"
    run_caddy_function mod_status
    assert_failure
}

@test "caddy: installs a valid route and records ownership" {
    printf 'http://example.test { respond "ok" }\n' > "$TEST_ROOT/route"
    route_helper install example "$TEST_ROOT/route"
    assert_success
    cmp -s "$TEST_ROOT/route" "$CADDY_APPS_DIR/example.caddy"
    grep -Fx example "$CADDY_ROUTE_MANIFEST"
    grep -Fx "systemctl reload caddy.service" "$MOCK_LOG"
}

@test "caddy: repeat install validates and reloads an owned route" {
    printf 'http://example.test { respond "ok" }\n' > "$TEST_ROOT/route"
    route_helper install example "$TEST_ROOT/route"
    assert_success
    chmod 0666 "$CADDY_APPS_DIR/example.caddy"
    route_helper status example "$TEST_ROOT/route"
    assert_failure
    route_helper install example "$TEST_ROOT/route"
    assert_success
    [ "$(stat -c %a "$CADDY_APPS_DIR/example.caddy")" = 644 ]
    route_helper status example "$TEST_ROOT/route"
    assert_success
    [ "$(grep -c 'systemctl start --wait caddy-validate.service' "$MOCK_LOG")" -eq 2 ]
    [ "$(grep -c 'systemctl reload caddy.service' "$MOCK_LOG")" -eq 2 ]
}

@test "caddy: identical unowned route validates and reloads before restoring ownership" {
    printf 'http://example.test { respond "ok" }\n' > "$TEST_ROOT/route"
    cp "$TEST_ROOT/route" "$CADDY_APPS_DIR/example.caddy"

    route_helper install example "$TEST_ROOT/route"

    assert_success
    grep -Fx example "$CADDY_ROUTE_MANIFEST"
    grep -Fx "systemctl start --wait caddy-validate.service" "$MOCK_LOG"
    grep -Fx "systemctl reload caddy.service" "$MOCK_LOG"
}

@test "caddy: stages a route without reloading the inactive gateway" {
    printf 'http://example.test { respond "ok" }\n' > "$TEST_ROOT/route"
    run_caddy_function "_caddy::stage_route example '$TEST_ROOT/route'"
    assert_success
    cmp -s "$TEST_ROOT/route" "$CADDY_APPS_DIR/example.caddy"
    grep -Fx example "$CADDY_ROUTE_MANIFEST"
    [ -f "$TEST_ROOT/var/lib/primer/caddy/gateway-restart-required" ]
    run grep -F "systemctl reload caddy.service" "$MOCK_LOG"
    assert_failure
}

@test "caddy: route status compares the generated and installed fragments" {
    printf 'http://example.test { respond "current" }\n' > "$TEST_ROOT/route"
    route_helper install example "$TEST_ROOT/route"
    assert_success

    route_helper status example "$TEST_ROOT/route"
    assert_success

    printf 'http://example.test { respond "changed" }\n' > "$TEST_ROOT/changed-route"
    route_helper status example "$TEST_ROOT/changed-route"
    assert_failure
}

@test "caddy: invalid replacement restores the last valid route without reload" {
    printf 'http://example.test { respond "ok" }\n' > "$TEST_ROOT/good"
    route_helper install example "$TEST_ROOT/good"
    assert_success
    printf 'INVALID\n' > "$TEST_ROOT/bad"
    route_helper install example "$TEST_ROOT/bad"
    assert_failure
    cmp -s "$TEST_ROOT/good" "$CADDY_APPS_DIR/example.caddy"
    [ "$(grep -c 'systemctl reload caddy.service' "$MOCK_LOG")" -eq 1 ]
}

@test "caddy: install reload failure restores the prior route and ownership" {
    printf 'old\n' > "$CADDY_APPS_DIR/example.caddy"
    printf 'example\nkeep\n' > "$CADDY_ROUTE_MANIFEST"
    printf 'new\n' > "$TEST_ROOT/route"
    touch "$TEST_ROOT/reject-reload"
    route_helper install example "$TEST_ROOT/route"
    assert_failure
    assert_output --partial "route reload failed; restored prior config"
    [ "$(cat "$CADDY_APPS_DIR/example.caddy")" = old ]
    [ "$(cat "$CADDY_ROUTE_MANIFEST")" = $'example\nkeep' ]
    [ "$(grep -c 'systemctl reload caddy.service' "$MOCK_LOG")" -eq 2 ]
}

@test "caddy: reconciliation removes only stale Primer-owned routes" {
    printf 'a\n' > "$CADDY_APPS_DIR/old.caddy"
    printf 'b\n' > "$CADDY_APPS_DIR/keep.caddy"
    printf 'u\n' > "$CADDY_APPS_DIR/unmanaged.caddy"
    printf 'old\nkeep\n' > "$CADDY_ROUTE_MANIFEST"
    route_helper reconcile keep
    assert_success
    [ ! -e "$CADDY_APPS_DIR/old.caddy" ]
    [ -e "$CADDY_APPS_DIR/keep.caddy" ]
    [ -e "$CADDY_APPS_DIR/unmanaged.caddy" ]
    [ "$(cat "$CADDY_ROUTE_MANIFEST")" = keep ]
}

@test "caddy: refuses to reconcile an unsafe route manifest" {
    printf 'old\n' > "$CADDY_APPS_DIR/old.caddy"
    printf 'old\n' > "$CADDY_ROUTE_MANIFEST"
    chmod 0666 "$CADDY_ROUTE_MANIFEST"

    route_helper reconcile

    assert_failure
    assert_output --partial "route manifest has unsafe ownership or permissions"
    [ -e "$CADDY_APPS_DIR/old.caddy" ]
    [ "$(cat "$CADDY_ROUTE_MANIFEST")" = old ]
}

@test "caddy: rejects unsafe route names" {
    printf 'ok\n' > "$TEST_ROOT/route"
    route_helper install ../escape "$TEST_ROOT/route"
    assert_failure
    assert_output --partial "invalid route name"
}

@test "caddy: failed cleanup validation restores removed routes and ownership" {
    printf 'old\n' > "$CADDY_APPS_DIR/old.caddy"
    printf 'keep\n' > "$CADDY_APPS_DIR/keep.caddy"
    printf 'old\nkeep\n' > "$CADDY_ROUTE_MANIFEST"
    touch "$TEST_ROOT/reject"
    route_helper reconcile keep
    assert_failure
    [ -e "$CADDY_APPS_DIR/old.caddy" ]
    [ "$(cat "$CADDY_ROUTE_MANIFEST")" = $'old\nkeep' ]
}

@test "caddy: cleanup reload failure restores removed routes and ownership" {
    printf 'old\n' > "$CADDY_APPS_DIR/old.caddy"
    printf 'keep\n' > "$CADDY_APPS_DIR/keep.caddy"
    printf 'old\nkeep\n' > "$CADDY_ROUTE_MANIFEST"
    touch "$TEST_ROOT/reject-reload"
    route_helper reconcile keep
    assert_failure
    assert_output --partial "route cleanup reload failed; restored prior config"
    [ "$(cat "$CADDY_APPS_DIR/old.caddy")" = old ]
    [ "$(cat "$CADDY_ROUTE_MANIFEST")" = $'old\nkeep' ]
    [ "$(grep -c 'systemctl reload caddy.service' "$MOCK_LOG")" -eq 2 ]
}

@test "caddy: refuses Plans migration when the addon is not selected" {
    cat > "$MOCK_DIR/tailscale" <<'EOF'
#!/bin/sh
printf 'tailscale %s\n' "$*" >> "$MOCK_LOG"
exit 0
EOF
    chmod +x "$MOCK_DIR/tailscale"
    run_caddy_function _caddy::migrate_listeners
    assert_failure
    assert_output --partial "plans-media addon is not selected"
    run grep -F "disable --now plans.service" "$MOCK_LOG"
    assert_failure
    run grep -F "tailscale serve" "$MOCK_LOG"
    assert_failure
}

@test "caddy: migrates Plans when the addon is selected" {
    cat >> "$TEST_CONF" <<'EOF'
    plans-media
EOF
cat > "$MOCK_DIR/tailscale" <<'EOF'
#!/bin/sh
printf 'tailscale %s\n' "$*" >> "$MOCK_LOG"
case "$*" in
    "serve status --json") printf '%s\n' '{"TCP":{"443":{"HTTPS":true}},"Web":{"host:443":{"Handlers":{"/":{"Proxy":"http://127.0.0.1:3773"}}}}}' ;;
esac
exit 0
EOF
    chmod +x "$MOCK_DIR/tailscale"
    run_caddy_function _caddy::migrate_listeners
    assert_success
    grep -F "tailscale serve --https=443 off" "$MOCK_LOG"
    grep -F "systemctl disable --now plans.service" "$MOCK_LOG"
}

@test "caddy: refuses to replace a customized Plans service" {
    cat >> "$TEST_CONF" <<'EOF'
    plans-media
EOF
    printf 'custom listener\n' > "$CADDY_CONFIG_DIR/plans.Caddyfile"

    run_caddy_function _caddy::migrate_listeners

    assert_failure
    assert_output --partial "will not replace a customized service"
    run grep -F "systemctl disable --now plans.service" "$MOCK_LOG"
    assert_failure
}

@test "caddy: refuses a Plans service with extra lifecycle commands" {
    cat >> "$TEST_CONF" <<'EOF'
    plans-media
EOF
    touch "$TEST_ROOT/plans-extra-command"

    run_caddy_function _caddy::migrate_listeners

    assert_failure
    assert_output --partial "will not replace a customized service"
    run grep -F "systemctl disable --now plans.service" "$MOCK_LOG"
    assert_failure
}

@test "caddy: refuses to replace an unrelated Tailscale Serve target" {
    touch "$TEST_ROOT/plans-disabled"
    cat > "$MOCK_DIR/tailscale" <<'EOF'
#!/bin/sh
printf 'tailscale %s\n' "$*" >> "$MOCK_LOG"
case "$*" in
    "serve status --json") printf '%s\n' '{"TCP":{"443":{"HTTPS":true}},"Web":{"host:443":{"Handlers":{"/":{"Proxy":"http://127.0.0.1:9999"}}}}}' ;;
esac
exit 0
EOF
    chmod +x "$MOCK_DIR/tailscale"

    run_caddy_function _caddy::check_listener_migration

    assert_failure
    assert_output --partial "will not replace an unrelated listener"
    run grep -F "tailscale serve --https=443 off" "$MOCK_LOG"
    assert_failure
}

@test "caddy: refuses to replace a Tailscale Serve listener with extra handlers" {
    touch "$TEST_ROOT/plans-disabled"
    cat > "$MOCK_DIR/tailscale" <<'EOF'
#!/bin/sh
printf 'tailscale %s\n' "$*" >> "$MOCK_LOG"
case "$*" in
    "serve status --json") printf '%s\n' '{"TCP":{"443":{"HTTPS":true}},"Web":{"host:443":{"Handlers":{"/":{"Proxy":"http://127.0.0.1:3773"},"/other":{"Proxy":"http://127.0.0.1:9999"}}}}}' ;;
esac
exit 0
EOF
    chmod +x "$MOCK_DIR/tailscale"

    run_caddy_function _caddy::check_listener_migration

    assert_failure
    assert_output --partial "will not replace an unrelated listener"
    run grep -F "tailscale serve --https=443 off" "$MOCK_LOG"
    assert_failure
}

@test "caddy: failed activation restores legacy listeners" {
    cat >> "$TEST_CONF" <<'EOF'
    plans-media
EOF
    touch "$TEST_ROOT/reject-activation"
    cat > "$MOCK_DIR/tailscale" <<'EOF'
#!/bin/sh
printf 'tailscale %s\n' "$*" >> "$MOCK_LOG"
case "$*" in
    "serve status --json") printf '%s\n' '{"TCP":{"443":{"HTTPS":true}},"Web":{"host:443":{"Handlers":{"/":{"Proxy":"http://127.0.0.1:3773"}}}}}' ;;
esac
exit 0
EOF
    chmod +x "$MOCK_DIR/tailscale"

    run_caddy_function '_caddy::activate_gateway_with_rollback true'

    assert_failure
    grep -F "tailscale serve --https=443 off" "$MOCK_LOG"
    grep -F "systemctl disable --now plans.service" "$MOCK_LOG"
    grep -F "systemctl enable plans.service" "$MOCK_LOG"
    grep -F "systemctl start plans.service" "$MOCK_LOG"
    grep -F "tailscale serve --bg --https=443 http://127.0.0.1:3773" "$MOCK_LOG"
}

@test "caddy: partial Plans disable failure restores its prior state" {
    cat >> "$TEST_CONF" <<'EOF'
    plans-media
EOF
    touch "$TEST_ROOT/reject-plans-stop"
    cat > "$MOCK_DIR/tailscale" <<'EOF'
#!/bin/sh
printf '%s\n' '{}'
EOF
    chmod +x "$MOCK_DIR/tailscale"

    run_caddy_function _caddy::migrate_listeners

    assert_failure
    grep -F "systemctl disable --now plans.service" "$MOCK_LOG"
    grep -F "systemctl enable plans.service" "$MOCK_LOG"
    grep -F "systemctl start plans.service" "$MOCK_LOG"
}

@test "caddy: stages matching T3 and Plans routes before migration" {
    cat >> "$TEST_CONF" <<'EOF'
    plans-media
migrate_plans_route = plans-media
migrate_plans_host = plans.tomagranate.com
migrate_plans_worker_host = agents-infra.sunburst-d5c.workers.dev
EOF
    printf 'GATE_SECRET=gate-private\n' > "$TEST_ROOT/legacy.env"
    cat > "$MOCK_DIR/tailscale" <<'EOF'
#!/bin/sh
case "$*" in
    "serve status --json") printf '%s\n' '{"TCP":{"443":{"HTTPS":true}},"Web":{"host:443":{"Handlers":{"/":{"Proxy":"http://127.0.0.1:3773"}}}}}' ;;
esac
exit 0
EOF
    chmod +x "$MOCK_DIR/tailscale"

    run_caddy_function _caddy::stage_migration_routes

    assert_success
    grep -F "reverse_proxy http://127.0.0.1:3773" "$TEST_ROOT/etc/caddy/apps.d/t3-code.caddy"
    grep -F "reverse_proxy https://agents-infra.sunburst-d5c.workers.dev" \
        "$TEST_ROOT/etc/caddy/apps.d/plans-media.caddy"
    [ "$(stat -c %a "$TEST_ROOT/etc/caddy/env.d/plans-media.env")" = 600 ]
    grep -Fx 'GATE_SECRET=gate-private' "$TEST_ROOT/etc/caddy/env.d/plans-media.env"
    [ "$(grep -c 'systemctl reload caddy.service' "$MOCK_LOG")" -eq 0 ]
}

@test "caddy: preserves legacy Plans secret quoting during migration" {
    cat >> "$TEST_CONF" <<'EOF'
    plans-media
migrate_plans_route = plans-media
migrate_plans_host = plans.tomagranate.com
migrate_plans_worker_host = agents-infra.sunburst-d5c.workers.dev
EOF
    printf 'GATE_SECRET="gate-private"\n' > "$TEST_ROOT/legacy.env"

    run_caddy_function _caddy::stage_migration_routes

    assert_success
    grep -Fx 'GATE_SECRET="gate-private"' "$TEST_ROOT/etc/caddy/env.d/plans-media.env"
}

@test "caddy: replaces stale managed Plans credentials before migration" {
    cat >> "$TEST_CONF" <<'EOF'
    plans-media
migrate_plans_route = plans-media
migrate_plans_host = plans.tomagranate.com
migrate_plans_worker_host = agents-infra.sunburst-d5c.workers.dev
EOF
    mkdir -p "$TEST_ROOT/etc/caddy/env.d"
    printf 'GATE_SECRET=""\n' > "$TEST_ROOT/etc/caddy/env.d/plans-media.env"
    chmod 0600 "$TEST_ROOT/etc/caddy/env.d/plans-media.env"
    stat -c '%d:%i:%s:%Y' "$TEST_ROOT/etc/caddy/env.d/plans-media.env" \
        > "$TEST_ROOT/etc/caddy/env.d/plans-media.env.valid"
    printf 'GATE_SECRET=gate-private\n' > "$TEST_ROOT/legacy.env"

    run_caddy_function _caddy::stage_migration_routes

    assert_success
    grep -Fx 'GATE_SECRET=gate-private' "$TEST_ROOT/etc/caddy/env.d/plans-media.env"
}

@test "caddy: rollback preserves a gateway that was already active" {
    cat >> "$TEST_CONF" <<'EOF'
    plans-media
migrate_plans_route = plans-media
migrate_plans_host = plans.tomagranate.com
migrate_plans_worker_host = agents-infra.sunburst-d5c.workers.dev
EOF
    printf 'GATE_SECRET=gate-private\n' > "$TEST_ROOT/legacy.env"
    printf 'old\n' > "$CADDY_APPS_DIR/old.caddy"
    printf 'old Plans route\n' > "$CADDY_APPS_DIR/plans-media.caddy"
    printf 'old\nplans-media\n' > "$CADDY_ROUTE_MANIFEST"
    cat > "$MOCK_DIR/tailscale" <<'EOF'
#!/bin/sh
printf '%s\n' '{}'
EOF
    chmod +x "$MOCK_DIR/tailscale"

    run_caddy_function '_caddy::snapshot_migration_routes && _caddy::stage_migration_routes && _caddy::activate_gateway_with_rollback false && touch "$TEST_ROOT/reject" && _caddy::reconcile_routes_with_rollback'

    assert_failure
    [ "$(cat "$CADDY_APPS_DIR/plans-media.caddy")" = 'old Plans route' ]
    grep -F "systemctl reload caddy.service" "$MOCK_LOG"
    grep -F "systemctl enable caddy.service" "$MOCK_LOG"
    run grep -F "systemctl disable --now caddy.service" "$MOCK_LOG"
    assert_failure
    grep -F "systemctl enable plans.service" "$MOCK_LOG"
    grep -F "systemctl start plans.service" "$MOCK_LOG"
    [ "$(grep -n 'systemctl reload caddy.service' "$MOCK_LOG" | tail -1 | cut -d: -f1)" -lt \
        "$(grep -n 'systemctl start plans.service' "$MOCK_LOG" | tail -1 | cut -d: -f1)" ]
}

@test "caddy: route reconciliation rollback stops Caddy before restoring listeners" {
    printf 'old\n' > "$CADDY_APPS_DIR/old.caddy"
    printf 'old\n' > "$CADDY_ROUTE_MANIFEST"
    touch "$TEST_ROOT/reject"
    cat > "$MOCK_DIR/tailscale" <<'EOF'
#!/bin/sh
printf 'tailscale %s\n' "$*" >> "$MOCK_LOG"
exit 0
EOF
    chmod +x "$MOCK_DIR/tailscale"

    run_caddy_function '_CADDY_MIGRATED_SERVE=true; _CADDY_MIGRATED_PLANS=true; _CADDY_PLANS_WAS_ACTIVE=true; _CADDY_PLANS_WAS_ENABLED=true; _CADDY_GATEWAY_WAS_ACTIVE=false; _CADDY_GATEWAY_WAS_ENABLED=false; _caddy::reconcile_routes_with_rollback'

    assert_failure
    grep -F "systemctl stop caddy.service" "$MOCK_LOG"
    grep -F "systemctl disable caddy.service" "$MOCK_LOG"
    grep -F "systemctl enable plans.service" "$MOCK_LOG"
    grep -F "systemctl start plans.service" "$MOCK_LOG"
    grep -F "tailscale serve --bg --https=443 http://127.0.0.1:3773" "$MOCK_LOG"
}

@test "caddy: final health failure rolls back migrated listeners" {
    touch "$TEST_ROOT/reject-health"
    cat > "$MOCK_DIR/tailscale" <<'EOF'
#!/bin/sh
printf 'tailscale %s\n' "$*" >> "$MOCK_LOG"
exit 0
EOF
    chmod +x "$MOCK_DIR/tailscale"

    run_caddy_function '_CADDY_MIGRATED_SERVE=true; _CADDY_MIGRATED_PLANS=true; _CADDY_PLANS_WAS_ACTIVE=true; _CADDY_PLANS_WAS_ENABLED=true; _CADDY_GATEWAY_WAS_ACTIVE=false; _CADDY_GATEWAY_WAS_ENABLED=false; _caddy::verify_gateway_with_rollback'

    assert_failure
    grep -F "systemctl stop caddy.service" "$MOCK_LOG"
    grep -F "systemctl disable caddy.service" "$MOCK_LOG"
    grep -F "systemctl enable plans.service" "$MOCK_LOG"
    grep -F "systemctl start plans.service" "$MOCK_LOG"
    grep -F "tailscale serve --bg --https=443 http://127.0.0.1:3773" "$MOCK_LOG"
}

@test "caddy: service permits its generator to update /etc/caddy" {
    grep -Fx "ReadWritePaths=/etc/caddy" \
        "$PRIMER_DIR/modules/caddy/files/etc/systemd/system/caddy.service"
    grep -Fx $'\tadmin unix//run/caddy/admin.sock' \
        "$PRIMER_DIR/modules/caddy/files/etc/caddy/Caddyfile"
    grep -Fx "ExecReload=/usr/local/bin/caddy reload --config /etc/caddy/Caddyfile --address unix//run/caddy/admin.sock --force" \
        "$PRIMER_DIR/modules/caddy/files/etc/systemd/system/caddy.service"
    grep -Fx "RuntimeDirectoryMode=0755" \
        "$PRIMER_DIR/modules/caddy/files/etc/systemd/system/caddy.service"
    grep -Fx "UMask=0077" \
        "$PRIMER_DIR/modules/caddy/files/etc/systemd/system/caddy.service"
}

@test "caddy: production route locking uses the helper's protected default" {
    run grep -F "/tmp/primer-caddy-route.lock" "$PRIMER_DIR/modules/caddy/module.zsh"
    assert_failure
    grep -F '/run/lock/primer-caddy-route.lock' \
        "$PRIMER_DIR/modules/caddy/files/usr/local/libexec/primer-caddy-route"
}

@test "caddy: a present but disabled Plans unit does not require the addon" {
    touch "$TEST_ROOT/plans-disabled"
    cat > "$MOCK_DIR/tailscale" <<'EOF'
#!/bin/sh
printf 'tailscale %s\n' "$*" >> "$MOCK_LOG"
exit 0
EOF
    chmod +x "$MOCK_DIR/tailscale"
    run zsh -c "
        export PRIMER_DIR='$PRIMER_DIR' DRY_RUN=false MOD_DIR='$PRIMER_DIR/modules/caddy'
        export MOD_NAME=caddy MOD_STATUS_FILE='$(mktemp)' MOD_ITEMS_FILE='$(mktemp)'
        export CADDY_TEST_ROOT=1 PATH='$MOCK_DIR':\"\$PATH\" MOCK_LOG='$MOCK_LOG' TEST_ROOT='$TEST_ROOT'
        source '$PRIMER_DIR/lib/module.zsh'
        source '$PRIMER_DIR/tests/helpers/module-config.zsh'
        test::load_module_config '$TEST_CONF'
        source '$PRIMER_DIR/modules/caddy/module.zsh'
        _caddy::migrate_listeners
    "
    assert_success
    run grep -F "systemctl disable --now plans.service" "$MOCK_LOG"
    assert_failure
}

@test "caddy: does not migrate a selected but already disabled Plans unit" {
    cat >> "$TEST_CONF" <<'EOF'
    plans-media
EOF
    touch "$TEST_ROOT/plans-disabled"
    cat > "$MOCK_DIR/tailscale" <<'EOF'
#!/bin/sh
printf 'tailscale %s\n' "$*" >> "$MOCK_LOG"
exit 0
EOF
    chmod +x "$MOCK_DIR/tailscale"

    run_caddy_function _caddy::migrate_listeners

    assert_success
    run grep -F "systemctl disable --now plans.service" "$MOCK_LOG"
    assert_failure
}

@test "caddy: tailnet generator binds every Tailscale address" {
    cat > "$MOCK_DIR/tailscale" <<'EOF'
#!/bin/sh
cat <<'JSON'
{"Self":{"DNSName":"host.tailnet.ts.net.","TailscaleIPs":["100.64.0.1","fd7a:115c:a1e0::1"]}}
JSON
EOF
    chmod +x "$MOCK_DIR/tailscale"
    run env CADDY_CONFIG_DIR="$CADDY_CONFIG_DIR" CADDY_RUNTIME_DIR="$TEST_ROOT/run" \
        TAILSCALE_BIN="$MOCK_DIR/tailscale" \
        "$PRIMER_DIR/modules/caddy/files/usr/local/libexec/primer-caddy-tailnet"
    assert_success
    grep -F "bind 100.64.0.1 fd7a:115c:a1e0::1" "$CADDY_CONFIG_DIR/tailnet.caddy"
    grep -Fx "TAILSCALE_HOSTNAME=host.tailnet.ts.net" "$TEST_ROOT/run/tailnet.env"

    CADDY_CONFIG_DIR="$CADDY_CONFIG_DIR" CADDY_RUNTIME_DIR="$TEST_ROOT/run" \
        TAILSCALE_BIN="$MOCK_DIR/tailscale" \
        "$PRIMER_DIR/modules/caddy/files/usr/local/libexec/primer-caddy-tailnet" status
    printf 'TAILSCALE_HOSTNAME=old.tailnet.ts.net\n' > "$TEST_ROOT/run/tailnet.env"
    run env CADDY_CONFIG_DIR="$CADDY_CONFIG_DIR" CADDY_RUNTIME_DIR="$TEST_ROOT/run" \
        TAILSCALE_BIN="$MOCK_DIR/tailscale" \
        "$PRIMER_DIR/modules/caddy/files/usr/local/libexec/primer-caddy-tailnet" status
    assert_failure
}
