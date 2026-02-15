#!/bin/zsh
# modules/mise -- Language runtimes via mise

mod_update() {
    ensure_brew

    if ! command -v mise &>/dev/null; then
        if [[ "$DRY_RUN" == true ]]; then
            # In dry-run we model intended actions even if binaries are not installed yet.
            primer::status_msg "planning runtimes..."
            echo "[dry-run] mise not found locally; assuming Homebrew install step provides it"
        else
            primer::status_msg "mise not found"
            echo "mise not found — it should have been installed by homebrew."
            echo "Try restarting your shell and running: primer update"
            return 1
        fi
    fi

    primer::status_msg "installing runtimes..."
    local tool name version
    for tool in $(mod_config tools); do
        name="${tool%%:*}"
        version="${tool#*:}"
        if [[ "$DRY_RUN" == true ]]; then
            echo "[dry-run] mise use --global ${name}@${version} --yes"
        else
            mise use --global "${name}@${version}" --yes
        fi
    done
    primer::status_msg "runtimes installed"
}

mod_status() {
    ensure_brew

    if ! command -v mise &>/dev/null; then
        primer::status_msg "mise not installed"
        return 1
    fi

    # List installed runtime names (deduplicated, concise)
    local runtimes=$(mise list --installed 2>/dev/null \
        | awk '{print $1}' \
        | sort -u \
        | paste -sd', ' -)

    if [[ -n "$runtimes" ]]; then
        primer::status_msg "$runtimes"
    else
        primer::status_msg "no runtimes"
    fi
    return 0
}
