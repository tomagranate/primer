#!/bin/zsh
# modules/xcode -- Full Xcode.app first-launch setup and simulator platforms

_xcode::app_path() {
    local configured
    configured="$(mod_config app_path | head -1)"
    [[ -n "$configured" ]] && print "$configured" || print "/Applications/Xcode.app"
}

_xcode::developer_dir() {
    print "$(_xcode::app_path)/Contents/Developer"
}

_xcode::app_installed() {
    [[ -d "$(_xcode::app_path)" && -d "$(_xcode::developer_dir)" ]]
}

_xcode::selected() {
    local active
    active="$(xcode-select -p 2>/dev/null)" || return 1
    [[ "$active" == "$(_xcode::developer_dir)" ]]
}

_xcode::select_app() {
    local developer_dir
    developer_dir="$(_xcode::developer_dir)"
    if [[ "$DRY_RUN" == true ]]; then
        echo "[dry-run] sudo xcode-select --switch $developer_dir"
        return 0
    fi

    sudo xcode-select --switch "$developer_dir"
}

_xcode::ensure_app() {
    if _xcode::app_installed; then
        return 0
    fi

    primer::status_msg "install Xcode.app"
    if [[ "$DRY_RUN" == true ]]; then
        echo "[dry-run] install Xcode.app from the App Store"
    else
        echo "Xcode.app is required for xcodebuild simulator setup."
        echo "Install Xcode from the App Store, then run primer update again."
    fi
    return 1
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
    _xcode::ensure_app || return 1

    if ! _xcode::selected; then
        primer::status_msg "selecting Xcode..."
        _xcode::select_app || return 1
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
    local missing=0 drifted=0 platform

    _xcode::app_installed || missing=$(( missing + 1 ))
    _xcode::selected || drifted=$(( drifted + 1 ))
    if _xcode::app_installed && _xcode::selected; then
        _xcode::first_launch_complete || drifted=$(( drifted + 1 ))
    fi

    while IFS= read -r platform; do
        [[ -z "$platform" ]] && continue
        if _xcode::app_installed && _xcode::selected; then
            _xcode::platform_runtime_installed "$platform" || drifted=$(( drifted + 1 ))
        else
            drifted=$(( drifted + 1 ))
        fi
    done <<< "$(_xcode::platforms)"

    if (( missing == 0 && drifted == 0 )); then
        primer::status_msg "configured"
        return 0
    fi

    local parts=()
    (( missing > 0 )) && parts+=("${missing} missing")
    (( drifted > 0 )) && parts+=("${drifted} drifted")
    primer::status_msg "${(j: · :)parts}"
    return 1
}
