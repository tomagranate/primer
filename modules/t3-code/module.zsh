#!/bin/zsh
# modules/t3-code -- Persistent T3 Code server over Tailscale Serve

_t3_code::mise_bin() {
    if command -v mise >/dev/null 2>&1; then
        command -v mise
        return 0
    fi
    local candidate
    for candidate in \
        "$HOME/.local/bin/mise" \
        "$HOME/.mise/bin/mise" \
        "$HOME/bin/mise" \
        "/opt/homebrew/bin/mise" \
        "/usr/local/bin/mise"; do
        [[ -x "$candidate" ]] || continue
        print -r -- "$candidate"
        return 0
    done
    return 1
}

_t3_code::run() {
    if command -v "$1" >/dev/null 2>&1; then
        "$@"
        return $?
    fi
    local mise_bin
    mise_bin="$(_t3_code::mise_bin)" || return 127
    "$mise_bin" exec -- "$@"
}

_t3_code::have() {
    command -v "$1" >/dev/null 2>&1 && return 0
    local mise_bin
    mise_bin="$(_t3_code::mise_bin)" || return 1
    "$mise_bin" exec -- command -v "$1" >/dev/null 2>&1
}

_t3_code::fail_items() {
    local detail="$1" item
    print -r -- "$detail"
    for item in service tailscale-serve desktop-app; do
        primer::item_update "$item" "failed" "$detail"
        primer::item_log "$item" "$detail"
    done
}

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

_t3_code::applications_dir() {
    print -r -- "${T3_CODE_APPLICATIONS_DIR:-$HOME/.local/share/applications}"
}

_t3_code::launcher_path() {
    print -r -- "$(_t3_code::applications_dir)/t3-code.desktop"
}

_t3_code::icon_path() {
    print -r -- "${T3_CODE_ICON_PATH:-$HOME/.local/share/icons/t3-code.png}"
}

_t3_code::browser_command() {
    local command_name
    command_name="$(mod_config browser_command | head -1)"
    [[ -n "$command_name" ]] || command_name=google-chrome-stable
    command -v "$command_name" 2>/dev/null
}

_t3_code::window_size() {
    local value
    value="$(mod_config window_size | head -1)"
    [[ "$value" == <1-9><0-9>##,<1-9><0-9>## ]] || value=1400,900
    print -r -- "$value"
}

_t3_code::window_position() {
    local value
    value="$(mod_config window_position | head -1)"
    [[ "$value" == <0-9>##,<0-9>## ]] || value=324,110
    print -r -- "$value"
}

_t3_code::launcher_contents() {
    local browser="$1" local_port="$2" icon_path="$3"
    print -r -- '[Desktop Entry]'
    print -r -- 'Type=Application'
    print -r -- 'Name=T3 Code'
    print -r -- 'Comment=Open the local T3 Code workspace'
    print -r -- "Exec=$browser --ozone-platform=x11 --user-data-dir=$HOME/.local/share/t3-code-browser --no-first-run --window-size=$(_t3_code::window_size) --window-position=$(_t3_code::window_position) --app=http://127.0.0.1:$local_port --class=T3Code"
    print -r -- "Icon=$icon_path"
    print -r -- 'Terminal=false'
    print -r -- 'Categories=Development;'
    print -r -- 'StartupNotify=true'
    print -r -- 'StartupWMClass=T3Code'
}

_t3_code::find_icon() {
    local -a candidates
    candidates=("$HOME"/.t3/runtime/versions/*/node_modules/t3/dist/client/apple-touch-icon.png(N.om))
    (( ${#candidates} > 0 )) && print -r -- "$candidates[1]"
}

_t3_code::install_launcher() {
    [[ "$(uname -s)" == Linux ]] || return 0

    local browser local_port source_icon icon_path launcher tmp
    local_port="$(_t3_code::local_port)" || return 1
    icon_path="$(_t3_code::icon_path)"
    launcher="$(_t3_code::launcher_path)"

    if [[ "$DRY_RUN" == true ]]; then
        echo "[dry-run] install T3 Code desktop app at $launcher"
        return 0
    fi

    browser="$(_t3_code::browser_command)" || return 1
    source_icon="$(_t3_code::find_icon)" || return 1
    mkdir -p "${launcher:h}" "${icon_path:h}" || return 1
    cp "$source_icon" "$icon_path" || return 1
    tmp="$(mktemp "${launcher:h}/.t3-code.desktop.XXXXXX")" || return 1
    _t3_code::launcher_contents "$browser" "$local_port" "$icon_path" > "$tmp" || {
        rm -f "$tmp"
        return 1
    }
    chmod 0644 "$tmp"
    mv "$tmp" "$launcher" || return 1
    command -v update-desktop-database >/dev/null 2>&1 \
        && update-desktop-database "${launcher:h}" >/dev/null 2>&1 || true
}

_t3_code::launcher_matches() {
    [[ "$(uname -s)" == Linux ]] || return 0
    local browser local_port icon_path expected
    browser="$(_t3_code::browser_command)" || return 1
    local_port="$(_t3_code::local_port)" || return 1
    icon_path="$(_t3_code::icon_path)"
    [[ -f "$icon_path" && -f "$(_t3_code::launcher_path)" ]] || return 1
    expected="$(mktemp)" || return 1
    _t3_code::launcher_contents "$browser" "$local_port" "$icon_path" > "$expected"
    cmp -s "$expected" "$(_t3_code::launcher_path)"
    local rc=$?
    rm -f "$expected"
    return "$rc"
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
    primer::items_init "service" "tailscale-serve" "desktop-app"

    if [[ "$DRY_RUN" == true ]]; then
        echo "[dry-run] t3 service install"
        echo "[dry-run] systemctl --user restart t3code.service"
        echo "[dry-run] tailscale serve --bg --https=$serve_port http://127.0.0.1:$local_port"
        _t3_code::install_launcher || return 1
        primer::item_update "service" "done"
        primer::item_update "tailscale-serve" "done"
        primer::item_update "desktop-app" "done"
        primer::status_msg "service planned"
        return 0
    fi

    local command
    for command in t3 tailscale systemctl; do
        if ! _t3_code::have "$command"; then
            _t3_code::fail_items "$command not found"
            primer::status_msg "$command not found"
            return 1
        fi
    done

    primer::status_msg "installing service..."
    if ! _t3_code::run t3 service install; then
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

    primer::status_msg "installing desktop app..."
    if ! _t3_code::install_launcher; then
        primer::item_update "desktop-app" "failed" "launcher install failed"
        primer::status_msg "desktop app install failed"
        return 1
    fi
    primer::item_update "desktop-app" "done"
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

    _t3_code::have t3 \
        && command -v tailscale >/dev/null 2>&1 \
        && command -v systemctl >/dev/null 2>&1 \
        && _t3_code::run t3 service status 2>/dev/null | grep -Fq "Status: installed" \
        && systemctl --user is-enabled --quiet t3code.service \
        && systemctl --user is-active --quiet t3code.service \
        && _t3_code::drop_in_matches "$local_port" \
        && _t3_code::serve_matches "$local_port" "$serve_port" \
        && _t3_code::launcher_matches || {
            primer::status_msg "service or proxy not ready"
            return 1
        }

    primer::status_msg "available over Tailscale"
}
