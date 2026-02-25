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
    local item
    for item in "${casks[@]}"; do
        primer::item_update "$item" "running"
        if [[ "$DRY_RUN" == true ]]; then
            primer::status_msg "installing $item..."
            echo "[dry-run] brew install --cask $item"
            primer::item_update "$item" "done"
        elif ! (( ${installed_casks[(I)$item]} )); then
            local guessed_bundle="$(_homebrew_apps::guess_app_bundle_name "$item")"
            local resolved_app_path="${cask_app_path[$item]:-${applications_dir}/${guessed_bundle}}"
            if [[ -d "$resolved_app_path" ]]; then
                primer::status_msg "warning: $item already installed outside brew cask"
                primer::item_update "$item" "skipped"
                any_warnings=true
                warning_count=$(( warning_count + 1 ))
                continue
            fi

            primer::status_msg "installing $item..."
            local install_output=""
            if install_output="$(brew install --cask "$item" 2>&1)"; then
                primer::item_update "$item" "done"
            else
                print -r -- "$install_output"
                if [[ "$install_output" == *"It seems there is already an App at"* ]]; then
                    primer::status_msg "warning: $item already installed outside brew cask"
                    primer::item_update "$item" "skipped"
                    any_warnings=true
                    warning_count=$(( warning_count + 1 ))
                else
                    primer::item_update "$item" "failed"
                    any_failed=true
                fi
            fi
        elif (( ${outdated_casks[(I)$item]} )); then
            primer::status_msg "updating $item..."
            brew upgrade --cask "$item" && primer::item_update "$item" "done" \
                                        || { primer::item_update "$item" "failed"; any_failed=true; }
        else
            primer::status_msg "$item up to date"
            primer::item_update "$item" "done"
        fi
    done

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
    if command -v brew &>/dev/null; then
        primer::status_msg "ready"
        return 0
    fi
    primer::status_msg "not installed"
    return 1
}
