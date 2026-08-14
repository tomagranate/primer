#!/bin/zsh
# modules/agents-sudo -- install the Linux agent sudo-session helper

mod_update() {
    if [[ "$(uname -s)" != Linux ]]; then
        primer::status_msg "Linux only"
        return 1
    fi

    deploy_scripts "$BIN_DIR"
    primer::status_msg "installed"
}

mod_status() {
    if [[ "$(uname -s)" != Linux ]]; then
        primer::status_msg "Linux only"
        return 1
    fi

    local src="$MOD_DIR/bin/agents-sudo"
    local dst="$BIN_DIR/agents-sudo"
    if [[ ! -f "$dst" ]]; then
        primer::status_msg "missing"
        return 1
    fi
    if [[ ! -x "$dst" ]]; then
        primer::status_msg "not executable"
        return 1
    fi
    if ! cmp -s "$src" "$dst"; then
        primer::status_msg "drifted"
        return 1
    fi

    primer::status_msg "installed"
}
