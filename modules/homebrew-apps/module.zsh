#!/bin/zsh
# modules/homebrew-apps -- Mac apps via Homebrew Cask

_homebrew_apps::title_case_word() {
    local w="$1"
    if [[ -z "$w" ]]; then
        print ""
        return 0
    fi
    print "${(U)w[1]}${w[2,-1]}"
}

_homebrew_apps::guess_app_bundle_name() {
    local cask="$1"
    local word words=() out=()
    words=(${(s:-:)cask})
    for word in "${words[@]}"; do
        out+=("$(_homebrew_apps::title_case_word "$word")")
    done
    print "${(j: :)out}.app"
}

_homebrew_apps::first_line() {
    local text="$1"
    local first="${text%%$'\n'*}"
    first="${first//$'\r'/}"
    print "$first"
}

_homebrew_apps::is_lock_error() {
    local output="$1"
    [[ "$output" == *"has already locked"* || "$output" == *"Another active Homebrew process"* ]]
}

_homebrew_apps::run_with_lock_retry() {
    local output_var="$1"
    shift
    local max_retries="${PRIMER_HOMEBREW_LOCK_RETRIES:-20}"
    local delay="${PRIMER_HOMEBREW_LOCK_RETRY_DELAY:-2}"
    local attempt=0 output=""

    while true; do
        output="$("$@" 2>&1)"
        local rc=$?
        if (( rc == 0 )); then
            typeset -g "$output_var=$output"
            return 0
        fi

        if _homebrew_apps::is_lock_error "$output" && (( attempt < max_retries )); then
            attempt=$(( attempt + 1 ))
            sleep "$delay"
            continue
        fi

        typeset -g "$output_var=$output"
        return "$rc"
    done
}

_homebrew_apps::install_cask_item() {
    local item="$1"
    if [[ "$DRY_RUN" == true ]]; then
        echo "[dry-run] brew install --cask $item"
        primer::parallel_item_result "done"
    elif ! (( ${installed_casks[(I)$item]} )); then
        local guessed_bundle="$(_homebrew_apps::guess_app_bundle_name "$item")"
        local resolved_app_path="${cask_app_path[$item]:-${applications_dir}/${guessed_bundle}}"
        if [[ -d "$resolved_app_path" ]]; then
            primer::parallel_item_result "skipped" "already installed outside brew cask"
            return 0
        fi

        local install_output=""
        if HOMEBREW_NO_COLOR=1 _homebrew_apps::run_with_lock_retry install_output brew install --quiet --cask "$item"; then
            primer::parallel_item_result "done"
        else
            print -r -- "$install_output"
            if [[ "$install_output" == *"It seems there is already an App at"* ]]; then
                primer::parallel_item_result "skipped" "already installed outside brew cask"
            else
                primer::parallel_item_result "failed" "$(_homebrew_apps::first_line "$install_output")"
                return 1
            fi
        fi
    elif (( ${outdated_casks[(I)$item]} )); then
        local upgrade_output=""
        if HOMEBREW_NO_COLOR=1 _homebrew_apps::run_with_lock_retry upgrade_output brew upgrade --quiet --cask "$item"; then
            primer::parallel_item_result "done"
        else
            print -r -- "$upgrade_output"
            primer::parallel_item_result "failed" "$(_homebrew_apps::first_line "$upgrade_output")"
            return 1
        fi
    else
        primer::parallel_item_result "done"
    fi
}

mod_update() {
    ensure_brew

    local casks=($(mod_config casks))
    primer::items_init "${casks[@]}"
    local applications_dir="${PRIMER_APPLICATIONS_DIR:-/Applications}"

    # Batch-query installed/outdated state upfront — much faster than per-item brew calls
    local installed_casks=()
    local outdated_casks=()
    local -A cask_app_path
    local map_entry cask_key app_path
    while IFS= read -r map_entry; do
        [[ -z "$map_entry" ]] && continue
        cask_key="${map_entry%%:*}"
        app_path="${map_entry#*:}"
        [[ -z "$cask_key" || -z "$app_path" ]] && continue
        if [[ "$app_path" == /* ]]; then
            cask_app_path[$cask_key]="$app_path"
        else
            cask_app_path[$cask_key]="${applications_dir}/${app_path}"
        fi
    done <<< "$(mod_config app_paths)"
    if [[ "$DRY_RUN" != true ]]; then
        primer::status_msg "checking apps..."
        installed_casks=( $(brew list --cask 2>/dev/null) )
        outdated_casks=(  $(brew outdated --cask --quiet 2>/dev/null) )
    fi

    local any_failed=false
    local any_warnings=false
    local warning_count=0
    local cask_jobs="${PRIMER_MAC_APPS_JOBS:-2}"
    primer::parallel_items "$cask_jobs" "installing apps" _homebrew_apps::install_cask_item "${casks[@]}" \
        || any_failed=true

    warning_count=$(grep -c '^skipped:' "$MOD_ITEMS_FILE" 2>/dev/null || true)
    (( warning_count > 0 )) && any_warnings=true

    if $any_failed; then
        primer::status_msg "completed with errors"
        return 1
    fi
    if $any_warnings; then
        primer::status_msg "done with $warning_count warning(s)"
        return 0
    fi
    primer::status_msg "done"
}

mod_status() {
    ensure_brew
    if ! command -v brew &>/dev/null; then
        primer::status_msg "not installed"
        return 1
    fi

    local casks=($(mod_config casks))
    local applications_dir="${PRIMER_APPLICATIONS_DIR:-/Applications}"
    local installed_casks=( $(brew list --cask 2>/dev/null) )
    local outdated_casks=( $(brew outdated --cask --quiet 2>/dev/null) )

    local -A cask_app_path
    local map_entry cask_key app_path
    while IFS= read -r map_entry; do
        [[ -z "$map_entry" ]] && continue
        cask_key="${map_entry%%:*}"
        app_path="${map_entry#*:}"
        [[ -z "$cask_key" || -z "$app_path" ]] && continue
        if [[ "$app_path" == /* ]]; then
            cask_app_path[$cask_key]="$app_path"
        else
            cask_app_path[$cask_key]="${applications_dir}/${app_path}"
        fi
    done <<< "$(mod_config app_paths)"

    local missing=0 outdated=0 warnings=0 item
    for item in "${casks[@]}"; do
        if (( ${installed_casks[(I)$item]} )); then
            (( ${outdated_casks[(I)$item]} )) && outdated=$(( outdated + 1 ))
            continue
        fi

        local guessed_bundle="$(_homebrew_apps::guess_app_bundle_name "$item")"
        local resolved_app_path="${cask_app_path[$item]:-${applications_dir}/${guessed_bundle}}"
        if [[ -d "$resolved_app_path" ]]; then
            warnings=$(( warnings + 1 ))
        else
            missing=$(( missing + 1 ))
        fi
    done

    if (( missing == 0 && outdated == 0 )); then
        if (( warnings > 0 )); then
            primer::status_msg "up to date · ${warnings} warning(s)"
        else
            primer::status_msg "up to date"
        fi
        return 0
    fi

    local parts=()
    (( missing > 0 )) && parts+=("${missing} missing")
    (( outdated > 0 )) && parts+=("${outdated} outdated")
    (( warnings > 0 )) && parts+=("${warnings} warning(s)")
    primer::status_msg "${(j: · :)parts}"
    return 1
}
