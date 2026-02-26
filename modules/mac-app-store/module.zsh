#!/bin/zsh
# modules/mac-app-store -- App Store apps via mas

mod_update() {
    ensure_brew

    # Install mas if not present
    if ! command -v mas &>/dev/null; then
        primer::status_msg "installing mas..."
        if [[ "$DRY_RUN" == true ]]; then
            echo "[dry-run] brew install mas"
        else
            brew install mas
        fi
    fi

    local items=($(mod_config mas))
    local names=()
    local item
    for item in "${items[@]}"; do
        names+=("${item%%:*}")
    done
    primer::items_init "${names[@]}"

    for item in "${items[@]}"; do
        local name="${item%%:*}" id="${item#*:}"
        primer::status_msg "installing $name..."
        primer::item_update "$name" "running"
        if [[ "$DRY_RUN" == true ]]; then
            echo "[dry-run] mas install $id  # $name"
            primer::item_update "$name" "done"
        else
            mas install "$id" && primer::item_update "$name" "done" \
                              || primer::item_update "$name" "failed"
        fi
    done

    primer::status_msg "installed"
}

mod_status() {
    ensure_brew
    if ! command -v mas &>/dev/null; then
        primer::status_msg "mas not installed"
        return 1
    fi

    local items=($(mod_config mas))
    local installed_ids=( $(mas list 2>/dev/null | awk '{print $1}') )
    local missing=0 item id
    for item in "${items[@]}"; do
        id="${item#*:}"
        (( ${installed_ids[(I)$id]} )) || missing=$(( missing + 1 ))
    done

    if (( missing > 0 )); then
        primer::status_msg "${missing} missing"
        return 1
    fi

    primer::status_msg "up to date"
    return 0
}
