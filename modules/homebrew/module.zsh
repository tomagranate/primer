#!/bin/zsh
# modules/homebrew -- Homebrew package manager + formulae from config

_homebrew::is_lock_error() {
    local output="$1"
    [[ "$output" == *"has already locked"* || "$output" == *"Another active Homebrew process"* ]]
}

_homebrew::is_untrusted_tap_error() {
    local output="$1"
    [[ "$output" == *"not trusted"* ]]
}

_homebrew::trust_configured_taps() {
    local tap
    for tap in $(mod_config taps); do
        [[ -z "$tap" ]] && continue
        brew trust "$tap" || return 1
    done
}

_homebrew::set_output_var() {
    local output_var="$1" value="$2"
    : "${(P)output_var::=$value}"
}

_homebrew::run_quiet() {
    local output_var="$1"
    shift
    local command_output=""
    command_output="$("$@" 2>&1)"
    local rc=$?
    _homebrew::set_output_var "$output_var" "$command_output"
    return "$rc"
}

_homebrew::failure_detail() {
    local fallback="$1" output="$2"
    local detail
    detail="$(primer::first_line "$output")"
    [[ -n "$detail" ]] && print "$detail" || print "$fallback failed"
}

_homebrew::print_command_failure() {
    local command_label="$1" output="$2"
    print -r -- "Error while running: $command_label"
    [[ -n "$output" ]] && print -r -- "$output"
}

_homebrew::formula_installed() {
    local item="$1"
    brew list --formula "$item" >/dev/null 2>&1
}

_homebrew::formula_up_to_date() {
    local item="$1"
    _homebrew::formula_installed "$item" || return 1

    local outdated=()
    outdated=( $(brew outdated --formula --quiet "$item" 2>/dev/null || true) )
    ! (( ${outdated[(I)$item]} ))
}

_homebrew::cask_installed() {
    local item="$1"
    brew list --cask "$item" >/dev/null 2>&1
}

_homebrew::cask_up_to_date() {
    local item="$1"
    _homebrew::cask_installed "$item" || return 1

    local outdated=()
    outdated=( $(brew outdated --cask --quiet "$item" 2>/dev/null || true) )
    ! (( ${outdated[(I)$item]} ))
}

_homebrew::run_with_lock_retry() {
    local output_var="$1"
    shift
    local max_retries="${PRIMER_HOMEBREW_LOCK_RETRIES:-20}"
    local delay="${PRIMER_HOMEBREW_LOCK_RETRY_DELAY:-2}"
    local attempt=0 command_output=""
    local trust_retried=false

    while true; do
        command_output="$("$@" 2>&1)"
        local rc=$?
        if (( rc == 0 )); then
            _homebrew::set_output_var "$output_var" "$command_output"
            return 0
        fi

        if _homebrew::is_lock_error "$command_output" && (( attempt < max_retries )); then
            attempt=$(( attempt + 1 ))
            sleep "$delay"
            continue
        fi

        if ! $trust_retried && _homebrew::is_untrusted_tap_error "$command_output"; then
            trust_retried=true
            _homebrew::trust_configured_taps || true
            continue
        fi

        _homebrew::set_output_var "$output_var" "$command_output"
        return "$rc"
    done
}

_homebrew::install_formula_item() {
    local item="$1"
    if [[ "$DRY_RUN" == true ]]; then
        echo "[dry-run] brew install $item"
        primer::parallel_item_result "done"
    elif ! (( ${installed_formulae[(I)$item]} )); then
        local output=""
        if _homebrew::run_with_lock_retry output brew install "$item"; then
            primer::parallel_item_result "done"
        else
            if _homebrew::formula_installed "$item"; then
                primer::parallel_item_result "done"
                return 0
            else
                _homebrew::print_command_failure "brew install $item" "$output"
                primer::parallel_item_result "failed" "$(_homebrew::failure_detail "brew install $item" "$output")"
                return 1
            fi
        fi
    elif (( ${outdated_formulae[(I)$item]} )); then
        local output=""
        if _homebrew::run_with_lock_retry output brew upgrade "$item"; then
            primer::parallel_item_result "done"
        else
            if _homebrew::formula_up_to_date "$item"; then
                primer::parallel_item_result "done"
                return 0
            else
                _homebrew::print_command_failure "brew upgrade $item" "$output"
                primer::parallel_item_result "failed" "$(_homebrew::failure_detail "brew upgrade $item" "$output")"
                return 1
            fi
        fi
    else
        primer::parallel_item_result "done"
    fi
}

_homebrew::install_cask_item() {
    local item="$1"
    if [[ "$DRY_RUN" == true ]]; then
        echo "[dry-run] brew install --cask $item"
        primer::parallel_item_result "done"
    elif ! (( ${installed_casks[(I)$item]} )); then
        local output=""
        if _homebrew::run_with_lock_retry output brew install --cask "$item"; then
            primer::parallel_item_result "done"
        else
            if _homebrew::cask_installed "$item"; then
                primer::parallel_item_result "done"
                return 0
            else
                _homebrew::print_command_failure "brew install --cask $item" "$output"
                primer::parallel_item_result "failed" "$(_homebrew::failure_detail "brew install --cask $item" "$output")"
                return 1
            fi
        fi
    elif (( ${outdated_casks[(I)$item]} )); then
        local output=""
        if _homebrew::run_with_lock_retry output brew upgrade --cask "$item"; then
            primer::parallel_item_result "done"
        else
            if _homebrew::cask_up_to_date "$item"; then
                primer::parallel_item_result "done"
                return 0
            else
                _homebrew::print_command_failure "brew upgrade --cask $item" "$output"
                primer::parallel_item_result "failed" "$(_homebrew::failure_detail "brew upgrade --cask $item" "$output")"
                return 1
            fi
        fi
    else
        primer::parallel_item_result "done"
    fi
}

mod_update() {
    # Install Homebrew if missing
    if ! command -v brew &>/dev/null && [[ ! -x /opt/homebrew/bin/brew ]]; then
        primer::status_msg "installing Homebrew..."
        if [[ "$DRY_RUN" == true ]]; then
            echo "[dry-run] Install Homebrew"
        else
            local install_output=""
            if ! _homebrew::run_quiet install_output /bin/bash -c \
                "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"; then
                _homebrew::print_command_failure "Homebrew installer" "$install_output"
                return 1
            fi
        fi
    fi
    ensure_brew

    if [[ "$DRY_RUN" != true ]] && ! command -v brew &>/dev/null; then
        print -r -- "Homebrew installation finished, but brew is not available on PATH."
        return 1
    fi

    primer::status_msg "updating Homebrew..."
    local output=""
    if [[ "$DRY_RUN" == true ]]; then
        run brew update
    elif ! _homebrew::run_quiet output brew update; then
        _homebrew::print_command_failure "brew update" "$output"
        return 1
    fi

    local taps=($(mod_config taps))
    local formulae=($(mod_config formulae))
    local casks=($(mod_config casks))

    # Initialise sub-item list with all packages
    primer::items_init "${taps[@]}" "${formulae[@]}" "${casks[@]}"

    # Batch-query installed/outdated state upfront — much faster than per-item brew calls
    local installed_taps=()
    local installed_formulae=()
    local outdated_formulae=()
    local installed_casks=()
    local outdated_casks=()
    if [[ "$DRY_RUN" != true ]]; then
        primer::status_msg "checking packages..."
        installed_taps=(     $(brew tap 2>/dev/null) )
        installed_formulae=( $(brew list --formula 2>/dev/null) )
        outdated_formulae=(  $(brew outdated --formula --quiet 2>/dev/null) )
        installed_casks=(    $(brew list --cask 2>/dev/null) )
        outdated_casks=(     $(brew outdated --cask --quiet 2>/dev/null) )
    fi

    local any_failed=false
    local item

    for item in "${taps[@]}"; do
        primer::item_update "$item" "running"
        if [[ "$DRY_RUN" == true ]]; then
            primer::status_msg "tapping $item..."
            echo "[dry-run] brew tap $item"
            echo "[dry-run] brew trust $item"
            primer::item_update "$item" "done"
        elif (( ${installed_taps[(I)$item]} )); then
            primer::status_msg "trusting $item..."
            if _homebrew::run_quiet output brew trust "$item"; then
                primer::item_update "$item" "done"
            else
                _homebrew::print_command_failure "brew trust $item" "$output"
                primer::item_update "$item" "failed" "$(_homebrew::failure_detail "brew trust $item" "$output")"
                any_failed=true
            fi
        else
            primer::status_msg "tapping $item..."
            if _homebrew::run_quiet output brew tap "$item"; then
                primer::status_msg "trusting $item..."
                if _homebrew::run_quiet output brew trust "$item"; then
                    primer::item_update "$item" "done"
                else
                    _homebrew::print_command_failure "brew trust $item" "$output"
                    primer::item_update "$item" "failed" "$(_homebrew::failure_detail "brew trust $item" "$output")"
                    any_failed=true
                fi
            else
                _homebrew::print_command_failure "brew tap $item" "$output"
                primer::item_update "$item" "failed" "$(_homebrew::failure_detail "brew tap $item" "$output")"
                any_failed=true
            fi
        fi
    done

    local formula_jobs="${PRIMER_HOMEBREW_JOBS:-3}"
    primer::parallel_items "$formula_jobs" "installing formulae" _homebrew::install_formula_item "${formulae[@]}" \
        || any_failed=true

    local cask_jobs="${PRIMER_HOMEBREW_CASK_JOBS:-2}"
    primer::parallel_items "$cask_jobs" "installing casks" _homebrew::install_cask_item "${casks[@]}" \
        || any_failed=true

    if $any_failed; then
        primer::status_msg "completed with errors"
        return 1
    fi
    primer::status_msg "done"
}

mod_status() {
    ensure_brew
    if ! command -v brew &>/dev/null; then
        primer::status_msg "not installed"
        return 1
    fi

    local taps=($(mod_config taps))
    local formulae=($(mod_config formulae))
    local casks=($(mod_config casks))

    local installed_taps=( $(brew tap 2>/dev/null) )
    local installed_formulae=( $(brew list --formula 2>/dev/null) )
    local outdated_formulae=( $(brew outdated --formula --quiet 2>/dev/null) )
    local installed_casks=( $(brew list --cask 2>/dev/null) )
    local outdated_casks=( $(brew outdated --cask --quiet 2>/dev/null) )

    local missing=0 outdated=0 item
    for item in "${taps[@]}"; do
        (( ${installed_taps[(I)$item]} )) || missing=$(( missing + 1 ))
    done
    for item in "${formulae[@]}"; do
        if ! (( ${installed_formulae[(I)$item]} )); then
            missing=$(( missing + 1 ))
        elif (( ${outdated_formulae[(I)$item]} )); then
            outdated=$(( outdated + 1 ))
        fi
    done
    for item in "${casks[@]}"; do
        if ! (( ${installed_casks[(I)$item]} )); then
            missing=$(( missing + 1 ))
        elif (( ${outdated_casks[(I)$item]} )); then
            outdated=$(( outdated + 1 ))
        fi
    done

    local version=$(brew --version 2>/dev/null | head -1 | sed 's/Homebrew /v/')
    version="${version%%-*}"

    if (( missing == 0 && outdated == 0 )); then
        primer::status_msg "${version} · up to date"
        return 0
    fi

    local parts=("$version")
    (( missing > 0 )) && parts+=("${missing} missing")
    (( outdated > 0 )) && parts+=("${outdated} outdated")
    primer::status_msg "${(j: · :)parts}"
    return 1
}
