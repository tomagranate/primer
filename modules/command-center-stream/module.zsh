#!/bin/zsh
# modules/command-center-stream -- private Moonlight Web bridge beside Sunshine.

typeset -gr _CC_STREAM_VERSION=3.0.1
typeset -gr _CC_STREAM_SHA256=a46acb1f663faaff9cd97abd9671fe049dd525bfe955e95f7b9f753cc2b99f1a

_command_center_stream::dir() {
    print -r -- "$HOME/.local/share/command-center-stream"
}

_command_center_stream::release() {
    print -r -- "$(_command_center_stream::dir)/releases/$_CC_STREAM_VERSION"
}

_command_center_stream::binary_ready() {
    local release="$(_command_center_stream::release)"
    [[ -x "$release/web-server" && -f "$release/static/index.html" \
        && -f "$release/.archive-sha256" \
        && "$(<"$release/.archive-sha256")" == "$_CC_STREAM_SHA256" ]]
}

# Stage and verify the archive before replacing only its release directory.
_command_center_stream::install_binary() {
    _command_center_stream::binary_ready && return 0
    local dir="$(_command_center_stream::dir)" release="$(_command_center_stream::release)" temp
    mkdir -p "$dir/releases" || return 1
    temp="$(mktemp -d "$dir/releases/.download.XXXXXX")" || return 1
    {
        curl -fsSL "https://github.com/MrCreativ3001/moonlight-web-stream/releases/download/v$_CC_STREAM_VERSION/moonlight-web-x86_64-unknown-linux-gnu.tar.gz" \
            -o "$temp/release.tar.gz" || return 1
        print -r -- "$_CC_STREAM_SHA256  $temp/release.tar.gz" | sha256sum --check --status || {
            print 'Streaming bridge archive checksum failed.' >&2
            return 1
        }
        tar -xzf "$temp/release.tar.gz" -C "$temp" || return 1
        chmod 0755 "$temp/package/web-server" || return 1
        [[ "$("$temp/package/web-server" --version)" == "web-server $_CC_STREAM_VERSION" \
            && -f "$temp/package/static/index.html" ]] || return 1
        print -r -- "$_CC_STREAM_SHA256" > "$temp/package/.archive-sha256" || return 1
        touch "$dir/.restart-required" || return 1
        rm -rf "$release" || return 1
        mv "$temp/package" "$release" || return 1
    } always {
        rm -rf "$temp"
    }
}

# Keep generated defaults and local settings. Set the bridge's required fields.
_command_center_stream::config_contents() {
    local source="$1" machine="$2" ip="$3" dir="$(_command_center_stream::dir)"
    jq --arg machine "$machine" --arg ip "$ip" --arg data "$dir/data.json" '
        .data_storage.type = "json" |
        .data_storage.path = $data |
        .web_server.bind_address = "127.0.0.1:8791" |
        .web_server.url_path_prefix = ("/stream/" + $machine) |
        .web_server.forwarded_header = {
            username_header: "X-CC-User", auto_create_missing_user: true
        } |
        .webrtc.ice_servers = [] |
        .webrtc.ice_server_script = null |
        .webrtc.port_range = {min: 40000, max: 40010} |
        .webrtc.nat_1to1 = {ips: [$ip], ice_candidate_type: "host"} |
        .moonlight.pair_device_name = "command-center"
    ' "$source"
}

# Compare before writing. Leave data.json outside every release directory.
_command_center_stream::install_config() {
    local machine="$1" ip="$2" dir="$(_command_center_stream::dir)" temp source
    temp="$(mktemp -d "$dir/.config.XXXXXX")" || return 1
    {
        source="$dir/config.json"
        if [[ ! -f "$source" ]]; then
            source="$temp/generated.json"
            "$(_command_center_stream::release)/web-server" --config-path "$source" config generate || return 1
        fi
        _command_center_stream::config_contents "$source" "$machine" "$ip" > "$temp/config.json" || return 1
        if ! cmp -s "$source" "$temp/config.json" || [[ "$source" != "$dir/config.json" ]]; then
            touch "$dir/.restart-required" || return 1
            chmod 0600 "$temp/config.json" || return 1
            mv -f "$temp/config.json" "$dir/config.json" || return 1
        fi
    } always {
        rm -rf "$temp"
    }
}

# Install changed files, then start or restart only this bridge's user service.
mod_update() {
    local dir="$(_command_center_stream::dir)" unit_dir="$HOME/.config/systemd/user" machine ip
    if [[ "$DRY_RUN" == true ]]; then
        print "[dry-run] install Moonlight Web $_CC_STREAM_VERSION with pinned SHA-256"
        print '[dry-run] configure loopback HTTP and Tailscale WebRTC; preserve data.json'
        print '[dry-run] enable and start command-center-stream.service beside Sunshine'
        primer::status_msg 'update planned'
        return 0
    fi
    [[ "$(uname -s)" == Linux && "$(uname -m)" == x86_64 ]] || {
        print 'The streaming bridge requires Linux x86_64.' >&2
        return 1
    }
    systemctl --user cat app-dev.lizardbyte.app.Sunshine.service >/dev/null || {
        print 'Install the Sunshine user service before this addon.' >&2
        return 1
    }
    machine="$(hostname -s)" || return 1
    machine="${machine:l}"
    [[ "$machine" == [a-z0-9]* && "$machine" != *[^a-z0-9-]* ]] || return 1
    ip="$(tailscale ip -4)" || return 1
    [[ "$ip" == <0-255>.<0-255>.<0-255>.<0-255> ]] || return 1
    mkdir -p "$dir" "$unit_dir" || return 1
    chmod 0700 "$dir" || return 1
    _command_center_stream::install_binary || return 1
    _command_center_stream::install_config "$machine" "$ip" || return 1
    if ! cmp -s "$MOD_DIR/files/command-center-stream.service" "$unit_dir/command-center-stream.service"; then
        touch "$dir/.restart-required" || return 1
        install -m 0644 "$MOD_DIR/files/command-center-stream.service" "$unit_dir/command-center-stream.service" || return 1
    fi
    systemctl --user is-enabled --quiet command-center-stream.service \
        || systemctl --user enable command-center-stream.service || return 1
    if [[ -e "$dir/.restart-required" ]]; then
        # Retry the reload too if an earlier activation failed after file writes.
        systemctl --user daemon-reload || return 1
        systemctl --user restart command-center-stream.service || return 1
    else
        systemctl --user start command-center-stream.service || return 1
    fi
    systemctl --user is-active --quiet command-center-stream.service || return 1
    rm -f "$dir/.restart-required" || return 1
    primer::status_msg 'streaming bridge ready'
}

# Report the installed release and user service without changing host state.
mod_status() {
    if _command_center_stream::binary_ready \
        && [[ ! -e "$(_command_center_stream::dir)/.restart-required" ]] \
        && systemctl --user is-enabled --quiet command-center-stream.service \
        && systemctl --user is-active --quiet command-center-stream.service; then
        primer::status_msg 'streaming bridge ready'
        return 0
    fi
    primer::status_msg 'streaming bridge not ready'
    return 1
}
