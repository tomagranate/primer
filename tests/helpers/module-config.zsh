# Minimal config loader for shell module tests. Production config parsing lives
# in app/src/config.ts; modules receive the resulting associative array.
typeset -gA _mod_config=()

test::load_module_config() {
    local config section="" key="" line
    _mod_config=()
    for config in "$@"; do
        while IFS= read -r line; do
            [[ "$line" =~ ^[[:space:]]*# || -z "${line// /}" ]] && continue
            if [[ "$line" =~ '^\[([a-z0-9_-]+)\]' ]]; then
                section="${match[1]}"
                key=""
            elif [[ "$line" =~ '^[[:space:]]+(.+)' && -n "$section" && -n "$key" ]]; then
                _mod_config[${section}.${key}]+=$'\n'"${match[1]}"
            elif [[ "$line" =~ '^([a-z_-]+)[[:space:]]*=[[:space:]]*(.*)' && -n "$section" ]]; then
                key="${match[1]}"
                _mod_config[${section}.${key}]="${match[2]}"
            fi
        done < "$config"
    done
}
