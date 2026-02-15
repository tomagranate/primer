#!/bin/zsh
# modules/xcode -- Xcode Command Line Tools

mod_update() {
    if xcode-select -p &>/dev/null; then
        primer::status_msg "already installed"
        return 0
    fi

    primer::status_msg "installing..."
    run xcode-select --install

    if [[ "$DRY_RUN" != true ]]; then
        echo "Waiting for Xcode CLT installation..."
        until xcode-select -p &>/dev/null; do
            sleep 5
        done
    fi

    primer::status_msg "installed"
}

mod_status() {
    if xcode-select -p &>/dev/null; then
        primer::status_msg "installed"
        return 0
    fi
    primer::status_msg "not installed"
    return 1
}
