#!/bin/zsh
# modules/caddy -- one validated Caddy gateway for Primer applications

_caddy::root_path() {
    print -r -- "${CADDY_ROOT_DIR:-}$1"
}

_caddy::binary() {
    print -r -- "${CADDY_BIN:-$(_caddy::root_path /usr/local/bin/caddy)}"
}

_caddy::route_helper() {
    print -r -- "${CADDY_ROUTE_HELPER:-$(_caddy::root_path /usr/local/libexec/primer-caddy-route)}"
}

_caddy::fragment_helper() {
    print -r -- "${CADDY_FRAGMENT_HELPER:-$PRIMER_DIR/modules/caddy/files/usr/local/libexec/primer-caddy-fragment}"
}

_caddy::cloudflare_env() {
    print -r -- "${CADDY_CLOUDFLARE_ENV:-$(_caddy::root_path /etc/caddy/env.d/cloudflare.env)}"
}

_caddy::cloudflare_api() {
    print -r -- "${CLOUDFLARE_API_BASE:-https://api.cloudflare.com/client/v4}"
}

# Keep bearer tokens out of curl's process arguments on multi-user machines.
_caddy::curl_with_token() {
    local token="$1" runtime header_file rc
    shift
    [[ -n "$token" && "$token" != *$'\n'* && "$token" != *$'\r'* ]] || return 1
    runtime="${XDG_RUNTIME_DIR:-}"
    if [[ -z "$runtime" && -n "${CADDY_TEST_ROOT:-}" ]]; then
        runtime="${CADDY_ROOT_DIR:-/tmp}"
    fi
    [[ -n "$runtime" && -d "$runtime" ]] || {
        print "XDG_RUNTIME_DIR is required for secure Cloudflare requests" >&2
        return 1
    }
    header_file="$(mktemp "$runtime/primer-caddy-header.XXXXXX")" || return 1
    chmod 0600 "$header_file"
    printf 'Authorization: Bearer %s\n' "$token" >"$header_file"
    curl --header "@$header_file" "$@"
    rc=$?
    rm -f "$header_file"
    return "$rc"
}

_caddy::op_ticket() {
    print -r -- "${PRIMER_OP_TICKET:-${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/op-ticket}"
}

_caddy::root() {
    if [[ -n "${CADDY_TEST_ROOT:-}" ]]; then
        "$@"
    else
        primer::run_as_root "configure the Caddy gateway" "$@"
    fi
}

_caddy::custom_binary_ready() {
    local binary version modules owner=root group=root
    binary="$(_caddy::binary)"
    version="$(mod_config caddy_version | head -1)"
    if [[ -n "${CADDY_TEST_ROOT:-}" ]]; then
        owner="$(id -un)"
        group="$(id -gn)"
    fi
    [[ -x "$binary" ]] || return 1
    [[ "$(stat -c %a "$binary" 2>/dev/null)" == 755 ]] \
        && [[ "$(stat -c %U "$binary" 2>/dev/null)" == "$owner" ]] \
        && [[ "$(stat -c %G "$binary" 2>/dev/null)" == "$group" ]] || return 1
    [[ "$($binary version 2>/dev/null)" == "$version "* || "$($binary version 2>/dev/null)" == "$version" ]] || return 1
    modules="$($binary list-modules 2>/dev/null)" || return 1
    print -r -- "$modules" | grep -Fxq dns.providers.cloudflare \
        && print -r -- "$modules" | grep -Fxq tls.get_certificate.tailscale
}

_caddy::cloudflare_required() {
    [[ "$(mod_config cloudflare_token_required | head -1)" == true ]]
}

_caddy::env_value() {
    local file="$1" key="$2" value
    value="$(_caddy::root sed -n "s/^${key}=//p" "$file" 2>/dev/null | head -1)" || return 1
    [[ -n "$value" && "$value" != *$'\n'* ]] || return 1
    print -r -- "$value"
}

_caddy::cloudflare_token_ready() {
    _caddy::env_value "$(_caddy::cloudflare_env)" CLOUDFLARE_API_TOKEN >/dev/null
}

_caddy::cloudflare_zone_id_ready() {
    _caddy::env_value "$(_caddy::cloudflare_env)" CLOUDFLARE_ZONE_ID >/dev/null
}

_caddy::cloudflare_validity_file() {
    print -r -- "$(_caddy::cloudflare_env).valid"
}

_caddy::cloudflare_fingerprint() {
    stat -c '%d:%i:%s:%Y' "$(_caddy::cloudflare_env)" 2>/dev/null
}

_caddy::record_cloudflare_validity() {
    local target temp
    target="$(_caddy::cloudflare_validity_file)"
    temp="$(mktemp)" || return 1
    _caddy::cloudflare_fingerprint > "$temp" || { rm -f "$temp"; return 1; }
    if [[ -n "${CADDY_TEST_ROOT:-}" ]]; then
        install -D -m 0644 "$temp" "$target"
    else
        _caddy::root install -D -o root -g root -m 0644 "$temp" "$target"
    fi
    local rc=$?
    rm -f "$temp"
    return "$rc"
}

_caddy::cloudflare_file_ready() {
    _caddy::cloudflare_required || return 0
    local file validity owner=root
    file="$(_caddy::cloudflare_env)"
    validity="$(_caddy::cloudflare_validity_file)"
    [[ -n "${CADDY_TEST_ROOT:-}" ]] && owner="$(id -un)"
    [[ -s "$file" ]] \
        && [[ "$(stat -c %a "$file" 2>/dev/null)" == 600 ]] \
        && [[ "$(stat -c %U "$file" 2>/dev/null)" == "$owner" ]] \
        && [[ -s "$validity" ]] \
        && [[ "$(stat -c %a "$validity" 2>/dev/null)" == 644 ]] \
        && [[ "$(stat -c %U "$validity" 2>/dev/null)" == "$owner" ]] \
        && [[ "$(<"$validity")" == "$(_caddy::cloudflare_fingerprint)" ]]
}

_caddy::restart_marker() {
    case "$1" in
        gateway|tailscale) print -r -- "$(_caddy::root_path /var/lib/primer/caddy/$1-restart-required)" ;;
        *) return 2 ;;
    esac
}

_caddy::mark_restart() {
    local marker owner=root group=root
    marker="$(_caddy::restart_marker "$1")" || return 1
    if [[ -n "${CADDY_TEST_ROOT:-}" ]]; then
        owner="$(id -un)"
        group="$(id -gn)"
    fi
    _caddy::root install -d -m 0755 "${marker:h}" \
        && _caddy::root chown "$owner:$group" "${marker:h}" \
        && _caddy::root install -m 0644 /dev/null "$marker"
}

_caddy::restart_pending() {
    local marker
    marker="$(_caddy::restart_marker "$1")" || return 1
    [[ -e "$marker" ]]
}

_caddy::clear_restart() {
    local marker
    marker="$(_caddy::restart_marker "$1")" || return 1
    _caddy::root rm -f "$marker"
}

_caddy::op_read() {
    local ref="$1" ticket
    if [[ -n "${OP_SERVICE_ACCOUNT_TOKEN:-}" ]]; then
        op read "$ref"
        return
    fi
    ticket="$(_caddy::op_ticket)"
    [[ -s "$ticket" ]] || {
        print "Agent access is not active. Run agents sudo, then retry Primer." >&2
        return 1
    }
    OP_SERVICE_ACCOUNT_TOKEN="$(<"$ticket")" op read "$ref"
}

_caddy::zone_name() {
    local zone
    zone="$(mod_config cloudflare_zone | head -1)"
    print -r -- "$zone" | grep -Eq '^[A-Za-z0-9.-]+$' || return 1
    print -r -- "${(L)zone}"
}

_caddy::lookup_zone_id() {
    local zone="$1" account_id="$2" reader_ref response
    reader_ref="$(mod_config cloudflare_reader_ref | head -1)"
    [[ -n "$reader_ref" ]] || { print "caddy.cloudflare_reader_ref is required" >&2; return 1; }
    response="$(_caddy::curl_with_token "$(_caddy::op_read "$reader_ref")" \
        -fsS --get "$(_caddy::cloudflare_api)/zones" \
        --data-urlencode "name=$zone" \
        --data-urlencode "account.id=$account_id" \
        --data-urlencode 'status=active')" || return 1
    print -r -- "$response" | jq -er \
        --arg zone "$zone" --arg account "$account_id" \
        '.result | map(select(.name == $zone and .account.id == $account)) |
         if length == 1 then .[0].id else error("expected one active Cloudflare zone") end'
}

_caddy::mint_cloudflare_token() {
    local account_ref minter_ref account_id zone zone_id permission_response permission_id
    local zone_permission_response zone_permission_id
    local machine token_name body response token_file token_id runtime rc
    account_ref="$(mod_config cloudflare_account_id_ref | head -1)"
    minter_ref="$(mod_config cloudflare_minter_ref | head -1)"
    [[ -n "$account_ref" && -n "$minter_ref" ]] || {
        print "Cloudflare Token Minter references are not configured" >&2
        return 1
    }
    command -v op >/dev/null 2>&1 || { print "op not found" >&2; return 1; }
    command -v curl >/dev/null 2>&1 || { print "curl not found" >&2; return 1; }
    command -v jq >/dev/null 2>&1 || { print "jq not found" >&2; return 1; }

    account_id="$(_caddy::op_read "$account_ref")" || return 1
    print -r -- "$account_id" | grep -Eq '^[0-9A-Fa-f]{32}$' || {
        print "Cloudflare account ID is invalid" >&2
        return 1
    }
    zone="$(_caddy::zone_name)" || return 1
    zone_id="$(_caddy::lookup_zone_id "$zone" "$account_id")" || return 1

    permission_response="$(_caddy::curl_with_token "$(_caddy::op_read "$minter_ref")" -fsS --get \
        "$(_caddy::cloudflare_api)/accounts/$account_id/tokens/permission_groups" \
        --data-urlencode 'name=DNS Write' \
        --data-urlencode 'scope=com.cloudflare.api.account.zone')" || return 1
    permission_id="$(print -r -- "$permission_response" | jq -er \
        '.result | map(select((.name == "DNS Write" or .name == "DNS Edit") and
          (.scopes | index("com.cloudflare.api.account.zone")))) |
         if length == 1 then .[0].id else error("expected one DNS Write permission group") end')" \
        || return 1
    zone_permission_response="$(_caddy::curl_with_token "$(_caddy::op_read "$minter_ref")" -fsS --get \
        "$(_caddy::cloudflare_api)/accounts/$account_id/tokens/permission_groups" \
        --data-urlencode 'name=Zone Read' \
        --data-urlencode 'scope=com.cloudflare.api.account.zone')" || return 1
    zone_permission_id="$(print -r -- "$zone_permission_response" | jq -er \
        '.result | map(select(.name == "Zone Read" and
          (.scopes | index("com.cloudflare.api.account.zone")))) |
         if length == 1 then .[0].id else error("expected one Zone Read permission group") end')" \
        || return 1

    machine="${(L)${CADDY_MACHINE_NAME:-$(hostname -s 2>/dev/null)}}"
    print -r -- "$machine" | grep -Eq '^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$' || return 1
    token_name="env-primer-caddy-${machine}-dns"
    body="$(jq -cn --arg name "$token_name" --arg zone "$zone_id" \
      --arg dns_permission "$permission_id" --arg zone_permission "$zone_permission_id" '{
      name: $name,
      policies: [{
        effect: "allow",
        resources: { ("com.cloudflare.api.account.zone." + $zone): "*" },
        permission_groups: [
          { id: $dns_permission, name: "DNS Write" },
          { id: $zone_permission, name: "Zone Read" }
        ]
      }]
    }')" || return 1
    runtime="${XDG_RUNTIME_DIR:-}"
    if [[ -z "$runtime" && -z "${CADDY_TEST_ROOT:-}" ]]; then
        print "XDG_RUNTIME_DIR is required for secure Cloudflare token setup" >&2
        return 1
    fi
    response="$(mktemp "${runtime:-/tmp}/primer-caddy-mint.XXXXXX")" || return 1
    chmod 0600 "$response"
    if ! _caddy::curl_with_token "$(_caddy::op_read "$minter_ref")" -fsS \
        "$(_caddy::cloudflare_api)/accounts/$account_id/tokens" \
        -H 'Content-Type: application/json' --data "$body" -o "$response"; then
        rm -f "$response"
        return 1
    fi
    if ! jq -e '.success == true and (.result.id | type == "string") and
        (.result.value | type == "string" and length > 0)' "$response" >/dev/null; then
        jq -r '.errors[]?.message' "$response" >&2
        rm -f "$response"
        return 1
    fi
    token_id="$(jq -r '.result.id' "$response")"
    token_file="$(mktemp "${runtime:-/tmp}/primer-caddy-cloudflare.XXXXXX")" || {
        rm -f "$response"
        return 1
    }
    chmod 0600 "$token_file"
    jq -r --arg zone "$zone_id" '
      "CLOUDFLARE_API_TOKEN=" + .result.value,
      "CLOUDFLARE_API_TOKEN_ID=" + .result.id,
      "CLOUDFLARE_ZONE_ID=" + $zone
    ' "$response" >"$token_file" || {
        rm -f "$response" "$token_file"
        return 1
    }
    rm -f "$response"
    _caddy::install_cloudflare_token_file "$token_file"
    rc=$?
    rm -f "$token_file"
    if (( rc != 0 )); then
        _caddy::curl_with_token "$(_caddy::op_read "$minter_ref")" -fsS -X DELETE \
            "$(_caddy::cloudflare_api)/accounts/$account_id/tokens/$token_id" \
            >/dev/null 2>&1 || true
    fi
    return "$rc"
}

_caddy::cloudflare_token_matches_zone() {
    local token="$1" zone_id="$2" zone response
    zone="$(_caddy::zone_name)" || return 1
    response="$(_caddy::curl_with_token "$token" -fsS \
        "$(_caddy::cloudflare_api)/zones/$zone_id")" || return 1
    print -r -- "$response" | jq -e --arg id "$zone_id" --arg zone "$zone" \
        '.success == true and .result.id == $id and .result.name == $zone' >/dev/null
}

_caddy::stored_cloudflare_token_ready() {
    local token token_id zone_id
    token="$(_caddy::env_value "$(_caddy::cloudflare_env)" CLOUDFLARE_API_TOKEN)" || return 1
    token_id="$(_caddy::env_value "$(_caddy::cloudflare_env)" CLOUDFLARE_API_TOKEN_ID)" || return 1
    zone_id="$(_caddy::env_value "$(_caddy::cloudflare_env)" CLOUDFLARE_ZONE_ID)" || return 1
    # Cloudflare token permissions are immutable. Primer only stores an ID for
    # tokens it minted with DNS Write access, so imported tokens are replaced.
    _caddy::cloudflare_token_matches_zone "$token" "$zone_id"
}

_caddy::delete_cloudflare_token() {
    local token_id="$1" account_id minter_ref
    [[ -n "$token_id" ]] || return 0
    account_id="$(_caddy::op_read "$(mod_config cloudflare_account_id_ref | head -1)")" || return 1
    minter_ref="$(mod_config cloudflare_minter_ref | head -1)"
    _caddy::curl_with_token "$(_caddy::op_read "$minter_ref")" -fsS -X DELETE \
        "$(_caddy::cloudflare_api)/accounts/$account_id/tokens/$token_id" >/dev/null
}

_caddy::install_cloudflare_token_file() {
    local source="$1" target="$(_caddy::cloudflare_env)"
    if [[ -n "${CADDY_TEST_ROOT:-}" ]]; then
        install -D -m 0600 "$source" "$target" \
            && _caddy::record_cloudflare_validity
    else
        _caddy::root install -D -o root -g root -m 0600 "$source" "$target" \
            && _caddy::record_cloudflare_validity
    fi
}

# Caddy owns the DNS token because multiple routes can use Cloudflare DNS-01.
_caddy::install_cloudflare_token() {
    _caddy::cloudflare_required || return 0
    local target token_id
    target="$(_caddy::cloudflare_env)"
    if _caddy::cloudflare_token_ready && _caddy::cloudflare_zone_id_ready; then
        if _caddy::stored_cloudflare_token_ready; then
            _caddy::root chmod 0600 "$target"
            [[ -n "${CADDY_TEST_ROOT:-}" ]] || _caddy::root chown root:root "$target"
            _caddy::record_cloudflare_validity
            return $?
        fi
        token_id="$(_caddy::env_value "$target" CLOUDFLARE_API_TOKEN_ID 2>/dev/null || true)"
        _caddy::mark_restart gateway || return 1
        _caddy::mint_cloudflare_token || return 1
        _caddy::delete_cloudflare_token "$token_id" \
            || print "Warning: could not remove the replaced Cloudflare token." >&2
        return 0
    fi
    _caddy::mark_restart gateway || return 1
    _caddy::mint_cloudflare_token || return 1
}

_caddy::install_binary() {
    _caddy::custom_binary_ready && return 0
    local caddy_version xcaddy_version cloudflare_module temp
    caddy_version="$(mod_config caddy_version | head -1)"
    xcaddy_version="$(mod_config xcaddy_version | head -1)"
    cloudflare_module="$(mod_config cloudflare_module | head -1)"
    [[ -n "$caddy_version" && -n "$xcaddy_version" && -n "$cloudflare_module" ]] || return 1
    command -v go >/dev/null 2>&1 || {
        print "go not found; the caddy module depends on mise with Go enabled" >&2
        return 1
    }
    temp="$(mktemp)" || return 1
    rm -f "$temp"
    go run "github.com/caddyserver/xcaddy/cmd/xcaddy@${xcaddy_version}" \
        build "$caddy_version" --output "$temp" --with "$cloudflare_module" || {
        rm -f "$temp"
        return 1
    }
    _caddy::root install -D -m 0755 "$temp" "$(_caddy::binary)"
    rm -f "$temp"
    _caddy::custom_binary_ready
}

_caddy::ensure_user() {
    getent passwd caddy >/dev/null 2>&1 && return 0
    _caddy::root useradd --system --home-dir /var/lib/caddy --create-home \
        --shell /usr/sbin/nologin caddy
}

_caddy::install_file() {
    local relative="$1" mode="$2" source target
    source="$MOD_DIR/files$relative"
    target="$(_caddy::root_path "$relative")"
    _caddy::root install -D -m "$mode" "$source" "$target"
}

_caddy::deploy() {
    local managed_path owner=root group=root
    if [[ -n "${CADDY_TEST_ROOT:-}" ]]; then
        owner="$(id -un)"
        group="$(id -gn)"
    fi
    _caddy::root install -d -m 0755 \
        "$(_caddy::root_path /etc/caddy)" \
        "$(_caddy::root_path /etc/caddy/apps.d)" \
        "$(_caddy::root_path /etc/caddy/env.d)" \
        "$(_caddy::root_path /var/lib/caddy)" \
        "$(_caddy::root_path /var/lib/primer)" \
        "$(_caddy::root_path /var/lib/primer/caddy)"
    _caddy::root chown "$owner:$group" \
        "$(_caddy::root_path /etc/caddy)" \
        "$(_caddy::root_path /etc/caddy/apps.d)" \
        "$(_caddy::root_path /etc/caddy/env.d)" \
        "$(_caddy::root_path /var/lib/primer)" \
        "$(_caddy::root_path /var/lib/primer/caddy)" || return 1
    for managed_path in \
        /etc/caddy/Caddyfile \
        /etc/systemd/system/caddy.service \
        /etc/systemd/system/caddy-validate.service \
        /etc/systemd/system/tailscaled.service.d/primer-caddy.conf; do
        _caddy::install_file "$managed_path" 0644 || return 1
    done
    _caddy::install_file /usr/local/libexec/primer-caddy-tailnet 0755 || return 1
    _caddy::install_file /usr/local/libexec/primer-caddy-route 0755 || return 1
    _caddy::install_file /usr/local/libexec/primer-caddy-fragment 0755 || return 1
    _caddy::root chown -R caddy:caddy "$(_caddy::root_path /var/lib/caddy)"
}

_caddy::definitions_ready() {
    local spec managed_path expected_mode owner=root group=root
    if [[ -n "${CADDY_TEST_ROOT:-}" ]]; then
        owner="$(id -un)"
        group="$(id -gn)"
    fi
    for managed_path in \
        /etc/caddy /etc/caddy/apps.d /etc/caddy/env.d \
        /var/lib/primer /var/lib/primer/caddy; do
        [[ "$(stat -c %a "$(_caddy::root_path "$managed_path")" 2>/dev/null)" == 755 ]] \
            && [[ "$(stat -c %U "$(_caddy::root_path "$managed_path")" 2>/dev/null)" == "$owner" ]] \
            && [[ "$(stat -c %G "$(_caddy::root_path "$managed_path")" 2>/dev/null)" == "$group" ]] \
            || return 1
    done
    for spec in \
        '/etc/caddy/Caddyfile 644' \
        '/etc/systemd/system/caddy.service 644' \
        '/etc/systemd/system/caddy-validate.service 644' \
        '/etc/systemd/system/tailscaled.service.d/primer-caddy.conf 644' \
        '/usr/local/libexec/primer-caddy-tailnet 755' \
        '/usr/local/libexec/primer-caddy-route 755' \
        '/usr/local/libexec/primer-caddy-fragment 755'; do
        managed_path="${spec% *}"
        expected_mode="${spec##* }"
        cmp -s "$MOD_DIR/files$managed_path" "$(_caddy::root_path "$managed_path")" || return 1
        [[ "$(stat -c %a "$(_caddy::root_path "$managed_path")" 2>/dev/null)" == "$expected_mode" ]] \
            && [[ "$(stat -c %U "$(_caddy::root_path "$managed_path")" 2>/dev/null)" == "$owner" ]] \
            && [[ "$(stat -c %G "$(_caddy::root_path "$managed_path")" 2>/dev/null)" == "$group" ]] \
            || return 1
    done
}

_caddy::routes_ready() {
    local manifest desired actual route owner=root group=root
    if [[ -n "${CADDY_TEST_ROOT:-}" ]]; then
        owner="$(id -un)"
        group="$(id -gn)"
    fi
    manifest="$(_caddy::root_path /etc/caddy/primer-routes)"
    [[ -f "$manifest" && ! -L "$manifest" ]] \
        && [[ "$(stat -c %a "$manifest" 2>/dev/null)" == 644 ]] \
        && [[ "$(stat -c %U "$manifest" 2>/dev/null)" == "$owner" ]] \
        && [[ "$(stat -c %G "$manifest" 2>/dev/null)" == "$group" ]] \
        || return 1
    desired="$(_caddy::desired_routes | sed '/^$/d' | sort -u)"
    actual="$(sed -n '/^[a-z0-9][a-z0-9-]*$/p' "$manifest" | sort -u)"
    [[ "$actual" == "$desired" ]] || return 1
    while IFS= read -r route; do
        [[ -n "$route" ]] || continue
        CADDY_CONFIG_DIR="$(_caddy::root_path /etc/caddy)" \
        CADDY_APPS_DIR="$(_caddy::root_path /etc/caddy/apps.d)" \
        CADDY_ROUTE_MANIFEST="$manifest" \
        CADDY_EXPECTED_OWNER="$owner" \
        CADDY_EXPECTED_GROUP="$group" \
            "$(_caddy::route_helper)" status "$route" || return 1
    done <<< "$desired"
}

_caddy::tailnet_ready() {
    local file owner=root group=root
    if [[ -n "${CADDY_TEST_ROOT:-}" ]]; then
        owner="$(id -un)"
        group="$(id -gn)"
    fi
    CADDY_CONFIG_DIR="$(_caddy::root_path /etc/caddy)" \
    CADDY_RUNTIME_DIR="$(_caddy::root_path /run/caddy)" \
        "$(_caddy::root_path /usr/local/libexec/primer-caddy-tailnet)" status || return 1
    for file in \
        "$(_caddy::root_path /etc/caddy/tailnet.caddy)" \
        "$(_caddy::root_path /run/caddy/tailnet.env)"; do
        [[ "$(stat -c %a "$file" 2>/dev/null)" == 644 ]] \
            && [[ "$(stat -c %U "$file" 2>/dev/null)" == "$owner" ]] \
            && [[ "$(stat -c %G "$file" 2>/dev/null)" == "$group" ]] \
            || return 1
    done
}

_caddy::tailnet_fingerprint() {
    local file
    for file in \
        "$(_caddy::root_path /etc/caddy/tailnet.caddy)" \
        "$(_caddy::root_path /run/caddy/tailnet.env)"; do
        [[ -f "$file" ]] && sha256sum "$file" || print -r -- "missing $file"
    done
}

_caddy::refresh_tailnet() {
    local before after
    before="$(_caddy::tailnet_fingerprint)"
    _caddy::root "$(_caddy::root_path /usr/local/libexec/primer-caddy-tailnet)" || return 1
    after="$(_caddy::tailnet_fingerprint)"
    # Keep the restart requirement if a later validation or migration step fails.
    [[ "$before" == "$after" ]] || _caddy::mark_restart gateway
}

_caddy::desired_routes() {
    mod_config routes
}

_caddy::desired_dns_names() {
    local machine zone name
    machine="${(L)${CADDY_MACHINE_NAME:-$(hostname -s 2>/dev/null)}}"
    print -r -- "$machine" | grep -Eq '^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$' || return 1
    zone="$(_caddy::zone_name)" || return 1
    while IFS= read -r name; do
        [[ -n "$name" ]] || continue
        name="${(L)name}"
        name="${name//\{machine\}/$machine}"
        print -r -- "$name" | grep -Eq '^[a-z0-9]([a-z0-9.-]*[a-z0-9])?$' || return 1
        [[ "$name" == "$zone" || "$name" == *".$zone" ]] || {
            print "Cloudflare DNS name is outside $zone: $name" >&2
            return 1
        }
        print -r -- "$name"
    done < <(mod_config dns_names)
}

_caddy::tailscale_addresses() {
    local status_json ipv4 ipv6
    status_json="$(tailscale status --json)" || return 1
    ipv4="$(print -r -- "$status_json" | jq -er \
        '[.Self.TailscaleIPs[]? | select(test("^[0-9]+(\\.[0-9]+){3}$"))] |
         if length == 1 then .[0] else error("expected one Tailscale IPv4 address") end')" \
        || return 1
    ipv6="$(print -r -- "$status_json" | jq -er \
        '[.Self.TailscaleIPs[]? | select(contains(":"))] |
         if length == 1 then .[0] else error("expected one Tailscale IPv6 address") end')" \
        || return 1
    print -r -- "A $ipv4"
    print -r -- "AAAA $ipv6"
}

_caddy::cloudflare_response_ok() {
    local response="$1"
    if print -r -- "$response" | jq -e '.success == true' >/dev/null; then
        return 0
    fi
    print -r -- "$response" | jq -r '.errors[]?.message' >&2
    return 1
}

_caddy::dns_records() {
    local token="$1" zone_id="$2" name="$3" type="$4"
    _caddy::curl_with_token "$token" -fsS --get \
        "$(_caddy::cloudflare_api)/zones/$zone_id/dns_records" \
        --data-urlencode "name=$name" \
        --data-urlencode "type=$type" \
        --data-urlencode 'match=all' \
        --data-urlencode 'per_page=5'
}

_caddy::reconcile_dns_record() {
    local token="$1" zone_id="$2" name="$3" type="$4" content="$5"
    local response count record_id body method url
    response="$(_caddy::dns_records "$token" "$zone_id" "$name" "$type")" || return 1
    _caddy::cloudflare_response_ok "$response" || return 1
    count="$(print -r -- "$response" | jq -er '.result | length')" || return 1
    (( count <= 1 )) || {
        print "Cloudflare has duplicate $type records for $name" >&2
        return 1
    }
    if (( count == 1 )) && print -r -- "$response" | jq -e \
        --arg content "$content" '.result[0] |
        .content == $content and .proxied == false and .ttl == 1' >/dev/null; then
        return 0
    fi

    body="$(jq -cn --arg type "$type" --arg name "$name" --arg content "$content" '{
      type: $type,
      name: $name,
      content: $content,
      ttl: 1,
      proxied: false,
      comment: "Managed by Primer for private Tailscale access"
    }')" || return 1
    method=POST
    url="$(_caddy::cloudflare_api)/zones/$zone_id/dns_records"
    if (( count == 1 )); then
        record_id="$(print -r -- "$response" | jq -er '.result[0].id')" || return 1
        method=PATCH
        url="$url/$record_id"
    fi
    response="$(_caddy::curl_with_token "$token" -fsS -X "$method" "$url" \
        -H 'Content-Type: application/json' --data "$body")" || return 1
    _caddy::cloudflare_response_ok "$response"
}

_caddy::reconcile_dns() {
    _caddy::cloudflare_required || return 0
    local token zone_id name type address entry
    local -a addresses names
    token="$(_caddy::env_value "$(_caddy::cloudflare_env)" CLOUDFLARE_API_TOKEN)" || return 1
    zone_id="$(_caddy::env_value "$(_caddy::cloudflare_env)" CLOUDFLARE_ZONE_ID)" || return 1
    addresses=("${(@f)$(_caddy::tailscale_addresses)}") || return 1
    names=("${(@f)$(_caddy::desired_dns_names)}") || return 1
    for name in "${names[@]}"; do
        for entry in "${addresses[@]}"; do
            type="${entry%% *}"
            address="${entry#* }"
            _caddy::reconcile_dns_record "$token" "$zone_id" "$name" "$type" "$address" || {
                unset token
                return 1
            }
        done
    done
    unset token
}

_caddy::dns_ready() {
    _caddy::cloudflare_required || return 0
    local token zone_id name type address entry response
    local -a addresses names
    token="$(_caddy::env_value "$(_caddy::cloudflare_env)" CLOUDFLARE_API_TOKEN)" || return 1
    zone_id="$(_caddy::env_value "$(_caddy::cloudflare_env)" CLOUDFLARE_ZONE_ID)" || return 1
    addresses=("${(@f)$(_caddy::tailscale_addresses)}") || return 1
    names=("${(@f)$(_caddy::desired_dns_names)}") || return 1
    for name in "${names[@]}"; do
        for entry in "${addresses[@]}"; do
            type="${entry%% *}"
            address="${entry#* }"
            response="$(_caddy::dns_records "$token" "$zone_id" "$name" "$type")" || return 1
            _caddy::cloudflare_response_ok "$response" || return 1
            print -r -- "$response" | jq -e --arg content "$address" \
                '.result | length == 1 and .[0].content == $content and
                 .[0].proxied == false and .[0].ttl == 1' >/dev/null || return 1
        done
    done
    unset token
}

_caddy::dns_resolves() {
    local name entry type address results resolved
    local -a addresses names
    addresses=("${(@f)$(_caddy::tailscale_addresses)}") || return 1
    names=("${(@f)$(_caddy::desired_dns_names)}") || return 1
    for name in "${names[@]}"; do
        for entry in "${addresses[@]}"; do
            type="${entry%% *}"
            address="${entry#* }"
            if [[ "$type" == A ]]; then
                results="$(getent ahostsv4 "$name" 2>/dev/null)" || return 1
            else
                results="$(getent ahostsv6 "$name" 2>/dev/null)" || return 1
            fi
            resolved="$(print -r -- "$results" | awk 'NF {print $1}' | sort -u)"
            [[ "$resolved" == "$address" ]] || return 1
        done
    done
}

_caddy::reconcile_routes() {
    local -a routes
    routes=("${(@f)$(_caddy::desired_routes)}")
    [[ ${#routes[@]} -eq 1 && -z "${routes[1]}" ]] && routes=()
    CADDY_CONFIG_DIR="$(_caddy::root_path /etc/caddy)" \
    CADDY_APPS_DIR="$(_caddy::root_path /etc/caddy/apps.d)" \
    CADDY_ROUTE_MANIFEST="$(_caddy::root_path /etc/caddy/primer-routes)" \
    CADDY_ROUTE_LOCK="${CADDY_TEST_ROOT:+${CADDY_ROUTE_LOCK:-}}" \
    CADDY_EXPECTED_OWNER="${CADDY_TEST_ROOT:+$(id -un)}" \
    CADDY_EXPECTED_GROUP="${CADDY_TEST_ROOT:+$(id -gn)}" \
        _caddy::root "$(_caddy::route_helper)" reconcile "${routes[@]}"
}

typeset -g _CADDY_MIGRATED_SERVE=false
typeset -g _CADDY_MIGRATED_PLANS=false
typeset -g _CADDY_PLANS_WAS_ACTIVE=false
typeset -g _CADDY_PLANS_WAS_ENABLED=false
typeset -g _CADDY_GATEWAY_WAS_ACTIVE=false
typeset -g _CADDY_GATEWAY_WAS_ENABLED=false
typeset -g _CADDY_MIGRATION_BACKUP=""

_caddy::snapshot_migration_routes() {
    local route source backup temp
    local -a routes=()
    backup="$(mktemp -d)" || return 1
    if _caddy::serve_migration_needed; then
        routes+=("$(mod_config migrate_tailscale_serve_route | head -1)")
    fi
    if _caddy::plans_migration_needed; then
        routes+=("$(mod_config migrate_plans_route | head -1)")
    fi
    for route in "${routes[@]}"; do
        print -r -- "$route" | grep -Eq '^[a-z0-9][a-z0-9-]*$' \
            || { rm -r "$backup"; return 1; }
        source="$(_caddy::root_path /etc/caddy/apps.d/$route.caddy)"
        [[ -f "$source" ]] && cp -p "$source" "$backup/$route.caddy"
    done
    temp="$(_caddy::root_path /etc/caddy/primer-routes)"
    [[ -f "$temp" ]] && cp -p "$temp" "$backup/primer-routes"
    print -r -- "${(F)routes}" > "$backup/routes"
    _CADDY_MIGRATION_BACKUP="$backup"
}

_caddy::restore_migration_routes() {
    local route target manifest
    [[ -n "$_CADDY_MIGRATION_BACKUP" && -d "$_CADDY_MIGRATION_BACKUP" ]] || return 0
    manifest="$(_caddy::root_path /etc/caddy/primer-routes)"
    while IFS= read -r route; do
        [[ -n "$route" ]] || continue
        target="$(_caddy::root_path /etc/caddy/apps.d/$route.caddy)"
        if [[ -f "$_CADDY_MIGRATION_BACKUP/$route.caddy" ]]; then
            _caddy::root install -m 0644 "$_CADDY_MIGRATION_BACKUP/$route.caddy" "$target" || return 1
        else
            _caddy::root rm -f "$target" || return 1
        fi
    done < "$_CADDY_MIGRATION_BACKUP/routes"
    if [[ -f "$_CADDY_MIGRATION_BACKUP/primer-routes" ]]; then
        _caddy::root install -m 0644 "$_CADDY_MIGRATION_BACKUP/primer-routes" "$manifest"
    else
        _caddy::root rm -f "$manifest"
    fi
}

_caddy::clear_migration_snapshot() {
    [[ -z "$_CADDY_MIGRATION_BACKUP" ]] || rm -r "$_CADDY_MIGRATION_BACKUP"
    _CADDY_MIGRATION_BACKUP=""
}

_caddy::restore_and_clear_migration_routes() {
    _caddy::restore_migration_routes || return 1
    _caddy::clear_migration_snapshot
}

_caddy::plans_service_managed() {
    systemctl cat plans.service >/dev/null 2>&1 \
        && { systemctl is-active --quiet plans.service \
            || systemctl is-enabled --quiet plans.service; }
}

_caddy::plans_service_matches() {
    local config expected actual unit expected_unit actual_unit fragment
    local exec_start exec_reload environment user group command
    config="$(_caddy::root_path /etc/caddy/plans.Caddyfile)"
    expected="$(mod_config migrate_plans_config_digest | head -1)"
    print -r -- "$expected" | grep -Eq '^[0-9a-f]{64}$' || return 1
    [[ -f "$config" ]] || return 1
    actual="$(sha256sum "$config" 2>/dev/null | awk '{print $1}')" || return 1
    [[ "$actual" == "$expected" ]] || return 1
    unit="$(_caddy::root_path /etc/systemd/system/plans.service)"
    expected_unit="$(mod_config migrate_plans_unit_digest | head -1)"
    print -r -- "$expected_unit" | grep -Eq '^[0-9a-f]{64}$' || return 1
    actual_unit="$(sha256sum "$unit" 2>/dev/null | awk '{print $1}')" || return 1
    [[ "$actual_unit" == "$expected_unit" ]] || return 1
    fragment="$(systemctl show plans.service --property=FragmentPath --value 2>/dev/null)" || return 1
    exec_start="$(systemctl show plans.service --property=ExecStart --value 2>/dev/null)" || return 1
    exec_reload="$(systemctl show plans.service --property=ExecReload --value 2>/dev/null)" || return 1
    environment="$(systemctl show plans.service --property=EnvironmentFiles --value 2>/dev/null)" || return 1
    user="$(systemctl show plans.service --property=User --value 2>/dev/null)" || return 1
    group="$(systemctl show plans.service --property=Group --value 2>/dev/null)" || return 1
    [[ "$fragment" == /etc/systemd/system/plans.service ]] \
        && [[ "$exec_start" == *'argv[]=/usr/local/bin/caddy run --config /etc/caddy/plans.Caddyfile ;'* ]] \
        && [[ "$exec_reload" == *'argv[]=/usr/local/bin/caddy reload --config /etc/caddy/plans.Caddyfile --force ;'* ]] \
        && [[ "$environment" == '/etc/agents-infra/plans.env (ignore_errors=no)' ]] \
        && [[ "$user" == caddy && "$group" == caddy ]] || return 1
    for command in ExecCondition ExecStartPre ExecStartPost ExecStop ExecStopPost; do
        [[ -z "$(systemctl show plans.service --property="$command" --value 2>/dev/null)" ]] || return 1
    done
}

_caddy::plans_migration_needed() {
    _caddy::desired_routes | grep -Fxq plans-media \
        && _caddy::plans_service_managed \
        && _caddy::plans_service_matches
}

_caddy::serve_migration_needed() {
    local serve_port serve_target serve_status
    serve_port="$(mod_config migrate_tailscale_serve_port | head -1)"
    serve_target="$(mod_config migrate_tailscale_serve_target | head -1)"
    [[ -n "$serve_port" ]] || return 1
    serve_status="$(tailscale serve status --json 2>/dev/null)" || return 1
    print -r -- "$serve_status" | jq -e --arg port "$serve_port" --arg target "$serve_target" \
        '.TCP[$port] != null and
         ([.Web | to_entries[]? | select(.key | endswith(":" + $port))] | length == 1) and
         ([.Web | to_entries[]? | select(.key | endswith(":" + $port)) |
           .value.Handlers | keys] == [["/"]]) and
         ([.Web | to_entries[]? | select(.key | endswith(":" + $port)) |
           .value.Handlers["/"].Proxy] == [$target])' >/dev/null 2>&1
}

_caddy::serve_port_present() {
    local serve_port serve_status
    serve_port="$(mod_config migrate_tailscale_serve_port | head -1)"
    [[ -n "$serve_port" ]] || return 1
    serve_status="$(tailscale serve status --json 2>/dev/null)" || return 1
    print -r -- "$serve_status" | jq -e --arg port "$serve_port" \
        '.TCP[$port] != null' >/dev/null 2>&1
}

_caddy::check_listener_migration() {
    local plans_present=false plans_selected=false plans_managed=false
    systemctl cat plans.service >/dev/null 2>&1 && plans_present=true
    _caddy::desired_routes | grep -Fxq plans-media && plans_selected=true
    if $plans_present && { systemctl is-active --quiet plans.service \
        || systemctl is-enabled --quiet plans.service; }; then
        plans_managed=true
    fi
    if $plans_managed && ! $plans_selected; then
        print "Legacy plans.service is active, but the plans-media addon is not selected." >&2
        print "Select plans-media before Primer migrates the Plans listener." >&2
        return 1
    fi
    if $plans_managed && $plans_selected && ! _caddy::plans_service_matches; then
        print "Legacy plans.service does not match Primer's expected listener." >&2
        print "Primer will not replace a customized service." >&2
        return 1
    fi
    if _caddy::serve_port_present && ! _caddy::serve_migration_needed; then
        print "Tailscale Serve port $(mod_config migrate_tailscale_serve_port | head -1) does not target $(mod_config migrate_tailscale_serve_target | head -1)." >&2
        print "Primer will not replace an unrelated listener." >&2
        return 1
    fi
}

_caddy::stage_route() {
    local name="$1" source="$2"
    _caddy::mark_restart gateway || return 1
    CADDY_CONFIG_DIR="$(_caddy::root_path /etc/caddy)" \
    CADDY_APPS_DIR="$(_caddy::root_path /etc/caddy/apps.d)" \
    CADDY_ROUTE_MANIFEST="$(_caddy::root_path /etc/caddy/primer-routes)" \
    CADDY_ROUTE_LOCK="${CADDY_TEST_ROOT:+${CADDY_ROUTE_LOCK:-}}" \
    CADDY_EXPECTED_OWNER="${CADDY_TEST_ROOT:+$(id -un)}" \
    CADDY_EXPECTED_GROUP="${CADDY_TEST_ROOT:+$(id -gn)}" \
        _caddy::root "$(_caddy::route_helper)" stage "$name" "$source"
}

_caddy::stage_plans_credentials() {
    local target legacy assignment temp
    target="$(_caddy::root_path /etc/caddy/env.d/plans-media.env)"
    if _caddy::managed_plans_credentials_ready "$target"; then
        return 0
    fi
    legacy="$(mod_config legacy_cloudflare_env | head -1)"
    assignment="$(_caddy::root sed -n '/^GATE_SECRET=/p' "$legacy" 2>/dev/null)" || return 1
    if [[ -z "$assignment" || "$assignment" == *$'\n'* ]]; then
        print "The legacy Plans gate secret is unavailable; refusing listener migration." >&2
        return 1
    fi
    temp="$(mktemp)" || return 1
    chmod 0600 "$temp"
    print -r -- "$assignment" >"$temp"
    _caddy::mark_restart gateway || { rm -f "$temp"; return 1; }
    if [[ -n "${CADDY_TEST_ROOT:-}" ]]; then
        install -D -m 0600 "$temp" "$target"
    else
        _caddy::root install -D -o root -g root -m 0600 "$temp" "$target"
    fi
    local rc=$?
    rm -f "$temp"
    return "$rc"
}

_caddy::managed_plans_credentials_ready() {
    local file="$1" validity="$1.valid" restart="$1.restart-required"
    local owner=root assignment fingerprint
    [[ -n "${CADDY_TEST_ROOT:-}" ]] && owner="$(id -un)"
    assignment="$(_caddy::root sed -n '/^GATE_SECRET=/p' "$file" 2>/dev/null)" || return 1
    [[ -n "$assignment" && "$assignment" != *$'\n'* ]] || return 1
    case "${assignment#GATE_SECRET=}" in
        ''|'""'|"''") return 1 ;;
    esac
    fingerprint="$(stat -c '%d:%i:%s:%Y' "$file" 2>/dev/null)" || return 1
    [[ "$(stat -c %a "$file" 2>/dev/null)" == 600 ]] \
        && [[ "$(stat -c %U "$file" 2>/dev/null)" == "$owner" ]] \
        && [[ -s "$validity" && "$(<"$validity")" == "$fingerprint" ]] \
        && [[ ! -e "$restart" ]]
}

_caddy::stage_migration_routes() {
    local route host target port worker temp machine
    if _caddy::serve_migration_needed; then
        route="$(mod_config migrate_tailscale_serve_route | head -1)"
        host="$(mod_config migrate_tailscale_serve_host | head -1)"
        target="$(mod_config migrate_tailscale_serve_target | head -1)"
        port="${target##*:}"
        machine="${(L)${CADDY_MACHINE_NAME:-$(hostname -s 2>/dev/null)}}"
        host="${host//\{machine\}/$machine}"
        [[ "$route" == t3-code ]] || return 1
        temp="$(mktemp)" || return 1
        "$(_caddy::fragment_helper)" t3-code "$host" "$port" >"$temp" \
            || { rm -f "$temp"; return 1; }
        _caddy::stage_route "$route" "$temp" || { rm -f "$temp"; return 1; }
        rm -f "$temp"
    fi
    if _caddy::plans_migration_needed; then
        route="$(mod_config migrate_plans_route | head -1)"
        host="$(mod_config migrate_plans_host | head -1)"
        worker="$(mod_config migrate_plans_worker_host | head -1)"
        [[ "$route" == plans-media ]] || return 1
        _caddy::stage_plans_credentials || return 1
        temp="$(mktemp)" || return 1
        "$(_caddy::fragment_helper)" plans-media "$host" "$worker" >"$temp" \
            || { rm -f "$temp"; return 1; }
        _caddy::stage_route "$route" "$temp" || { rm -f "$temp"; return 1; }
        rm -f "$temp"
    fi
}

_caddy::migrate_listeners() {
    local serve_port serve_target
    _CADDY_MIGRATED_SERVE=false
    _CADDY_MIGRATED_PLANS=false
    _CADDY_PLANS_WAS_ACTIVE=false
    _CADDY_PLANS_WAS_ENABLED=false
    _caddy::check_listener_migration || return 1

    serve_port="$(mod_config migrate_tailscale_serve_port | head -1)"
    serve_target="$(mod_config migrate_tailscale_serve_target | head -1)"
    if _caddy::serve_migration_needed; then
        [[ -n "$serve_target" ]] || {
            print "caddy.migrate_tailscale_serve_target is required for rollback" >&2
            return 1
        }
        _caddy::root tailscale serve --https="$serve_port" off || return 1
        _CADDY_MIGRATED_SERVE=true
    fi
    if _caddy::plans_migration_needed; then
        systemctl is-active --quiet plans.service && _CADDY_PLANS_WAS_ACTIVE=true
        systemctl is-enabled --quiet plans.service && _CADDY_PLANS_WAS_ENABLED=true
        _CADDY_MIGRATED_PLANS=true
        if ! _caddy::root systemctl disable --now plans.service; then
            _caddy::restore_listeners
            return 1
        fi
    fi
}

_caddy::restore_listeners() {
    local rc=0 serve_port serve_target
    if $_CADDY_MIGRATED_PLANS; then
        if $_CADDY_PLANS_WAS_ENABLED; then
            _caddy::root systemctl enable plans.service || rc=1
        else
            _caddy::root systemctl disable plans.service || rc=1
        fi
        if $_CADDY_PLANS_WAS_ACTIVE; then
            _caddy::root systemctl start plans.service || rc=1
        else
            _caddy::root systemctl stop plans.service || rc=1
        fi
    fi
    if $_CADDY_MIGRATED_SERVE; then
        serve_port="$(mod_config migrate_tailscale_serve_port | head -1)"
        serve_target="$(mod_config migrate_tailscale_serve_target | head -1)"
        _caddy::root tailscale serve --bg --https="$serve_port" "$serve_target" || rc=1
    fi
    return "$rc"
}

_caddy::activate_gateway() {
    local gateway_needs_restart="$1"
    _caddy::root systemctl enable caddy.service || return 1
    if _caddy::root systemctl is-active --quiet caddy.service; then
        if [[ "$gateway_needs_restart" == true ]]; then
            _caddy::root systemctl restart caddy.service
        else
            _caddy::root systemctl reload caddy.service
        fi
    else
        _caddy::root systemctl start caddy.service
    fi
}

_caddy::activate_gateway_with_rollback() {
    local gateway_needs_restart="$1"
    _CADDY_GATEWAY_WAS_ACTIVE=false
    _CADDY_GATEWAY_WAS_ENABLED=false
    systemctl is-active --quiet caddy.service && _CADDY_GATEWAY_WAS_ACTIVE=true
    systemctl is-enabled --quiet caddy.service && _CADDY_GATEWAY_WAS_ENABLED=true
    if ! _caddy::migrate_listeners; then
        _caddy::restore_and_clear_migration_routes
        return 1
    fi
    if ! _caddy::activate_gateway "$gateway_needs_restart"; then
        _caddy::rollback_migration
        return 1
    fi
}

_caddy::rollback_migration() {
    if ! $_CADDY_MIGRATED_SERVE && ! $_CADDY_MIGRATED_PLANS; then
        return 0
    fi
    local rc=0
    if ! _caddy::restore_migration_routes; then
        print "Caddy migration route rollback failed." >&2
        return 1
    fi
    if $_CADDY_GATEWAY_WAS_ACTIVE; then
        _caddy::root systemctl start --wait caddy-validate.service || rc=1
        if _caddy::root systemctl is-active --quiet caddy.service; then
            _caddy::root systemctl reload caddy.service || rc=1
        else
            _caddy::root systemctl start caddy.service || rc=1
        fi
    else
        _caddy::root systemctl stop caddy.service || rc=1
    fi
    if $_CADDY_GATEWAY_WAS_ENABLED; then
        _caddy::root systemctl enable caddy.service || rc=1
    else
        _caddy::root systemctl disable caddy.service || rc=1
    fi
    _caddy::restore_listeners || rc=1
    _caddy::clear_migration_snapshot
    (( rc == 0 )) || print "Caddy migration rollback failed." >&2
    return "$rc"
}

_caddy::reconcile_routes_with_rollback() {
    _caddy::reconcile_routes && return 0
    _caddy::rollback_migration
    return 1
}

_caddy::verify_gateway_with_rollback() {
    _caddy::root systemctl is-active --quiet caddy.service && return 0
    _caddy::rollback_migration
    return 1
}

mod_update() {
    primer::items_init "binary" "configuration" "credentials" "dns" "routes" "service"
    if [[ "$DRY_RUN" == true ]]; then
        print "[dry-run] build custom Caddy $(mod_config caddy_version | head -1) with $(mod_config cloudflare_module | head -1)"
        print "[dry-run] install Caddy service and config under /etc/caddy"
        _caddy::cloudflare_required \
            && print "[dry-run] mint or load a zone-scoped Cloudflare DNS token"
        _caddy::cloudflare_required \
            && print "[dry-run] reconcile DNS-only A and AAAA records: $(_caddy::desired_dns_names | tr '\n' ' ')"
        print "[dry-run] reconcile Primer routes: $(_caddy::desired_routes | tr '\n' ' ')"
        print "[dry-run] validate caddy-validate.service before reload"
        print "[dry-run] sudo systemctl enable --now caddy.service"
        primer::item_update "binary" done
        primer::item_update "configuration" done
        primer::item_update "credentials" done
        primer::item_update "dns" done
        primer::item_update "routes" done
        primer::item_update "service" done
        primer::status_msg "gateway planned"
        return 0
    fi

    if ! _caddy::custom_binary_ready \
        || ! cmp -s "$MOD_DIR/files/etc/systemd/system/caddy.service" \
            "$(_caddy::root_path /etc/systemd/system/caddy.service)" \
        || ! cmp -s "$MOD_DIR/files/etc/caddy/Caddyfile" \
            "$(_caddy::root_path /etc/caddy/Caddyfile)"; then
        _caddy::mark_restart gateway || return 1
    fi
    _caddy::install_binary || { primer::item_update binary failed "build failed"; return 1; }
    primer::item_update binary done
    _caddy::ensure_user || return 1
    if ! cmp -s "$MOD_DIR/files/etc/systemd/system/tailscaled.service.d/primer-caddy.conf" \
        "$(_caddy::root_path /etc/systemd/system/tailscaled.service.d/primer-caddy.conf)"; then
        _caddy::mark_restart tailscale || return 1
    fi
    _caddy::deploy || { primer::item_update configuration failed "deploy failed"; return 1; }
    primer::item_update configuration done
    _caddy::install_cloudflare_token \
        || { primer::item_update credentials failed "configuration required"; return 1; }
    primer::item_update credentials done
    _caddy::reconcile_dns \
        || { primer::item_update dns failed "Cloudflare update failed"; return 1; }
    primer::item_update dns done
    _caddy::root systemctl daemon-reload || return 1
    if _caddy::restart_pending tailscale; then
        _caddy::root systemctl restart tailscaled.service || return 1
        _caddy::clear_restart tailscale || return 1
    fi
    _caddy::refresh_tailnet || return 1
    _caddy::snapshot_migration_routes || return 1
    _caddy::stage_migration_routes || {
        _caddy::restore_and_clear_migration_routes
        return 1
    }
    _caddy::root systemctl start --wait caddy-validate.service || {
        _caddy::restore_and_clear_migration_routes
        return 1
    }
    _caddy::check_listener_migration || {
        _caddy::restore_and_clear_migration_routes
        return 1
    }
    local gateway_needs_restart=false
    _caddy::restart_pending gateway && gateway_needs_restart=true
    _caddy::activate_gateway_with_rollback "$gateway_needs_restart" || return 1
    if $gateway_needs_restart; then
        _caddy::clear_restart gateway || return 1
    fi
    _caddy::reconcile_routes_with_rollback || {
        primer::item_update routes failed "reconcile failed"
        return 1
    }
    primer::item_update routes done
    _caddy::verify_gateway_with_rollback || return 1
    _caddy::clear_migration_snapshot
    primer::item_update service done
    primer::status_msg "gateway ready"
}

mod_status() {
    _caddy::custom_binary_ready \
        && _caddy::definitions_ready \
        && _caddy::cloudflare_file_ready \
        && _caddy::tailnet_ready \
        && ! _caddy::restart_pending gateway \
        && ! _caddy::restart_pending tailscale \
        && systemctl is-enabled --quiet caddy.service \
        && systemctl is-active --quiet caddy.service || {
            primer::status_msg "gateway not ready"
            return 1
        }
    if ! _caddy::dns_resolves; then
        primer::status_msg "Cloudflare DNS records need update"
        return 1
    fi
    _caddy::routes_ready || {
        primer::status_msg "routes need update"
        return 1
    }
    primer::status_msg "gateway ready"
}
