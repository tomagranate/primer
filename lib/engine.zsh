#!/bin/zsh
# lib/engine.zsh -- Ready-queue DAG engine with parallel execution

zmodload zsh/datetime   # EPOCHREALTIME for sub-second timing

# ── Module Registry (populated by engine::load_config) ────────────────────────

typeset -ga _mod_order=()       # Module names in config order
typeset -gA _mod_deps=()        # module -> "dep1,dep2,..."
typeset -gA _mod_desc=()        # module -> "Display Label"
typeset -gA _mod_config=()      # "module.key" -> "value\nvalue..."

# ── Runtime State ─────────────────────────────────────────────────────────────

typeset -gA _state=()           # module -> pending|running|done|failed|skipped
typeset -gA _pids=()            # module -> background PID
typeset -gA _start=()           # module -> start EPOCHREALTIME
typeset -gA _elapsed=()         # module -> "N.Ns" (set when finished)
typeset -g  PRIMER_TMPDIR=""

# ── Config Parsing (INI format) ──────────────────────────────────────────────

engine::load_config() {
    local config="$1" section="" key=""
    _mod_order=()
    _mod_deps=()
    _mod_desc=()
    _mod_config=()

    while IFS= read -r line; do
        # Skip comments and blank lines
        [[ "$line" =~ ^[[:space:]]*# ]] && continue
        [[ -z "${line// /}" ]] && continue

        # Section header: [module_name]
        if [[ "$line" =~ '^\[([a-z_]+)\]' ]]; then
            section="${match[1]}"
            _mod_order+=("$section")
            key=""
            continue
        fi

        # Indented continuation line (part of a multi-value key)
        if [[ "$line" =~ '^[[:space:]]+(.+)' && -n "$key" && -n "$section" ]]; then
            _mod_config[${section}.${key}]+=$'\n'"${match[1]}"
            continue
        fi

        # Key = value line
        if [[ "$line" =~ '^([a-z_]+)[[:space:]]*=[[:space:]]*(.*)' && -n "$section" ]]; then
            key="${match[1]}"
            local val="${match[2]}"
            _mod_config[${section}.${key}]="$val"
            [[ "$key" == "depends_on" ]] && _mod_deps[$section]="${val// /}"
            [[ "$key" == "label" ]]      && _mod_desc[$section]="$val"
        fi
    done < "$config"
}

# ── DAG Helpers ───────────────────────────────────────────────────────────────

# Are all dependencies of this module in "done" state?
engine::_deps_met() {
    local mod="$1"
    local deps="${_mod_deps[$mod]}"
    [[ -z "$deps" ]] && return 0

    local dep
    for dep in ${(s:,:)deps}; do
        [[ "${_state[$dep]}" != "done" ]] && return 1
    done
    return 0
}

# Has any dependency of this module failed or been skipped?
engine::_deps_failed() {
    local mod="$1"
    local deps="${_mod_deps[$mod]}"
    [[ -z "$deps" ]] && return 1

    local dep
    for dep in ${(s:,:)deps}; do
        [[ "${_state[$dep]}" == "failed" || "${_state[$dep]}" == "skipped" ]] && return 0
    done
    return 1
}

# Are there any modules still pending or running?
engine::_has_active() {
    local mod
    for mod in $_mod_order; do
        [[ "${_state[$mod]}" == "pending" || "${_state[$mod]}" == "running" ]] && return 0
    done
    return 1
}

# ── Module Lifecycle ──────────────────────────────────────────────────────────

# Fork a module as a background subshell
engine::_start_module() {
    local mod="$1" action="$2"
    local logfile="${PRIMER_TMPDIR}/${mod}.log"
    local statusfile="${PRIMER_TMPDIR}/${mod}.status"
    local mod_dir="${PRIMER_DIR}/modules/${mod}"

    (
        export MOD_STATUS_FILE="$statusfile"
        export MOD_DIR="$mod_dir"
        export MOD_NAME="$mod"
        # Source helpers (run, deploy_files, check_files, primer::status_msg, ensure_brew)
        source "${PRIMER_DIR}/lib/ui.zsh"
        # Source the module
        source "${mod_dir}/module.zsh" || {
            echo "Failed to load module: ${mod}"
            exit 1
        }
        # Call the action function
        "mod_${action}"
    ) &>"$logfile" &

    local pid=$!
    _pids[$mod]=$pid
    _state[$mod]="running"
    _start[$mod]=$EPOCHREALTIME
}

# Check running modules for completion
engine::_poll_running() {
    local mod
    for mod in $_mod_order; do
        [[ "${_state[$mod]}" != "running" ]] && continue

        # Is this PID still alive?
        if ! kill -0 ${_pids[$mod]} 2>/dev/null; then
            local rc=0
            wait ${_pids[$mod]} 2>/dev/null || rc=$?
            _elapsed[$mod]=$(printf '%.1f' $(( EPOCHREALTIME - _start[$mod] )))

            if (( rc == 0 )); then
                _state[$mod]="done"
            else
                _state[$mod]="failed"
            fi
        fi
    done
}

# Find and start all modules whose dependencies are now satisfied
engine::_start_ready() {
    local action="$1"
    local mod
    for mod in $_mod_order; do
        [[ "${_state[$mod]}" != "pending" ]] && continue

        if engine::_deps_failed "$mod"; then
            _state[$mod]="skipped"
        elif engine::_deps_met "$mod"; then
            engine::_start_module "$mod" "$action"
        fi
    done
}

# ── Display ───────────────────────────────────────────────────────────────────

# Read the status message a module wrote to its status file
engine::_get_detail() {
    local mod="$1"
    local statusfile="${PRIMER_TMPDIR}/${mod}.status"

    case "${_state[$mod]}" in
        pending)  print "waiting" ;;
        running)
            if [[ -f "$statusfile" ]]; then
                cat "$statusfile"
            else
                print "running..."
            fi
            ;;
        done|failed)
            if [[ -f "$statusfile" ]]; then
                cat "$statusfile"
            else
                [[ "${_state[$mod]}" == "done" ]] && print "done" || print "failed"
            fi
            ;;
        skipped)  print "dep failed" ;;
    esac
}

# Get elapsed time string for a module
engine::_get_elapsed() {
    local mod="$1"
    case "${_state[$mod]}" in
        running)
            printf '%.1fs' $(( EPOCHREALTIME - _start[$mod] ))
            ;;
        done|failed)
            [[ -n "${_elapsed[$mod]}" ]] && print "${_elapsed[$mod]}s"
            ;;
    esac
}

# Build summary counts string
engine::_summary() {
    local n_done=0 n_running=0 n_pending=0 n_failed=0 n_skipped=0
    local mod
    for mod in $_mod_order; do
        case "${_state[$mod]}" in
            done)    n_done=$(( n_done + 1 ))       ;;
            running) n_running=$(( n_running + 1 )) ;;
            pending) n_pending=$(( n_pending + 1 )) ;;
            failed)  n_failed=$(( n_failed + 1 ))   ;;
            skipped) n_skipped=$(( n_skipped + 1 )) ;;
        esac
    done

    local parts=()
    (( n_done    > 0 )) && parts+=("${n_done} done")
    (( n_running > 0 )) && parts+=("${n_running} running")
    (( n_pending > 0 )) && parts+=("${n_pending} waiting")
    (( n_failed  > 0 )) && parts+=("${n_failed} failed")
    (( n_skipped > 0 )) && parts+=("${n_skipped} skipped")

    print "${(j: · :)parts}"
}

# Render all module lines + footer (used in the frame redraw loop)
engine::_render() {
    ui::frame_begin

    local mod
    for mod in $_mod_order; do
        ui::frame_line "$(ui::module_line \
            "${_state[$mod]}" \
            "${_mod_desc[$mod]}" \
            "$(engine::_get_detail "$mod")" \
            "$(engine::_get_elapsed "$mod")")"
    done

    # Blank line before footer
    ui::frame_line ""

    # Footer box with summary
    local summary="$(engine::_summary)"
    local footer_color="$C_BLUE"
    # Turn red if anything failed
    local mod_check
    for mod_check in $_mod_order; do
        [[ "${_state[$mod_check]}" == "failed" ]] && footer_color="$C_RED" && break
    done

    local pad=$(( BOX_W - 2 - ${#summary} ))
    ui::frame_line "$(ui::hline "╭" "╮" "$footer_color")"
    ui::frame_line "$(printf '  %s│%s %s%*s %s│%s' \
        "$footer_color" "$C_RESET" "$summary" "$pad" "" "$footer_color" "$C_RESET")"
    ui::frame_line "$(ui::hline "╰" "╯" "$footer_color")"
}

# ── Public API ────────────────────────────────────────────────────────────────

engine::run_update() {
    PRIMER_TMPDIR=$(mktemp -d)
    trap "rm -rf '$PRIMER_TMPDIR'" EXIT

    # Reset state
    _state=()
    _pids=()
    _start=()
    _elapsed=()
    local mod
    for mod in $_mod_order; do
        _state[$mod]="pending"
    done

    # Header
    local title="primer update"
    local header_color="$C_BLUE"
    if [[ "$DRY_RUN" == true ]]; then
        title="primer update (dry run)"
        header_color="$C_CYAN"
    fi

    # Pre-authenticate sudo (needed by touchid module, skip in dry-run)
    if [[ "$DRY_RUN" != true ]]; then
        if ! sudo -n true 2>/dev/null; then
            if [[ -t 0 ]]; then
                print ""
                print "  ${C_DIM}Some steps need admin access.${C_RESET}"
                sudo -v || true
            elif [[ -e /dev/tty ]]; then
                print ""
                print "  ${C_DIM}Some steps need admin access.${C_RESET}"
                sudo -v </dev/tty 2>/dev/null || true
            fi
        fi
    fi
    print ""
    ui::box "$title" "$header_color"
    print ""

    # Hide cursor for clean animation
    printf '\e[?25l'
    trap "printf '\e[?25h'; rm -rf '$PRIMER_TMPDIR'" EXIT INT TERM

    # Initial render
    engine::_render

    # ── Ready-queue DAG loop ──────────────────────────────────────────────────
    while engine::_has_active; do
        engine::_poll_running
        engine::_start_ready "update"

        # Advance spinner
        SPIN_IDX=$(( (SPIN_IDX + 1) % ${#SPINNER[@]} ))

        engine::_render
        sleep 0.08
    done

    # Final render with cursor restored
    engine::_render
    printf '\e[?25h'
    # Clear the trap so cursor-show doesn't fire twice
    trap "rm -rf '$PRIMER_TMPDIR'" EXIT

    # Show error details for any failed modules
    local any_failed=false
    for mod in $_mod_order; do
        if [[ "${_state[$mod]}" == "failed" ]]; then
            any_failed=true
            local logfile="${PRIMER_TMPDIR}/${mod}.log"
            if [[ -f "$logfile" && -s "$logfile" ]]; then
                ui::error_box "${_mod_desc[$mod]}" "$logfile"
            fi
        fi
    done

    print ""

    $any_failed && return 1
    return 0
}

engine::run_status() {
    # Header
    print ""
    ui::box "primer status" "$C_CYAN"
    print ""

    local n_ok=0 n_issues=0
    local mod rc detail state statusfile

    for mod in $_mod_order; do
        statusfile=$(mktemp)
        local mod_dir="${PRIMER_DIR}/modules/${mod}"

        # Run mod_status in a subshell (sequential, no parallelism needed)
        rc=0
        (
            export MOD_STATUS_FILE="$statusfile"
            export MOD_DIR="$mod_dir"
            export MOD_NAME="$mod"
            source "${PRIMER_DIR}/lib/ui.zsh"
            source "${mod_dir}/module.zsh" 2>/dev/null || exit 1
            mod_status
        ) &>/dev/null || rc=$?

        detail=""
        [[ -f "$statusfile" ]] && detail="$(cat "$statusfile")"
        [[ -z "$detail" ]] && detail=$( (( rc == 0 )) && echo "ok" || echo "not found" )
        rm -f "$statusfile"

        if (( rc == 0 )); then
            state="done"
            n_ok=$(( n_ok + 1 ))
        else
            state="failed"
            n_issues=$(( n_issues + 1 ))
        fi

        print "$(ui::module_line "$state" "${_mod_desc[$mod]}" "$detail" "")"
    done

    # Footer
    print ""
    local parts=()
    (( n_ok     > 0 )) && parts+=("${n_ok} healthy")
    (( n_issues > 0 )) && parts+=("${n_issues} issues")
    local summary="${(j: · :)parts}"

    local color="$C_CYAN"
    (( n_issues > 0 )) && color="$C_RED"
    ui::box "$summary" "$color"
    print ""

    (( n_issues > 0 )) && return 1
    return 0
}
