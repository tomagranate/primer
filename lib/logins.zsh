#!/bin/zsh
# lib/logins.zsh -- Interactive login gates, pickers, and reporting

# ── Login Gates ───────────────────────────────────────────────────────────────

# Can this login run now (its module deps are done)?
engine::_login_module_deps_met() {
    local name="$1"
    local depends_on="${_mod_config[logins.${name}_depends_on]:-}"
    [[ -z "$depends_on" ]] && return 0
    local missing
    missing="$(engine::_missing_login_module_deps "$depends_on")"
    [[ -z "$missing" ]]
}

# Logins still pending that block pending modules and can run now.
engine::_runnable_logins_needed_by_pending() {
    local mod dep name
    local -A needed_set=()
    local -a needed=()

    for mod in $_mod_order; do
        [[ "${_state[$mod]}" == "pending" ]] || continue
        engine::_module_deps_met "$mod" || continue
        engine::_login_deps_failed "$mod" && continue
        engine::_login_deps_met "$mod" && continue

        local deps="${_mod_login_deps[$mod]}"
        [[ -z "$deps" ]] && continue
        for dep in ${(s:,:)deps}; do
            [[ "${_login_state[$dep]:-}" == "pending" ]] || continue
            engine::_login_module_deps_met "$dep" || continue
            needed_set[$dep]=true
        done
    done

    for name in $_login_all_order; do
        [[ "${needed_set[$name]:-}" == true ]] && needed+=("$name")
    done

    (( ${#needed[@]} > 0 )) || return 1
    print -l -- "${needed[@]}"
    return 0
}

# Rebuild _login_order to unresolved logins for a later pass.
engine::_reset_login_order_to_pending() {
    _login_order=()
    local name
    for name in $_login_all_order; do
        [[ "${_login_state[$name]:-}" == "pending" ]] && _login_order+=("$name")
    done
}

# Run logins that gate pending modules, then restore remaining optional logins.
engine::_run_gate_logins() {
    local -a needed=()
    local line
    while IFS= read -r line; do
        [[ -n "$line" ]] && needed+=("$line")
    done < <(engine::_runnable_logins_needed_by_pending)
    (( ${#needed[@]} == 0 )) && return 0

    _login_phase="gate"
    _login_order=("${needed[@]}")

    engine::_select_interactive_logins || {
        local rc=$?
        _login_phase="final"
        engine::_reset_login_order_to_pending
        return $rc
    }
    engine::_run_interactive_logins || {
        local rc=$?
        _login_phase="final"
        engine::_reset_login_order_to_pending
        return $rc
    }

    _login_phase="final"
    engine::_reset_login_order_to_pending
    return 0
}

# ── Interactive Login Selection ──────────────────────────────────────────────

engine::_login_toggle() {
    local name="$1"
    if [[ "${_login_selected[$name]:-false}" == true ]]; then
        _login_selected[$name]="false"
    else
        _login_selected[$name]="true"
    fi
}

engine::_missing_login_requirements() {
    local requires="$1"
    local req_words requirement
    local -a missing=()

    req_words="${requires//,/ }"
    for requirement in ${(z)req_words}; do
        [[ -z "$requirement" ]] && continue
        command -v "$requirement" >/dev/null 2>&1 || missing+=("$requirement")
    done

    print "${(j:, :)missing}"
    (( ${#missing[@]} == 0 ))
}

engine::_missing_login_module_deps() {
    local deps="$1"
    local dep_words dep
    local -a missing=()

    dep_words="${deps//,/ }"
    for dep in ${(z)dep_words}; do
        [[ -z "$dep" ]] && continue
        [[ "${_state[$dep]:-}" == "done" ]] || missing+=("$dep")
    done

    print "${(j:, :)missing}"
    (( ${#missing[@]} == 0 ))
}

engine::_login_already_done() {
    local status_cmd="$1"
    [[ -z "$status_cmd" ]] && return 1
    zsh -c "$status_cmd" >/dev/null 2>&1
}

# Build one picker row for each login. Both pickers share this builder.
# The row under the cursor gets a pointer and a bright color. Results go to
# ENGINE_LOGIN_PICKER_LINES.
engine::_build_login_picker_lines() {
    local cursor="$1"
    local name label marker pointer color i

    ENGINE_LOGIN_PICKER_LINES=()
    for (( i = 1; i <= ${#_login_order[@]}; i++ )); do
        name="${_login_order[$i]}"
        label="${_mod_config[logins.${name}_label]:-$name}"
        marker=$([[ "${_login_selected[$name]:-false}" == true ]] && print "●" || print "○")
        if (( i == cursor )); then
            pointer="›"
            color="$C_CYAN"
        else
            pointer=" "
            color="$C_DIM"
        fi
        ENGINE_LOGIN_PICKER_LINES+=("  ${color}${pointer}${C_RESET}  ${color}${marker}${C_RESET}  ${label}")
    done
    return 0
}

# Print the picker for the inline scrolling frame.
engine::_render_login_picker() {
    local cursor="$1"

    print "  ${C_DIM}Use Up/Down to move. Space toggles a login. Enter starts selected logins.${C_RESET}"
    print ""

    engine::_build_login_picker_lines "$cursor"
    (( ${#ENGINE_LOGIN_PICKER_LINES[@]} > 0 )) && print -rl -- "${ENGINE_LOGIN_PICKER_LINES[@]}"
    return 0
}

engine::_login_notice() {
    local line="$1" mode="${2:-normal}"
    if [[ "$mode" == "tui" ]]; then
        _login_notice_lines+=("$line")
    else
        print "$line"
    fi
}

engine::_prime_login_selection() {
    local mode="${1:-normal}"
    local name label default default_bool depends_on missing_deps requires missing_reqs status_cmd done_detail
    local -a eligible=()

    _login_selected=()
    _login_notice_lines=()

    if [[ "$mode" != "tui" ]]; then
        print ""
        ui::box "login setup" "$C_CYAN"
        print ""
        if [[ "${_login_phase:-final}" == "gate" ]]; then
            print "  ${C_DIM}Some install steps need account access. Choose accounts to authenticate now.${C_RESET}"
        else
            print "  ${C_DIM}Installation is complete. Choose the accounts to authenticate now.${C_RESET}"
        fi
    fi

    for name in $_login_order; do
        label="${_mod_config[logins.${name}_label]:-$name}"
        depends_on="${_mod_config[logins.${name}_depends_on]:-}"
        requires="${_mod_config[logins.${name}_requires]:-}"
        status_cmd="${_mod_config[logins.${name}_status]:-}"

        missing_deps=""
        if [[ -n "$depends_on" ]]; then
            missing_deps="$(engine::_missing_login_module_deps "$depends_on")"
        fi
        if [[ -n "$missing_deps" ]]; then
            engine::_login_notice "  ${C_YELLOW}${GLYPH_SKIP}${C_RESET}  $label unavailable (waiting on: $missing_deps)" "$mode"
            _login_state[$name]="skipped"
            _login_detail[$name]="waiting on: $missing_deps"
            continue
        fi

        missing_reqs=""
        if [[ -n "$requires" ]]; then
            missing_reqs="$(engine::_missing_login_requirements "$requires")"
        fi
        if [[ -n "$missing_reqs" ]]; then
            engine::_login_notice "  ${C_YELLOW}${GLYPH_SKIP}${C_RESET}  $label unavailable (missing: $missing_reqs)" "$mode"
            _login_state[$name]="skipped"
            _login_detail[$name]="missing: $missing_reqs"
            continue
        fi

        if engine::_login_already_done "$status_cmd"; then
            done_detail="${_mod_config[logins.${name}_done_detail]:-logged in}"
            engine::_login_notice "  ${C_GREEN}${GLYPH_OK}${C_RESET}  $label already $done_detail" "$mode"
            _login_state[$name]="done"
            _login_detail[$name]="$done_detail"
            continue
        fi

        default="${_mod_config[logins.${name}_default]:-yes}"
        default_bool="$(engine::_bool_default "$default")"
        _login_selected[$name]="$default_bool"
        _login_state[$name]="pending"
        _login_detail[$name]="selected"
        eligible+=("$name")
    done

    _login_order=("${eligible[@]}")
    (( ${#_login_order[@]} > 0 ))
}

engine::_draw_login_picker() {
    local cursor="$1" output="$2" move_up="${3:-0}"
    local rendered_line

    if (( move_up > 0 )); then
        printf '\e[%dA' "$move_up" > "$output"
    fi
    while IFS= read -r rendered_line; do
        printf '\r\e[2K%s\n' "$rendered_line"
    done < <(engine::_render_login_picker "$cursor") > "$output"
    printf '\e[J' > "$output"
}

engine::_render_login_selection_tui() {
    local cursor="$1"
    local rows cols divider
    rows="$(engine::_terminal_rows)"
    cols="$(engine::_terminal_cols)"
    divider="$(engine::_repeat_char "-" "$cols")"

    local title="login setup"
    local footer="Up/Down move | Space toggles | Enter starts selected logins | Ctrl-C skips"
    local -a lines=()
    local notice

    if [[ "${_login_phase:-final}" == "gate" ]]; then
        lines+=("  ${C_DIM}Some install steps need account access. Choose accounts now.${C_RESET}")
    else
        lines+=("  ${C_DIM}Choose accounts to authenticate now.${C_RESET}")
    fi
    for notice in "${_login_notice_lines[@]}"; do
        lines+=("$notice")
    done
    (( ${#_login_notice_lines[@]} > 0 )) && lines+=("")

    engine::_build_login_picker_lines "$cursor"
    (( ${#ENGINE_LOGIN_PICKER_LINES[@]} > 0 )) && lines+=("${ENGINE_LOGIN_PICKER_LINES[@]}")
    (( ${#_login_order[@]} == 0 )) && lines+=("  ${C_DIM}No login steps are available.${C_RESET}")

    printf '\e[H'
    engine::_tui_line 1 "$C_BOLD_CYAN$(engine::_plain_fit "$title" "$cols")$C_RESET"
    engine::_tui_line 2 "$C_DIM$divider$C_RESET"

    local content_start=3 footer_start=$(( rows - 1 )) content_rows=$(( footer_start - content_start ))
    (( content_rows < 1 )) && content_rows=1
    local row idx overflow
    for (( row = content_start; row < footer_start; row++ )); do
        idx=$(( row - content_start + 1 ))
        if (( idx <= ${#lines[@]} )); then
            if (( row == footer_start - 1 && ${#lines[@]} > content_rows )); then
                overflow=$(( ${#lines[@]} - content_rows + 1 ))
                engine::_tui_line "$row" "  ${C_DIM}... ${overflow} more${C_RESET}"
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

# Read picker keys until the user confirms or cancels. Both pickers share this
# loop. Call "$redraw" with the cursor plus any extra arguments after each key.
# Read the result from ENGINE_LOGIN_CURSOR and ENGINE_LOGIN_INTERRUPTED.
engine::_login_key_loop() {
    local input="$1" redraw="$2"
    shift 2
    local key seq

    while true; do
        IFS= read -rsk1 key < "$input" || break
        case "$key" in
            $'\003')
                ENGINE_LOGIN_INTERRUPTED=true
                break
                ;;
            $'\r'|$'\n')
                break
                ;;
            " ")
                engine::_login_toggle "${_login_order[$ENGINE_LOGIN_CURSOR]}"
                ;;
            $'\e')
                seq=""
                IFS= read -rsk2 -t 0.05 seq < "$input" || true
                case "$seq" in
                    "[A") ENGINE_LOGIN_CURSOR=$(( ENGINE_LOGIN_CURSOR <= 1 ? ${#_login_order[@]} : ENGINE_LOGIN_CURSOR - 1 )) ;;
                    "[B") ENGINE_LOGIN_CURSOR=$(( ENGINE_LOGIN_CURSOR >= ${#_login_order[@]} ? 1 : ENGINE_LOGIN_CURSOR + 1 )) ;;
                esac
                ;;
        esac
        "$redraw" "$ENGINE_LOGIN_CURSOR" "$@"
    done
    return 0
}

engine::_select_interactive_logins_tui() {
    if ! engine::_prime_login_selection tui; then
        engine::_render_login_selection_tui 1
        sleep 0.8
        return 0
    fi

    if ! primer::has_prompt_tty; then
        local name
        for name in $_login_order; do
            _login_selected[$name]="false"
            _login_state[$name]="skipped"
            _login_detail[$name]="no terminal"
        done
        _login_notice_lines+=("  ${C_DIM}No interactive terminal available; skipping login prompts.${C_RESET}")
        engine::_render_login_selection_tui 1
        sleep 0.8
        return 0
    fi

    local input="/dev/stdin"
    [[ ! -t 0 ]] && input="/dev/tty"

    local old_stty
    ENGINE_LOGIN_CURSOR=1
    ENGINE_LOGIN_INTERRUPTED=false
    old_stty="$(stty -g < "$input")" || return 1
    stty raw -echo < "$input"
    engine::_render_login_selection_tui "$ENGINE_LOGIN_CURSOR"

    engine::_login_key_loop "$input" engine::_render_login_selection_tui

    stty "$old_stty" < "$input" 2>/dev/null || true
    if [[ "$ENGINE_LOGIN_INTERRUPTED" == true ]]; then
        _login_interrupted=true
        engine::_render_login_selection_tui "$ENGINE_LOGIN_CURSOR"
        return 130
    fi
    return 0
}

engine::_select_interactive_logins() {
    (( ${#_login_order[@]} == 0 )) && return 0
    [[ "$DRY_RUN" == true ]] && return 0

    if [[ "$PRIMER_UPDATE_MODE" == "alternate" && "$PRIMER_ALT_SCREEN_ACTIVE" == true ]]; then
        engine::_select_interactive_logins_tui
        return $?
    fi

    if ! engine::_prime_login_selection; then
        return 0
    fi

    print ""

    if ! primer::has_prompt_tty; then
        local name
        for name in $_login_order; do
            _login_selected[$name]="false"
            _login_state[$name]="skipped"
            _login_detail[$name]="no terminal"
        done
        print "  ${C_DIM}No interactive terminal available; skipping login prompts.${C_RESET}"
        return 0
    fi

    local input="/dev/stdin" output="/dev/stdout"
    if [[ ! -t 0 ]]; then
        input="/dev/tty"
        output="/dev/tty"
    fi

    local old_stty picker_lines
    ENGINE_LOGIN_CURSOR=1
    ENGINE_LOGIN_INTERRUPTED=false
    picker_lines=$(( ${#_login_order[@]} + 2 ))
    old_stty="$(stty -g < "$input")" || return 1

    printf '\e[?25l' > "$output"
    stty raw -echo < "$input"
    engine::_draw_login_picker "$ENGINE_LOGIN_CURSOR" "$output" 0

    engine::_login_key_loop "$input" engine::_draw_login_picker "$output" "$picker_lines"

    stty "$old_stty" < "$input" 2>/dev/null || true
    printf '\e[?25h' > "$output"
    print ""

    if [[ "$ENGINE_LOGIN_INTERRUPTED" == true ]]; then
        print "  ${C_DIM}Login setup cancelled.${C_RESET}"
        return 130
    fi
}

engine::_record_login_result() {
    local name="$1" label="$2" rc="$3"

    if (( rc == 0 )); then
        print "  ${C_GREEN}${GLYPH_OK}${C_RESET}  $label complete"
        _login_state[$name]="done"
        _login_detail[$name]="complete"
        return 0
    fi

    if (( rc == 130 )); then
        print ""
        print "  ${C_YELLOW}${GLYPH_SKIP}${C_RESET}  $label skipped"
        _login_state[$name]="skipped"
        _login_detail[$name]="interrupted"
        _login_interrupted=true
        return 0
    fi

    print "  ${C_RED}${GLYPH_FAIL}${C_RESET}  $label failed"
    _login_state[$name]="failed"
    _login_detail[$name]="failed"
    return 1
}

engine::_render_login_command_tui() {
    local label="$1" instruction="$2"
    local rows cols divider
    rows="$(engine::_terminal_rows)"
    cols="$(engine::_terminal_cols)"
    divider="$(engine::_repeat_char "-" "$cols")"

    printf '\e[H'
    engine::_tui_line 1 "$C_BOLD_CYAN$(engine::_plain_fit "login: $label" "$cols")$C_RESET"
    engine::_tui_line 2 "$C_DIM$divider$C_RESET"
    engine::_tui_line 3 "  ${C_BLUE}›${C_RESET}  $label"
    if [[ -n "$instruction" ]]; then
        engine::_tui_line 4 "     ${C_DIM}${instruction}${C_RESET}"
    else
        engine::_tui_line 4 ""
    fi
    engine::_tui_line 5 ""

    local row
    for (( row = 6; row < rows - 1; row++ )); do
        engine::_tui_line "$row" ""
    done
    engine::_tui_line "$(( rows - 1 ))" "$C_DIM$divider$C_RESET"
    engine::_tui_line "$rows" "$C_BOLD$(engine::_plain_fit "Complete the prompt above. Ctrl-C skips this login." "$cols")$C_RESET"
    printf '\e[6;1H'
}

engine::_login_logfile() {
    local name="$1"
    local safe="${name//[^A-Za-z0-9_.-]/_}"
    [[ -n "$PRIMER_TMPDIR" ]] || return 1
    print "${PRIMER_TMPDIR}/login-${safe}.log"
}

engine::_run_login_command() {
    local name="$1" command_line="$2"
    local logfile
    logfile="$(engine::_login_logfile "$name")" || return 1
    : > "$logfile"
    _login_log[$name]="$logfile"

    if [[ -t 0 ]]; then
        zsh -c "$command_line" > >(tee "$logfile") 2> >(tee -a "$logfile" >&2)
        return $?
    fi

    if primer::has_prompt_tty; then
        zsh -c "$command_line" </dev/tty > >(tee "$logfile" >/dev/tty) 2> >(tee -a "$logfile" >/dev/tty)
        return $?
    fi

    zsh -c "$command_line" >>"$logfile" 2>&1
}

engine::_render_login_error_output() {
    (( ${#_login_all_order[@]} == 0 )) && return 0
    [[ "$DRY_RUN" == true ]] && return 0

    local name label logfile any_error=false
    for name in $_login_all_order; do
        [[ "${_login_state[$name]:-}" == "failed" || "${_login_detail[$name]:-}" == "interrupted" ]] || continue
        logfile="${_login_log[$name]:-}"
        [[ -n "$logfile" && -s "$logfile" ]] || continue

        label="${_mod_config[logins.${name}_label]:-$name}"
        ui::error_box "$label -- login output" "$logfile"
        any_error=true
    done

    $any_error
}

engine::_run_interactive_logins() {
    (( ${#_login_order[@]} == 0 )) && return 0
    [[ "$DRY_RUN" == true ]] && return 0

    local selected_count=0 name
    for name in $_login_order; do
        if [[ "${_login_selected[$name]:-false}" == true ]]; then
            selected_count=$(( selected_count + 1 ))
        else
            _login_state[$name]="skipped"
            _login_detail[$name]="not selected"
        fi
    done
    (( selected_count == 0 )) && return 0

    local login_tui=false
    [[ "$PRIMER_UPDATE_MODE" == "alternate" && "$PRIMER_ALT_SCREEN_ACTIVE" == true ]] && login_tui=true

    if ! $login_tui; then
        print ""
        ui::box "interactive logins" "$C_CYAN"
        print ""
    fi

    local label requires missing status_cmd command_line instruction done_detail rc any_failed=false
    for name in $_login_order; do
        [[ "${_login_selected[$name]:-false}" == true ]] || continue

        label="${_mod_config[logins.${name}_label]:-$name}"
        requires="${_mod_config[logins.${name}_requires]:-}"
        status_cmd="${_mod_config[logins.${name}_status]:-}"
        command_line="${_mod_config[logins.${name}_command]:-}"
        instruction="${_mod_config[logins.${name}_instruction]:-}"

        missing=""
        if [[ -n "${_mod_config[logins.${name}_depends_on]:-}" ]]; then
            missing="$(engine::_missing_login_module_deps "${_mod_config[logins.${name}_depends_on]}")"
        fi
        if [[ -n "$missing" ]]; then
            print "  ${C_YELLOW}${GLYPH_SKIP}${C_RESET}  $label skipped (waiting on: $missing)"
            _login_state[$name]="skipped"
            _login_detail[$name]="waiting on: $missing"
            any_failed=true
            continue
        fi

        missing=""
        if [[ -n "$requires" ]]; then
            missing="$(engine::_missing_login_requirements "$requires")"
        fi
        if [[ -n "$missing" ]]; then
            print "  ${C_YELLOW}${GLYPH_SKIP}${C_RESET}  $label skipped (missing: $missing)"
            _login_state[$name]="skipped"
            _login_detail[$name]="missing: $missing"
            any_failed=true
            continue
        fi

        if [[ -n "$status_cmd" ]]; then
            if engine::_login_already_done "$status_cmd"; then
                done_detail="${_mod_config[logins.${name}_done_detail]:-logged in}"
                print "  ${C_GREEN}${GLYPH_OK}${C_RESET}  $label already $done_detail"
                _login_state[$name]="done"
                _login_detail[$name]="$done_detail"
                continue
            fi
        fi

        if [[ -z "$command_line" ]]; then
            print "  ${C_YELLOW}${GLYPH_SKIP}${C_RESET}  $label skipped (no command configured)"
            _login_state[$name]="skipped"
            _login_detail[$name]="no command"
            any_failed=true
            continue
        fi

        if $login_tui; then
            engine::_render_login_command_tui "$label" "$instruction"
            printf '%b' '\033[?25h'
        else
            print "  ${C_BLUE}›${C_RESET}  $label"
            [[ -n "$instruction" ]] && print "     ${C_DIM}${instruction}${C_RESET}"
        fi
        rc=0
        local command_interrupted=false
        trap 'command_interrupted=true' INT
        engine::_run_login_command "$name" "$command_line" || rc=$?
        trap - INT
        $login_tui && printf '%b' '\033[?25l'
        [[ "$command_interrupted" == true && "$rc" != 0 ]] && rc=130

        if ! engine::_record_login_result "$name" "$label" "$rc"; then
            any_failed=true
        fi
        $login_tui && sleep 0.5
    done

    $login_tui || print ""
    $any_failed && return 1
    return 0
}

engine::_render_login_summary() {
    (( ${#_login_all_order[@]} == 0 )) && return 0
    [[ "$DRY_RUN" == true ]] && return 0

    local any_login=false name
    for name in $_login_all_order; do
        [[ -n "${_login_state[$name]:-}" && "${_login_state[$name]}" != "pending" ]] && any_login=true
    done
    $any_login || return 0

    print ""
    ui::box "login summary" "$C_CYAN"
    print ""

    local label state detail
    for name in $_login_all_order; do
        label="${_mod_config[logins.${name}_label]:-$name}"
        state="${_login_state[$name]:-skipped}"
        detail="${_login_detail[$name]:-not selected}"
        [[ "$state" == "pending" ]] && state="skipped" detail="not selected"
        ui::module_line "$state" "$label" "$detail"
        print ""
    done
}
