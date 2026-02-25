#!/bin/zsh
# modules/homebrew-apps -- Mac apps via Homebrew Cask

mod_update() {
    ensure_brew

    local casks=($(mod_config casks))
    primer::items_init "${casks[@]}"

    # Batch-query installed/outdated state upfront — much faster than per-item brew calls
    local installed_casks=()
    local outdated_casks=()
    if [[ "$DRY_RUN" != true ]]; then
        primer::status_msg "checking apps..."
        installed_casks=( $(brew list --cask 2>/dev/null) )
        outdated_casks=(  $(brew outdated --cask --quiet 2>/dev/null) )
    fi

    local any_failed=false
    local item
    for item in "${casks[@]}"; do
        primer::item_update "$item" "running"
        if [[ "$DRY_RUN" == true ]]; then
            primer::status_msg "installing $item..."
            echo "[dry-run] brew install --cask $item"
            primer::item_update "$item" "done"
        elif ! (( ${installed_casks[(I)$item]} )); then
            primer::status_msg "installing $item..."
            brew install --cask "$item" && primer::item_update "$item" "done" \
                                        || { primer::item_update "$item" "failed"; any_failed=true; }
        elif (( ${outdated_casks[(I)$item]} )); then
            primer::status_msg "updating $item..."
            brew upgrade --cask "$item" && primer::item_update "$item" "done" \
                                        || { primer::item_update "$item" "failed"; any_failed=true; }
        else
            primer::status_msg "$item up to date"
            primer::item_update "$item" "done"
        fi
    done

    if $any_failed; then
        primer::status_msg "completed with errors"
        return 1
    fi
    primer::status_msg "done"
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
