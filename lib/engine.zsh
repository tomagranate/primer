#!/bin/zsh
# lib/engine.zsh -- Ready-queue DAG engine with parallel execution

zmodload zsh/datetime   # EPOCHREALTIME for sub-second timing

# ── Module Registry (populated by engine::load_config) ────────────────────────

typeset -ga _mod_order=()       # Module names in config order
typeset -gA _mod_deps=()        # module -> "dep1,dep2,..."
typeset -gA _mod_desc=()        # module -> "Display Label"
typeset -gA _mod_config=()      # "module.key" -> "value\nvalue..."
typeset -ga _login_order=()     # Login target names in config order
typeset -ga _login_all_order=() # All configured login target names
typeset -gA _login_selected=()  # login -> true|false
typeset -gA _login_state=()     # login -> done|failed|skipped|pending
typeset -gA _login_detail=()    # login -> summary detail
typeset -gA _login_log=()       # login -> captured command output
typeset -ga _login_notice_lines=()
typeset -g  _login_interrupted=false

# ── Runtime State ─────────────────────────────────────────────────────────────

typeset -gA _state=()           # module -> pending|running|done|failed|skipped
typeset -gA _pids=()            # module -> background PID
typeset -gA _start=()           # module -> start EPOCHREALTIME
typeset -gA _elapsed=()         # module -> "N.Ns" (set when finished)
typeset -g  PRIMER_TMPDIR=""
typeset -g  ENGINE_RENDER_FINAL=false
typeset -g  PRIMER_RENDER_TTY=false
typeset -g  PRIMER_UI_MODE="${PRIMER_UI_MODE:-}"
typeset -g  PRIMER_UPDATE_MODE=""
typeset -g  PRIMER_ALT_SCREEN_ACTIVE=false
typeset -g  ENGINE_INTERRUPTED=false
typeset -g  ENGINE_REPORTED=false
typeset -g  ENGINE_UPDATE_STARTED=false
typeset -g  ENGINE_REPORT_TITLE=""
typeset -g  ENGINE_REPORT_COLOR="$C_BLUE"
typeset -F  ENGINE_UPDATE_STARTED_AT=0
typeset -gi ENGINE_RENDERED_ITEM_LINES=0
typeset -gA _log_offsets=()

# ── Config Parsing (INI format) ──────────────────────────────────────────────

engine::_load_config_file() {
    local config="$1" section="" key=""

    [[ -f "$config" ]] || {
        print "Missing config file: $config" >&2
        return 1
    }

    while IFS= read -r line; do
        # Skip comments and blank lines
        [[ "$line" =~ ^[[:space:]]*# ]] && continue
        [[ -z "${line// /}" ]] && continue

        # Section header: [module_name] (allows hyphens)
        if [[ "$line" =~ '^\[([a-z_-]+)\]' ]]; then
            section="${match[1]}"
            if [[ "$section" != "logins" && -z "${_mod_seen[$section]:-}" ]]; then
                _mod_order+=("$section")
                _mod_seen[$section]=true
            fi
            key=""
            continue
        fi

        # Indented continuation line (part of a multi-value key)
        if [[ "$line" =~ '^[[:space:]]+(.+)' && -n "$key" && -n "$section" ]]; then
            _mod_config[${section}.${key}]+=$'\n'"${match[1]}"
            continue
        fi

        # Key = value line
        if [[ "$line" =~ '^([a-z_-]+)[[:space:]]*=[[:space:]]*(.*)' && -n "$section" ]]; then
            key="${match[1]}"
            local val="${match[2]}"
            _mod_config[${section}.${key}]="$val"
            [[ "$key" == "depends_on" ]] && _mod_deps[$section]="${val// /}"
            [[ "$key" == "label" ]]      && _mod_desc[$section]="$val"
        fi
    done < "$config"
    return 0
}

engine::load_config() {
    local config
    _mod_order=()
    typeset -gA _mod_seen=()
    _mod_deps=()
    _mod_desc=()
    _mod_config=()
    _login_order=()
    _login_all_order=()
    _login_selected=()
    _login_state=()
    _login_detail=()
    _login_log=()
    _login_notice_lines=()
    _login_interrupted=false

    for config in "$@"; do
        engine::_load_config_file "$config" || return 1
    done

    engine::_load_logins
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
        [[ "${_state[$dep]}" == "failed" || "${_state[$dep]}" == "skipped" || "${_state[$dep]}" == "interrupted" ]] && return 0
    done
    return 1
}

# Pre-mark modules as skipped based on PRIMER_SKIP / PRIMER_ONLY env vars.
# Called once after all states are set to "pending". The DAG loop then
# cascade-skips dependents of skipped modules via engine::_deps_failed.
engine::_apply_filters() {
    local mod
    if [[ -n "${PRIMER_SKIP:-}" ]]; then
        for mod in $_mod_order; do
            [[ " ${PRIMER_SKIP} " == *" ${mod} "* ]] && _state[$mod]="skipped"
        done
    fi
    if [[ -n "${PRIMER_ONLY:-}" ]]; then
        for mod in $_mod_order; do
            [[ " ${PRIMER_ONLY} " != *" ${mod} "* ]] && _state[$mod]="skipped"
        done
    fi
}

# ── Interactive Login Selection ──────────────────────────────────────────────

engine::_trim() {
    local value="$1"
    value="${value#"${value%%[![:space:]]*}"}"
    value="${value%"${value##*[![:space:]]}"}"
    print -r -- "$value"
}

engine::_config_lines() {
    local raw="${_mod_config[$1]}"
    local line
    while IFS= read -r line; do
        line="$(engine::_trim "$line")"
        [[ -n "$line" ]] && print -r -- "$line"
    done <<< "$raw"
}

engine::_bool_default() {
    local value="${1:l}"
    case "$value" in
        yes|y|true|1|on) print "true" ;;
        no|n|false|0|off) print "false" ;;
        *) print "true" ;;
    esac
}

engine::_answer_to_bool() {
    local answer="${1:l}" default_bool="$2"
    answer="$(engine::_trim "$answer")"
    if [[ -z "$answer" ]]; then
        print "$default_bool"
        return 0
    fi

    case "$answer" in
        y|yes|true|1|on) print "true" ;;
        n|no|false|0|off) print "false" ;;
        *) return 1 ;;
    esac
}

engine::_login_toggle() {
    local name="$1"
    if [[ "${_login_selected[$name]:-false}" == true ]]; then
        _login_selected[$name]="false"
    else
        _login_selected[$name]="true"
    fi
}

engine::_load_logins() {
    _login_order=()
    _login_all_order=()
    _login_selected=()
    _login_state=()
    _login_detail=()

    local name
    for name in ${(f)"$(engine::_config_lines logins.order)"}; do
        if [[ -n "$name" ]]; then
            _login_order+=("$name")
            _login_all_order+=("$name")
            _login_state[$name]="pending"
            _login_detail[$name]="waiting"
        fi
    done
}

engine::_has_prompt_tty() {
    [[ -t 0 ]] && return 0
    [[ -e /dev/tty ]] || return 1
    ( : </dev/tty >/dev/tty ) 2>/dev/null
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
    ${(z)status_cmd} >/dev/null 2>&1
}

engine::_render_login_picker() {
    local cursor="$1"
    local name label marker pointer color i

    print "  ${C_DIM}Use Up/Down to move. Space toggles a login. Enter starts selected logins.${C_RESET}"
    print ""

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
        printf '  %s%s%s  %s%s%s  %s\n' "$color" "$pointer" "$C_RESET" "$color" "$marker" "$C_RESET" "$label"
    done
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
        print "  ${C_DIM}Installation is complete. Choose the accounts to authenticate now.${C_RESET}"
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
    local notice name label marker pointer color i

    lines+=("  ${C_DIM}Choose accounts to authenticate now.${C_RESET}")
    for notice in "${_login_notice_lines[@]}"; do
        lines+=("$notice")
    done
    (( ${#_login_notice_lines[@]} > 0 )) && lines+=("")

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
        lines+=("  ${color}${pointer}${C_RESET}  ${color}${marker}${C_RESET}  $label")
    done
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

engine::_select_interactive_logins_tui() {
    if ! engine::_prime_login_selection tui; then
        engine::_render_login_selection_tui 1
        sleep 0.8
        return 0
    fi

    if ! engine::_has_prompt_tty; then
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

    local old_stty cursor=1 key seq interrupted=false
    old_stty="$(stty -g < "$input")" || return 1
    stty raw -echo < "$input"
    engine::_render_login_selection_tui "$cursor"

    while true; do
        IFS= read -rsk1 key < "$input" || break
        case "$key" in
            $'\003')
                interrupted=true
                break
                ;;
            $'\r'|$'\n')
                break
                ;;
            " ")
                engine::_login_toggle "${_login_order[$cursor]}"
                ;;
            $'\e')
                seq=""
                IFS= read -rsk2 -t 0.05 seq < "$input" || true
                case "$seq" in
                    "[A") cursor=$(( cursor <= 1 ? ${#_login_order[@]} : cursor - 1 )) ;;
                    "[B") cursor=$(( cursor >= ${#_login_order[@]} ? 1 : cursor + 1 )) ;;
                esac
                ;;
        esac
        engine::_render_login_selection_tui "$cursor"
    done

    stty "$old_stty" < "$input" 2>/dev/null || true
    if [[ "$interrupted" == true ]]; then
        _login_interrupted=true
        engine::_render_login_selection_tui "$cursor"
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

    if ! engine::_has_prompt_tty; then
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

    local old_stty cursor=1 key seq picker_lines interrupted=false
    picker_lines=$(( ${#_login_order[@]} + 2 ))
    old_stty="$(stty -g < "$input")" || return 1

    printf '\e[?25l' > "$output"
    stty raw -echo < "$input"
    engine::_draw_login_picker "$cursor" "$output" 0

    while true; do
        IFS= read -rsk1 key < "$input" || break
        case "$key" in
            $'\003')
                interrupted=true
                break
                ;;
            $'\r'|$'\n')
                break
                ;;
            " ")
                engine::_login_toggle "${_login_order[$cursor]}"
                ;;
            $'\e')
                seq=""
                IFS= read -rsk2 -t 0.05 seq < "$input" || true
                case "$seq" in
                    "[A") cursor=$(( cursor <= 1 ? ${#_login_order[@]} : cursor - 1 )) ;;
                    "[B") cursor=$(( cursor >= ${#_login_order[@]} ? 1 : cursor + 1 )) ;;
                esac
                ;;
        esac

        engine::_draw_login_picker "$cursor" "$output" "$picker_lines"
    done

    stty "$old_stty" < "$input" 2>/dev/null || true
    printf '\e[?25h' > "$output"
    print ""

    if [[ "$interrupted" == true ]]; then
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

    local -a command_parts
    command_parts=("${(z)command_line}")
    if [[ -t 0 ]]; then
        "${command_parts[@]}" > >(tee "$logfile") 2> >(tee -a "$logfile" >&2)
        return $?
    fi

    if engine::_has_prompt_tty; then
        "${command_parts[@]}" </dev/tty > >(tee "$logfile" >/dev/tty) 2> >(tee -a "$logfile" >/dev/tty)
        return $?
    fi

    "${command_parts[@]}" >>"$logfile" 2>&1
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
    local runner="${PRIMER_TMPDIR}/${mod}.runner.zsh"
    local configfile="${PRIMER_TMPDIR}/${mod}.config.zsh"
    local mod_dir="${PRIMER_DIR}/modules/${mod}"

    {
        print -r -- "typeset -gA _mod_config=()"
        local key
        for key in ${(k)_mod_config}; do
            [[ "$key" == "${mod}."* ]] || continue
            print -r -- "_mod_config[$key]=${(qqq)_mod_config[$key]}"
        done
    } > "$configfile"

    cat > "$runner" <<'EOF'
#!/bin/zsh
source "${PRIMER_DIR}/lib/ui.zsh"
source "${MOD_CONFIG_FILE}"
source "${MOD_DIR}/module.zsh" || {
    echo "Failed to load module: ${MOD_NAME}"
    exit 1
}
"mod_${MOD_ACTION}"
EOF
    chmod +x "$runner"

    (
        export MOD_STATUS_FILE="$statusfile"
        export MOD_ITEMS_FILE="${PRIMER_TMPDIR}/${mod}.items"
        export MOD_CONFIG_FILE="$configfile"
        export MOD_DIR="$mod_dir"
        export MOD_NAME="$mod"
        export MOD_ACTION="$action"
        export PRIMER_DIR
        export DRY_RUN
        export HOMEBREW_NO_COLOR=1
        export HOMEBREW_NO_EMOJI=1
        export HOMEBREW_NO_ENV_HINTS=1
        export NONINTERACTIVE=1

        if command -v script >/dev/null 2>&1; then
            if script --version >/dev/null 2>&1; then
                script -q -e -c "zsh ${(q)runner}" "$logfile" </dev/null >/dev/null 2>&1
            else
                script -q "$logfile" zsh "$runner" </dev/null >/dev/null 2>&1
            fi
        else
            zsh "$runner" </dev/null >"$logfile" 2>&1
        fi
    ) &

    local pid=$!
    _pids[$mod]=$pid
    _state[$mod]="running"
    _start[$mod]=$EPOCHREALTIME
    _log_offsets[$mod]=0

    if [[ "$PRIMER_UPDATE_MODE" == "log" ]]; then
        print -- "==> ${_mod_desc[$mod]}"
    fi
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
            if [[ "$PRIMER_UPDATE_MODE" == "log" ]]; then
                engine::_stream_log_delta "$mod"
                print -- "--> ${_mod_desc[$mod]}: ${_state[$mod]} (${_elapsed[$mod]}s)"
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
            if [[ "$PRIMER_UPDATE_MODE" == "log" ]]; then
                print -- "--> ${_mod_desc[$mod]}: skipped (dependency failed)"
            fi
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

engine::_render_module_items() {
    local items_file="$1" mod_state="$2" budget="$3"
    local -a running_lines=() failed_lines=() skipped_lines=() pending_lines=() done_lines=() other_lines=() lines=()
    local item_state item_name item_detail rendered_line
    ENGINE_RENDERED_ITEM_LINES=0

    while IFS=: read -r item_state item_name item_detail; do
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

    (( ${#lines[@]} == 0 || budget == 0 )) && return 0

    local visible_rows=$budget
    (( visible_rows > ${#lines[@]} )) && visible_rows=${#lines[@]}

    local i
    for (( i = 1; i <= visible_rows; i++ )); do
        if (( i == visible_rows && ${#lines[@]} > visible_rows )); then
            local remaining=$(( ${#lines[@]} - visible_rows + 1 ))
            ui::frame_line "$(printf '   %s... %d more%s' "$C_DIM" "$remaining" "$C_RESET")"
        else
            ui::frame_line "${lines[$i]}"
        fi
        ENGINE_RENDERED_ITEM_LINES=$(( ENGINE_RENDERED_ITEM_LINES + 1 ))
    done
}

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

engine::_module_item_lines_for_tui() {
    local items_file="$1" mod_state="$2" budget="$3"
    local -a running_lines=() failed_lines=() skipped_lines=() pending_lines=() done_lines=() other_lines=() lines=()
    local item_state item_name item_detail rendered_line i visible_rows remaining

    (( budget <= 0 )) && return 0
    while IFS=: read -r item_state item_name item_detail; do
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
            printf '   %s... %d more%s\n' "$C_DIM" "$remaining" "$C_RESET"
        else
            printf '%s\n' "${lines[$i]}"
        fi
    done
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
    dd if="$logfile" bs=1 skip="$offset" count="$delta" 2>/dev/null
    _log_offsets[$mod]="$size"
}

engine::_stream_all_log_deltas() {
    local mod
    for mod in $_mod_order; do
        [[ "${_state[$mod]}" == "running" || "${_state[$mod]}" == "done" || "${_state[$mod]}" == "failed" || "${_state[$mod]}" == "interrupted" ]] || continue
        engine::_stream_log_delta "$mod"
    done
}

engine::_mark_interrupted() {
    ENGINE_INTERRUPTED=true
    local mod pid
    for mod in $_mod_order; do
        case "${_state[$mod]}" in
            running)
                pid="${_pids[$mod]}"
                [[ -n "$pid" ]] && kill "$pid" 2>/dev/null || true
                _elapsed[$mod]=$(printf '%.1f' $(( EPOCHREALTIME - _start[$mod] )))
                _state[$mod]="interrupted"
                ;;
            pending)
                _state[$mod]="skipped"
                ;;
        esac
    done
}

engine::_handle_interrupt() {
    engine::_mark_interrupted
    engine::_print_update_report
    [[ -n "$PRIMER_TMPDIR" ]] && rm -rf "$PRIMER_TMPDIR"
    exit 130
}

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

engine::_cleanup_update() {
    local rc=$?
    if [[ "$ENGINE_UPDATE_STARTED" != true ]]; then
        :
    elif [[ "$ENGINE_REPORTED" != true && -n "$PRIMER_TMPDIR" && -d "$PRIMER_TMPDIR" ]]; then
        if (( rc != 0 )) || [[ "$ENGINE_INTERRUPTED" == true ]]; then
            engine::_print_update_report
        else
            engine::_finish_terminal_ui
        fi
    else
        engine::_finish_terminal_ui
    fi
    [[ -n "$PRIMER_TMPDIR" ]] && rm -rf "$PRIMER_TMPDIR"
    return "$rc"
}

engine::_module_needs_sudo() {
    case "$1" in
        apt|flatpak|login-shell|touchid|xcode) return 0 ;;
        *) return 1 ;;
    esac
}

engine::_needs_sudo() {
    (( EUID == 0 )) && return 1

    local mod
    for mod in $_mod_order; do
        [[ "${_state[$mod]}" == "skipped" ]] && continue
        engine::_module_needs_sudo "$mod" && return 0
    done

    return 1
}

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

    # ── Ready-queue DAG loop ──────────────────────────────────────────────────
    while engine::_has_active; do
        engine::_poll_running
        if [[ "$PRIMER_UPDATE_MODE" == "log" ]]; then
            engine::_stream_all_log_deltas
        fi
        engine::_start_ready "update"

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

    local login_failed=false
    if [[ "$any_interrupted" != true ]]; then
        trap - INT TERM
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
            print -n "$local_rc" > "$rcfile"
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

                # Rarely, a parallel status check can finish with rc=0 but write no detail.
                # Retry once synchronously so we prefer module-provided actionable detail.
                if (( rc == 0 )) && [[ -z "$detail" ]]; then
                    local retry_status
                    retry_status=$(mktemp)
                    local retry_rc=0
                    (
                        export MOD_STATUS_FILE="$retry_status"
                        export MOD_DIR="${PRIMER_DIR}/modules/${mod}"
                        export MOD_NAME="$mod"
                        source "${PRIMER_DIR}/lib/ui.zsh"
                        source "${PRIMER_DIR}/modules/${mod}/module.zsh" 2>/dev/null || exit 1
                        mod_status
                    ) &>/dev/null || retry_rc=$?
                    if (( retry_rc == 0 )) && [[ -f "$retry_status" ]]; then
                        detail="$(cat "$retry_status")"
                    fi
                    rm -f "$retry_status"
                fi

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
