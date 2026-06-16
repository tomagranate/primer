#!/bin/zsh
# modules/xcode-clt -- Xcode Command Line Tools

_xcode_clt::installed() {
    xcode-select -p &>/dev/null
}

mod_update() {
    if _xcode_clt::installed; then
        primer::status_msg "installed"
        return 0
    fi

    primer::status_msg "installing..."
    run xcode-select --install

    if [[ "$DRY_RUN" != true ]]; then
        echo "Waiting for Xcode Command Line Tools installation..."
        until _xcode_clt::installed; do
            sleep 5
        done
    fi

    primer::status_msg "installed"
}

mod_status() {
    if _xcode_clt::installed; then
        primer::status_msg "installed"
        return 0
    fi

    primer::status_msg "missing"
    return 1
}
