#!/bin/zsh
# modules/git -- Git extension scripts

mod_update() {
    deploy_scripts "$BIN_DIR"
    primer::status_msg "installed"
}

mod_status() {
    local total=0 missing=0 drifted=0 nonexec=0
    local src dst
    for src in "$MOD_DIR"/bin/*(N); do
        total=$(( total + 1 ))
        dst="$BIN_DIR/${src:t}"
        if [[ ! -f "$dst" ]]; then
            missing=$(( missing + 1 ))
            continue
        fi
        [[ -x "$dst" ]] || nonexec=$(( nonexec + 1 ))
        cmp -s "$src" "$dst" || drifted=$(( drifted + 1 ))
    done

    if (( total == 0 )); then
        primer::status_msg "no scripts"
        return 0
    fi

    if (( missing == 0 && drifted == 0 && nonexec == 0 )); then
        primer::status_msg "$total scripts"
        return 0
    fi

    local parts=()
    (( missing > 0 )) && parts+=("${missing} missing")
    (( drifted > 0 )) && parts+=("${drifted} drifted")
    (( nonexec > 0 )) && parts+=("${nonexec} perms")
    primer::status_msg "${(j: · :)parts}"
    return 1
}
