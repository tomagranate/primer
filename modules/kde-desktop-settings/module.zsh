#!/bin/zsh
# modules/kde-desktop-settings -- KDE desktop shortcuts and settings

_kde_desktop_settings::keyd_src() {
    print "$MOD_DIR/files/keyd/default.conf"
}

_kde_desktop_settings::ghostty_block_file() {
    print "$MOD_DIR/files/ghostty/keybinds.conf"
}

_kde_desktop_settings::ghostty_config() {
    print "$CONFIG_DIR/ghostty/config"
}

_kde_desktop_settings::ghostty_start_marker() {
    print "# >>> PRIMER MANAGED START (modules/kde-desktop-settings/files/ghostty/keybinds.conf) >>>"
}

_kde_desktop_settings::ghostty_end_marker() {
    print "# <<< PRIMER MANAGED END (modules/kde-desktop-settings/files/ghostty/keybinds.conf) <<<"
}

_kde_desktop_settings::run_as_root() {
    primer::run_as_root "KDE desktop settings" "$@"
}

_kde_desktop_settings::keyd_command() {
    local command_name
    command_name="$(mod_config keyd_command | head -1)"
    [[ -n "$command_name" ]] && print -r -- "$command_name" || print keyd.rvaiya
}

_kde_desktop_settings::qdbus_command() {
    local command_name
    command_name="$(mod_config qdbus_command | head -1)"
    [[ -n "$command_name" ]] && print -r -- "$command_name" || print qdbus6
}

_kde_desktop_settings::upsert_block() {
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

_kde_desktop_settings::block_needs_update() {
    local target="$1"
    local block_file="$2"
    local start_marker="$3"
    local end_marker="$4"
    local extracted
    extracted="$(mktemp)"

    if [[ ! -f "$target" || ! -f "$block_file" ]]; then
        rm -f "$extracted"
        return 0
    fi

    awk \
        -v start="$start_marker" \
        -v end="$end_marker" '
        BEGIN { in_block = 0; saw_start = 0; saw_end = 0 }
        index($0, start) { in_block = 1; saw_start = 1 }
        in_block { print }
        index($0, end) { in_block = 0; saw_end = 1 }
        END {
            if (!(saw_start && saw_end)) exit 2
        }
    ' "$target" > "$extracted" 2>/dev/null

    local rc=$?
    if (( rc != 0 )); then
        rm -f "$extracted"
        return 0
    fi

    if cmp -s "$block_file" "$extracted"; then
        rm -f "$extracted"
        return 1
    fi

    rm -f "$extracted"
    return 0
}

_kde_desktop_settings::install_keyd_config() {
    local src="$(_kde_desktop_settings::keyd_src)"
    if [[ "$DRY_RUN" == true ]]; then
        echo "[dry-run] install $src -> /etc/keyd/default.conf"
        echo "[dry-run] systemctl enable --now keyd"
        echo "[dry-run] $(_kde_desktop_settings::keyd_command) reload"
        return 0
    fi

    _kde_desktop_settings::run_as_root install -d -m 0755 /etc/keyd || return 1
    _kde_desktop_settings::run_as_root install -m 0644 "$src" /etc/keyd/default.conf || return 1
    _kde_desktop_settings::run_as_root systemctl enable --now keyd || return 1
    _kde_desktop_settings::run_as_root "$(_kde_desktop_settings::keyd_command)" reload || return 1
}

_kde_desktop_settings::install_launcher_script() {
    local user_name="${USER:-$LOGNAME}"
    local user_id qdbus_command
    user_id="$(id -u "$user_name" 2>/dev/null || id -u)"
    qdbus_command="$(_kde_desktop_settings::qdbus_command)"

    if [[ "$DRY_RUN" == true ]]; then
        echo "[dry-run] install /usr/local/bin/desktop-launcher for $user_name ($user_id) with $qdbus_command"
        return 0
    fi

    local tmp
    tmp="$(mktemp)"
    cat > "$tmp" <<EOF
#!/bin/sh
user_name=$user_name
user_id=$user_id
qdbus_command=$qdbus_command

if [ "\$(id -u)" = "\$user_id" ]; then
  exec env DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/\$user_id/bus" \\
    "\$qdbus_command" org.kde.krunner /App org.kde.krunner.App.display
fi

exec runuser -u "\$user_name" -- env \\
  DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/\$user_id/bus" \\
  "\$qdbus_command" org.kde.krunner /App org.kde.krunner.App.display
EOF

    _kde_desktop_settings::run_as_root install -m 0755 "$tmp" /usr/local/bin/desktop-launcher
    local rc=$?
    rm -f "$tmp"
    return "$rc"
}

_kde_desktop_settings::write_kwin_shortcuts() {
    local qdbus_command="$(_kde_desktop_settings::qdbus_command)"
    if [[ "$DRY_RUN" == true ]]; then
        echo "[dry-run] configure KRunner, desktop navigation, fullscreen, blur"
        return 0
    fi

    command -v kwriteconfig6 >/dev/null 2>&1 || return 0

    kwriteconfig6 --file kglobalshortcutsrc --group org.kde.krunner.desktop --key _launch $'Meta+Space\tAlt+Space,Alt+Space,Run Command'
    kwriteconfig6 --file kglobalshortcutsrc --group kwin --key 'Switch to Next Desktop' 'Ctrl+Alt+Right,Ctrl+Alt+Right,Switch to Next Desktop'
    kwriteconfig6 --file kglobalshortcutsrc --group kwin --key 'Switch to Previous Desktop' 'Ctrl+Alt+Left,Ctrl+Alt+Left,Switch to Previous Desktop'
    kwriteconfig6 --file kglobalshortcutsrc --group kwin --key 'Window Fullscreen' 'Ctrl+Alt+Shift+G,Ctrl+Alt+Shift+G,Make Window Fullscreen'
    kwriteconfig6 --file kwinrc --group Plugins --key blurEnabled true
    kwriteconfig6 --file kwinrc --group Plugins --key contrastEnabled true
    kwriteconfig6 --file kwinrc --group Effect-blur --key BlurStrength 12
    kwriteconfig6 --file kwinrc --group Effect-blur --key NoiseStrength 2

    if command -v "$qdbus_command" >/dev/null 2>&1; then
        "$qdbus_command" org.kde.KWin /KWin reconfigure >/dev/null 2>&1 || true
    fi
}

_kde_desktop_settings::ensure_virtual_desktops() {
    local desired="${1:-4}"
    local qdbus_command="$(_kde_desktop_settings::qdbus_command)"
    [[ "$desired" == <-> ]] || desired=4

    if [[ "$DRY_RUN" == true ]]; then
        echo "[dry-run] ensure ${desired} KDE virtual desktops"
        return 0
    fi
    command -v "$qdbus_command" >/dev/null 2>&1 || return 0

    local count
    count="$("$qdbus_command" org.kde.KWin /VirtualDesktopManager org.freedesktop.DBus.Properties.Get org.kde.KWin.VirtualDesktopManager count 2>/dev/null || print 0)"
    [[ "$count" == <-> ]] || count=0

    local position name
    while (( count < desired )); do
        position="$count"
        name="Desktop $(( count + 1 ))"
        "$qdbus_command" org.kde.KWin /VirtualDesktopManager org.kde.KWin.VirtualDesktopManager.createDesktop "$position" "$name" >/dev/null 2>&1 || break
        count=$(( count + 1 ))
    done

    "$qdbus_command" org.kde.KWin /KWin reconfigure >/dev/null 2>&1 || true
}

_kde_desktop_settings::configure_ghostty() {
    local target="$(_kde_desktop_settings::ghostty_config)"
    local block="$(_kde_desktop_settings::ghostty_block_file)"
    if [[ "$DRY_RUN" == true ]]; then
        echo "[dry-run] update managed Ghostty keybinding block in $target"
        return 0
    fi

    _kde_desktop_settings::upsert_block \
        "$target" \
        "$block" \
        "$(_kde_desktop_settings::ghostty_start_marker)" \
        "$(_kde_desktop_settings::ghostty_end_marker)"
}

mod_update() {
    primer::status_msg "configuring..."
    _kde_desktop_settings::install_keyd_config || return 1
    _kde_desktop_settings::install_launcher_script || return 1
    _kde_desktop_settings::write_kwin_shortcuts || return 1
    _kde_desktop_settings::ensure_virtual_desktops "$(mod_config virtual_desktops | head -1)" || return 1
    _kde_desktop_settings::configure_ghostty || return 1
    primer::status_msg "configured"
}

mod_status() {
    local issues=0

    if ! command -v "$(_kde_desktop_settings::keyd_command)" >/dev/null 2>&1; then
        issues=$(( issues + 1 ))
    elif [[ ! -f /etc/keyd/default.conf ]] || ! cmp -s "$(_kde_desktop_settings::keyd_src)" /etc/keyd/default.conf; then
        issues=$(( issues + 1 ))
    fi

    [[ -x /usr/local/bin/desktop-launcher ]] || issues=$(( issues + 1 ))

    _kde_desktop_settings::block_needs_update \
        "$(_kde_desktop_settings::ghostty_config)" \
        "$(_kde_desktop_settings::ghostty_block_file)" \
        "$(_kde_desktop_settings::ghostty_start_marker)" \
        "$(_kde_desktop_settings::ghostty_end_marker)" && issues=$(( issues + 1 ))

    if command -v kreadconfig6 >/dev/null 2>&1; then
        [[ "$(kreadconfig6 --file kglobalshortcutsrc --group kwin --key 'Window Fullscreen')" == "Ctrl+Alt+Shift+G,Ctrl+Alt+Shift+G,Make Window Fullscreen" ]] || issues=$(( issues + 1 ))
        [[ "$(kreadconfig6 --file kwinrc --group Plugins --key blurEnabled)" == "true" ]] || issues=$(( issues + 1 ))
        [[ "$(kreadconfig6 --file kwinrc --group Plugins --key contrastEnabled)" == "true" ]] || issues=$(( issues + 1 ))
    fi

    if (( issues == 0 )); then
        primer::status_msg "configured"
        return 0
    fi

    primer::status_msg "${issues} issue(s)"
    return 1
}
