#!/bin/zsh
# lib/engine.zsh -- Ready-queue DAG engine with parallel execution

zmodload zsh/datetime   # EPOCHREALTIME for sub-second timing

# ── Module Registry (populated by engine::load_config) ────────────────────────

typeset -ga _mod_order=()       # Module names in config order
typeset -gA _mod_deps=()        # module -> "dep1,dep2,..."
typeset -gA _mod_desc=()        # module -> "Display Label"
typeset -gA _mod_config=()      # "module.key" -> "value\nvalue..."
typeset -ga _login_order=()     # Login target names in config order
typeset -gA _login_selected=()  # login -> true|false

# ── Runtime State ─────────────────────────────────────────────────────────────

typeset -gA _state=()           # module -> pending|running|done|failed|skipped
typeset -gA _pids=()            # module -> background PID
typeset -gA _start=()           # module -> start EPOCHREALTIME
typeset -gA _elapsed=()         # module -> "N.Ns" (set when finished)
typeset -g  PRIMER_TMPDIR=""
typeset -g  ENGINE_RENDER_FINAL=false
typeset -g  PRIMER_RENDER_TTY=false
typeset -gi ENGINE_RENDERED_ITEM_LINES=0

# ── Config Parsing (INI format) ──────────────────────────────────────────────

engine::load_config() {
    local config="$1" section="" key=""
    _mod_order=()
    _mod_deps=()
    _mod_desc=()
    _mod_config=()
    _login_order=()
    _login_selected=()

    while IFS= read -r line; do
        # Skip comments and blank lines
        [[ "$line" =~ ^[[:space:]]*# ]] && continue
        [[ -z "${line// /}" ]] && continue

        # Section header: [module_name] (allows hyphens)
        if [[ "$line" =~ '^\[([a-z_-]+)\]' ]]; then
            section="${match[1]}"
            [[ "$section" != "logins" ]] && _mod_order+=("$section")
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
        [[ "${_state[$dep]}" == "failed" || "${_state[$dep]}" == "skipped" ]] && return 0
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
    _login_selected=()

    local name
    for name in ${(f)"$(engine::_config_lines logins.order)"}; do
        [[ -n "$name" ]] && _login_order+=("$name")
    done
}

engine::_has_prompt_tty() {
    [[ -t 0 ]] && return 0
    [[ -e /dev/tty ]] || return 1
    ( : </dev/tty >/dev/tty ) 2>/dev/null
}

engine::_render_login_picker() {
    local cursor="$1"
    local name label marker pointer color i

    print "  ${C_DIM}Use ↑/↓ to move, Space to toggle, Enter to continue.${C_RESET}"
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

engine::_select_interactive_logins() {
    (( ${#_login_order[@]} == 0 )) && return 0
    [[ "$DRY_RUN" == true ]] && return 0

    _login_selected=()

    if ! engine::_has_prompt_tty; then
        local name
        for name in $_login_order; do
            _login_selected[$name]="false"
        done
        return 0
    fi

    print ""
    ui::box "primer login setup" "$C_CYAN"
    print ""

    local name default default_bool
    for name in $_login_order; do
        default="${_mod_config[logins.${name}_default]:-yes}"
        default_bool="$(engine::_bool_default "$default")"
        _login_selected[$name]="$default_bool"
    done

    local input="/dev/stdin" output="/dev/stdout"
    if [[ ! -t 0 ]]; then
        input="/dev/tty"
        output="/dev/tty"
    fi

    local old_stty cursor=1 key seq lines
    lines=$(( ${#_login_order[@]} + 2 ))
    old_stty="$(stty -g < "$input")" || return 1

    {
        stty raw -echo < "$input"
        engine::_render_login_picker "$cursor" > "$output"

        while true; do
            IFS= read -rsk1 key < "$input" || break
            case "$key" in
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

            printf '\e[%dA' "$lines" > "$output"
            {
                local rendered_line
                while IFS= read -r rendered_line; do
                    printf '\e[2K%s\n' "$rendered_line"
                done < <(engine::_render_login_picker "$cursor")
            } > "$output"
        done
    } always {
        stty "$old_stty" < "$input" 2>/dev/null || true
    }
    print ""
}

engine::_run_interactive_logins() {
    (( ${#_login_order[@]} == 0 )) && return 0
    [[ "$DRY_RUN" == true ]] && return 0

    local selected_count=0 name
    for name in $_login_order; do
        [[ "${_login_selected[$name]:-false}" == true ]] && selected_count=$(( selected_count + 1 ))
    done
    (( selected_count == 0 )) && return 0

    print ""
    ui::box "interactive logins" "$C_CYAN"
    print ""

    local label requires status_cmd command_line rc any_failed=false
    for name in $_login_order; do
        [[ "${_login_selected[$name]:-false}" == true ]] || continue

        label="${_mod_config[logins.${name}_label]:-$name}"
        requires="${_mod_config[logins.${name}_requires]:-}"
        status_cmd="${_mod_config[logins.${name}_status]:-}"
        command_line="${_mod_config[logins.${name}_command]:-}"

        if [[ -n "$requires" ]] && ! command -v "$requires" >/dev/null 2>&1; then
            print "  ${C_YELLOW}${GLYPH_SKIP}${C_RESET}  $label skipped (${requires} not found)"
            any_failed=true
            continue
        fi

        if [[ -n "$status_cmd" ]]; then
            if ${(z)status_cmd} >/dev/null 2>&1; then
                print "  ${C_GREEN}${GLYPH_OK}${C_RESET}  $label already logged in"
                continue
            fi
        fi

        if [[ -z "$command_line" ]]; then
            print "  ${C_YELLOW}${GLYPH_SKIP}${C_RESET}  $label skipped (no command configured)"
            any_failed=true
            continue
        fi

        print "  ${C_BLUE}›${C_RESET}  $label"
        rc=0
        if [[ -t 0 ]]; then
            ${(z)command_line} || rc=$?
        elif engine::_has_prompt_tty; then
            ${(z)command_line} </dev/tty >/dev/tty || rc=$?
        else
            rc=1
        fi

        if (( rc == 0 )); then
            print "  ${C_GREEN}${GLYPH_OK}${C_RESET}  $label complete"
        else
            print "  ${C_RED}${GLYPH_FAIL}${C_RESET}  $label failed"
            any_failed=true
        fi
    done

    print ""
    $any_failed && return 1
    return 0
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
        [[ "${_state[$mod_check]}" == "failed" ]] && footer_color="$C_RED" && break
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

    # Apply --skip / --only filters
    engine::_apply_filters

    # Decide all post-install interactive logins before installation begins.
    engine::_select_interactive_logins

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

    local live_ui=false
    [[ -t 1 ]] && live_ui=true
    UI_LIVE_FRAME="$live_ui"
    PRIMER_RENDER_TTY="$live_ui"
    UI_REPAINT_MODE="cursor"
    ENGINE_RENDER_FINAL=false

    if $live_ui; then
        # Hide cursor for clean animation. The renderer is the only writer to
        # stdout; module output is captured in per-module logs.
        printf '\e[?25l'
        trap "printf '\e[?25h'; rm -rf '$PRIMER_TMPDIR'" EXIT INT TERM

        # Initial render
        engine::_render
    fi

    # ── Ready-queue DAG loop ──────────────────────────────────────────────────
    while engine::_has_active; do
        engine::_poll_running
        engine::_start_ready "update"

        # Advance spinner
        SPIN_IDX=$(( (SPIN_IDX + 1) % ${#SPINNER[@]} ))

        $live_ui && engine::_render
        sleep 0.08
    done

    # Final render back in the normal terminal history.
    if $live_ui; then
        printf '\e[?25h'
        if $_frame_active && (( _frame_lines > 0 )); then
            printf '\e[%dA\e[J' $_frame_lines
        fi
        _frame_active=false
        _frame_lines=0
        _prev_frame_lines=0
    fi
    UI_LIVE_FRAME=false
    PRIMER_RENDER_TTY=false
    UI_REPAINT_MODE="cursor"
    ENGINE_RENDER_FINAL=true
    engine::_render
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

    local login_failed=false
    engine::_run_interactive_logins || login_failed=true

    print ""

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
        printf '\e[?25l'
        trap "printf '\e[?25h'" INT TERM
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

    $live_ui && printf '\e[?25h'
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
