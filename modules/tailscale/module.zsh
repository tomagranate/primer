#!/bin/zsh
# modules/tailscale -- Tailscale client via the official Linux installer

_tailscale::install_url() {
    local url="$(mod_config url | head -1)"
    [[ -n "$url" ]] && print -r -- "$url" || print "https://tailscale.com/install.sh"
}

_tailscale::installed() {
    command -v tailscale >/dev/null 2>&1 && tailscale version >/dev/null 2>&1
}

mod_update() {
    local url="$(_tailscale::install_url)"
    primer::items_init "tailscale"

    if [[ "$DRY_RUN" == true ]]; then
        echo "[dry-run] curl -fsSL $url | sudo -n sh"
        primer::item_update "tailscale" "done"
        primer::status_msg "install planned"
        return 0
    fi

    if _tailscale::installed; then
        primer::item_update "tailscale" "done"
        primer::status_msg "installed"
        return 0
    fi

    if ! command -v curl >/dev/null 2>&1; then
        primer::item_update "tailscale" "failed" "curl not found"
        primer::status_msg "curl not found"
        return 1
    fi

    primer::status_msg "installing..."
    if curl -fsSL "$url" | primer::run_as_root "Tailscale" sh; then
        if _tailscale::installed; then
            primer::item_update "tailscale" "done"
            primer::status_msg "installed"
            return 0
        fi

        primer::item_update "tailscale" "failed" "check failed"
        primer::status_msg "install check failed"
        return 1
    fi

    primer::item_update "tailscale" "failed" "installer failed"
    primer::status_msg "install failed"
    return 1
}

mod_status() {
    if _tailscale::installed; then
        primer::status_msg "installed"
        return 0
    fi

    primer::status_msg "not installed"
    return 1
}
