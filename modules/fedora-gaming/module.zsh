#!/bin/zsh
# modules/fedora-gaming -- native Steam and gaming support for Fedora KDE

typeset -a FEDORA_GAMING_PACKAGES=(
    steam
    steam-devices
    gamemode.x86_64
    gamemode.i686
    mangohud.x86_64
    mangohud.i686
    gamescope
    vulkan-tools
)

_fedora_gaming::root_path() {
    local path="$1" root="${FEDORA_GAMING_ROOT:-/}"
    [[ "$root" == / ]] && print -r -- "/$path" || print -r -- "${root%/}/$path"
}

_fedora_gaming::is_fedora() {
    [[ "$DRY_RUN" == true ]] && return 0
    local release="$(_fedora_gaming::root_path etc/os-release)"
    [[ -r "$release" ]] && grep -Eq '^ID="?fedora"?$' "$release"
}

_fedora_gaming::run_as_root() {
    if [[ "$DRY_RUN" == true ]]; then
        printf '[dry-run] sudo %s\n' "$*"
        return 0
    fi
    primer::run_as_root "Fedora gaming setup" "$@"
}

_fedora_gaming::rpmfusion_enabled() {
    rpm -q "rpmfusion-$1-release" >/dev/null 2>&1
}

_fedora_gaming::package_installed() {
    rpm -q "$1" >/dev/null 2>&1
}

_fedora_gaming::vulkan_ready() {
    vulkaninfo --summary 2>/dev/null \
        | grep -Eq 'deviceType[[:space:]]*= PHYSICAL_DEVICE_TYPE_(DISCRETE|INTEGRATED)_GPU'
}

_fedora_gaming::gamemode_ready() {
    gamemoded -t >/dev/null 2>&1
}

_fedora_gaming::target_user() {
    if [[ -n "${SUDO_USER:-}" && "$SUDO_USER" != root ]]; then
        print -r -- "$SUDO_USER"
    elif [[ -n "${USER:-}" && "$USER" != root ]]; then
        print -r -- "$USER"
    else
        id -un
    fi
}

_fedora_gaming::gamemode_group_ready() {
    local user
    user="$(_fedora_gaming::target_user)" || return 1
    id -nG "$user" 2>/dev/null | tr ' ' '\n' | grep -Fxq gamemode
}

_fedora_gaming::install_gamemode_group() {
    local user
    user="$(_fedora_gaming::target_user)" || return 1
    _fedora_gaming::gamemode_group_ready && return 0
    _fedora_gaming::run_as_root usermod -aG gamemode "$user"
}

_fedora_gaming::install_rpmfusion() {
    local version
    if [[ "$DRY_RUN" == true ]]; then
        version='$(rpm -E %fedora)'
        _fedora_gaming::run_as_root dnf5 -y --color=never install \
            "https://mirrors.rpmfusion.org/free/fedora/rpmfusion-free-release-${version}.noarch.rpm" \
            "https://mirrors.rpmfusion.org/nonfree/fedora/rpmfusion-nonfree-release-${version}.noarch.rpm"
        return $?
    fi

    version="$(rpm -E %fedora)" || return 1
    if ! _fedora_gaming::rpmfusion_enabled free; then
        _fedora_gaming::run_as_root dnf5 -y --color=never install \
            "https://mirrors.rpmfusion.org/free/fedora/rpmfusion-free-release-${version}.noarch.rpm" || return 1
    fi
    if ! _fedora_gaming::rpmfusion_enabled nonfree; then
        _fedora_gaming::run_as_root dnf5 -y --color=never install \
            "https://mirrors.rpmfusion.org/nonfree/fedora/rpmfusion-nonfree-release-${version}.noarch.rpm" || return 1
    fi
}

mod_update() {
    if [[ "$(uname -s)" != Linux ]] || ! _fedora_gaming::is_fedora; then
        primer::status_msg "Fedora Linux only"
        return 1
    fi

    primer::items_init "${FEDORA_GAMING_PACKAGES[@]}"

    if [[ "$DRY_RUN" == true ]]; then
        _fedora_gaming::install_rpmfusion || return 1
        _fedora_gaming::run_as_root dnf5 -y --color=never install "${FEDORA_GAMING_PACKAGES[@]}" || return 1
        _fedora_gaming::install_gamemode_group || return 1
        echo "[dry-run] gamemoded -t"
        echo "[dry-run] vulkaninfo --summary"
        _fedora_gaming::run_as_root udevadm control --reload-rules || return 1
        local package
        for package in "${FEDORA_GAMING_PACKAGES[@]}"; do
            primer::item_update "$package" done planned
        done
        primer::status_msg "gaming stack planned"
        return 0
    fi

    if ! command -v dnf5 >/dev/null 2>&1 || ! command -v rpm >/dev/null 2>&1; then
        primer::status_msg "dnf5 or rpm not found"
        return 1
    fi

    _fedora_gaming::install_rpmfusion || {
        primer::status_msg "RPM Fusion setup failed"
        return 1
    }

    local -a missing=()
    local package
    for package in "${FEDORA_GAMING_PACKAGES[@]}"; do
        if _fedora_gaming::package_installed "$package"; then
            primer::item_update "$package" skipped "already installed"
        else
            missing+=("$package")
            primer::item_update "$package" running queued
        fi
    done

    if (( ${#missing[@]} > 0 )); then
        primer::status_msg "installing gaming packages..."
        if ! _fedora_gaming::run_as_root dnf5 -y --color=never install "${missing[@]}"; then
            for package in "${missing[@]}"; do
                primer::item_update "$package" failed "install failed"
            done
            primer::status_msg "package installation failed"
            return 1
        fi
    fi

    local failed=0
    for package in "${FEDORA_GAMING_PACKAGES[@]}"; do
        if _fedora_gaming::package_installed "$package"; then
            primer::item_update "$package" done installed
        else
            primer::item_update "$package" failed "not installed"
            (( failed++ ))
        fi
    done
    if (( failed > 0 )); then
        primer::status_msg "$failed package(s) missing"
        return 1
    fi

    if ! _fedora_gaming::install_gamemode_group; then
        primer::status_msg "GameMode group setup failed"
        return 1
    fi
    _fedora_gaming::run_as_root udevadm control --reload-rules || return 1
    if ! _fedora_gaming::gamemode_ready; then
        primer::status_msg "GameMode self-test failed"
        return 1
    fi
    if ! _fedora_gaming::vulkan_ready; then
        primer::status_msg "hardware Vulkan unavailable"
        return 1
    fi

    primer::status_msg "ready; reconnect controllers"
}

mod_status() {
    if [[ "$(uname -s)" != Linux ]] || ! _fedora_gaming::is_fedora; then
        primer::status_msg "Fedora Linux only"
        return 1
    fi

    local issues=0 package
    _fedora_gaming::rpmfusion_enabled free || (( issues++ ))
    _fedora_gaming::rpmfusion_enabled nonfree || (( issues++ ))
    for package in "${FEDORA_GAMING_PACKAGES[@]}"; do
        _fedora_gaming::package_installed "$package" || (( issues++ ))
    done
    _fedora_gaming::gamemode_group_ready || (( issues++ ))
    _fedora_gaming::gamemode_ready || (( issues++ ))
    _fedora_gaming::vulkan_ready || (( issues++ ))

    if (( issues == 0 )); then
        primer::status_msg "ready"
        return 0
    fi

    primer::status_msg "$issues issue(s)"
    return 1
}
