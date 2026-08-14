#!/bin/zsh
# modules/ghostty -- Ghostty terminal configuration

mod_update() {
    deploy_files "$CONFIG_DIR"
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
            in_kde_block = 1
            next
        }
        /^# <<< PRIMER MANAGED END \(modules\/kde-desktop-settings\/files\/ghostty\/keybinds\.conf\) <<<$/{
            in_kde_block = 0
            next
        }
        !in_kde_block { lines[++count] = $0 }
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
    if _ghostty::config_matches; then
        primer::status_msg "synced (1 files)"
        return 0
    fi

    primer::status_msg "1 drifted"
    return 1
}
