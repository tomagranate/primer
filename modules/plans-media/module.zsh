#!/bin/zsh
# modules/plans-media -- Plans and Media gateway route for Agents infrastructure

_plans_media::root_path() {
    print -r -- "${PLANS_MEDIA_ROOT_DIR:-}$1"
}

_plans_media::root() {
    if [[ -n "${PLANS_MEDIA_TEST_ROOT:-}" ]]; then "$@"; else primer::run_as_root "configure Plans and Media" "$@"; fi
}

_plans_media::secrets_file() {
    print -r -- "${PLANS_MEDIA_SECRETS_FILE:-$(_plans_media::root_path /etc/caddy/env.d/plans-media.env)}"
}

_plans_media::route_helper() {
    print -r -- "${CADDY_ROUTE_HELPER:-$(_plans_media::root_path /usr/local/libexec/primer-caddy-route)}"
}

_plans_media::fragment_helper() {
    print -r -- "${CADDY_FRAGMENT_HELPER:-$PRIMER_DIR/modules/caddy/files/usr/local/libexec/primer-caddy-fragment}"
}

_plans_media::install_secret_file() {
    local source="$1" target="$2"
    if [[ -n "${PLANS_MEDIA_TEST_ROOT:-}" ]]; then
        install -D -m 0600 "$source" "$target"
    else
        _plans_media::root install -D -o root -g root -m 0600 "$source" "$target"
    fi
}

_plans_media::install_secrets() {
    local target legacy gate_ref gate temp
    target="$(_plans_media::secrets_file)"
    gate_ref="$(mod_config gate_secret_ref | head -1)"
    if [[ -n "$gate_ref" ]]; then
        command -v op >/dev/null 2>&1 || { print "op not found" >&2; return 1; }
        gate="$(op read "$gate_ref")" || return 1
    fi

    legacy="$(mod_config legacy_secrets_file | head -1)"
    if [[ -z "$gate" && -n "$legacy" ]] && _plans_media::root test -s "$legacy"; then
        gate="$(_plans_media::root sed -n 's/^GATE_SECRET=//p' "$legacy" 2>/dev/null | head -1)"
    fi

    if [[ -z "$gate" ]] && _plans_media::root test -s "$target"; then
        gate="$(_plans_media::root sed -n 's/^GATE_SECRET=//p' "$target" 2>/dev/null | head -1)"
    fi
    if [[ -z "$gate" && -z "$gate_ref" ]]; then
        print "Plans secrets are not configured." >&2
        print "Set plans-media.gate_secret_ref to a stable op:// reference." >&2
        return 1
    fi
    [[ -n "$gate" && "$gate" != *$'\n'* ]] || {
        print "The Plans gate secret must be a non-empty single line." >&2
        return 1
    }
    temp="$(mktemp)" || return 1
    chmod 0600 "$temp"
    printf 'GATE_SECRET=%s\n' "$gate" >"$temp"
    unset gate
    _plans_media::install_secret_file "$temp" "$target"
    local rc=$?
    rm -f "$temp"
    return "$rc"
}

_plans_media::route_contents() {
    local host worker
    host="$(mod_config host | head -1)"
    worker="$(mod_config worker_host | head -1)"
    print -r -- "$host" | grep -Eq '^[A-Za-z0-9.-]+$' || return 1
    print -r -- "$worker" | grep -Eq '^[A-Za-z0-9.-]+$' || return 1
    "$(_plans_media::fragment_helper)" plans-media "$host" "$worker"
}

_plans_media::install_route() {
    local temp
    temp="$(mktemp)" || return 1
    _plans_media::route_contents >"$temp" || { rm -f "$temp"; return 1; }
    _plans_media::root "$(_plans_media::route_helper)" install plans-media "$temp"
    local rc=$?
    rm -f "$temp"
    return "$rc"
}

mod_update() {
    primer::items_init secrets route
    if [[ "$DRY_RUN" == true ]]; then
        print "[dry-run] install root-owned mode 0600 Plans secret environment"
        print "[dry-run] install Caddy route plans-media -> $(mod_config worker_host | head -1)"
        primer::item_update secrets done
        primer::item_update route done
        primer::status_msg "route planned"
        return 0
    fi
    _plans_media::install_secrets || { primer::item_update secrets failed "configuration required"; return 1; }
    primer::item_update secrets done
    _plans_media::install_route || { primer::item_update route failed "validation failed"; return 1; }
    primer::item_update route done
    primer::status_msg "Plans and Media ready"
}

mod_status() {
    local route
    route="$(mktemp)" || return 1
    _plans_media::route_contents >"$route" || { rm -f "$route"; return 1; }
    _plans_media::root test -s "$(_plans_media::secrets_file)" \
        && _plans_media::root test "$(stat -c %a "$(_plans_media::secrets_file)" 2>/dev/null || true)" = 600 \
        && _plans_media::root "$(_plans_media::route_helper)" status plans-media "$route" || {
            rm -f "$route"
            primer::status_msg "route or secrets not ready"
            return 1
        }
    rm -f "$route"
    primer::status_msg "Plans and Media ready"
}
