#!/bin/zsh
# modules/ghostty -- Ghostty terminal configuration

_ghostty::linux_block_file() {
    print "$MOD_DIR/linux.conf"
}

_ghostty::linux_start_marker() {
    print "# >>> PRIMER MANAGED START (modules/ghostty/linux.conf) >>>"
}

_ghostty::linux_end_marker() {
    print "# <<< PRIMER MANAGED END (modules/ghostty/linux.conf) <<<"
}

_ghostty::upsert_block() {
    local target="$1"
    local block_file="$2"
    local start_marker="$3"
    local end_marker="$4"
    local tmp="${target}.tmp.$$"

    mkdir -p "${target:h}"
    if [[ ! -f "$target" ]]; then
        cp "$block_file" "$target"
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
    ' "$target" > "$tmp"
    mv "$tmp" "$target"
}

_ghostty::remove_block() {
    local target="$1"
    local start_marker="$2"
    local end_marker="$3"
    local tmp="${target}.tmp.$$"
    [[ -f "$target" ]] || return 0

    awk \
        -v start="$start_marker" \
        -v end="$end_marker" '
        index($0, start) { in_block = 1; next }
        index($0, end) { in_block = 0; next }
        !in_block { print }
    ' "$target" > "$tmp"
    mv "$tmp" "$target"
}

_ghostty::configure_linux_command() {
    local target="$CONFIG_DIR/ghostty/config"
    if [[ "$(uname -s)" == Linux ]]; then
        _ghostty::upsert_block \
            "$target" \
            "$(_ghostty::linux_block_file)" \
            "$(_ghostty::linux_start_marker)" \
            "$(_ghostty::linux_end_marker)"
        return $?
    fi
    _ghostty::remove_block \
        "$target" \
        "$(_ghostty::linux_start_marker)" \
        "$(_ghostty::linux_end_marker)"
}

_ghostty::linux_command_matches() {
    [[ "$(uname -s)" != Linux ]] && return 0
    local target="$CONFIG_DIR/ghostty/config"
    local extracted
    extracted="$(mktemp)" || return 1
    awk \
        -v start="$(_ghostty::linux_start_marker)" \
        -v end="$(_ghostty::linux_end_marker)" '
        BEGIN { in_block = 0; saw_start = 0; saw_end = 0 }
        index($0, start) { in_block = 1; saw_start = 1 }
        in_block { print }
        index($0, end) { in_block = 0; saw_end = 1 }
        END { if (!(saw_start && saw_end)) exit 2 }
    ' "$target" > "$extracted" 2>/dev/null
    local rc=$?
    if (( rc != 0 )); then
        rm -f "$extracted"
        return 1
    fi
    cmp -s "$(_ghostty::linux_block_file)" "$extracted"
    rc=$?
    rm -f "$extracted"
    return "$rc"
}

mod_update() {
    deploy_files "$CONFIG_DIR"
    if [[ "$DRY_RUN" == true ]]; then
        if [[ "$(uname -s)" == Linux ]]; then
            echo "[dry-run] set Ghostty command = zsh"
        fi
        primer::status_msg "configured"
        return 0
    fi
    _ghostty::configure_linux_command || return 1
    primer::status_msg "configured"
}

_ghostty::config_matches() {
    local source="$MOD_DIR/files/ghostty/config"
    local target="$CONFIG_DIR/ghostty/config"
    [[ -f "$target" ]] || return 1

    local filtered
    filtered="$(mktemp)" || return 1
    awk '
        /^# >>> PRIMER MANAGED START \(modules\/kde-desktop-settings\/files\/ghostty\/keybinds\.conf\) >>>$/ {
            in_extra = 1
            next
        }
        /^# <<< PRIMER MANAGED END \(modules\/kde-desktop-settings\/files\/ghostty\/keybinds\.conf\) <<<$/{
            in_extra = 0
            next
        }
        /^# >>> PRIMER MANAGED START \(modules\/ghostty\/linux\.conf\) >>>$/ {
            in_extra = 1
            next
        }
        /^# <<< PRIMER MANAGED END \(modules\/ghostty\/linux\.conf\) <<<$/{
            in_extra = 0
            next
        }
        !in_extra { lines[++count] = $0 }
        END {
            while (count > 0 && lines[count] == "") count--
            for (line = 1; line <= count; line++) print lines[line]
        }
    ' "$target" > "$filtered"

    cmp -s "$source" "$filtered"
    local rc=$?
    rm -f "$filtered"
    return "$rc"
}

mod_status() {
    if _ghostty::config_matches && _ghostty::linux_command_matches; then
        primer::status_msg "synced (1 files)"
        return 0
    fi

    primer::status_msg "1 drifted"
    return 1
}
