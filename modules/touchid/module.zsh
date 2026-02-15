#!/bin/zsh
# modules/touchid -- Enable Touch ID for sudo

mod_update() {
    local sudo_local="/etc/pam.d/sudo_local"
    local tid_line="auth       sufficient     pam_tid.so"

    if [[ -f "$sudo_local" ]] && grep -q "pam_tid.so" "$sudo_local"; then
        primer::status_msg "already enabled"
        return 0
    fi

    primer::status_msg "enabling..."
    if [[ "$DRY_RUN" == true ]]; then
        echo "[dry-run] Enable Touch ID for sudo in $sudo_local"
    else
        echo "$tid_line" | sudo tee "$sudo_local" >/dev/null
    fi

    primer::status_msg "enabled"
}

mod_status() {
    local sudo_local="/etc/pam.d/sudo_local"

    if [[ -f "$sudo_local" ]] && grep -q "pam_tid.so" "$sudo_local"; then
        primer::status_msg "enabled"
        return 0
    fi
    primer::status_msg "not enabled"
    return 1
}
