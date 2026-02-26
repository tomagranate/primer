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
    local tools=($(mod_config tools))
    local tool name version

    local labels=()
    for tool in "${tools[@]}"; do
        labels+=("${tool%%:*}@${tool#*:}")
    done
    primer::items_init "${labels[@]}"

    for tool in "${tools[@]}"; do
        name="${tool%%:*}"
        version="${tool#*:}"
        local label="${name}@${version}"
        primer::status_msg "installing $label..."
        primer::item_update "$label" "running"
        if [[ "$DRY_RUN" == true ]]; then
            echo "[dry-run] mise use --global ${label} --yes"
            primer::item_update "$label" "done"
        else
            mise use --global "${label}" --yes \
                && primer::item_update "$label" "done" \
                || primer::item_update "$label" "failed"
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

    local tools=($(mod_config tools))
    local installed_names=( $(mise list --installed 2>/dev/null | awk '{print $1}' | sort -u) )
    local missing=0 tool name
    for tool in "${tools[@]}"; do
        name="${tool%%:*}"
        (( ${installed_names[(I)$name]} )) || missing=$(( missing + 1 ))
    done

    if (( missing > 0 )); then
        primer::status_msg "${missing} missing"
        return 1
    fi

    primer::status_msg "up to date"
    return 0
}
