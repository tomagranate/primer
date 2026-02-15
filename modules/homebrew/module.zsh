#!/bin/zsh
# modules/homebrew -- Homebrew package manager + all packages from config

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

    # Generate Brewfile from config and run brew bundle
    primer::status_msg "installing packages..."
    local brewfile="$(mktemp)"
    local item
    for item in $(mod_config formulae); do echo "brew \"$item\"" >> "$brewfile"; done
    for item in $(mod_config casks);    do echo "cask \"$item\"" >> "$brewfile"; done
    for item in $(mod_config mas); do
        local name="${item%%:*}" id="${item#*:}"
        echo "mas \"$name\", id: $id" >> "$brewfile"
    done

    if [[ "$DRY_RUN" == true ]]; then
        echo "[dry-run] brew bundle with:"
        cat "$brewfile"
    else
        brew bundle --file="$brewfile"
    fi
    rm -f "$brewfile"
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
