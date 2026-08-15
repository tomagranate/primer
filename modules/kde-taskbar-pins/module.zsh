#!/bin/zsh
# modules/kde-taskbar-pins -- Ordered KDE Plasma taskbar launchers

_kde_taskbar_pins::qdbus_command() {
    local command_name
    command_name="$(mod_config qdbus_command | head -1)"
    [[ -n "$command_name" ]] && print -r -- "$command_name" || print qdbus6
}

_kde_taskbar_pins::config_file() {
    print -r -- "${KDE_TASKBAR_CONFIG_FILE:-$HOME/.config/plasma-org.kde.plasma.desktop-appletsrc}"
}

_kde_taskbar_pins::launchers() {
    mod_config launchers
}

_kde_taskbar_pins::launcher_csv() {
    local -a launchers
    launchers=("${(@f)$(_kde_taskbar_pins::launchers)}")
    (( ${#launchers} > 0 )) || return 1
    local IFS=,
    print -r -- "${launchers[*]}"
}

_kde_taskbar_pins::launcher_json() {
    local launcher output='[' separator=''
    while IFS= read -r launcher; do
        [[ "$launcher" =~ '^[A-Za-z0-9._:/-]+$' ]] || return 1
        output+="${separator}\"${launcher}\""
        separator=,
    done < <(_kde_taskbar_pins::launchers)
    [[ -n "$separator" ]] || return 1
    print -r -- "${output}]"
}

_kde_taskbar_pins::current_launchers() {
    local config="$(_kde_taskbar_pins::config_file)"
    [[ -f "$config" ]] || return 1
    awk '
        /^\[Containments\]\[[0-9]+\]\[Applets\]\[[0-9]+\]$/ {
            applet = $0
            next
        }
        /^plugin=org\.kde\.plasma\.icontasks$/ {
            icon_tasks[applet] = 1
            next
        }
        /^\[Containments\]\[[0-9]+\]\[Applets\]\[[0-9]+\]\[Configuration\]\[General\]$/ {
            general = $0
            sub(/\[Configuration\]\[General\]$/, "", general)
            next
        }
        /^launchers=/ && icon_tasks[general] {
            sub(/^launchers=/, "")
            print
            exit
        }
    ' "$config"
}

_kde_taskbar_pins::matches() {
    local desired current
    desired="$(_kde_taskbar_pins::launcher_csv)" || return 1
    current="$(_kde_taskbar_pins::current_launchers)" || return 1
    [[ "$current" == "$desired" ]]
}

_kde_taskbar_pins::apply() {
    local qdbus_command desired_json script
    qdbus_command="$(_kde_taskbar_pins::qdbus_command)"
    desired_json="$(_kde_taskbar_pins::launcher_json)" || return 1

    if [[ "$DRY_RUN" == true ]]; then
        echo "[dry-run] set KDE taskbar launchers to $(_kde_taskbar_pins::launcher_csv)"
        return 0
    fi

    command -v "$qdbus_command" >/dev/null 2>&1 || return 1
    "$qdbus_command" org.kde.plasmashell >/dev/null 2>&1 || return 1

    script="var desired=${desired_json}; var found=0; var ps=panels(); for(var i=0;i<ps.length;i++){var ws=ps[i].widgets(); for(var j=0;j<ws.length;j++){if(ws[j].type==='org.kde.plasma.icontasks'){ws[j].currentConfigGroup=['General']; ws[j].writeConfig('launchers',desired); found++;}}} if(found===0){throw new Error('No icon task manager found');}"
    "$qdbus_command" org.kde.plasmashell /PlasmaShell \
        org.kde.PlasmaShell.evaluateScript "$script" >/dev/null 2>&1 || return 1

    local attempt=0
    while (( attempt < 20 )); do
        _kde_taskbar_pins::matches && return 0
        sleep 0.1
        attempt=$(( attempt + 1 ))
    done
    return 1
}

mod_update() {
    primer::status_msg "configuring..."
    if _kde_taskbar_pins::apply; then
        primer::status_msg "configured"
        return 0
    fi
    primer::status_msg "Plasma taskbar update failed"
    return 1
}

mod_status() {
    if _kde_taskbar_pins::matches; then
        primer::status_msg "configured"
        return 0
    fi
    primer::status_msg "launcher order differs"
    return 1
}
