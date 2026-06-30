#!/bin/zsh
# modules/git -- Git CLI config + extension scripts

_git::config_entries() {
    mod_config settings
}

_git::config_parts() {
    local entry="$1"
    [[ "$entry" == *:* ]] || return 1
    local key="${entry%%:*}"
    local value="${entry#*:}"
    [[ -n "$key" && -n "$value" ]] || return 1
    print -r -- "$key:$value"
}

_git::apply_config() {
    local entry key value
    while IFS= read -r entry; do
        [[ -z "$entry" ]] && continue
        if ! _git::config_parts "$entry" >/dev/null; then
            primer::status_msg "invalid setting: $entry"
            return 1
        fi
        key="${entry%%:*}"
        value="${entry#*:}"
        git config --global "$key" "$value" || return 1
    done <<< "$(_git::config_entries)"
}

_git::config_mismatch_count() {
    local entry key expected actual mismatched=0
    while IFS= read -r entry; do
        [[ -z "$entry" ]] && continue
        if ! _git::config_parts "$entry" >/dev/null; then
            mismatched=$(( mismatched + 1 ))
            continue
        fi
        key="${entry%%:*}"
        expected="${entry#*:}"
        actual="$(git config --global --get "$key" 2>/dev/null || true)"
        [[ "$actual" == "$expected" ]] || mismatched=$(( mismatched + 1 ))
    done <<< "$(_git::config_entries)"
    print "$mismatched"
}

mod_update() {
    primer::status_msg "configuring Git..."
    if [[ "$DRY_RUN" == true ]]; then
        local entry key value
        while IFS= read -r entry; do
            [[ -z "$entry" ]] && continue
            key="${entry%%:*}"
            value="${entry#*:}"
            echo "[dry-run] git config --global $key $value"
        done <<< "$(_git::config_entries)"
    else
        _git::apply_config || return 1
    fi

    deploy_scripts "$BIN_DIR"
    primer::status_msg "configured"
}

mod_status() {
    local total=0 missing=0 drifted=0 nonexec=0
    local src dst
    for src in "$MOD_DIR"/bin/*(N); do
        total=$(( total + 1 ))
        dst="$BIN_DIR/${src:t}"
        if [[ ! -f "$dst" ]]; then
            missing=$(( missing + 1 ))
            continue
        fi
        [[ -x "$dst" ]] || nonexec=$(( nonexec + 1 ))
        cmp -s "$src" "$dst" || drifted=$(( drifted + 1 ))
    done

    local config_mismatched=0
    if command -v git >/dev/null 2>&1; then
        config_mismatched="$(_git::config_mismatch_count)"
    else
        config_mismatched=1
    fi

    if (( total == 0 && config_mismatched == 0 )); then
        primer::status_msg "configured"
        return 0
    fi

    if (( missing == 0 && drifted == 0 && nonexec == 0 && config_mismatched == 0 )); then
        primer::status_msg "configured · $total scripts"
        return 0
    fi

    local parts=()
    (( config_mismatched > 0 )) && parts+=("${config_mismatched} settings")
    (( missing > 0 )) && parts+=("${missing} missing")
    (( drifted > 0 )) && parts+=("${drifted} drifted")
    (( nonexec > 0 )) && parts+=("${nonexec} perms")
    primer::status_msg "${(j: · :)parts}"
    return 1
}
