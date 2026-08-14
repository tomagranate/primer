#!/bin/zsh
# modules/google-chrome -- Google Chrome from Google's native Linux packages

_google_chrome::format() {
    local format
    format="$(mod_config format | head -1)"
    if [[ -n "$format" ]]; then
        print -r -- "$format"
    elif command -v dnf5 >/dev/null 2>&1 && command -v rpm >/dev/null 2>&1; then
        print rpm
    elif command -v apt-get >/dev/null 2>&1 && command -v dpkg-query >/dev/null 2>&1; then
        print deb
    fi
}

_google_chrome::package() {
    local package
    package="$(mod_config package | head -1)"
    if [[ -n "$package" ]]; then
        print -r -- "$package"
    else
        print google-chrome-stable
    fi
}

_google_chrome::command() {
    local command_name
    command_name="$(mod_config command | head -1)"
    if [[ -n "$command_name" ]]; then
        print -r -- "$command_name"
    else
        print google-chrome-stable
    fi
}

_google_chrome::package_url() {
    local url
    url="$(mod_config url | head -1)"
    if [[ -n "$url" ]]; then
        print -r -- "$url"
        return
    fi

    case "$(_google_chrome::format)" in
        rpm) print https://dl.google.com/linux/direct/google-chrome-stable_current_x86_64.rpm ;;
        deb) print https://dl.google.com/linux/direct/google-chrome-stable_current_amd64.deb ;;
    esac
}

_google_chrome::installed() {
    local command_name
    command_name="$(_google_chrome::command)"
    command -v "$command_name" >/dev/null 2>&1 && "$command_name" --version >/dev/null 2>&1
}

_google_chrome::run_as_root() {
    primer::run_as_root "Google Chrome" "$@"
}

_google_chrome::install_package() {
    local format="$1" package_file="$2"
    case "$format" in
        rpm)
            _google_chrome::run_as_root dnf5 -y --color=never install "$package_file"
            ;;
        deb)
            _google_chrome::run_as_root env DEBIAN_FRONTEND=noninteractive \
                apt-get install -y "$package_file"
            ;;
        *)
            return 1
            ;;
    esac
}

mod_update() {
    local package format url
    package="$(_google_chrome::package)"
    format="$(_google_chrome::format)"
    url="$(_google_chrome::package_url)"
    primer::items_init "$package"

    if [[ "$format" != "rpm" && "$format" != "deb" ]]; then
        primer::item_update "$package" "failed" "unsupported package format"
        primer::status_msg "unsupported package format"
        return 1
    fi

    if [[ "$DRY_RUN" == true ]]; then
        echo "[dry-run] curl -fsSL $url -o <package>"
        if [[ "$format" == "rpm" ]]; then
            echo "[dry-run] sudo dnf5 -y --color=never install <package>"
        else
            echo "[dry-run] sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y <package>"
        fi
        primer::item_update "$package" "done" "planned"
        primer::status_msg "install planned"
        return 0
    fi

    if _google_chrome::installed; then
        primer::item_update "$package" "skipped" "already installed"
        primer::status_msg "installed"
        return 0
    fi

    if ! command -v curl >/dev/null 2>&1; then
        primer::item_update "$package" "failed" "curl not found"
        primer::status_msg "curl not found"
        return 1
    fi

    if [[ "$format" == "rpm" ]] && ! command -v dnf5 >/dev/null 2>&1; then
        primer::item_update "$package" "failed" "dnf5 not found"
        primer::status_msg "dnf5 not found"
        return 1
    fi
    if [[ "$format" == "deb" ]] && ! command -v apt-get >/dev/null 2>&1; then
        primer::item_update "$package" "failed" "apt-get not found"
        primer::status_msg "apt-get not found"
        return 1
    fi

    local package_file
    package_file="$(mktemp --suffix=".$format")" || return 1
    primer::status_msg "downloading..."
    if ! curl -fsSL "$url" -o "$package_file"; then
        rm -f "$package_file"
        primer::item_update "$package" "failed" "download failed"
        primer::status_msg "download failed"
        return 1
    fi

    primer::status_msg "installing..."
    _google_chrome::install_package "$format" "$package_file"
    local install_rc=$?
    rm -f "$package_file"

    if (( install_rc == 0 )) && _google_chrome::installed; then
        primer::item_update "$package" "done" "installed"
        primer::status_msg "installed"
        return 0
    fi

    primer::item_update "$package" "failed" "install failed"
    primer::status_msg "install failed"
    return 1
}

mod_status() {
    if _google_chrome::installed; then
        primer::status_msg "installed"
        return 0
    fi

    primer::status_msg "not installed"
    return 1
}
