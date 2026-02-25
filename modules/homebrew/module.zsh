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

    local item

    for item in "${taps[@]}"; do
        primer::status_msg "tapping $item..."
        primer::item_update "$item" "running"
        if [[ "$DRY_RUN" == true ]]; then
            echo "[dry-run] brew tap $item"
            primer::item_update "$item" "done"
        else
            brew tap "$item" && primer::item_update "$item" "done" \
                             || primer::item_update "$item" "failed"
        fi
    done

    for item in "${formulae[@]}"; do
        primer::status_msg "installing $item..."
        primer::item_update "$item" "running"
        if [[ "$DRY_RUN" == true ]]; then
            echo "[dry-run] brew install $item"
            primer::item_update "$item" "done"
        else
            brew install "$item" && primer::item_update "$item" "done" \
                                 || primer::item_update "$item" "failed"
        fi
    done

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
        local version=$(brew --version 2>/dev/null | head -1 | sed 's/Homebrew /v/')
        version="${version%%-*}"
        primer::status_msg "$version"
        return 0
    fi
    primer::status_msg "not installed"
    return 1
}
