#!/bin/zsh
# modules/1password -- 1Password desktop app and CLI from the official RPM repository

_1password::key_url() {
    local url
    url="$(mod_config key_url | head -1)"
    [[ -n "$url" ]] && print -r -- "$url" || print "https://downloads.1password.com/linux/keys/1password.asc"
}

_1password::repo_path() {
    local repo_file
    repo_file="$(mod_config repo_path | head -1)"
    [[ -n "$repo_file" ]] && print -r -- "$repo_file" || print "/etc/yum.repos.d/1password.repo"
}

_1password::repo_body() {
    local repo
    repo="$(mod_config repo)"
    if [[ -n "$repo" ]]; then
        print -r -- "$repo"
        return
    fi
    cat <<'EOF'
[1password]
name=1Password Stable Channel
baseurl=https://downloads.1password.com/linux/rpm/stable/$basearch
enabled=1
gpgcheck=1
repo_gpgcheck=1
gpgkey=https://downloads.1password.com/linux/keys/1password.asc
EOF
}

_1password::packages() {
    local -a packages=()
    local line
    while IFS= read -r line; do
        [[ -n "$line" ]] && packages+=("$line")
    done < <(mod_config packages)
    if (( ${#packages[@]} == 0 )); then
        packages=(1password 1password-cli)
    fi
    print -l -- "${packages[@]}"
}

_1password::app_command() {
    local command_name
    command_name="$(mod_config app_command | head -1)"
    [[ -n "$command_name" ]] && print -r -- "$command_name" || print 1password
}

_1password::cli_command() {
    local command_name
    command_name="$(mod_config cli_command | head -1)"
    [[ -n "$command_name" ]] && print -r -- "$command_name" || print op
}

_1password::run_as_root() {
    primer::run_as_root "1Password" "$@"
}

_1password::package_installed() {
    rpm -q "$1" >/dev/null 2>&1
}

_1password::command_available() {
    command -v "$1" >/dev/null 2>&1
}

_1password::installed() {
    local package
    for package in $(_1password::packages); do
        _1password::package_installed "$package" || return 1
    done
    _1password::command_available "$(_1password::app_command)" || return 1
    _1password::command_available "$(_1password::cli_command)" || return 1
}

mod_update() {
    local key_url repo_path
    local -a packages
    key_url="$(_1password::key_url)"
    repo_path="$(_1password::repo_path)"
    packages=($(_1password::packages))
    primer::items_init "${packages[@]}"

    if [[ "$DRY_RUN" == true ]]; then
        echo "[dry-run] sudo rpm --import $key_url"
        echo "[dry-run] write $repo_path"
        echo "[dry-run] sudo dnf5 -y --color=never install ${packages[*]}"
        local package
        for package in "${packages[@]}"; do
            primer::item_update "$package" "done" "planned"
        done
        primer::status_msg "install planned"
        return 0
    fi

    if ! command -v curl >/dev/null 2>&1; then
        local package
        for package in "${packages[@]}"; do
            primer::item_update "$package" "failed" "curl not found"
        done
        primer::status_msg "curl not found"
        return 1
    fi
    if ! command -v rpm >/dev/null 2>&1; then
        local package
        for package in "${packages[@]}"; do
            primer::item_update "$package" "failed" "rpm not found"
        done
        primer::status_msg "rpm not found"
        return 1
    fi
    if ! command -v dnf5 >/dev/null 2>&1; then
        local package
        for package in "${packages[@]}"; do
            primer::item_update "$package" "failed" "dnf5 not found"
        done
        primer::status_msg "dnf5 not found"
        return 1
    fi

    primer::status_msg "configuring repo..."
    _1password::run_as_root rpm --import "$key_url" || {
        local package
        for package in "${packages[@]}"; do
            primer::item_update "$package" "failed" "key import failed"
        done
        primer::status_msg "key failed"
        return 1
    }

    local source_tmp
    source_tmp="$(mktemp)" || return 1
    _1password::repo_body > "$source_tmp"
    _1password::run_as_root install -m 0644 "$source_tmp" "$repo_path" || {
        rm -f "$source_tmp"
        local package
        for package in "${packages[@]}"; do
            primer::item_update "$package" "failed" "repo install failed"
        done
        primer::status_msg "repo failed"
        return 1
    }
    rm -f "$source_tmp"

    if _1password::installed; then
        local package
        for package in "${packages[@]}"; do
            primer::item_update "$package" "skipped" "already installed"
        done
        primer::status_msg "installed"
        return 0
    fi

    primer::status_msg "installing..."
    local package
    for package in "${packages[@]}"; do
        primer::item_update "$package" "running" "installing"
    done
    if _1password::run_as_root dnf5 -y --color=never install "${packages[@]}"; then
        if _1password::installed; then
            for package in "${packages[@]}"; do
                primer::item_update "$package" "done" "installed"
            done
            primer::status_msg "installed"
            return 0
        fi

        for package in "${packages[@]}"; do
            if _1password::package_installed "$package"; then
                primer::item_update "$package" "done" "installed"
            else
                primer::item_update "$package" "failed" "check failed"
            fi
        done
        primer::status_msg "install check failed"
        return 1
    fi

    for package in "${packages[@]}"; do
        primer::item_update "$package" "failed" "install failed"
    done
    primer::status_msg "install failed"
    return 1
}

mod_status() {
    local issues=0 package
    local repo_path="$(_1password::repo_path)"

    [[ -f "$repo_path" ]] || issues=$(( issues + 1 ))
    for package in $(_1password::packages); do
        _1password::package_installed "$package" || issues=$(( issues + 1 ))
    done
    _1password::command_available "$(_1password::app_command)" || issues=$(( issues + 1 ))
    _1password::command_available "$(_1password::cli_command)" || issues=$(( issues + 1 ))

    if (( issues == 0 )); then
        primer::status_msg "installed"
        return 0
    fi

    primer::status_msg "${issues} issue(s)"
    return 1
}
