#!/bin/zsh
# modules/flatpak -- Desktop apps via Flatpak

_flatpak::remote() {
    local remote="$(mod_config remote | head -1)"
    [[ -n "$remote" ]] && print "$remote" || print flathub
}

_flatpak::apps() {
    mod_config apps
}

_flatpak::run_as_root() {
    if (( EUID == 0 )); then
        "$@"
    elif command -v sudo >/dev/null 2>&1; then
        sudo "$@"
    else
        print "sudo is required to configure flatpak remotes" >&2
        return 1
    fi
}

_flatpak::installed() {
    flatpak info "$1" >/dev/null 2>&1
}

mod_update() {
    local remote="$(_flatpak::remote)"
    local apps=($(_flatpak::apps))
    primer::items_init "${apps[@]}"

    if (( ${#apps[@]} == 0 )); then
        primer::status_msg "no apps"
        return 0
    fi

    if [[ "$DRY_RUN" == true ]]; then
        echo "[dry-run] flatpak remote-add --if-not-exists $remote https://dl.flathub.org/repo/flathub.flatpakrepo"
        echo "[dry-run] flatpak install -y $remote ${apps[*]}"
        local app
        for app in "${apps[@]}"; do
            primer::item_update "$app" "done"
        done
        primer::status_msg "apps planned"
        return 0
    fi

    if ! command -v flatpak >/dev/null 2>&1; then
        primer::status_msg "flatpak not found"
        return 1
    fi

    _flatpak::run_as_root flatpak remote-add --if-not-exists "$remote" https://dl.flathub.org/repo/flathub.flatpakrepo || return 1
    if flatpak install -y "$remote" "${apps[@]}"; then
        local app
        for app in "${apps[@]}"; do
            if _flatpak::installed "$app"; then
                primer::item_update "$app" "done"
            else
                primer::item_update "$app" "failed" "not installed"
            fi
        done
        primer::status_msg "apps installed"
        return 0
    fi

    primer::status_msg "install failed"
    return 1
}

mod_status() {
    if ! command -v flatpak >/dev/null 2>&1; then
        primer::status_msg "flatpak not available"
        return 1
    fi

    local missing=0 app
    for app in $(_flatpak::apps); do
        _flatpak::installed "$app" || missing=$(( missing + 1 ))
    done

    if (( missing == 0 )); then
        primer::status_msg "installed"
        return 0
    fi

    primer::status_msg "${missing} missing"
    return 1
}
