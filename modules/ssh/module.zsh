#!/bin/zsh
# modules/ssh -- SSH key generation + macOS keychain-backed agent config

_ssh::config_start_marker() {
    print "# >>> PRIMER MANAGED START (modules/ssh) >>>"
}

_ssh::config_end_marker() {
    print "# <<< PRIMER MANAGED END (modules/ssh) <<<"
}

_ssh::expand_path() {
    local path="$1"
    if [[ "$path" == \~/* ]]; then
        print "$HOME/${path#\~/}"
    else
        print "$path"
    fi
}

_ssh::key_path() {
    local configured="$(mod_config key_path | head -1)"
    [[ -z "$configured" ]] && configured="~/.ssh/id_ed25519"
    _ssh::expand_path "$configured"
}

_ssh::key_comment() {
    local configured="$(mod_config comment | head -1)"
    [[ -n "$configured" ]] && { print "$configured"; return 0; }
    print "${USER:-primer}@$(hostname -s 2>/dev/null || hostname 2>/dev/null || print mac)"
}

_ssh::config_block() {
    local key_path="$1"
    local start_marker="$(_ssh::config_start_marker)"
    local end_marker="$(_ssh::config_end_marker)"
    print "$start_marker"
    print "Host *"
    print "    AddKeysToAgent yes"
    print "    UseKeychain yes"
    print "    IdentityFile $key_path"
    print "$end_marker"
}

_ssh::upsert_config_block() {
    local config_file="$HOME/.ssh/config"
    local key_path="$1"
    local start_marker="$(_ssh::config_start_marker)"
    local end_marker="$(_ssh::config_end_marker)"
    local block_file tmp
    block_file="$(mktemp)"
    tmp="${config_file}.tmp.$$"
    _ssh::config_block "$key_path" > "$block_file"

    if [[ ! -f "$config_file" ]]; then
        cp "$block_file" "$config_file"
        chmod 600 "$config_file"
        rm -f "$block_file"
        return 0
    fi

    awk \
        -v start="$start_marker" \
        -v end="$end_marker" \
        -v block_file="$block_file" '
        BEGIN {
            in_block = 0
            replaced = 0
            while ((getline line < block_file) > 0) {
                block = block line ORS
            }
            close(block_file)
        }
        index($0, start) {
            if (!replaced) {
                printf "%s", block
                replaced = 1
            }
            in_block = 1
            next
        }
        index($0, end) {
            in_block = 0
            next
        }
        !in_block { print }
        END {
            if (!replaced) {
                if (NR > 0) print ""
                printf "%s", block
            }
        }
    ' "$config_file" > "$tmp"
    mv "$tmp" "$config_file"
    chmod 600 "$config_file"
    rm -f "$block_file"
}

_ssh::config_needs_update() {
    local config_file="$HOME/.ssh/config"
    local key_path="$1"
    local start_marker="$(_ssh::config_start_marker)"
    local end_marker="$(_ssh::config_end_marker)"
    local expected extracted
    expected="$(mktemp)"
    extracted="$(mktemp)"
    _ssh::config_block "$key_path" > "$expected"

    if [[ ! -f "$config_file" ]]; then
        rm -f "$expected" "$extracted"
        return 0
    fi

    awk \
        -v start="$start_marker" \
        -v end="$end_marker" '
        BEGIN { in_block = 0; saw_start = 0; saw_end = 0 }
        index($0, start) { in_block = 1; saw_start = 1 }
        in_block { print }
        index($0, end) { in_block = 0; saw_end = 1 }
        END { if (!(saw_start && saw_end)) exit 2 }
    ' "$config_file" > "$extracted" 2>/dev/null
    local awk_rc=$?
    if (( awk_rc != 0 )); then
        rm -f "$expected" "$extracted"
        return 0
    fi

    if cmp -s "$expected" "$extracted"; then
        rm -f "$expected" "$extracted"
        return 1
    fi
    rm -f "$expected" "$extracted"
    return 0
}

_ssh::add_key_to_agent() {
    local key_path="$1"
    ssh-add --apple-use-keychain "$key_path" >/dev/null 2>&1 \
        || ssh-add -K "$key_path" >/dev/null 2>&1 \
        || ssh-add "$key_path" >/dev/null 2>&1
}

mod_update() {
    local key_path="$(_ssh::key_path)"
    local key_dir="${key_path:h}"
    local comment="$(_ssh::key_comment)"

    primer::status_msg "configuring..."
    if [[ "$DRY_RUN" == true ]]; then
        [[ -f "$key_path" ]] || echo "[dry-run] ssh-keygen -t ed25519 -C $comment -f $key_path"
        echo "[dry-run] update $HOME/.ssh/config"
        echo "[dry-run] ssh-add --apple-use-keychain $key_path"
        primer::status_msg "configured"
        return 0
    fi

    mkdir -p "$key_dir"
    chmod 700 "$key_dir"
    if [[ ! -f "$key_path" ]]; then
        primer::status_msg "generating key..."
        ssh-keygen -t ed25519 -C "$comment" -f "$key_path" -N "" >/dev/null
    fi
    chmod 600 "$key_path"
    [[ -f "${key_path}.pub" ]] && chmod 644 "${key_path}.pub"

    _ssh::upsert_config_block "$key_path"
    primer::status_msg "adding to keychain..."
    _ssh::add_key_to_agent "$key_path" || true
    primer::status_msg "configured"
}

mod_status() {
    local key_path="$(_ssh::key_path)"
    local missing=0 drifted=0

    [[ -f "$key_path" ]] || missing=$(( missing + 1 ))
    [[ -f "${key_path}.pub" ]] || missing=$(( missing + 1 ))
    _ssh::config_needs_update "$key_path" && drifted=$(( drifted + 1 ))

    if (( missing == 0 && drifted == 0 )); then
        primer::status_msg "configured"
        return 0
    fi

    local parts=()
    (( missing > 0 )) && parts+=("${missing} missing")
    (( drifted > 0 )) && parts+=("config drifted")
    primer::status_msg "${(j: · :)parts}"
    return 1
}
