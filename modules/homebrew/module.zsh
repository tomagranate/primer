#!/bin/zsh
# modules/homebrew -- Homebrew package manager + formulae from config

mod_update() {
    # Install Homebrew if missing
    if ! command -v brew &>/dev/null && [[ ! -x /opt/homebrew/bin/brew ]]; then
        primer::status_msg "installing Homebrew..."
        if [[ "$DRY_RUN" == true ]]; then
            echo "[dry-run] Install Homebrew"
        else
            /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
        fi
    fi
    ensure_brew

    primer::status_msg "updating Homebrew..."
    run brew update

    local taps=($(mod_config taps))
    local formulae=($(mod_config formulae))
    local casks=($(mod_config casks))

    # Initialise sub-item list with all packages
    primer::items_init "${taps[@]}" "${formulae[@]}" "${casks[@]}"

    # Batch-query installed/outdated state upfront — much faster than per-item brew calls
    local installed_taps=()
    local installed_formulae=()
    local outdated_formulae=()
    local installed_casks=()
    local outdated_casks=()
    if [[ "$DRY_RUN" != true ]]; then
        primer::status_msg "checking packages..."
        installed_taps=(     $(brew tap 2>/dev/null) )
        installed_formulae=( $(brew list --formula 2>/dev/null) )
        outdated_formulae=(  $(brew outdated --formula --quiet 2>/dev/null) )
        installed_casks=(    $(brew list --cask 2>/dev/null) )
        outdated_casks=(     $(brew outdated --cask --quiet 2>/dev/null) )
    fi

    local any_failed=false
    local item

    for item in "${taps[@]}"; do
        primer::item_update "$item" "running"
        if [[ "$DRY_RUN" == true ]]; then
            primer::status_msg "tapping $item..."
            echo "[dry-run] brew tap $item"
            primer::item_update "$item" "done"
        elif (( ${installed_taps[(I)$item]} )); then
            primer::status_msg "$item up to date"
            primer::item_update "$item" "done"
        else
            primer::status_msg "tapping $item..."
            brew tap "$item" && primer::item_update "$item" "done" \
                             || { primer::item_update "$item" "failed"; any_failed=true; }
        fi
    done

    for item in "${formulae[@]}"; do
        primer::item_update "$item" "running"
        if [[ "$DRY_RUN" == true ]]; then
            primer::status_msg "installing $item..."
            echo "[dry-run] brew install $item"
            primer::item_update "$item" "done"
        elif ! (( ${installed_formulae[(I)$item]} )); then
            primer::status_msg "installing $item..."
            brew install "$item" && primer::item_update "$item" "done" \
                                 || { primer::item_update "$item" "failed"; any_failed=true; }
        elif (( ${outdated_formulae[(I)$item]} )); then
            primer::status_msg "updating $item..."
            brew upgrade "$item" && primer::item_update "$item" "done" \
                                 || { primer::item_update "$item" "failed"; any_failed=true; }
        else
            primer::status_msg "$item up to date"
            primer::item_update "$item" "done"
        fi
    done

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
        local version=$(brew --version 2>/dev/null | head -1 | sed 's/Homebrew /v/')
        version="${version%%-*}"
        primer::status_msg "$version"
        return 0
    fi
    primer::status_msg "not installed"
    return 1
}
