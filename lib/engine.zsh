#!/bin/zsh
# lib/engine.zsh -- Ready-queue DAG engine with parallel execution
#
# This file is a facade. It loads the engine parts, then defines the two
# public entry points.

typeset -g _ENGINE_LIB_DIR="${${(%):-%N}:A:h}"
[[ -f "${_ENGINE_LIB_DIR}/config.zsh" ]] || _ENGINE_LIB_DIR="${PRIMER_DIR:-}/lib"

source "${_ENGINE_LIB_DIR}/config.zsh"
source "${_ENGINE_LIB_DIR}/dag.zsh"
source "${_ENGINE_LIB_DIR}/logins.zsh"
source "${_ENGINE_LIB_DIR}/render.zsh"

unset _ENGINE_LIB_DIR

# ── Public API ────────────────────────────────────────────────────────────────

engine::run_update() {
    PRIMER_TMPDIR=$(mktemp -d)
    trap 'engine::_cleanup_update' EXIT
    trap 'engine::_handle_interrupt' INT TERM

    # Reset state
    _state=()
    _pids=()
    _start=()
    _elapsed=()
    _log_offsets=()
    ENGINE_INTERRUPTED=false
    ENGINE_REPORTED=false
    ENGINE_UPDATE_STARTED=false
    ENGINE_UPDATE_STARTED_AT=$EPOCHREALTIME
    PRIMER_ALT_SCREEN_ACTIVE=false
    local mod
    for mod in $_mod_order; do
        _state[$mod]="pending"
    done

    # Apply --skip / --only filters
    engine::_apply_filters

    # Header
    local title="primer update"
    local header_color="$C_BLUE"
    if [[ "$DRY_RUN" == true ]]; then
        title="primer update (dry run)"
        header_color="$C_CYAN"
    fi
    ENGINE_REPORT_TITLE="$title"
    ENGINE_REPORT_COLOR="$header_color"

    # Pre-authenticate sudo before modules run in backgrounded subprocesses.
    if [[ "$DRY_RUN" != true ]] && engine::_needs_sudo; then
        print ""
        print "  ${C_DIM}Some steps need admin access.${C_RESET}"
        primer::sudo_validate "Primer setup" || return 1
    fi

    engine::_select_update_mode || return 1
    ENGINE_UPDATE_STARTED=true
    if [[ "$PRIMER_UPDATE_MODE" == "alternate" ]]; then
        engine::_begin_alternate_ui
    else
        UI_LIVE_FRAME=false
        PRIMER_RENDER_TTY=false
        UI_REPAINT_MODE="cursor"
        print ""
        ui::box "$title" "$header_color"
        print ""
        print -- "Streaming setup logs..."
    fi

    # ── Ready-queue DAG loop (modules + mid-run login gates) ──────────────────
    local login_failed=false
    local login_rc=0
    while engine::_has_active; do
        engine::_poll_running
        if [[ "$PRIMER_UPDATE_MODE" == "log" ]]; then
            engine::_stream_all_log_deltas
        fi
        engine::_start_ready "update"

        # When install work is idle, run logins that pending modules need.
        if [[ "$ENGINE_INTERRUPTED" != true ]] && ! engine::_any_running; then
            if engine::_runnable_logins_needed_by_pending >/dev/null; then
                trap - INT TERM
                login_rc=0
                engine::_run_gate_logins || login_rc=$?
                trap 'engine::_handle_interrupt' INT TERM
                if (( login_rc == 130 )); then
                    engine::_mark_interrupted
                    break
                fi
                (( login_rc != 0 )) && login_failed=true
                engine::_start_ready "update"
            fi
        fi

        # Advance spinner
        SPIN_IDX=$(( (SPIN_IDX + 1) % ${#SPINNER[@]} ))

        [[ "$PRIMER_UPDATE_MODE" == "alternate" ]] && engine::_render_update_tui
        [[ "$ENGINE_INTERRUPTED" == true ]] && break
        sleep 0.08
    done

    if [[ "$PRIMER_UPDATE_MODE" == "log" ]]; then
        engine::_stream_all_log_deltas
    fi

    local any_failed=false
    local any_interrupted=false
    for mod in $_mod_order; do
        [[ "${_state[$mod]}" == "failed" ]] && any_failed=true
        [[ "${_state[$mod]}" == "interrupted" ]] && any_interrupted=true
    done

    # Optional logins that no module required (or were not resolved mid-run).
    if [[ "$any_interrupted" != true ]]; then
        trap - INT TERM
        _login_phase="final"
        engine::_reset_login_order_to_pending
        engine::_select_interactive_logins || return $?
        engine::_run_interactive_logins || login_failed=true
    fi

    engine::_print_update_report
    engine::_render_login_summary
    engine::_render_login_error_output

    trap - INT TERM
    trap 'rm -rf "$PRIMER_TMPDIR"' EXIT
    $any_interrupted && return 130
    $any_failed && return 1
    $login_failed && return 1
    return 0
}

engine::run_status() {
    # Header
    print ""
    ui::box "primer status" "$C_CYAN"
    print ""

    local mod rc detail state statusfile rcfile mod_dir pid
    local elapsed
    local -A _status_files=()
    local -A _rc_files=()
    local -A _status_pids=()
    local -A _status_states=()
    local -A _status_details=()
    local -A _status_start=()
    local -A _status_elapsed=()

    # Launch all mod_status checks in parallel.
    for mod in $_mod_order; do
        statusfile=$(mktemp)
        rcfile=$(mktemp)
        mod_dir="${PRIMER_DIR}/modules/${mod}"
        _status_files[$mod]="$statusfile"
        _rc_files[$mod]="$rcfile"
        _status_states[$mod]="running"
        _status_details[$mod]="checking..."
        _status_start[$mod]=$EPOCHREALTIME

        (
            local local_rc=0
            export MOD_STATUS_FILE="$statusfile"
            export MOD_DIR="$mod_dir"
            export MOD_NAME="$mod"
            source "${PRIMER_DIR}/lib/ui.zsh"
            source "${mod_dir}/module.zsh" 2>/dev/null || local_rc=1
            if (( local_rc == 0 )); then
                mod_status || local_rc=$?
            fi
            # Write the rc file atomically, and only after mod_status has
            # written its status text. A non-empty rc file therefore proves the
            # status text is complete too, so the reader needs no retry.
            print -n "$local_rc" > "${rcfile}.tmp"
            mv -f "${rcfile}.tmp" "$rcfile"
            exit "$local_rc"
        ) &>/dev/null &

        _status_pids[$mod]=$!
    done

    # Render live status rows while checks run when attached to a terminal.
    local live_ui=false
    [[ -t 1 ]] && live_ui=true
    UI_LIVE_FRAME="$live_ui"
    if $live_ui; then
        printf '%b' '\033[?25l'
        trap "printf '%b' '\033[?25h'" INT TERM
    fi
    while true; do
        # Poll running checks first so each frame shows the latest states/results.
        for mod in $_mod_order; do
            [[ "${_status_states[$mod]}" != "running" ]] && continue
            pid="${_status_pids[$mod]}"
            rcfile="${_rc_files[$mod]}"
            if [[ -s "$rcfile" ]]; then
                wait "$pid" 2>/dev/null || true
                statusfile="${_status_files[$mod]}"

                rc="$(cat "$rcfile")"
                detail=""
                [[ -f "$statusfile" ]] && detail="$(cat "$statusfile")"
                [[ -z "$detail" ]] && detail=$( (( rc == 0 )) && echo "up to date" || echo "not found" )
                _status_details[$mod]="$detail"
                _status_states[$mod]=$( (( rc == 0 )) && echo "done" || echo "failed" )
                _status_elapsed[$mod]=$(printf '%.1f' $(( EPOCHREALTIME - _status_start[$mod] )))

                rm -f "$statusfile" "$rcfile"
            else
                # Show any in-flight status text written by the module.
                statusfile="${_status_files[$mod]}"
                if [[ -f "$statusfile" ]]; then
                    detail="$(cat "$statusfile")"
                    [[ -n "$detail" ]] && _status_details[$mod]="$detail"
                fi
            fi
        done

        local n_ok=0 n_issues=0 n_running=0
        for mod in $_mod_order; do
            case "${_status_states[$mod]}" in
                running) n_running=$(( n_running + 1 )) ;;
                done)    n_ok=$(( n_ok + 1 )) ;;
                failed)  n_issues=$(( n_issues + 1 )) ;;
            esac
        done

        if $live_ui || (( n_running == 0 )); then
            SPIN_IDX=$(( (SPIN_IDX + 1) % ${#SPINNER[@]} ))

            ui::frame_begin
            for mod in $_mod_order; do
                state="${_status_states[$mod]}"
                elapsed=""
                case "$state" in
                    running)
                        elapsed=$(printf '%.1fs' $(( EPOCHREALTIME - _status_start[$mod] )))
                        ;;
                    done|failed)
                        [[ -n "${_status_elapsed[$mod]}" ]] && elapsed="${_status_elapsed[$mod]}s"
                        ;;
                esac
                ui::frame_line "$(ui::module_line "$state" "${_mod_desc[$mod]}" "${_status_details[$mod]}" "$elapsed")"
            done

            ui::frame_line ""
            local parts=()
            local issue_label="issues"
            local checking_label="checking"
            (( n_issues == 1 )) && issue_label="issue"
            (( n_running == 1 )) && checking_label="checking"
            (( n_ok > 0 )) && parts+=("${n_ok} healthy")
            (( n_issues > 0 )) && parts+=("${n_issues} ${issue_label}")
            (( n_running > 0 )) && parts+=("${n_running} ${checking_label}")
            local summary="${(j: · :)parts}"
            local footer_color="$C_CYAN"
            (( n_issues > 0 )) && footer_color="$C_RED"
            local pad=$(( BOX_W - 2 - ${#summary} ))
            ui::frame_line "$(ui::hline "╭" "╮" "$footer_color")"
            ui::frame_line "$(printf '  %s│%s %s%*s %s│%s' \
                "$footer_color" "$C_RESET" "$summary" "$pad" "" "$footer_color" "$C_RESET")"
            ui::frame_line "$(ui::hline "╰" "╯" "$footer_color")"
            ui::frame_end
        fi

        (( n_running == 0 )) && break
        sleep 0.08
    done

    $live_ui && printf '%b' '\033[?25h'
    trap - INT TERM
    print ""

    local n_ok=0 n_issues=0
    for mod in $_mod_order; do
        [[ "${_status_states[$mod]}" == "done" ]] && n_ok=$(( n_ok + 1 ))
        [[ "${_status_states[$mod]}" == "failed" ]] && n_issues=$(( n_issues + 1 ))
    done
    (( n_issues > 0 )) && return 1
    return 0
}
