#!/bin/zsh
# modules/xcode -- Optional full Xcode first-launch and simulator setup

_xcode::active_developer_dir() {
    xcode-select -p 2>/dev/null
}

_xcode::full_xcode_active() {
    local developer_dir
    developer_dir="$(_xcode::active_developer_dir)" || return 1
    [[ "$developer_dir" == *.app/Contents/Developer ]]
}

_xcode::platforms() {
    mod_config simulator_platforms
}

_xcode::first_launch_complete() {
    command -v xcodebuild >/dev/null 2>&1 || return 1
    xcodebuild -checkFirstLaunchStatus >/dev/null 2>&1
}

_xcode::run_first_launch() {
    if [[ "$DRY_RUN" == true ]]; then
        echo "[dry-run] sudo xcodebuild -runFirstLaunch -checkForNewerComponents"
        return 0
    fi

    sudo xcodebuild -runFirstLaunch -checkForNewerComponents
}

_xcode::download_platform() {
    local platform="$1"
    if [[ "$DRY_RUN" == true ]]; then
        echo "[dry-run] xcodebuild -downloadPlatform $platform"
        return 0
    fi

    xcodebuild -downloadPlatform "$platform"
}

_xcode::platform_runtime_installed() {
    local platform="$1"
    command -v xcrun >/dev/null 2>&1 || return 1
    xcrun simctl runtime list 2>/dev/null | grep -E "^${platform}[[:space:]][0-9].*" >/dev/null
}

_xcode::download_platforms() {
    local platform
    while IFS= read -r platform; do
        [[ -z "$platform" ]] && continue
        if _xcode::platform_runtime_installed "$platform"; then
            continue
        fi
        primer::status_msg "downloading $platform simulator..."
        _xcode::download_platform "$platform" || return 1
    done <<< "$(_xcode::platforms)"
}

mod_update() {
    if ! _xcode::full_xcode_active; then
        primer::status_msg "not installed"
        return 0
    fi

    if ! _xcode::first_launch_complete; then
        primer::status_msg "running first launch..."
        _xcode::run_first_launch || return 1
    fi

    if [[ -n "$(_xcode::platforms)" ]]; then
        _xcode::download_platforms || return 1
    fi

    primer::status_msg "configured"
}

mod_status() {
    local drifted=0 platform

    if ! _xcode::full_xcode_active; then
        primer::status_msg "not installed"
        return 0
    fi

    _xcode::first_launch_complete || drifted=$(( drifted + 1 ))

    while IFS= read -r platform; do
        [[ -z "$platform" ]] && continue
        _xcode::platform_runtime_installed "$platform" || drifted=$(( drifted + 1 ))
    done <<< "$(_xcode::platforms)"

    if (( drifted == 0 )); then
        primer::status_msg "configured"
        return 0
    fi

    local parts=()
    (( drifted > 0 )) && parts+=("${drifted} drifted")
    primer::status_msg "${(j: · :)parts}"
    return 1
}
