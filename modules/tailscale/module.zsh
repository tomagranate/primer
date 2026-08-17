#!/bin/zsh
# modules/tailscale -- Tailscale client via the official Linux installer

_tailscale::install_url() {
    local url="$(mod_config url | head -1)"
    [[ -n "$url" ]] && print -r -- "$url" || print "https://tailscale.com/install.sh"
}

_tailscale::installed() {
    command -v tailscale >/dev/null 2>&1 && tailscale version >/dev/null 2>&1
}

_tailscale::connected() {
    tailscale status >/dev/null 2>&1
}

_tailscale::ssh_enabled() {
    tailscale debug prefs 2>/dev/null | grep -Eq '"RunSSH":[[:space:]]*true'
}

_tailscale::run_as_root() {
    primer::run_as_root "Tailscale" "$@"
}

_tailscale::enable_ssh() {
    if [[ "$DRY_RUN" == true ]]; then
        echo "[dry-run] sudo tailscale set --ssh"
        primer::item_update "ssh" "done" "planned"
        return 0
    fi

    if ! _tailscale::connected; then
        primer::item_update "ssh" "skipped" "waiting for login"
        return 0
    fi

    if _tailscale::ssh_enabled; then
        primer::item_update "ssh" "skipped" "already enabled"
        return 0
    fi

    if _tailscale::run_as_root tailscale set --ssh && _tailscale::ssh_enabled; then
        primer::item_update "ssh" "done" "enabled"
        return 0
    fi

    primer::item_update "ssh" "failed" "enable failed"
    return 1
}

mod_update() {
    local url="$(_tailscale::install_url)"
    primer::items_init "tailscale" "ssh"

    if [[ "$DRY_RUN" == true ]]; then
        echo "[dry-run] curl -fsSL $url | sudo -n sh"
        primer::item_update "tailscale" "done"
        _tailscale::enable_ssh || return 1
        primer::status_msg "install planned"
        return 0
    fi

    if _tailscale::installed; then
        primer::item_update "tailscale" "done"
    else
        if ! command -v curl >/dev/null 2>&1; then
            primer::item_update "tailscale" "failed" "curl not found"
            primer::item_update "ssh" "failed" "client missing"
            primer::status_msg "curl not found"
            return 1
        fi

        primer::status_msg "installing..."
        if ! curl -fsSL "$url" | _tailscale::run_as_root sh; then
            primer::item_update "tailscale" "failed" "installer failed"
            primer::item_update "ssh" "failed" "client missing"
            primer::status_msg "install failed"
            return 1
        fi
        if ! _tailscale::installed; then
            primer::item_update "tailscale" "failed" "check failed"
            primer::item_update "ssh" "failed" "client missing"
            primer::status_msg "install check failed"
            return 1
        fi
        primer::item_update "tailscale" "done"
    fi

    primer::status_msg "enabling Tailscale SSH..."
    _tailscale::enable_ssh || {
        primer::status_msg "ssh enable failed"
        return 1
    }

    if _tailscale::connected && _tailscale::ssh_enabled; then
        primer::status_msg "installed with ssh"
    else
        primer::status_msg "installed"
    fi
}

mod_status() {
    if ! _tailscale::installed; then
        primer::status_msg "not installed"
        return 1
    fi

    if _tailscale::connected && ! _tailscale::ssh_enabled; then
        primer::status_msg "ssh disabled"
        return 1
    fi

    if _tailscale::connected; then
        primer::status_msg "installed with ssh"
        return 0
    fi

    primer::status_msg "installed"
    return 0
}
