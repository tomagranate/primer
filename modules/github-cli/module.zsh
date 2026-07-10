#!/bin/zsh
# modules/github-cli -- GitHub CLI via GitHub's official apt repository

_github_cli::key_url() {
    local url="$(mod_config key_url | head -1)"
    [[ -n "$url" ]] && print -r -- "$url" || print "https://cli.github.com/packages/githubcli-archive-keyring.gpg"
}

_github_cli::repo_line() {
    local repo="$(mod_config repo | head -1)"
    [[ -n "$repo" ]] && print -r -- "$repo" || print "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main"
}

_github_cli::package_name() {
    local package="$(mod_config package | head -1)"
    [[ -n "$package" ]] && print -r -- "$package" || print "gh"
}

_github_cli::run_as_root() {
    primer::run_as_root "GitHub CLI" "$@"
}

_github_cli::installed() {
    local package="$(_github_cli::package_name)"
    dpkg-query -W -f='${Status}' "$package" 2>/dev/null | grep -q "install ok installed"
}

_github_cli::json_auth_status_supported() {
    command -v gh >/dev/null 2>&1 || return 1
    local err_file
    err_file="$(mktemp)"
    gh auth status --json hosts >/dev/null 2>"$err_file"
    local output
    output="$(cat "$err_file")"
    rm -f "$err_file"
    [[ "$output" != *"unknown flag: --json"* ]]
}

mod_update() {
    local key_url="$(_github_cli::key_url)"
    local repo_line="$(_github_cli::repo_line)"
    local package="$(_github_cli::package_name)"

    primer::items_init "$package"

    if [[ "$DRY_RUN" == true ]]; then
        echo "[dry-run] install GitHub CLI apt key from $key_url"
        echo "[dry-run] write /etc/apt/sources.list.d/github-cli.list"
        echo "[dry-run] sudo apt-get update"
        echo "[dry-run] sudo apt-get install -y $package"
        primer::item_update "$package" "done"
        primer::status_msg "install planned"
        return 0
    fi

    if ! command -v curl >/dev/null 2>&1; then
        primer::item_update "$package" "failed" "curl not found"
        primer::status_msg "missing curl"
        return 1
    fi

    primer::status_msg "configuring repo..."
    local key_tmp
    key_tmp="$(mktemp)"
    if ! curl -fsSL "$key_url" > "$key_tmp"; then
        rm -f "$key_tmp"
        primer::item_update "$package" "failed" "key download failed"
        primer::status_msg "key failed"
        return 1
    fi

    _github_cli::run_as_root install -d -m 0755 /etc/apt/keyrings || {
        rm -f "$key_tmp"
        primer::item_update "$package" "failed" "keyring dir failed"
        primer::status_msg "keyring failed"
        return 1
    }
    _github_cli::run_as_root install -m 0644 "$key_tmp" /etc/apt/keyrings/githubcli-archive-keyring.gpg || {
        rm -f "$key_tmp"
        primer::item_update "$package" "failed" "key install failed"
        primer::status_msg "key failed"
        return 1
    }
    rm -f "$key_tmp"

    local source_tmp
    source_tmp="$(mktemp)"
    print -r -- "$repo_line" > "$source_tmp"
    _github_cli::run_as_root install -m 0644 "$source_tmp" /etc/apt/sources.list.d/github-cli.list || {
        rm -f "$source_tmp"
        primer::item_update "$package" "failed" "repo install failed"
        primer::status_msg "repo failed"
        return 1
    }
    rm -f "$source_tmp"

    primer::status_msg "installing..."
    _github_cli::run_as_root apt-get update || return 1
    if _github_cli::run_as_root env DEBIAN_FRONTEND=noninteractive apt-get install -y "$package"; then
        if _github_cli::installed && _github_cli::json_auth_status_supported; then
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

    [[ -f /etc/apt/keyrings/githubcli-archive-keyring.gpg ]] || issues=$(( issues + 1 ))
    [[ -f /etc/apt/sources.list.d/github-cli.list ]] || issues=$(( issues + 1 ))
    _github_cli::installed || issues=$(( issues + 1 ))
    _github_cli::json_auth_status_supported || issues=$(( issues + 1 ))

    if (( issues == 0 )); then
        primer::status_msg "installed"
        return 0
    fi

    primer::status_msg "${issues} issue(s)"
    return 1
}
