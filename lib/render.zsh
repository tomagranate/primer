#!/bin/zsh
# lib/render.zsh -- Frame rendering, TUI drawing, and run reports

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
        interrupted) print "interrupted" ;;
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
        done|failed|interrupted)
            [[ -n "${_elapsed[$mod]}" ]] && print "${_elapsed[$mod]}s"
            ;;
    esac
}

# Build summary counts string
engine::_summary() {
    local n_done=0 n_running=0 n_pending=0 n_failed=0 n_skipped=0 n_interrupted=0
    local mod
    for mod in $_mod_order; do
        case "${_state[$mod]}" in
            done)    n_done=$(( n_done + 1 ))       ;;
            running) n_running=$(( n_running + 1 )) ;;
            pending) n_pending=$(( n_pending + 1 )) ;;
            failed)  n_failed=$(( n_failed + 1 ))   ;;
            skipped) n_skipped=$(( n_skipped + 1 )) ;;
            interrupted) n_interrupted=$(( n_interrupted + 1 )) ;;
        esac
    done

    local parts=()
    (( n_done    > 0 )) && parts+=("${n_done} done")
    (( n_running > 0 )) && parts+=("${n_running} running")
    (( n_pending > 0 )) && parts+=("${n_pending} waiting")
    (( n_failed  > 0 )) && parts+=("${n_failed} failed")
    (( n_interrupted > 0 )) && parts+=("${n_interrupted} interrupted")
    (( n_skipped > 0 )) && parts+=("${n_skipped} skipped")

    print "${(j: · :)parts}"
}

# Render all module lines + footer (used in the frame redraw loop)
engine::_render() {
    ui::frame_begin

    local active_item_budget
    active_item_budget="$(engine::_active_item_budget)"
    local remaining_item_budget="$active_item_budget"

    local mod
    for mod in $_mod_order; do
        ui::frame_line "$(ui::module_line \
            "${_state[$mod]}" \
            "${_mod_desc[$mod]}" \
            "$(engine::_get_detail "$mod")" \
            "$(engine::_get_elapsed "$mod")")"

        # Running modules show their active checklist inline. Completed modules
        # collapse during the live run, then the final render expands all
        # resolved sub-items for review.
        if [[ "${_state[$mod]}" == "running" || "$ENGINE_RENDER_FINAL" == true ]]; then
            local items_file="${PRIMER_TMPDIR}/${mod}.items"
            if [[ -f "$items_file" ]]; then
                local item_budget="$active_item_budget"
                if [[ "$ENGINE_RENDER_FINAL" != true && $UI_LIVE_FRAME == true ]]; then
                    item_budget="$remaining_item_budget"
                fi
                engine::_render_module_items "$items_file" "${_state[$mod]}" "$item_budget"
                if [[ "$ENGINE_RENDER_FINAL" != true && $UI_LIVE_FRAME == true ]]; then
                    remaining_item_budget=$(( remaining_item_budget - ENGINE_RENDERED_ITEM_LINES ))
                    (( remaining_item_budget < 0 )) && remaining_item_budget=0
                fi
            fi
        fi
    done

    # Blank line before footer
    ui::frame_line ""

    # Footer box with summary
    local summary="$(engine::_summary)"
    local footer_color="$C_BLUE"
    # Turn red if anything failed
    local mod_check
    for mod_check in $_mod_order; do
        [[ "${_state[$mod_check]}" == "failed" || "${_state[$mod_check]}" == "interrupted" ]] && footer_color="$C_RED" && break
    done

    local pad=$(( BOX_W - 2 - ${#summary} ))
    ui::frame_line "$(ui::hline "╭" "╮" "$footer_color")"
    ui::frame_line "$(printf '  %s│%s %s%*s %s│%s' \
        "$footer_color" "$C_RESET" "$summary" "$pad" "" "$footer_color" "$C_RESET")"
    ui::frame_line "$(ui::hline "╰" "╯" "$footer_color")"

    ui::frame_end
}

engine::_active_item_budget() {
    if [[ "$ENGINE_RENDER_FINAL" == true ]]; then
        print 9999
        return 0
    fi
    if [[ "$UI_LIVE_FRAME" != true ]]; then
        print 9999
        return 0
    fi
    if [[ "$PRIMER_RENDER_TTY" != true && "${PRIMER_TEST_TTY:-}" != true ]]; then
        print 9999
        return 0
    fi

    local terminal_rows="${LINES:-}"
    if [[ -z "$terminal_rows" || "$terminal_rows" != <-> ]]; then
        terminal_rows="$(tput lines 2>/dev/null)"
    fi
    [[ -z "$terminal_rows" || "$terminal_rows" != <-> ]] && terminal_rows=40

    # Header above the frame is 5 lines. Frame fixed cost is all module rows
    # plus blank line and 3 footer rows. Leave one spare line to avoid scrolling.
    local fixed_rows=$(( 5 + ${#_mod_order[@]} + 1 + 3 + 1 ))
    local budget=$(( terminal_rows - fixed_rows ))
    (( budget < 0 )) && budget=0
    print "$budget"
}

# Build the sub-item lines of one module. Both renderers share this builder.
# Each line of the items file is "state<TAB>name<TAB>detail"; lib/ui.zsh writes
# it. Sort the items by state, then clip them to the budget. The last line
# shows the overflow count when the items do not fit. Results go to
# ENGINE_ITEM_LINES.
engine::_build_module_item_lines() {
    local items_file="$1" mod_state="$2" budget="$3"
    local -a running_lines=() failed_lines=() skipped_lines=() pending_lines=() done_lines=() other_lines=() lines=()
    local item_state item_name item_detail rendered_line i visible_rows remaining

    ENGINE_ITEM_LINES=()
    (( budget <= 0 )) && return 0

    while IFS=$'\t' read -r item_state item_name item_detail; do
        [[ -z "$item_name" ]] && continue
        if [[ "$mod_state" != "running" ]]; then
            [[ "$item_state" == "pending" ]] && continue
        fi
        rendered_line="$(ui::sub_item_line "$item_state" "$item_name" "$item_detail")"
        case "$item_state" in
            running) running_lines+=("$rendered_line") ;;
            failed)  failed_lines+=("$rendered_line") ;;
            skipped) skipped_lines+=("$rendered_line") ;;
            pending) pending_lines+=("$rendered_line") ;;
            done)    done_lines+=("$rendered_line") ;;
            *)       other_lines+=("$rendered_line") ;;
        esac
    done < "$items_file"
    lines=("${running_lines[@]}" "${failed_lines[@]}" "${skipped_lines[@]}" "${pending_lines[@]}" "${done_lines[@]}" "${other_lines[@]}")
    (( ${#lines[@]} == 0 )) && return 0

    visible_rows=$budget
    (( visible_rows > ${#lines[@]} )) && visible_rows=${#lines[@]}
    for (( i = 1; i <= visible_rows; i++ )); do
        if (( i == visible_rows && ${#lines[@]} > visible_rows )); then
            remaining=$(( ${#lines[@]} - visible_rows + 1 ))
            ENGINE_ITEM_LINES+=("$(printf '   %s... %d more%s' "$C_DIM" "$remaining" "$C_RESET")")
        else
            ENGINE_ITEM_LINES+=("${lines[$i]}")
        fi
    done
    return 0
}

# Emit the sub-item lines into the scrolling frame.
engine::_render_module_items() {
    engine::_build_module_item_lines "$1" "$2" "$3"

    ENGINE_RENDERED_ITEM_LINES=0
    local rendered_line
    for rendered_line in "${ENGINE_ITEM_LINES[@]}"; do
        ui::frame_line "$rendered_line"
        ENGINE_RENDERED_ITEM_LINES=$(( ENGINE_RENDERED_ITEM_LINES + 1 ))
    done
    return 0
}

# ── Terminal Helpers ──────────────────────────────────────────────────────────

engine::_terminal_rows() {
    local rows="${LINES:-}"
    if [[ -z "$rows" || "$rows" != <-> ]]; then
        rows="$(tput lines 2>/dev/null)"
    fi
    [[ -z "$rows" || "$rows" != <-> ]] && rows=24
    (( rows < 8 )) && rows=8
    print "$rows"
}

engine::_terminal_cols() {
    local cols="${COLUMNS:-}"
    if [[ -z "$cols" || "$cols" != <-> ]]; then
        cols="$(tput cols 2>/dev/null)"
    fi
    [[ -z "$cols" || "$cols" != <-> ]] && cols=80
    (( cols < 40 )) && cols=40
    print "$cols"
}

engine::_plain_fit() {
    local text="$1" width="$2"
    (( width < 1 )) && return 0
    if (( ${#text} > width )); then
        if (( width > 1 )); then
            text="${text[1,$(( width - 1 ))]}…"
        else
            text="${text[1,1]}"
        fi
    fi
    printf "%-${width}s" "$text"
}

engine::_repeat_char() {
    local char="$1" count="$2"
    (( count <= 0 )) && return 0
    local padding
    padding="$(printf '%*s' "$count" '')"
    print -n -- "${padding// /$char}"
}

engine::_tui_line() {
    local row="$1" text="${2:-}"
    printf '\e[%d;1H\e[2K%s' "$row" "$text"
}

# ── Progress and Alternate Screen ─────────────────────────────────────────────

engine::_progress_counts() {
    local n_done=0 n_failed=0 n_skipped=0 n_interrupted=0 n_running=0 n_pending=0 mod
    for mod in $_mod_order; do
        case "${_state[$mod]}" in
            done) n_done=$(( n_done + 1 )) ;;
            failed) n_failed=$(( n_failed + 1 )) ;;
            skipped) n_skipped=$(( n_skipped + 1 )) ;;
            interrupted) n_interrupted=$(( n_interrupted + 1 )) ;;
            running) n_running=$(( n_running + 1 )) ;;
            pending) n_pending=$(( n_pending + 1 )) ;;
        esac
    done
    print "$n_done:$n_failed:$n_skipped:$n_interrupted:$n_running:$n_pending"
}

engine::_progress_bar() {
    local width="$1" counts="$2"
    local n_done n_failed n_skipped n_interrupted n_running n_pending
    IFS=: read -r n_done n_failed n_skipped n_interrupted n_running n_pending <<< "$counts"
    local total=${#_mod_order[@]}
    local complete=$(( n_done + n_failed + n_skipped + n_interrupted ))
    local bar_width=$(( width - 22 ))
    (( bar_width < 8 )) && bar_width=8
    (( bar_width > 36 )) && bar_width=36
    local filled=0
    (( total > 0 )) && filled=$(( complete * bar_width / total ))
    (( filled > bar_width )) && filled=$bar_width
    local empty=$(( bar_width - filled ))
    local bar
    bar="$(engine::_repeat_char "#" "$filled")$(engine::_repeat_char " " "$empty")"
    printf '[%s] %d/%d modules' "$bar" "$complete" "$total"
}

# Print the sub-item lines for the alternate-screen compositor.
engine::_module_item_lines_for_tui() {
    engine::_build_module_item_lines "$1" "$2" "$3"

    (( ${#ENGINE_ITEM_LINES[@]} == 0 )) && return 0
    printf '%s\n' "${ENGINE_ITEM_LINES[@]}"
    return 0
}

engine::_render_update_tui() {
    local rows cols
    rows="$(engine::_terminal_rows)"
    cols="$(engine::_terminal_cols)"
    COLUMNS="$cols"
    ui::refresh_layout

    local elapsed=0
    (( ENGINE_UPDATE_STARTED_AT > 0 )) && elapsed=$(( EPOCHREALTIME - ENGINE_UPDATE_STARTED_AT ))
    local counts summary header progress footer
    counts="$(engine::_progress_counts)"
    summary="$(engine::_summary)"
    header="$(printf '%s  %s  %.1fs' "${ENGINE_REPORT_TITLE:-primer update}" "$summary" "$elapsed")"
    progress="$(engine::_progress_bar "$cols" "$counts")"
    footer="$(printf '%s | Ctrl-C to stop' "$progress")"

    printf '\e[H'
    engine::_tui_line 1 "$C_BOLD_CYAN$(engine::_plain_fit "$header" "$cols")$C_RESET"
    local divider
    divider="$(engine::_repeat_char "-" "$cols")"
    engine::_tui_line 2 "$C_DIM$divider$C_RESET"

    local content_start=3 footer_start=$(( rows - 1 ))
    local content_rows=$(( footer_start - content_start ))
    (( content_rows < 1 )) && content_rows=1

    local -a lines=()
    local mod items_file item_budget remaining_item_budget
    local base_rows=${#_mod_order[@]}
    item_budget=$(( content_rows - base_rows ))
    (( item_budget < 0 )) && item_budget=0
    remaining_item_budget=$item_budget

    for mod in $_mod_order; do
        lines+=("$(ui::module_line "${_state[$mod]}" "${_mod_desc[$mod]}" "$(engine::_get_detail "$mod")" "$(engine::_get_elapsed "$mod")")")
        if [[ "${_state[$mod]}" == "running" && $remaining_item_budget -gt 0 ]]; then
            items_file="${PRIMER_TMPDIR}/${mod}.items"
            if [[ -f "$items_file" ]]; then
                local -a item_lines=()
                item_lines=("${(@f)$(engine::_module_item_lines_for_tui "$items_file" "${_state[$mod]}" "$remaining_item_budget")}")
                if (( ${#item_lines[@]} > 0 )); then
                    lines+=("${item_lines[@]}")
                    remaining_item_budget=$(( remaining_item_budget - ${#item_lines[@]} ))
                    (( remaining_item_budget < 0 )) && remaining_item_budget=0
                fi
            fi
        fi
    done

    local row idx overflow
    for (( row = content_start; row < footer_start; row++ )); do
        idx=$(( row - content_start + 1 ))
        if (( idx <= ${#lines[@]} )); then
            if (( row == footer_start - 1 && ${#lines[@]} > content_rows )); then
                overflow=$(( ${#lines[@]} - content_rows + 1 ))
                engine::_tui_line "$row" "   ${C_DIM}... ${overflow} more${C_RESET}"
            else
                engine::_tui_line "$row" "${lines[$idx]}"
            fi
        else
            engine::_tui_line "$row" ""
        fi
    done

    engine::_tui_line "$footer_start" "$C_DIM$divider$C_RESET"
    engine::_tui_line "$rows" "$C_BOLD$(engine::_plain_fit "$footer" "$cols")$C_RESET"
}

engine::_select_update_mode() {
    case "${PRIMER_UI_MODE:-}" in
        alternate)
            if [[ -t 1 ]]; then
                PRIMER_UPDATE_MODE="alternate"
            else
                print -- "--tui requires stdout to be a terminal." >&2
                return 1
            fi
            ;;
        log)
            PRIMER_UPDATE_MODE="log"
            ;;
        ""|auto)
            if [[ -t 1 ]]; then
                PRIMER_UPDATE_MODE="alternate"
            else
                PRIMER_UPDATE_MODE="log"
            fi
            ;;
        *)
            print -- "Unknown UI mode: ${PRIMER_UI_MODE}" >&2
            return 1
            ;;
    esac
}

engine::_begin_alternate_ui() {
    PRIMER_ALT_SCREEN_ACTIVE=true
    UI_LIVE_FRAME=true
    PRIMER_RENDER_TTY=true
    UI_REPAINT_MODE="tui"
    ENGINE_RENDER_FINAL=false
    printf '%b' '\033[?1049h\033[?25l\033[2J'
    engine::_render_update_tui
}

engine::_finish_terminal_ui() {
    if [[ "$PRIMER_ALT_SCREEN_ACTIVE" == true ]]; then
        printf '%b' '\033[?25h\033[?1049l'
        PRIMER_ALT_SCREEN_ACTIVE=false
    elif [[ "$UI_LIVE_FRAME" == true ]]; then
        printf '%b' '\033[?25h'
    fi
    UI_LIVE_FRAME=false
    PRIMER_RENDER_TTY=false
    UI_REPAINT_MODE="cursor"
    _frame_active=false
    _frame_lines=0
    _prev_frame_lines=0
}

# ── Log Streaming ─────────────────────────────────────────────────────────────

engine::_stream_log_delta() {
    local mod="$1"
    local logfile="${PRIMER_TMPDIR}/${mod}.log"
    [[ -f "$logfile" ]] || return 0

    local size offset delta
    size="$(wc -c < "$logfile" | tr -d ' ')"
    [[ "$size" == <-> ]] || return 0
    offset="${_log_offsets[$mod]:-0}"
    [[ "$offset" == <-> ]] || offset=0
    (( size <= offset )) && return 0

    delta=$(( size - offset ))
    # Emit the bytes in [offset, size). "tail -c +N" is POSIX and works on both
    # macOS and Linux, unlike the GNU-only iflag options of dd.
    tail -c "+$(( offset + 1 ))" "$logfile" 2>/dev/null | head -c "$delta" 2>/dev/null
    _log_offsets[$mod]="$size"
}

engine::_stream_all_log_deltas() {
    local mod
    for mod in $_mod_order; do
        [[ "${_state[$mod]}" == "running" || "${_state[$mod]}" == "done" || "${_state[$mod]}" == "failed" || "${_state[$mod]}" == "interrupted" ]] || continue
        engine::_stream_log_delta "$mod"
    done
}

# ── Run Report ────────────────────────────────────────────────────────────────

engine::_print_update_report() {
    [[ "$ENGINE_REPORTED" == true ]] && return 0
    ENGINE_REPORTED=true

    engine::_finish_terminal_ui
    ENGINE_RENDER_FINAL=true
    UI_LIVE_FRAME=false
    PRIMER_RENDER_TTY=false
    if [[ -n "$ENGINE_REPORT_TITLE" ]]; then
        print ""
        ui::box "$ENGINE_REPORT_TITLE" "$ENGINE_REPORT_COLOR"
        print ""
    fi
    engine::_render

    local mod
    for mod in $_mod_order; do
        if [[ "${_state[$mod]}" == "failed" ]]; then
            local logfile="${PRIMER_TMPDIR}/${mod}.log"
            if [[ -f "$logfile" && -s "$logfile" ]]; then
                ui::error_box "${_mod_desc[$mod]}" "$logfile"
            fi
        fi
    done

    print ""
}
