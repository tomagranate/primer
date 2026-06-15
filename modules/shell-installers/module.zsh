#!/bin/zsh
# modules/shell-installers -- Tools installed by remote shell installers

typeset -ga _shell_installer_names=()
typeset -gA _shell_installer_url=()
typeset -gA _shell_installer_command=()
typeset -gA _shell_installer_check=()

_shell_installers::trim() {
    local value="$1"
    value="${value#"${value%%[![:space:]]*}"}"
    value="${value%"${value##*[![:space:]]}"}"
    print -r -- "$value"
}

_shell_installers::parse_field() {
    local line="$1"
    local key="${line%%:*}"
    local value="${line#*:}"
    key="$(_shell_installers::trim "$key")"
    value="$(_shell_installers::trim "$value")"
    print -r -- "${key}:${value}"
}

_shell_installers::parse_config() {
    _shell_installer_names=()
    _shell_installer_url=()
    _shell_installer_command=()
    _shell_installer_check=()

    local line current="" field key value
    while IFS= read -r line; do
        line="$(_shell_installers::trim "$line")"
        [[ -z "$line" ]] && continue

        if [[ "$line" == "- name:"* ]]; then
            field="$(_shell_installers::parse_field "${line#- }")"
            value="${field#*:}"
            current="$value"
            [[ -n "$current" ]] && _shell_installer_names+=("$current")
            continue
        fi

        [[ -z "$current" || "$line" != *":"* ]] && continue
        field="$(_shell_installers::parse_field "$line")"
        key="${field%%:*}"
        value="${field#*:}"
        case "$key" in
            url)     _shell_installer_url[$current]="$value" ;;
            command) _shell_installer_command[$current]="$value" ;;
            check)   _shell_installer_check[$current]="$value" ;;
        esac
    done <<< "$(mod_config installers)"
}

_shell_installers::check_command() {
    local name="$1"
    local check="${_shell_installer_check[$name]}"
    [[ -n "$check" ]] || check="command -v ${_shell_installer_command[$name]}"
    [[ -n "$check" ]] || return 1

    zsh -c "$check" >/dev/null 2>&1
}

_shell_installers::install_item() {
    setopt localoptions pipefail

    local name="$1"
    local url="${_shell_installer_url[$name]}"
    if [[ -z "$url" ]]; then
        primer::parallel_item_result "failed" "missing url"
        return 1
    fi

    if _shell_installers::check_command "$name"; then
        primer::parallel_item_result "done"
        return 0
    fi

    if [[ "$DRY_RUN" == true ]]; then
        echo "[dry-run] curl -fsSL $url | bash"
        primer::parallel_item_result "done"
        return 0
    fi

    if ! curl -fsSL "$url" | bash; then
        primer::parallel_item_result "failed" "installer failed"
        return 1
    fi

    if ! _shell_installers::check_command "$name"; then
        primer::parallel_item_result "failed" "check failed"
        return 1
    fi

    primer::parallel_item_result "done"
}

mod_update() {
    _shell_installers::parse_config
    primer::items_init "${_shell_installer_names[@]}"

    if (( ${#_shell_installer_names[@]} == 0 )); then
        primer::status_msg "no installers"
        return 0
    fi

    local any_failed=false
    primer::parallel_items 1 "installing tools" _shell_installers::install_item "${_shell_installer_names[@]}" \
        || any_failed=true

    if $any_failed; then
        primer::status_msg "completed with errors"
        return 1
    fi

    primer::status_msg "done"
}

mod_status() {
    _shell_installers::parse_config

    local missing=0 invalid=0 name
    for name in "${_shell_installer_names[@]}"; do
        if [[ -z "${_shell_installer_url[$name]}" || -z "${_shell_installer_command[$name]}" ]]; then
            invalid=$(( invalid + 1 ))
            continue
        fi
        _shell_installers::check_command "$name" || missing=$(( missing + 1 ))
    done

    if (( missing == 0 && invalid == 0 )); then
        primer::status_msg "installed"
        return 0
    fi

    local parts=()
    (( missing > 0 )) && parts+=("${missing} missing")
    (( invalid > 0 )) && parts+=("${invalid} invalid")
    primer::status_msg "${(j: · :)parts}"
    return 1
}
