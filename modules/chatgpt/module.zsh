#!/bin/zsh
# modules/chatgpt -- ChatGPT desktop app from OpenAI's native Linux packages

_chatgpt::format() {
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

_chatgpt::package() {
    local package
    package="$(mod_config package | head -1)"
    [[ -n "$package" ]] && print -r -- "$package" || print chatgpt
}

_chatgpt::command() {
    local command_name
    command_name="$(mod_config command | head -1)"
    [[ -n "$command_name" ]] && print -r -- "$command_name" || print chatgpt
}

_chatgpt::arch() {
    local arch
    arch="$(uname -m)"
    case "$arch" in
        x86_64|amd64) print x64 ;;
        aarch64|arm64) print arm64 ;;
        *) print "$arch" ;;
    esac
}

_chatgpt::package_url() {
    local url
    url="$(mod_config url | head -1)"
    if [[ -n "$url" ]]; then
        print -r -- "$url"
        return
    fi

    local format="$(_chatgpt::format)" arch="$(_chatgpt::arch)"
    case "$format:$arch" in
        rpm:x64) print https://persistent.oaistatic.com/codex-app-prod/linux/rpm/latest/chatgpt.x86_64.rpm ;;
        rpm:arm64) print https://persistent.oaistatic.com/codex-app-prod/linux/rpm/latest/chatgpt.aarch64.rpm ;;
        deb:x64) print https://persistent.oaistatic.com/codex-app-prod/linux/deb/latest/chatgpt_amd64.deb ;;
        deb:arm64) print https://persistent.oaistatic.com/codex-app-prod/linux/deb/latest/chatgpt_arm64.deb ;;
    esac
}

_chatgpt::installed() {
    local package="$(_chatgpt::package)"
    case "$(_chatgpt::format)" in
        rpm) rpm -q "$package" >/dev/null 2>&1 ;;
        deb) dpkg-query -W -f='${Status}' "$package" 2>/dev/null | grep -q "install ok installed" ;;
        *) command -v "$(_chatgpt::command)" >/dev/null 2>&1 ;;
    esac
}

_chatgpt::run_as_root() {
    primer::run_as_root "ChatGPT" "$@"
}

_chatgpt::install_package() {
    local format="$1" package_file="$2"
    case "$format" in
        rpm)
            _chatgpt::run_as_root dnf5 -y --color=never install "$package_file"
            ;;
        deb)
            _chatgpt::run_as_root env DEBIAN_FRONTEND=noninteractive \
                apt-get install -y "$package_file"
            ;;
        *)
            return 1
            ;;
    esac
}

mod_update() {
    local package format url
    package="$(_chatgpt::package)"
    format="$(_chatgpt::format)"
    url="$(_chatgpt::package_url)"
    primer::items_init "$package"

    if [[ "$format" != "rpm" && "$format" != "deb" ]]; then
        primer::item_update "$package" "failed" "unsupported package format"
        primer::status_msg "unsupported package format"
        return 1
    fi
    if [[ -z "$url" ]]; then
        primer::item_update "$package" "failed" "unsupported architecture"
        primer::status_msg "unsupported architecture"
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

    if _chatgpt::installed; then
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
    _chatgpt::install_package "$format" "$package_file"
    local install_rc=$?
    rm -f "$package_file"

    if (( install_rc == 0 )) && _chatgpt::installed; then
        primer::item_update "$package" "done" "installed"
        primer::status_msg "installed"
        return 0
    fi

    primer::item_update "$package" "failed" "install failed"
    primer::status_msg "install failed"
    return 1
}

mod_status() {
    if _chatgpt::installed; then
        primer::status_msg "installed"
        return 0
    fi

    primer::status_msg "not installed"
    return 1
}
