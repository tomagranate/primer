#!/bin/zsh
# modules/xcode-cli-tools -- Xcode Command Line Tools setup

_xcode_cli_tools::installed() {
    xcode-select -p &>/dev/null
}

_xcode_cli_tools::install() {
    if [[ "$DRY_RUN" == true ]]; then
        echo "[dry-run] xcode-select --install"
        return 0
    fi

    xcode-select --install
}

mod_update() {
    if _xcode_cli_tools::installed; then
        primer::status_msg "installed"
        return 0
    fi

    primer::status_msg "open installer..."
    _xcode_cli_tools::install || true

    if [[ "$DRY_RUN" == true ]]; then
        primer::status_msg "install requested"
        return 0
    fi

    primer::status_msg "accept installer..."
    echo "Accept the Command Line Tools installer dialog to continue."
    until _xcode_cli_tools::installed; do
        sleep 5
    done

    primer::status_msg "installed"
}

mod_status() {
    if _xcode_cli_tools::installed; then
        primer::status_msg "installed"
        return 0
    fi

    primer::status_msg "missing"
    return 1
}
