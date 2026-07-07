#!/bin/zsh
# modules/apt -- Debian/Ubuntu packages via apt

_apt::packages() {
    mod_config packages
}

_apt::run_as_root() {
    primer::run_as_root "APT packages" "$@"
}

_apt::installed() {
    local package="$1"
    dpkg-query -W -f='${Status}' "$package" 2>/dev/null | grep -q "install ok installed"
}

mod_update() {
    local packages=($(_apt::packages))
    primer::items_init "${packages[@]}"
    (( ${#packages[@]} > 0 )) || {
        primer::status_msg "no packages"
        return 0
    }

    if [[ "$DRY_RUN" == true ]]; then
        echo "[dry-run] sudo apt-get update"
        echo "[dry-run] sudo apt-get install -y ${packages[*]}"
        local package
        for package in "${packages[@]}"; do
            primer::item_update "$package" "done"
        done
        primer::status_msg "packages planned"
        return 0
    fi

    if ! command -v apt-get >/dev/null 2>&1; then
        primer::status_msg "apt-get not found"
        return 1
    fi

    primer::status_msg "updating package index..."
    _apt::run_as_root apt-get update || return 1

    primer::status_msg "installing packages..."
    if _apt::run_as_root env DEBIAN_FRONTEND=noninteractive apt-get install -y "${packages[@]}"; then
        local package
        for package in "${packages[@]}"; do
            if _apt::installed "$package"; then
                primer::item_update "$package" "done"
            else
                primer::item_update "$package" "failed" "not installed"
            fi
        done
        primer::status_msg "packages installed"
        return 0
    fi

    primer::status_msg "install failed"
    return 1
}

mod_status() {
    if ! command -v apt-get >/dev/null 2>&1 || ! command -v dpkg-query >/dev/null 2>&1; then
        primer::status_msg "apt not available"
        return 1
    fi

    local missing=0 package
    for package in $(_apt::packages); do
        _apt::installed "$package" || missing=$(( missing + 1 ))
    done

    if (( missing == 0 )); then
        primer::status_msg "installed"
        return 0
    fi

    primer::status_msg "${missing} missing"
    return 1
}
