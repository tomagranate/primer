#!/bin/zsh
# modules/dnf -- Fedora packages and COPR repositories via DNF5

_dnf::bootstrap_packages() {
    mod_config bootstrap_packages
}

_dnf::packages() {
    mod_config packages
}

_dnf::coprs() {
    mod_config coprs
}

_dnf::command() {
    print dnf5
}

_dnf::run_as_root() {
    primer::run_as_root "DNF packages" "$@"
}

_dnf::installed() {
    rpm -q "$1" >/dev/null 2>&1
}

_dnf::copr_enabled() {
    local copr="$1" command="$(_dnf::command)"
    local repo_fragment="${copr//\//:}"
    "$command" repolist --enabled 2>/dev/null | grep -Fq "$repo_fragment"
}

_dnf::line_has_package() {
    local line="$1" package="$2"
    case "$line" in
        *"] ${package}-"*|*"Installing ${package}-"*|*" ${package} "*|*": ${package}") return 0 ;;
    esac
    return 1
}

_dnf::route_batch_output() {
    local batch_log="$1"
    shift
    local -a packages=("$@")
    local line package phase="resolving"

    while IFS= read -r line || [[ -n "$line" ]]; do
        line="${line//$'\r'/}"
        print -r -- "$line"
        print -r -- "$line" >> "$batch_log"
        if [[ "$line" == "Running transaction"* ]]; then
            phase="installing"
            for package in "${packages[@]}"; do
                if ! _dnf::installed "$package"; then
                    primer::item_update "$package" "running" "waiting to install"
                    primer::item_log "$package" "Waiting for RPM transaction."
                fi
            done
        fi

        for package in "${packages[@]}"; do
            _dnf::line_has_package "$line" "$package" || continue
            primer::item_log "$package" "$line"
            if [[ "$phase" == "installing" ]]; then
                primer::item_update "$package" "running" "installing"
                if _dnf::installed "$package"; then
                    primer::item_update "$package" "done" "installed"
                    primer::item_log "$package" "$package: installed"
                fi
            else
                primer::item_update "$package" "running" "downloading"
            fi
        done
    done
}

_dnf::append_batch_failure() {
    local package="$1" batch_log="$2" line
    primer::item_log "$package" "Batch command failed. Full error tail follows."
    while IFS= read -r line || [[ -n "$line" ]]; do
        primer::item_log "$package" "$line"
    done < <(tail -n 40 "$batch_log")
}

_dnf::install_batch() {
    local label="$1"
    shift
    local -a requested=("$@") missing=()
    local package command batch_log rc
    command="$(_dnf::command)"

    for package in "${requested[@]}"; do
        if _dnf::installed "$package"; then
            primer::item_update "$package" "skipped" "already installed"
            primer::item_log "$package" "$package: already installed"
        else
            missing+=("$package")
        fi
    done
    (( ${#missing[@]} == 0 )) && return 0

    batch_log="$(mktemp "${TMPDIR:-/tmp}/primer-dnf5.XXXXXX")" || return 1
    for package in "${missing[@]}"; do
        primer::item_update "$package" "running" "queued"
        primer::item_log "$package" "Batch command: sudo -n $command -y --color=never install ${missing[*]}"
    done

    primer::status_msg "$label 0/${#missing[@]}..."
    _dnf::run_as_root "$command" -y --color=never install "${missing[@]}" 2>&1 \
        | _dnf::route_batch_output "$batch_log" "${missing[@]}"
    local -a batch_status=("${pipestatus[@]}")
    rc="${batch_status[1]:-1}"

    local complete=0 failed=0
    for package in "${missing[@]}"; do
        if _dnf::installed "$package"; then
            local previous_state="$(primer::item_state "$package" 2>/dev/null)"
            primer::item_update "$package" "done" "installed"
            [[ "$previous_state" == "done" ]] || primer::item_log "$package" "$package: installed"
            complete=$(( complete + 1 ))
        else
            primer::item_update "$package" "failed" "batch exit $rc"
            _dnf::append_batch_failure "$package" "$batch_log"
            failed=$(( failed + 1 ))
        fi
        primer::status_msg "$label $(( complete + failed ))/${#missing[@]}..."
    done
    rm -f "$batch_log"

    if (( failed > 0 )); then
        primer::status_msg "$label: $failed failed"
    elif (( rc != 0 )); then
        primer::status_msg "$label: command exit $rc"
    else
        primer::status_msg "$label complete"
    fi
    (( rc == 0 && failed == 0 ))
}

mod_update() {
    local -a bootstrap_packages=($(_dnf::bootstrap_packages))
    local -a packages=($(_dnf::packages))
    local -a coprs=($(_dnf::coprs))
    local -a all_packages=("${bootstrap_packages[@]}" "${packages[@]}")
    local command="$(_dnf::command)"
    primer::items_init "${all_packages[@]}"

    if [[ "$DRY_RUN" == true ]]; then
        (( ${#bootstrap_packages[@]} == 0 )) || \
            echo "[dry-run] sudo $command -y --color=never install ${bootstrap_packages[*]}"
        local copr
        for copr in "${coprs[@]}"; do
            echo "[dry-run] sudo $command -y --color=never copr enable $copr"
        done
        (( ${#packages[@]} == 0 )) || \
            echo "[dry-run] sudo $command -y --color=never install ${packages[*]}"
        local package
        for package in "${all_packages[@]}"; do
            primer::item_update "$package" "done" "planned"
            primer::item_log "$package" "$package: planned"
        done
        primer::status_msg "packages planned"
        return 0
    fi

    if ! command -v "$command" >/dev/null 2>&1 || ! command -v rpm >/dev/null 2>&1; then
        primer::status_msg "dnf5 or rpm not found"
        return 1
    fi

    primer::status_msg "checking DNF5 plugins..."
    _dnf::install_batch "DNF5 plugins" "${bootstrap_packages[@]}" || return 1

    local copr
    for copr in "${coprs[@]}"; do
        if ! _dnf::copr_enabled "$copr"; then
            primer::status_msg "enabling $copr..."
            if ! _dnf::run_as_root "$command" -y --color=never copr enable "$copr"; then
                primer::status_msg "failed to enable $copr"
                return 1
            fi
        fi
    done

    primer::status_msg "checking packages..."
    _dnf::install_batch "Packages" "${packages[@]}" || return 1
    primer::status_msg "packages installed"
}

mod_status() {
    local command="$(_dnf::command)"
    if ! command -v "$command" >/dev/null 2>&1 || ! command -v rpm >/dev/null 2>&1; then
        primer::status_msg "dnf5 not available"
        return 1
    fi

    local missing=0 package copr
    for package in $(_dnf::bootstrap_packages) $(_dnf::packages); do
        _dnf::installed "$package" || missing=$(( missing + 1 ))
    done
    for copr in $(_dnf::coprs); do
        _dnf::copr_enabled "$copr" || missing=$(( missing + 1 ))
    done

    if (( missing == 0 )); then
        primer::status_msg "installed"
        return 0
    fi

    primer::status_msg "${missing} missing"
    return 1
}
