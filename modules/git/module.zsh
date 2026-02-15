#!/bin/zsh
# modules/git -- Git extension scripts

mod_update() {
    deploy_scripts "$BIN_DIR"
    primer::status_msg "installed"
}

mod_status() {
    local total=0 installed=0
    local src
    for src in "$MOD_DIR"/bin/*(N); do
        total=$(( total + 1 ))
        [[ -x "$BIN_DIR/${src:t}" ]] && installed=$(( installed + 1 ))
    done

    if (( total == 0 )); then
        primer::status_msg "no scripts"
        return 0
    fi

    if (( installed == total )); then
        primer::status_msg "$total scripts"
        return 0
    fi
    primer::status_msg "$installed/$total installed"
    return 1
}
