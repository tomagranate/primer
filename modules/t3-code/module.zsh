#!/bin/zsh
# modules/t3-code -- Persistent T3 Code server over Tailscale Serve

_t3_code::port() {
    local key="$1" fallback="$2" value
    value="$(mod_config "$key" | head -1)"
    [[ -n "$value" ]] || value="$fallback"
    [[ "$value" == <1-65535> ]] || return 1
    print -r -- "$value"
}

_t3_code::local_port() {
    _t3_code::port local_port 3773
}

_t3_code::serve_port() {
    _t3_code::port tailscale_serve_port 443
}

_t3_code::unit_dir() {
    print -r -- "${T3_CODE_SYSTEMD_USER_DIR:-$HOME/.config/systemd/user}"
}

_t3_code::drop_in_path() {
    print -r -- "$(_t3_code::unit_dir)/t3code.service.d/primer.conf"
}

_t3_code::drop_in_contents() {
    local local_port="$1"
    print -r -- "[Service]"
    print -r -- "Environment=T3CODE_MODE=web"
    print -r -- "Environment=T3CODE_HOST=127.0.0.1"
    print -r -- "Environment=T3CODE_PORT=$local_port"
}

_t3_code::drop_in_matches() {
    local local_port="$1" target
    target="$(_t3_code::drop_in_path)"
    [[ -f "$target" ]] || return 1
    [[ "$(<"$target")" == "$(_t3_code::drop_in_contents "$local_port")" ]]
}

_t3_code::install_drop_in() {
    local local_port="$1" target dir tmp
    target="$(_t3_code::drop_in_path)"
    dir="${target:h}"
    mkdir -p "$dir" || return 1
    tmp="$(mktemp "$dir/.primer.conf.XXXXXX")" || return 1
    _t3_code::drop_in_contents "$local_port" > "$tmp" || {
        rm -f "$tmp"
        return 1
    }
    if [[ -f "$target" ]] && cmp -s "$tmp" "$target"; then
        rm -f "$tmp"
        return 0
    fi
    mv "$tmp" "$target"
}

_t3_code::serve_matches() {
    local local_port="$1" serve_port="$2" serve_json
    serve_json="$(tailscale serve status --json 2>/dev/null)" || return 1
    serve_json="${serve_json//[[:space:]]/}"
    [[ "$serve_json" == *"\"$serve_port\""* ]] || return 1
    [[ "$serve_json" == *"\"Proxy\":\"http://127.0.0.1:$local_port\""* ]]
}

mod_update() {
    local local_port serve_port
    local_port="$(_t3_code::local_port)" || {
        primer::status_msg "invalid local port"
        return 1
    }
    serve_port="$(_t3_code::serve_port)" || {
        primer::status_msg "invalid Tailscale Serve port"
        return 1
    }
    primer::items_init "service" "tailscale-serve"

    if [[ "$DRY_RUN" == true ]]; then
        echo "[dry-run] t3 service install"
        echo "[dry-run] systemctl --user restart t3code.service"
        echo "[dry-run] tailscale serve --bg --https=$serve_port http://127.0.0.1:$local_port"
        primer::item_update "service" "done"
        primer::item_update "tailscale-serve" "done"
        primer::status_msg "service planned"
        return 0
    fi

    local command
    for command in t3 tailscale systemctl; do
        if ! command -v "$command" >/dev/null 2>&1; then
            primer::status_msg "$command not found"
            return 1
        fi
    done

    primer::status_msg "installing service..."
    if ! t3 service install; then
        primer::item_update "service" "failed" "service install failed"
        primer::status_msg "service install failed"
        return 1
    fi

    if ! _t3_code::install_drop_in "$local_port" \
        || ! systemctl --user daemon-reload \
        || ! systemctl --user restart t3code.service \
        || ! systemctl --user is-active --quiet t3code.service; then
        primer::item_update "service" "failed" "service start failed"
        primer::status_msg "service start failed"
        return 1
    fi
    primer::item_update "service" "done"

    primer::status_msg "configuring Tailscale Serve..."
    if ! tailscale serve --bg --https="$serve_port" "http://127.0.0.1:$local_port" \
        || ! _t3_code::serve_matches "$local_port" "$serve_port"; then
        primer::item_update "tailscale-serve" "failed" "proxy setup failed"
        primer::status_msg "Tailscale Serve setup failed"
        return 1
    fi
    primer::item_update "tailscale-serve" "done"
    primer::status_msg "available over Tailscale"
}

mod_status() {
    local local_port serve_port
    local_port="$(_t3_code::local_port)" || {
        primer::status_msg "invalid local port"
        return 1
    }
    serve_port="$(_t3_code::serve_port)" || {
        primer::status_msg "invalid Tailscale Serve port"
        return 1
    }

    command -v t3 >/dev/null 2>&1 \
        && command -v tailscale >/dev/null 2>&1 \
        && command -v systemctl >/dev/null 2>&1 \
        && t3 service status 2>/dev/null | grep -Fq "Status: installed" \
        && systemctl --user is-enabled --quiet t3code.service \
        && systemctl --user is-active --quiet t3code.service \
        && _t3_code::drop_in_matches "$local_port" \
        && _t3_code::serve_matches "$local_port" "$serve_port" || {
            primer::status_msg "service or proxy not ready"
            return 1
        }

    primer::status_msg "available over Tailscale"
}
