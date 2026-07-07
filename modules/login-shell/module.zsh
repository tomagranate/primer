#!/bin/zsh
# modules/login-shell -- Make zsh the user's login shell when possible

_login_shell::zsh_path() {
    command -v zsh 2>/dev/null || {
        [[ -x /usr/bin/zsh ]] && print /usr/bin/zsh
    }
}

_login_shell::current_shell() {
    if command -v getent >/dev/null 2>&1; then
        getent passwd "${USER:-}" 2>/dev/null | awk -F: '{print $7}'
        return 0
    fi
    print -r -- "${SHELL:-}"
}

_login_shell::shells_file() {
    print -r -- "${PRIMER_SHELLS_FILE:-/etc/shells}"
}

_login_shell::is_current() {
    local zsh_path="$1" current
    current="$(_login_shell::current_shell)"
    [[ "$current" == "$zsh_path" || "${current:t}" == zsh ]]
}

_login_shell::ensure_shells_entry() {
    local zsh_path="$1"
    local shells_file="$(_login_shell::shells_file)"
    [[ -f "$shells_file" ]] || return 0
    grep -Fxq "$zsh_path" "$shells_file" && return 0

    if (( EUID == 0 )); then
        print -r -- "$zsh_path" >> "$shells_file"
    elif command -v sudo >/dev/null 2>&1; then
        print -r -- "$zsh_path" | sudo tee -a "$shells_file" >/dev/null
    else
        return 1
    fi
}

mod_update() {
    local zsh_path
    zsh_path="$(_login_shell::zsh_path)"
    if [[ -z "$zsh_path" ]]; then
        primer::status_msg "zsh not found"
        return 1
    fi

    if _login_shell::is_current "$zsh_path"; then
        primer::status_msg "already zsh"
        return 0
    fi

    if [[ "$DRY_RUN" == true ]]; then
        echo "[dry-run] ensure $zsh_path is listed in /etc/shells"
        echo "[dry-run] chsh -s $zsh_path ${USER:-$LOGNAME}"
        primer::status_msg "shell planned"
        return 0
    fi

    if ! command -v chsh >/dev/null 2>&1; then
        primer::status_msg "chsh unavailable"
        return 0
    fi

    _login_shell::ensure_shells_entry "$zsh_path" || true
    chsh -s "$zsh_path" "${USER:-$LOGNAME}" || {
        primer::status_msg "chsh failed"
        return 1
    }

    primer::status_msg "shell changed"
}

mod_status() {
    local zsh_path
    zsh_path="$(_login_shell::zsh_path)"
    if [[ -z "$zsh_path" ]]; then
        primer::status_msg "zsh not found"
        return 1
    fi

    if _login_shell::is_current "$zsh_path"; then
        primer::status_msg "zsh"
        return 0
    fi

    primer::status_msg "not zsh"
    return 1
}
