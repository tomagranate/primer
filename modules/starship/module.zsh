#!/bin/zsh
# modules/starship -- Starship prompt configuration

mod_update() {
    deploy_files "$CONFIG_DIR"
    primer::status_msg "configured"
}

mod_status() {
    check_files "$CONFIG_DIR"
}
