#!/bin/zsh
# modules/npm-global -- Global npm CLIs

typeset -ga _npm_global_names=()
typeset -gA _npm_global_package=()
typeset -gA _npm_global_command=()
typeset -gA _npm_global_check=()

_npm_global::trim() {
    local value="$1"
    value="${value#"${value%%[![:space:]]*}"}"
    value="${value%"${value##*[![:space:]]}"}"
    print -r -- "$value"
}

_npm_global::parse_field() {
    local line="$1"
    local key="${line%%:*}"
    local value="${line#*:}"
    key="$(_npm_global::trim "$key")"
    value="$(_npm_global::trim "$value")"
    print -r -- "${key}:${value}"
}

_npm_global::parse_config() {
    _npm_global_names=()
    _npm_global_package=()
    _npm_global_command=()
    _npm_global_check=()

    local line current="" field key value
    while IFS= read -r line; do
        line="$(_npm_global::trim "$line")"
        [[ -z "$line" ]] && continue

        if [[ "$line" == "- name:"* ]]; then
            field="$(_npm_global::parse_field "${line#- }")"
            value="${field#*:}"
            current="$value"
            [[ -n "$current" ]] && _npm_global_names+=("$current")
            continue
        fi

        [[ -z "$current" || "$line" != *":"* ]] && continue
        field="$(_npm_global::parse_field "$line")"
        key="${field%%:*}"
        value="${field#*:}"
        case "$key" in
            package) _npm_global_package[$current]="$value" ;;
            command) _npm_global_command[$current]="$value" ;;
            check)   _npm_global_check[$current]="$value" ;;
        esac
    done <<< "$(mod_config packages)"
}

_npm_global::mise_bin() {
    if command -v mise >/dev/null 2>&1; then
        command -v mise
        return 0
    fi

    local candidate
    for candidate in \
        "$HOME/.local/bin/mise" \
        "$HOME/.mise/bin/mise" \
        "$HOME/bin/mise" \
        "/opt/homebrew/bin/mise" \
        "/usr/local/bin/mise"; do
        [[ -x "$candidate" ]] || continue
        print -r -- "$candidate"
        return 0
    done

    return 1
}

_npm_global::run_npm() {
    local mise_bin
    if mise_bin="$(_npm_global::mise_bin)"; then
        "$mise_bin" exec -- npm "$@"
        return $?
    fi

    if command -v npm >/dev/null 2>&1; then
        npm "$@"
        return $?
    fi

    return 127
}

_npm_global::check_command() {
    local name="$1"
    local check="${_npm_global_check[$name]}"
    [[ -n "$check" ]] || check="command -v ${_npm_global_command[$name]}"
    [[ -n "$check" ]] || return 1

    local mise_bin
    if mise_bin="$(_npm_global::mise_bin)"; then
        "$mise_bin" exec -- zsh -c "$check" >/dev/null 2>&1
        return $?
    fi

    zsh -c "$check" >/dev/null 2>&1
}

_npm_global::install_item() {
    local name="$1"
    local package="${_npm_global_package[$name]}"
    if [[ -z "$package" ]]; then
        primer::parallel_item_result "failed" "missing package"
        return 1
    fi

    if [[ "$DRY_RUN" == true ]]; then
        echo "[dry-run] npm install -g $package"
        primer::parallel_item_result "done"
        return 0
    fi

    if _npm_global::check_command "$name"; then
        primer::parallel_item_result "done"
        return 0
    fi

    if ! _npm_global::run_npm install -g "$package"; then
        primer::parallel_item_result "failed" "install failed"
        return 1
    fi

    if ! _npm_global::check_command "$name"; then
        primer::parallel_item_result "failed" "check failed"
        return 1
    fi

    primer::parallel_item_result "done"
}

mod_update() {
    _npm_global::parse_config
    primer::items_init "${_npm_global_names[@]}"

    if (( ${#_npm_global_names[@]} == 0 )); then
        primer::status_msg "no packages"
        return 0
    fi

    local any_failed=false
    primer::parallel_items 1 "installing npm CLIs" _npm_global::install_item "${_npm_global_names[@]}" \
        || any_failed=true

    if $any_failed; then
        primer::status_msg "completed with errors"
        return 1
    fi

    primer::status_msg "installed"
}

mod_status() {
    _npm_global::parse_config

    local missing=0 invalid=0 name
    for name in "${_npm_global_names[@]}"; do
        if [[ -z "${_npm_global_package[$name]}" || -z "${_npm_global_command[$name]}" ]]; then
            invalid=$(( invalid + 1 ))
            continue
        fi
        _npm_global::check_command "$name" || missing=$(( missing + 1 ))
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
