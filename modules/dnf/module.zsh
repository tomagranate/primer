#!/bin/zsh
# modules/dnf -- Fedora packages and COPR repositories via DNF

_dnf::bootstrap_packages() {
    mod_config bootstrap_packages
}

_dnf::packages() {
    mod_config packages
}

_dnf::coprs() {
    mod_config coprs
}

_dnf::run_as_root() {
    primer::run_as_root "DNF packages" "$@"
}

_dnf::installed() {
    rpm -q "$1" >/dev/null 2>&1
}

_dnf::copr_enabled() {
    local copr="$1"
    local repo_fragment="${copr//\//:}"
    dnf repolist --enabled 2>/dev/null | grep -Fq "$repo_fragment"
}

_dnf::install_missing() {
    local packages=("$@")
    local missing=() package
    for package in "${packages[@]}"; do
        _dnf::installed "$package" || missing+=("$package")
    done
    (( ${#missing[@]} == 0 )) && return 0
    _dnf::run_as_root dnf install -y "${missing[@]}"
}

mod_update() {
    local bootstrap_packages=($(_dnf::bootstrap_packages))
    local packages=($(_dnf::packages))
    local coprs=($(_dnf::coprs))
    local all_packages=("${bootstrap_packages[@]}" "${packages[@]}")
    primer::items_init "${all_packages[@]}"

    if [[ "$DRY_RUN" == true ]]; then
        (( ${#bootstrap_packages[@]} == 0 )) || \
            echo "[dry-run] sudo dnf install -y ${bootstrap_packages[*]}"
        local copr
        for copr in "${coprs[@]}"; do
            echo "[dry-run] sudo dnf copr enable -y $copr"
        done
        (( ${#packages[@]} == 0 )) || \
            echo "[dry-run] sudo dnf install -y ${packages[*]}"
        local package
        for package in "${all_packages[@]}"; do
            primer::item_update "$package" "done"
        done
        primer::status_msg "packages planned"
        return 0
    fi

    if ! command -v dnf >/dev/null 2>&1 || ! command -v rpm >/dev/null 2>&1; then
        primer::status_msg "dnf or rpm not found"
        return 1
    fi

    primer::status_msg "installing DNF plugins..."
    _dnf::install_missing "${bootstrap_packages[@]}" || return 1

    local copr
    for copr in "${coprs[@]}"; do
        if ! _dnf::copr_enabled "$copr"; then
            primer::status_msg "enabling $copr..."
            _dnf::run_as_root dnf copr enable -y "$copr" || return 1
        fi
    done

    primer::status_msg "installing packages..."
    _dnf::install_missing "${packages[@]}" || return 1

    local failed=0 package
    for package in "${all_packages[@]}"; do
        if _dnf::installed "$package"; then
            primer::item_update "$package" "done"
        else
            primer::item_update "$package" "failed" "not installed"
            failed=$(( failed + 1 ))
        fi
    done

    if (( failed > 0 )); then
        primer::status_msg "${failed} missing"
        return 1
    fi

    primer::status_msg "packages installed"
}

mod_status() {
    if ! command -v dnf >/dev/null 2>&1 || ! command -v rpm >/dev/null 2>&1; then
        primer::status_msg "dnf not available"
        return 1
    fi

    local missing=0 package copr
    for package in $(_dnf::bootstrap_packages) $(_dnf::packages); do
        _dnf::installed "$package" || missing=$(( missing + 1 ))
    done
    for copr in $(_dnf::coprs); do
        _dnf::copr_enabled "$copr" || missing=$(( missing + 1 ))
    done

    if (( missing == 0 )); then
        primer::status_msg "installed"
        return 0
    fi

    primer::status_msg "${missing} missing"
    return 1
}
