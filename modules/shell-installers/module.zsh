#!/bin/zsh
# modules/shell-installers -- Tools installed by remote shell installers

typeset -ga _shell_installer_names=()
typeset -gA _shell_installer_url=()
typeset -gA _shell_installer_command=()
typeset -gA _shell_installer_check=()
typeset -gA _shell_installer_args=()
typeset -gA _shell_installer_shell=()
typeset -gA _shell_installer_privileged=()

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
    _shell_installer_args=()
    _shell_installer_shell=()
    _shell_installer_privileged=()

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
            args)    _shell_installer_args[$current]="$value" ;;
            shell)   _shell_installer_shell[$current]="$value" ;;
            privileged) _shell_installer_privileged[$current]="$value" ;;
        esac
    done <<< "$(mod_config installers)"
}

_shell_installers::shell_for() {
    local name="$1"
    local shell_name="${_shell_installer_shell[$name]:-bash}"
    case "$shell_name" in
        bash|sh) print -r -- "$shell_name" ;;
        *) print -r -- "bash" ;;
    esac
}

_shell_installers::is_privileged() {
    local name="$1"
    [[ "${_shell_installer_privileged[$name]:l}" == true ]]
}

_shell_installers::check_command() {
    local name="$1"
    local check="${_shell_installer_check[$name]}"
    [[ -n "$check" ]] || check="command -v ${_shell_installer_command[$name]}"
    [[ -n "$check" ]] || return 1

    zsh -c "$check" >/dev/null 2>&1 && return 0

    local -a check_parts=(${(z)check})
    local command_name="${_shell_installer_command[$name]}"
    [[ -z "$command_name" && ${#check_parts[@]} -gt 0 ]] && command_name="${check_parts[1]}"
    [[ -z "$command_name" ]] && return 1

    local -a args=()
    if (( ${#check_parts[@]} > 1 && "${check_parts[1]}" == "$command_name" )); then
        args=("${(@)check_parts[2,-1]}")
    fi

    local candidate
    for candidate in \
        "$HOME/.${name}/bin/${command_name}" \
        "$HOME/.${name}/${command_name}" \
        "$HOME/.local/bin/${command_name}" \
        "$HOME/bin/${command_name}" \
        "/opt/homebrew/bin/${command_name}" \
        "/usr/local/bin/${command_name}"; do
        [[ -x "$candidate" ]] || continue
        "$candidate" "${args[@]}" >/dev/null 2>&1 && return 0
    done

    return 1
}

_shell_installers::install_item() {
    setopt localoptions pipefail

    local name="$1"
    local url="${_shell_installer_url[$name]}"
    if [[ -z "$url" ]]; then
        primer::parallel_item_result "failed" "missing url"
        return 1
    fi

    if [[ "$DRY_RUN" == true ]]; then
        local shell_name="$(_shell_installers::shell_for "$name")"
        local prefix=""
        _shell_installers::is_privileged "$name" && prefix="sudo -n "
        if [[ -n "${_shell_installer_args[$name]:-}" ]]; then
            echo "[dry-run] curl -fsSL $url | ${prefix}${shell_name} -s -- ${_shell_installer_args[$name]}"
        else
            echo "[dry-run] curl -fsSL $url | ${prefix}${shell_name}"
        fi
        primer::parallel_item_result "done"
        return 0
    fi

    if _shell_installers::check_command "$name"; then
        primer::parallel_item_result "done"
        return 0
    fi

    local -a args=()
    if [[ -n "${_shell_installer_args[$name]:-}" ]]; then
        local arg_line="${_shell_installer_args[$name]}"
        args=(${(z)arg_line})
    fi

    local shell_name="$(_shell_installers::shell_for "$name")"
    local install_rc=0
    if _shell_installers::is_privileged "$name"; then
        if (( ${#args[@]} > 0 )); then
            curl -fsSL "$url" | primer::run_as_root "Shell installer: ${name}" "$shell_name" -s -- "${args[@]}" || install_rc=$?
        else
            curl -fsSL "$url" | primer::run_as_root "Shell installer: ${name}" "$shell_name" || install_rc=$?
        fi
    else
        if (( ${#args[@]} > 0 )); then
            curl -fsSL "$url" | "$shell_name" -s -- "${args[@]}" || install_rc=$?
        else
            curl -fsSL "$url" | "$shell_name" || install_rc=$?
        fi
    fi

    if (( install_rc != 0 )); then
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
