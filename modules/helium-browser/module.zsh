#!/bin/zsh
# modules/helium-browser -- Helium Browser via official apt repository

_helium_browser::key_url() {
    local url="$(mod_config key_url | head -1)"
    [[ -n "$url" ]] && print -r -- "$url" || print "https://raw.githubusercontent.com/imputnet/helium-linux/main/pubkey.asc"
}

_helium_browser::repo_line() {
    local repo="$(mod_config repo | head -1)"
    [[ -n "$repo" ]] && print -r -- "$repo" || print "deb [arch=amd64,arm64 signed-by=/usr/share/keyrings/helium.gpg] https://pkg.helium.computer/deb stable main"
}

_helium_browser::package_name() {
    local package="$(mod_config package | head -1)"
    [[ -n "$package" ]] && print -r -- "$package" || print "helium-bin"
}

_helium_browser::command_name() {
    local command_name="$(mod_config command | head -1)"
    [[ -n "$command_name" ]] && print -r -- "$command_name" || print "helium"
}

_helium_browser::run_as_root() {
    primer::run_as_root "Helium Browser" "$@"
}

_helium_browser::installed() {
    local package="$(_helium_browser::package_name)"
    dpkg-query -W -f='${Status}' "$package" 2>/dev/null | grep -q "install ok installed"
}

_helium_browser::command_available() {
    command -v "$(_helium_browser::command_name)" >/dev/null 2>&1
}

mod_update() {
    local key_url="$(_helium_browser::key_url)"
    local repo_line="$(_helium_browser::repo_line)"
    local package="$(_helium_browser::package_name)"

    primer::items_init "$package"

    if [[ "$DRY_RUN" == true ]]; then
        echo "[dry-run] curl -fsSL $key_url | gpg --dearmor | sudo -n tee /usr/share/keyrings/helium.gpg >/dev/null"
        echo "[dry-run] write /etc/apt/sources.list.d/helium.list"
        echo "[dry-run] sudo apt-get update"
        echo "[dry-run] sudo apt-get install -y $package"
        primer::item_update "$package" "done"
        primer::status_msg "install planned"
        return 0
    fi

    if ! command -v curl >/dev/null 2>&1 || ! command -v gpg >/dev/null 2>&1; then
        primer::item_update "$package" "failed" "curl or gpg not found"
        primer::status_msg "missing tools"
        return 1
    fi

    primer::status_msg "configuring repo..."
    local key_tmp
    key_tmp="$(mktemp)"
    if ! curl -fsSL "$key_url" | gpg --dearmor > "$key_tmp"; then
        rm -f "$key_tmp"
        primer::item_update "$package" "failed" "key download failed"
        primer::status_msg "key failed"
        return 1
    fi

    _helium_browser::run_as_root install -m 0644 "$key_tmp" /usr/share/keyrings/helium.gpg || {
        rm -f "$key_tmp"
        primer::item_update "$package" "failed" "key install failed"
        primer::status_msg "key failed"
        return 1
    }
    rm -f "$key_tmp"

    local source_tmp
    source_tmp="$(mktemp)"
    print -r -- "$repo_line" > "$source_tmp"
    _helium_browser::run_as_root install -m 0644 "$source_tmp" /etc/apt/sources.list.d/helium.list || {
        rm -f "$source_tmp"
        primer::item_update "$package" "failed" "repo install failed"
        primer::status_msg "repo failed"
        return 1
    }
    rm -f "$source_tmp"

    primer::status_msg "installing..."
    _helium_browser::run_as_root apt-get update || return 1
    if _helium_browser::run_as_root env DEBIAN_FRONTEND=noninteractive apt-get install -y "$package"; then
        if _helium_browser::installed; then
            primer::item_update "$package" "done"
            primer::status_msg "installed"
            return 0
        fi

        primer::item_update "$package" "failed" "check failed"
        primer::status_msg "install check failed"
        return 1
    fi

    primer::item_update "$package" "failed" "install failed"
    primer::status_msg "install failed"
    return 1
}

mod_status() {
    local issues=0

    [[ -f /usr/share/keyrings/helium.gpg ]] || issues=$(( issues + 1 ))
    [[ -f /etc/apt/sources.list.d/helium.list ]] || issues=$(( issues + 1 ))
    _helium_browser::installed || issues=$(( issues + 1 ))
    _helium_browser::command_available || issues=$(( issues + 1 ))

    if (( issues == 0 )); then
        primer::status_msg "installed"
        return 0
    fi

    primer::status_msg "${issues} issue(s)"
    return 1
}
