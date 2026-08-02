#!/bin/zsh
# lib/config.zsh -- Global registries and INI config parsing

zmodload zsh/datetime   # EPOCHREALTIME for sub-second timing

# ── Module Registry (populated by engine::load_config) ────────────────────────

typeset -ga _mod_order=()       # Module names in config order
typeset -gA _mod_deps=()        # module -> "dep1,dep2,..."
typeset -gA _mod_login_deps=()  # module -> "login1,login2,..."
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
typeset -g  _login_phase="final" # gate|final (picker copy)

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
typeset -ga ENGINE_ITEM_LINES=()         # Built sub-item lines for one module
typeset -ga ENGINE_LOGIN_PICKER_LINES=() # Built login picker rows
typeset -gi ENGINE_LOGIN_CURSOR=1        # Login picker cursor row
typeset -g  ENGINE_LOGIN_INTERRUPTED=false
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
            [[ "$key" == "depends_on_logins" ]] && _mod_login_deps[$section]="${val// /}"
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
    _mod_login_deps=()
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
    _login_phase="final"

    for config in "$@"; do
        engine::_load_config_file "$config" || return 1
    done

    engine::_load_logins
}

# ── Value Helpers ─────────────────────────────────────────────────────────────

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

# ── Login Registry ────────────────────────────────────────────────────────────

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
