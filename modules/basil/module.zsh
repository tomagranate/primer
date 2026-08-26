#!/bin/zsh
# modules/basil -- Basil's local services and shared-gateway routes

_basil::repo() {
    local repo_path
    repo_path="$(mod_config repo_path | head -1)"
    print -r -- "${repo_path/#\~/$HOME}"
}

_basil::unit_dir() {
    print -r -- "${BASIL_SYSTEMD_USER_DIR:-$HOME/.config/systemd/user}"
}

_basil::config_dir() {
    print -r -- "${BASIL_CONFIG_DIR:-$HOME/.config/primer/basil}"
}

_basil::route_helper() {
    print -r -- "${CADDY_ROUTE_HELPER:-/usr/local/libexec/primer-caddy-route}"
}

_basil::root() {
    local reason="$1"
    shift
    if [[ -n "${BASIL_TEST_ROOT:-}" ]]; then
        [[ -z "${BASIL_ROOT_LOG:-}" ]] || print -r -- "$*" >> "$BASIL_ROOT_LOG"
        "$@"
    else
        primer::run_as_root "$reason" "$@"
    fi
}

_basil::docker() {
    _basil::root "manage Basil containers" env BASIL_REPO="$(_basil::repo)" docker "$@"
}

_basil::cloudflared_version() {
    local version
    version="$(mod_config cloudflared_version | head -1)"
    [[ "$version" == <->.<->.<-> ]] || {
        print "basil.cloudflared_version is invalid" >&2
        return 1
    }
    print -r -- "$version"
}

_basil::cloudflared_ready() {
    local version target="$HOME/.local/bin/cloudflared"
    version="$(_basil::cloudflared_version)" || return 1
    [[ -x "$target" ]] && "$target" --version 2>/dev/null | grep -Fq "version $version "
}

_basil::install_cloudflared() {
    local version architecture target temp
    version="$(_basil::cloudflared_version)" || return 1
    case "$(uname -m)" in
        x86_64) architecture=amd64 ;;
        aarch64|arm64) architecture=arm64 ;;
        *) print "cloudflared does not support this architecture: $(uname -m)" >&2; return 1 ;;
    esac
    target="$HOME/.local/bin/cloudflared"
    _basil::cloudflared_ready && return 0
    mkdir -p "$HOME/.local/bin"
    temp="$(mktemp)" || return 1
    curl -fsSL \
        "https://github.com/cloudflare/cloudflared/releases/download/$version/cloudflared-linux-$architecture" \
        -o "$temp" || { rm -f "$temp"; return 1; }
    install -m 0755 "$temp" "$target" || { rm -f "$temp"; return 1; }
    rm -f "$temp"
    "$target" --version 2>/dev/null | grep -Fq "version $version "
}

_basil::required_sources() {
    local repo="$(_basil::repo)" file
    for file in \
        deploy/basil-tunnel.service \
        deploy/basil-webhook-shim.service \
        deploy/basil-brain-sync.service \
        deploy/basil-brain-sync.timer \
        deploy/brain-sync.sh \
        deploy/infra/kuma-webhook-shim.py; do
        [[ -f "$repo/$file" ]] || { print "Basil source is missing: $repo/$file" >&2; return 1; }
    done
}

_basil::required_credentials() {
    local repo="$(_basil::repo)" file
    for file in deploy/infra/tunnel.env deploy/infra/webhook-shim.env; do
        [[ -s "$repo/$file" ]] || {
            print "Basil credential file is missing: $repo/$file" >&2
            print "Create it from Basil's documented secret setup before enabling this addon." >&2
            return 1
        }
        chmod 0600 "$repo/$file" || return 1
    done
}

_basil::install_units() {
    local repo="$(_basil::repo)" unit_dir="$(_basil::unit_dir)" unit
    local -a restart_units=()
    mkdir -p "$unit_dir"
    for unit in basil-tunnel.service basil-webhook-shim.service basil-brain-sync.service basil-brain-sync.timer; do
        if [[ ! -f "$unit_dir/$unit" ]] || ! cmp -s "$repo/deploy/$unit" "$unit_dir/$unit"; then
            systemctl --user is-active --quiet "$unit" && restart_units+=("$unit")
        fi
        install -m 0644 "$repo/deploy/$unit" "$unit_dir/$unit" || return 1
    done
    systemctl --user daemon-reload || return 1
    (( ${#restart_units[@]} == 0 )) || systemctl --user restart "${restart_units[@]}"
}

_basil::definitions_match() {
    local repo="$(_basil::repo)" unit_dir="$(_basil::unit_dir)" config_dir="$(_basil::config_dir)" unit
    for unit in basil-tunnel.service basil-webhook-shim.service basil-brain-sync.service basil-brain-sync.timer; do
        [[ -f "$repo/deploy/$unit" && -f "$unit_dir/$unit" ]] \
            && cmp -s "$repo/deploy/$unit" "$unit_dir/$unit" || return 1
    done
    [[ -f "$config_dir/compose.yaml" ]] \
        && cmp -s "$MOD_DIR/files/compose.yaml" "$config_dir/compose.yaml"
}

_basil::install_compose() {
    local repo="$(_basil::repo)" config_dir="$(_basil::config_dir)" current_config
    mkdir -p "$config_dir"
    install -m 0644 "$MOD_DIR/files/compose.yaml" "$config_dir/compose.yaml" || return 1
    current_config="$(_basil::docker inspect --format '{{ index .Config.Labels "com.docker.compose.project.config_files" }}' ntfy 2>/dev/null || true)"
    if [[ -n "$current_config" && "$current_config" != "$config_dir/compose.yaml" ]]; then
        # The old Basil compose file binds 8090 directly. Its bind-mounted data
        # survives this one-time container migration behind Caddy.
        _basil::docker compose --file "$repo/deploy/infra/compose.yaml" down || return 1
    fi
    _basil::docker compose --project-name basil --file "$config_dir/compose.yaml" up -d
}

_basil::route_contents() {
    local ntfy_port kuma_port hostname
    ntfy_port="$(mod_config ntfy_gateway_port | head -1)"
    kuma_port="$(mod_config kuma_gateway_port | head -1)"
    [[ "$ntfy_port" == <1-65535> && "$kuma_port" == <1-65535> ]] || return 1
    hostname="$(_basil::tailnet_hostname)" || return 1
    print -r -- "http://127.0.0.1:$ntfy_port {"
    print -r -- '    reverse_proxy http://127.0.0.1:18090'
    print -r -- '}'
    print -r -- "https://$hostname:$kuma_port {"
    print -r -- '    import tailnet'
    print -r -- '    reverse_proxy http://127.0.0.1:18091'
    print -r -- '}'
}

_basil::tailnet_hostname() {
    local hostname="${CADDY_TAILSCALE_HOSTNAME:-}"
    if [[ -z "$hostname" && -r "${CADDY_TAILNET_ENV:-/run/caddy/tailnet.env}" ]]; then
        hostname="$(sed -n 's/^TAILSCALE_HOSTNAME=//p' "${CADDY_TAILNET_ENV:-/run/caddy/tailnet.env}" | head -1)"
    fi
    print -r -- "$hostname" | grep -Eq '^[A-Za-z0-9.-]+$' || return 1
    print -r -- "$hostname"
}

_basil::install_route() {
    local temp
    temp="$(mktemp)" || return 1
    _basil::route_contents >"$temp" || { rm -f "$temp"; return 1; }
    _basil::root "install Basil routes" "$(_basil::route_helper)" install basil "$temp"
    local rc=$?
    rm -f "$temp"
    return "$rc"
}

_basil::enable_services() {
    command -v hermes >/dev/null 2>&1 || { print "hermes not found" >&2; return 1; }
    _basil::install_cloudflared || { print "cloudflared install failed" >&2; return 1; }
    hermes gateway install || return 1
    systemctl --user enable --now hermes-gateway.service || return 1
    systemctl --user enable --now basil-tunnel.service basil-webhook-shim.service basil-brain-sync.timer
}

_basil::enable_docker() {
    _basil::root "enable Docker for Basil" systemctl enable --now docker.service
}

_basil::containers_ready() {
    curl -fsS --max-time 5 http://127.0.0.1:18090/v1/health >/dev/null \
        && curl -fsS --max-time 5 http://127.0.0.1:18091/ >/dev/null
}

_basil::boot_ready() {
    [[ "$(loginctl show-user "${USER:-$LOGNAME}" -p Linger --value 2>/dev/null)" == yes ]] \
        && systemctl is-enabled --quiet docker.service
}

mod_update() {
    primer::items_init gateway tunnel webhook brain-sync containers route
    if [[ "$DRY_RUN" == true ]]; then
        print "[dry-run] verify Basil source and credential files under $(_basil::repo)"
        print "[dry-run] install Hermes, cloudflared, tunnel, webhook, and brain-sync user services"
        print "[dry-run] sudo systemctl enable --now docker.service"
        print "[dry-run] docker compose --project-name basil up -d"
        print "[dry-run] install Caddy route basil"
        local item
        for item in gateway tunnel webhook brain-sync containers route; do primer::item_update "$item" done; done
        primer::status_msg "services planned"
        return 0
    fi

    _basil::install_cloudflared || return 1
    _basil::required_sources && _basil::required_credentials || return 1
    _basil::install_units || return 1
    _basil::root "enable Basil user services at boot" loginctl enable-linger "${USER:-$LOGNAME}" || return 1
    _basil::enable_services || return 1
    primer::item_update gateway done
    primer::item_update tunnel done
    primer::item_update webhook done
    primer::item_update brain-sync done
    _basil::enable_docker || { primer::item_update containers failed "Docker service failed"; return 1; }
    _basil::install_compose || { primer::item_update containers failed "compose failed"; return 1; }
    primer::item_update containers done
    _basil::install_route || { primer::item_update route failed "validation failed"; return 1; }
    primer::item_update route done
    primer::status_msg "Basil ready"
}

mod_status() {
    local unit route
    _basil::cloudflared_ready || {
        primer::status_msg "cloudflared needs update"
        return 1
    }
    _basil::definitions_match || {
        primer::status_msg "service definitions need update"
        return 1
    }
    _basil::boot_ready || {
        primer::status_msg "boot services need update"
        return 1
    }
    for unit in hermes-gateway.service basil-tunnel.service basil-webhook-shim.service basil-brain-sync.timer; do
        systemctl --user is-enabled --quiet "$unit" && systemctl --user is-active --quiet "$unit" || {
            primer::status_msg "$unit not ready"
            return 1
        }
    done
    route="$(mktemp)" || return 1
    _basil::route_contents >"$route" || { rm -f "$route"; return 1; }
    _basil::containers_ready \
        && "$(_basil::route_helper)" status basil "$route" || {
            rm -f "$route"
            primer::status_msg "containers or route not ready"
            return 1
        }
    rm -f "$route"
    primer::status_msg "Basil ready"
}
