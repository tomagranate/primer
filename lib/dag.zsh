#!/bin/zsh
# lib/dag.zsh -- Dependency checks, filters, and module lifecycle

# ── DAG Helpers ───────────────────────────────────────────────────────────────

# Are all module dependencies of this module in "done" state?
engine::_module_deps_met() {
    local mod="$1"
    local deps="${_mod_deps[$mod]}"
    [[ -z "$deps" ]] && return 0

    local dep
    for dep in ${(s:,:)deps}; do
        [[ "${_state[$dep]}" != "done" ]] && return 1
    done
    return 0
}

# Has any module dependency failed, been skipped, or been interrupted?
engine::_module_deps_failed() {
    local mod="$1"
    local deps="${_mod_deps[$mod]}"
    [[ -z "$deps" ]] && return 1

    local dep
    for dep in ${(s:,:)deps}; do
        [[ "${_state[$dep]}" == "failed" || "${_state[$dep]}" == "skipped" || "${_state[$dep]}" == "interrupted" ]] && return 0
    done
    return 1
}

# Are all login dependencies satisfied? Dry-run treats login deps as met.
engine::_login_deps_met() {
    local mod="$1"
    local deps="${_mod_login_deps[$mod]}"
    [[ -z "$deps" ]] && return 0
    [[ "$DRY_RUN" == true ]] && return 0

    local dep
    for dep in ${(s:,:)deps}; do
        [[ "${_login_state[$dep]:-}" != "done" ]] && return 1
    done
    return 0
}

# Has any login dependency failed or been skipped?
engine::_login_deps_failed() {
    local mod="$1"
    local deps="${_mod_login_deps[$mod]}"
    [[ -z "$deps" ]] && return 1
    [[ "$DRY_RUN" == true ]] && return 1

    local dep
    for dep in ${(s:,:)deps}; do
        [[ "${_login_state[$dep]:-}" == "failed" || "${_login_state[$dep]:-}" == "skipped" ]] && return 0
    done
    return 1
}

# Are all dependencies of this module in "done" state?
engine::_deps_met() {
    local mod="$1"
    engine::_module_deps_met "$mod" || return 1
    engine::_login_deps_met "$mod" || return 1
    return 0
}

# Has any dependency of this module failed or been skipped?
engine::_deps_failed() {
    local mod="$1"
    engine::_module_deps_failed "$mod" && return 0
    engine::_login_deps_failed "$mod" && return 0
    return 1
}

# Is any module currently running?
engine::_any_running() {
    local mod
    for mod in $_mod_order; do
        [[ "${_state[$mod]}" == "running" ]] && return 0
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

# ── Sudo Detection ────────────────────────────────────────────────────────────

# A module needs sudo when its config declares it, or when any of its config
# values marks a privileged step.
engine::_module_needs_sudo() {
    local mod="$1"

    local declared="${_mod_config[${mod}.needs_sudo]:-}"
    if [[ -n "$declared" && "$(engine::_bool_default "$declared")" == "true" ]]; then
        return 0
    fi

    local key
    for key in ${(k)_mod_config}; do
        [[ "$key" == "${mod}."* ]] || continue
        [[ "${_mod_config[$key]}" == *"privileged: true"* ]] && return 0
    done

    return 1
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

        if engine::_module_needs_sudo "$mod"; then
            zsh "$runner" >"$logfile" 2>&1
        elif command -v script >/dev/null 2>&1; then
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

# ── Interrupt and Cleanup ─────────────────────────────────────────────────────

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
