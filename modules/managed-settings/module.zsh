#!/bin/zsh
# modules/managed-settings -- Apply small JSON/TOML user settings from config

_managed_settings::expand_path() {
    local path="$1"
    path="${path/#\~/$HOME}"
    path="${path//\$HOME/$HOME}"
    path="${path//\$XDG_CONFIG_HOME/${XDG_CONFIG_HOME:-$HOME/.config}}"
    print -r -- "$path"
}

_managed_settings::json_entries() {
    mod_config json
}

_managed_settings::toml_entries() {
    mod_config toml
}

_managed_settings::entry_parts() {
    local entry="$1"
    local file key value
    [[ "$entry" == *"|"*"|"* ]] || return 1
    file="${entry%%|*}"
    entry="${entry#*|}"
    key="${entry%%|*}"
    value="${entry#*|}"
    [[ -n "$file" && -n "$key" && -n "$value" ]] || return 1
    print -r -- "$file|$key|$value"
}

_managed_settings::json_source() {
    local target="$1"
    if [[ -f "$target" ]]; then
        print -r -- "$target"
        return 0
    fi

    local empty
    empty="$(mktemp)"
    print '{}' > "$empty"
    print -r -- "$empty"
}

_managed_settings::json_apply() {
    local file="$1" key="$2" value="$3"
    command -v jq >/dev/null 2>&1 || return 1

    local target source tmp
    target="$(_managed_settings::expand_path "$file")"
    source="$(_managed_settings::json_source "$target")" || return 1
    tmp="$(mktemp)"
    mkdir -p "${target:h}"

    if [[ "$value" == "delete" ]]; then
        jq --arg path "$key" 'delpaths([($path | split("."))])' "$source" > "$tmp" || {
            rm -f "$tmp"
            [[ "$source" == /tmp/* ]] && rm -f "$source"
            return 1
        }
    else
        jq --arg path "$key" --argjson value "$value" 'setpath(($path | split(".")); $value)' "$source" > "$tmp" || {
            rm -f "$tmp"
            [[ "$source" == /tmp/* ]] && rm -f "$source"
            return 1
        }
    fi

    [[ "$source" == /tmp/* ]] && rm -f "$source"
    mv "$tmp" "$target"
}

_managed_settings::json_matches() {
    local file="$1" key="$2" value="$3"
    command -v jq >/dev/null 2>&1 || return 1

    local target
    target="$(_managed_settings::expand_path "$file")"
    [[ -f "$target" ]] || return 1

    if [[ "$value" == "delete" ]]; then
        jq -e --arg path "$key" 'getpath($path | split(".")) == null' "$target" >/dev/null
    else
        jq -e --arg path "$key" --argjson value "$value" 'getpath($path | split(".")) == $value' "$target" >/dev/null
    fi
}

_managed_settings::toml_key_parts() {
    local dotted="$1"
    if [[ "$dotted" == *.* ]]; then
        print -r -- "${dotted%.*}|${dotted##*.}"
    else
        print -r -- "|$dotted"
    fi
}

_managed_settings::toml_apply() {
    local file="$1" dotted="$2" value="$3"
    local target section key parts tmp
    target="$(_managed_settings::expand_path "$file")"
    parts="$(_managed_settings::toml_key_parts "$dotted")" || return 1
    section="${parts%%|*}"
    key="${parts#*|}"
    tmp="$(mktemp)"
    mkdir -p "${target:h}"

    if [[ ! -f "$target" ]]; then
        if [[ -n "$section" ]]; then
            {
                print "[$section]"
                print "$key = $value"
            } > "$tmp"
        else
            print "$key = $value" > "$tmp"
        fi
        mv "$tmp" "$target"
        return 0
    fi

    if [[ -z "$section" ]]; then
        {
            print "$key = $value"
            awk -v key="$key" '
                /^\[[^]]+\][[:space:]]*$/ { section = 1 }
                !section && $0 ~ "^[[:space:]]*" key "[[:space:]]*=" { next }
                { print }
            ' "$target"
        } > "$tmp"
        mv "$tmp" "$target"
        return 0
    fi

    awk -v wanted="$section" -v key="$key" -v value="$value" '
        function section_name(line, name) {
            name = line
            sub(/^\[/, "", name)
            sub(/\][[:space:]]*$/, "", name)
            return name
        }
        function emit_setting() {
            if (in_section && !emitted) {
                print key " = " value
                emitted = 1
            }
        }
        /^\[[^]]+\][[:space:]]*$/ {
            emit_setting()
            current = section_name($0)
            in_section = (current == wanted)
            if (in_section) {
                seen = 1
            }
            print
            next
        }
        in_section && $0 ~ "^[[:space:]]*" key "[[:space:]]*=" {
            next
        }
        { print }
        END {
            emit_setting()
            if (!seen) {
                print ""
                print "[" wanted "]"
                print key " = " value
            }
        }
    ' "$target" > "$tmp"
    mv "$tmp" "$target"
}

_managed_settings::toml_matches() {
    local file="$1" dotted="$2" value="$3"
    local target section key parts
    target="$(_managed_settings::expand_path "$file")"
    [[ -f "$target" ]] || return 1
    parts="$(_managed_settings::toml_key_parts "$dotted")" || return 1
    section="${parts%%|*}"
    key="${parts#*|}"

    awk -v wanted="$section" -v key="$key" -v expected="$value" '
        function trim(value) {
            sub(/^[[:space:]]+/, "", value)
            sub(/[[:space:]]+$/, "", value)
            return value
        }
        function section_name(line, name) {
            name = line
            sub(/^\[/, "", name)
            sub(/\][[:space:]]*$/, "", name)
            return name
        }
        /^\[[^]]+\][[:space:]]*$/ {
            section = section_name($0)
            next
        }
        section == wanted && $0 ~ "^[[:space:]]*" key "[[:space:]]*=" {
            actual = $0
            sub("^[[:space:]]*" key "[[:space:]]*=[[:space:]]*", "", actual)
            if (trim(actual) == expected) found = 1
        }
        END { exit found ? 0 : 1 }
    ' "$target"
}

_managed_settings::apply_entries() {
    local kind="$1" entry parts file key value
    local any_failed=false
    while IFS= read -r entry; do
        [[ -z "$entry" ]] && continue
        parts="$(_managed_settings::entry_parts "$entry")" || {
            any_failed=true
            continue
        }
        file="${parts%%|*}"
        parts="${parts#*|}"
        key="${parts%%|*}"
        value="${parts#*|}"
        if [[ "$kind" == "json" ]]; then
            _managed_settings::json_apply "$file" "$key" "$value" || any_failed=true
        else
            _managed_settings::toml_apply "$file" "$key" "$value" || any_failed=true
        fi
    done
    ! $any_failed
}

_managed_settings::count_drift() {
    local kind="$1" entry parts file key value drifted=0
    while IFS= read -r entry; do
        [[ -z "$entry" ]] && continue
        parts="$(_managed_settings::entry_parts "$entry")" || {
            drifted=$(( drifted + 1 ))
            continue
        }
        file="${parts%%|*}"
        parts="${parts#*|}"
        key="${parts%%|*}"
        value="${parts#*|}"
        if [[ "$kind" == "json" ]]; then
            _managed_settings::json_matches "$file" "$key" "$value" || drifted=$(( drifted + 1 ))
        else
            _managed_settings::toml_matches "$file" "$key" "$value" || drifted=$(( drifted + 1 ))
        fi
    done
    print "$drifted"
}

mod_update() {
    if [[ "$DRY_RUN" == true ]]; then
        local entry parts file
        while IFS= read -r entry; do
            [[ -z "$entry" ]] && continue
            parts="$(_managed_settings::entry_parts "$entry")" || continue
            file="${parts%%|*}"
            echo "[dry-run] configure $(_managed_settings::expand_path "$file")"
        done <<< "$(_managed_settings::json_entries)$'\n'$(_managed_settings::toml_entries)"
        primer::status_msg "settings planned"
        return 0
    fi

    _managed_settings::apply_entries json <<< "$(_managed_settings::json_entries)" || return 1
    _managed_settings::apply_entries toml <<< "$(_managed_settings::toml_entries)" || return 1
    primer::status_msg "configured"
}

mod_status() {
    local json_drift toml_drift total
    json_drift="$(_managed_settings::count_drift json <<< "$(_managed_settings::json_entries)")"
    toml_drift="$(_managed_settings::count_drift toml <<< "$(_managed_settings::toml_entries)")"
    total=$(( json_drift + toml_drift ))

    if (( total == 0 )); then
        primer::status_msg "configured"
        return 0
    fi

    primer::status_msg "${total} drifted"
    return 1
}
