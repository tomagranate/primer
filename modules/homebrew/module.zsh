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

_homebrew::run_with_lock_retry() {
    local output_var="$1"
    shift
    local max_retries="${PRIMER_HOMEBREW_LOCK_RETRIES:-20}"
    local delay="${PRIMER_HOMEBREW_LOCK_RETRY_DELAY:-2}"
    local attempt=0 output=""
    local trust_retried=false

    while true; do
        output="$("$@" 2>&1)"
        local rc=$?
        if (( rc == 0 )); then
            typeset -g "$output_var=$output"
            return 0
        fi

        if _homebrew::is_lock_error "$output" && (( attempt < max_retries )); then
            attempt=$(( attempt + 1 ))
            sleep "$delay"
            continue
        fi

        if ! $trust_retried && _homebrew::is_untrusted_tap_error "$output"; then
            trust_retried=true
            _homebrew::trust_configured_taps || true
            continue
        fi

        typeset -g "$output_var=$output"
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
            print -r -- "$output"
            primer::parallel_item_result "failed" "$(primer::first_line "$output")"
            return 1
        fi
    elif (( ${outdated_formulae[(I)$item]} )); then
        local output=""
        if _homebrew::run_with_lock_retry output brew upgrade "$item"; then
            primer::parallel_item_result "done"
        else
            print -r -- "$output"
            primer::parallel_item_result "failed" "$(primer::first_line "$output")"
            return 1
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
            print -r -- "$output"
            primer::parallel_item_result "failed" "$(primer::first_line "$output")"
            return 1
        fi
    elif (( ${outdated_casks[(I)$item]} )); then
        local output=""
        if _homebrew::run_with_lock_retry output brew upgrade --cask "$item"; then
            primer::parallel_item_result "done"
        else
            print -r -- "$output"
            primer::parallel_item_result "failed" "$(primer::first_line "$output")"
            return 1
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
            /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
        fi
    fi
    ensure_brew

    primer::status_msg "updating Homebrew..."
    run brew update

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
            brew trust "$item" && primer::item_update "$item" "done" \
                               || { primer::item_update "$item" "failed"; any_failed=true; }
        else
            primer::status_msg "tapping $item..."
            if brew tap "$item"; then
                primer::status_msg "trusting $item..."
                brew trust "$item" && primer::item_update "$item" "done" \
                                   || { primer::item_update "$item" "failed"; any_failed=true; }
            else
                primer::item_update "$item" "failed"
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
