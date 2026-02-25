#!/bin/zsh
# modules/homebrew-apps -- Mac apps via Homebrew Cask

mod_update() {
    ensure_brew

    local casks=($(mod_config casks))
    primer::items_init "${casks[@]}"

    local item
    for item in "${casks[@]}"; do
        primer::status_msg "installing $item..."
        primer::item_update "$item" "running"
        if [[ "$DRY_RUN" == true ]]; then
            echo "[dry-run] brew install --cask $item"
            primer::item_update "$item" "done"
        else
            brew install --cask "$item" && primer::item_update "$item" "done" \
                                        || primer::item_update "$item" "failed"
        fi
    done

    primer::status_msg "installed"
}

mod_status() {
    ensure_brew
    if command -v brew &>/dev/null; then
        primer::status_msg "ready"
        return 0
    fi
    primer::status_msg "not installed"
    return 1
}
