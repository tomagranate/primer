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

_plans_media::restart_gateway() {
    local systemctl_bin=systemctl gateway=caddy.service
    if [[ -n "${PLANS_MEDIA_TEST_ROOT:-}" ]]; then
        systemctl_bin="${SYSTEMCTL_BIN:-systemctl}"
        gateway="${CADDY_SERVICE:-caddy.service}"
    fi
    _plans_media::root "$systemctl_bin" restart "$gateway"
}

_plans_media::install_secret_file() {
    local source="$1" target="$2"
    if [[ -n "${PLANS_MEDIA_TEST_ROOT:-}" ]]; then
        install -D -m 0600 "$source" "$target"
    else
        _plans_media::root install -D -o root -g root -m 0600 "$source" "$target"
    fi
}

_plans_media::secret_validity_file() {
    print -r -- "$(_plans_media::secrets_file).valid"
}

_plans_media::restart_marker() {
    print -r -- "$(_plans_media::secrets_file).restart-required"
}

_plans_media::mark_restart() {
    local marker
    marker="$(_plans_media::restart_marker)"
    if [[ -n "${PLANS_MEDIA_TEST_ROOT:-}" ]]; then
        install -D -m 0644 /dev/null "$marker"
    else
        _plans_media::root install -D -o root -g root -m 0644 /dev/null "$marker"
    fi
}

_plans_media::clear_restart() {
    _plans_media::root rm -f "$(_plans_media::restart_marker)"
}

_plans_media::secret_fingerprint() {
    stat -c '%d:%i:%s:%Y' "$(_plans_media::secrets_file)" 2>/dev/null
}

_plans_media::record_secret_validity() {
    local target temp
    target="$(_plans_media::secret_validity_file)"
    temp="$(mktemp)" || return 1
    _plans_media::secret_fingerprint > "$temp" || { rm -f "$temp"; return 1; }
    if [[ -n "${PLANS_MEDIA_TEST_ROOT:-}" ]]; then
        install -D -m 0644 "$temp" "$target"
    else
        _plans_media::root install -D -o root -g root -m 0644 "$temp" "$target"
    fi
    local rc=$?
    rm -f "$temp"
    return "$rc"
}

_plans_media::systemd_env_quote() {
    local value="$1"
    value="${value//\\/\\\\}"
    value="${value//\"/\\\"}"
    print -r -- "\"$value\""
}

_plans_media::gate_assignment() {
    local file="$1" assignments
    assignments="$(_plans_media::root sed -n '/^GATE_SECRET=/p' "$file" 2>/dev/null)" || return 1
    [[ -n "$assignments" && "$assignments" != *$'\n'* ]] || return 1
    case "${assignments#GATE_SECRET=}" in
        ''|'""'|"''") return 1 ;;
    esac
    print -r -- "$assignments"
}

_plans_media::install_secrets() {
    local target legacy gate_ref gate assignment temp
    target="$(_plans_media::secrets_file)"
    gate_ref="$(mod_config gate_secret_ref | head -1)"
    if [[ -n "$gate_ref" ]]; then
        command -v op >/dev/null 2>&1 || { print "op not found" >&2; return 1; }
        gate="$(op read "$gate_ref")" || return 1
    fi

    legacy="$(mod_config legacy_secrets_file | head -1)"
    if [[ -z "$gate" && -n "$legacy" ]] && _plans_media::root test -s "$legacy"; then
        assignment="$(_plans_media::gate_assignment "$legacy")" || return 1
    fi

    if [[ -z "$gate" && -z "$assignment" ]] && _plans_media::root test -s "$target"; then
        _plans_media::gate_assignment "$target" >/dev/null || {
            print "The managed Plans gate secret is invalid." >&2
            return 1
        }
        if ! _plans_media::secrets_ready; then
            _plans_media::mark_restart || return 1
        fi
        if [[ -n "${PLANS_MEDIA_TEST_ROOT:-}" ]]; then
            chmod 0600 "$target"
        else
            _plans_media::root chown root:root "$target" \
                && _plans_media::root chmod 0600 "$target"
        fi
        _plans_media::record_secret_validity
        return $?
    fi
    if [[ -z "$gate" && -z "$assignment" && -z "$gate_ref" ]]; then
        print "Plans secrets are not configured." >&2
        print "Set plans-media.gate_secret_ref to a stable op:// reference." >&2
        return 1
    fi
    [[ -n "$assignment" || ( -n "$gate" && "$gate" != *$'\n'* ) ]] || {
        print "The Plans gate secret must be a non-empty single line." >&2
        return 1
    }
    temp="$(mktemp)" || return 1
    chmod 0600 "$temp"
    if [[ -n "$assignment" ]]; then
        print -r -- "$assignment" >"$temp"
    else
        printf 'GATE_SECRET=%s\n' "$(_plans_media::systemd_env_quote "$gate")" >"$temp"
    fi
    unset gate
    if [[ ! -f "$target" ]] || ! cmp -s "$temp" "$target"; then
        _plans_media::mark_restart || { rm -f "$temp"; return 1; }
    fi
    _plans_media::install_secret_file "$temp" "$target" \
        && _plans_media::record_secret_validity
    local rc=$?
    rm -f "$temp"
    return "$rc"
}

_plans_media::secrets_ready() {
    local file validity owner=root
    file="$(_plans_media::secrets_file)"
    validity="$(_plans_media::secret_validity_file)"
    if [[ -n "${PLANS_MEDIA_TEST_ROOT:-}" ]]; then
        owner="${PLANS_MEDIA_EXPECTED_OWNER:-$(id -un)}"
    fi
    [[ -s "$file" ]] \
        && [[ "$(stat -c %a "$file" 2>/dev/null)" == 600 ]] \
        && [[ "$(stat -c %U "$file" 2>/dev/null)" == "$owner" ]] \
        && [[ -s "$validity" ]] \
        && [[ "$(stat -c %a "$validity" 2>/dev/null)" == 644 ]] \
        && [[ "$(stat -c %U "$validity" 2>/dev/null)" == "$owner" ]] \
        && [[ "$(<"$validity")" == "$(_plans_media::secret_fingerprint)" ]] \
        && [[ ! -e "$(_plans_media::restart_marker)" ]]
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
    _plans_media::restart_gateway \
        && _plans_media::clear_restart \
        || { primer::item_update route failed "restart failed"; return 1; }
    primer::item_update route done
    primer::status_msg "Plans and Media ready"
}

mod_status() {
    local route
    route="$(mktemp)" || return 1
    _plans_media::route_contents >"$route" || { rm -f "$route"; return 1; }
    _plans_media::secrets_ready \
        && "$(_plans_media::route_helper)" status plans-media "$route" || {
            rm -f "$route"
            primer::status_msg "route or secrets not ready"
            return 1
        }
    rm -f "$route"
    primer::status_msg "Plans and Media ready"
}
