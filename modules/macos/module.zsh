#!/bin/zsh
# modules/macos -- macOS defaults and Dock layout

_macos::default_parts() {
    local entry="$1"
    local -a parts
    parts=(${(s.:.)entry})
    [[ ${#parts[@]} -eq 4 ]] || return 1
    print -r -- "${parts[1]}:${parts[2]}:${parts[3]}:${parts[4]}"
}

_macos::write_default() {
    local domain="$1" key="$2" type="$3" value="$4"
    case "$type" in
        bool) defaults write "$domain" "$key" -bool "$value" ;;
        int) defaults write "$domain" "$key" -int "$value" ;;
        float) defaults write "$domain" "$key" -float "$value" ;;
        string) defaults write "$domain" "$key" -string "$value" ;;
        *) return 1 ;;
    esac
}

_macos::read_default() {
    local domain="$1" key="$2"
    defaults read "$domain" "$key" 2>/dev/null
}

_macos::expand_path() {
    local path="$1"
    if [[ "$path" == \~/* ]]; then
        print "$HOME/${path#\~/}"
    else
        print "$path"
    fi
}

_macos::screenshot_location() {
    local configured="$(mod_config screenshot_location | head -1)"
    [[ -z "$configured" ]] && return 0
    _macos::expand_path "$configured"
}

_macos::configure_screenshots() {
    local location="$(_macos::screenshot_location)"
    [[ -z "$location" ]] && return 0
    mkdir -p "$location" || return 1
    defaults write com.apple.screencapture location -string "$location"
}

_macos::normalise_default_value() {
    local type="$1" value="$2"
    case "$type:$value" in
        bool:true|bool:TRUE|bool:True|bool:1) print "true" ;;
        bool:false|bool:FALSE|bool:False|bool:0) print "false" ;;
        *) print "$value" ;;
    esac
}

_macos::app_name() {
    local path="$1"
    local name="${path:t}"
    print "${name%.app}"
}

_macos::dock_default_apps() {
    cat <<'EOF'
/Applications/Safari.app
/System/Applications/Apps.app
/System/Applications/App Store.app
/System/Applications/Calendar.app
/System/Applications/Contacts.app
/System/Applications/FaceTime.app
/System/Applications/Freeform.app
/System/Applications/Mail.app
/System/Applications/Maps.app
/System/Applications/Messages.app
/System/Applications/Music.app
/System/Applications/News.app
/System/Applications/Notes.app
/System/Applications/Photos.app
/System/Applications/Podcasts.app
/System/Applications/Reminders.app
/System/Applications/System Settings.app
/System/Applications/TV.app
EOF
}

_macos::list_contains_line() {
    local needle="$1"
    local line
    while IFS= read -r line; do
        [[ "$line" == "$needle" ]] && return 0
    done
    return 1
}

_macos::apply_defaults() {
    local entry domain key type value
    while IFS= read -r entry; do
        [[ -z "$entry" ]] && continue
        if ! _macos::default_parts "$entry" >/dev/null; then
            primer::status_msg "invalid default: $entry"
            return 1
        fi
        domain="${entry%%:*}"
        entry="${entry#*:}"
        key="${entry%%:*}"
        entry="${entry#*:}"
        type="${entry%%:*}"
        value="${entry#*:}"
        _macos::write_default "$domain" "$key" "$type" "$value" || return 1
    done <<< "$(mod_config defaults)"
}

_macos::configure_dock() {
    local app desired_apps
    command -v dockutil >/dev/null 2>&1 || return 1
    desired_apps="$(mod_config dock_apps)"

    while IFS= read -r app; do
        [[ -z "$app" ]] && continue
        _macos::list_contains_line "$app" <<< "$desired_apps" && continue
        dockutil --remove "$(_macos::app_name "$app")" --no-restart >/dev/null 2>&1 || true
    done <<< "$(_macos::dock_default_apps)"

    while IFS= read -r app; do
        [[ -z "$app" ]] && continue
        [[ -e "$app" ]] || continue
        if dockutil --find "$(_macos::app_name "$app")" >/dev/null 2>&1; then
            dockutil --move "$(_macos::app_name "$app")" --position end --no-restart >/dev/null
        else
            dockutil --add "$app" --no-restart >/dev/null
        fi
    done <<< "$(mod_config dock_apps)"
}

_macos::network_services() {
    networksetup -listallnetworkservices 2>/dev/null | sed '1d; /^\*/d; /^$/d'
}

_macos::configure_dns() {
    local servers=($(mod_config dns_servers))
    (( ${#servers[@]} > 0 )) || return 0
    local service
    _macos::network_services | while IFS= read -r service; do
        [[ -z "$service" ]] && continue
        networksetup -setdnsservers "$service" "${servers[@]}" || return 1
    done
}

_macos::dns_matches() {
    local service="$1"
    local expected=($(mod_config dns_servers))
    local actual=($(networksetup -getdnsservers "$service" 2>/dev/null | grep -E '^[0-9a-fA-F:.]+$'))
    [[ "${(j: :)actual}" == "${(j: :)expected}" ]]
}

_macos::default_browser() {
    mod_config default_browser | head -1
}

_macos::configure_default_browser() {
    local browser="$(_macos::default_browser)"
    [[ -z "$browser" ]] && return 0
    command -v defaultbrowser >/dev/null 2>&1 || return 1
    defaultbrowser "$browser" >/dev/null
}

_macos::default_browser_matches() {
    local browser="$(_macos::default_browser)"
    [[ -z "$browser" ]] && return 0
    command -v defaultbrowser >/dev/null 2>&1 || return 1
    local current="$(defaultbrowser 2>/dev/null | head -1)"
    [[ "$current" == "$browser" || "$current" == *"$browser"* ]]
}

mod_update() {
    primer::status_msg "configuring settings..."

    if [[ "$DRY_RUN" == true ]]; then
        local entry app service servers browser screenshot_location
        while IFS= read -r entry; do
            [[ -z "$entry" ]] && continue
            echo "[dry-run] defaults write ${entry}"
        done <<< "$(mod_config defaults)"
        screenshot_location="$(_macos::screenshot_location)"
        if [[ -n "$screenshot_location" ]]; then
            echo "[dry-run] mkdir -p $screenshot_location"
            echo "[dry-run] defaults write com.apple.screencapture location -string $screenshot_location"
        fi
        if [[ -n "$(mod_config dock_apps)" ]]; then
            while IFS= read -r app; do
                [[ -z "$app" ]] && continue
                _macos::list_contains_line "$app" <<< "$(mod_config dock_apps)" && continue
                echo "[dry-run] dockutil --remove $(_macos::app_name "$app") --no-restart"
            done <<< "$(_macos::dock_default_apps)"
            while IFS= read -r app; do
                [[ -z "$app" ]] && continue
                [[ -e "$app" ]] || { echo "[dry-run] skip missing Dock app $app"; continue; }
                echo "[dry-run] dockutil --add $app --no-restart"
            done <<< "$(mod_config dock_apps)"
            echo "[dry-run] killall Dock"
        fi
        servers="$(mod_config dns_servers | tr '\n' ' ' | sed 's/[[:space:]]*$//')"
        if [[ -n "$servers" ]]; then
            while IFS= read -r service; do
                [[ -z "$service" ]] && continue
                echo "[dry-run] networksetup -setdnsservers $service $servers"
            done <<< "$(_macos::network_services)"
        fi
        browser="$(_macos::default_browser)"
        [[ -n "$browser" ]] && echo "[dry-run] defaultbrowser $browser"
        primer::status_msg "configured"
        return 0
    fi

    _macos::apply_defaults || return 1
    _macos::configure_screenshots || return 1

    if [[ -n "$(mod_config dock_apps)" ]]; then
        primer::status_msg "configuring Dock..."
        _macos::configure_dock || return 1
        killall Dock >/dev/null 2>&1 || true
    fi

    if [[ -n "$(mod_config dns_servers)" ]]; then
        primer::status_msg "configuring DNS..."
        _macos::configure_dns || return 1
    fi

    if [[ -n "$(_macos::default_browser)" ]]; then
        primer::status_msg "configuring browser..."
        _macos::configure_default_browser || return 1
    fi

    killall Finder >/dev/null 2>&1 || true
    killall SystemUIServer >/dev/null 2>&1 || true
    primer::status_msg "configured"
}

mod_status() {
    local missing=0 drifted=0 entry domain key type expected actual app service screenshot_location

    while IFS= read -r entry; do
        [[ -z "$entry" ]] && continue
        domain="${entry%%:*}"
        entry="${entry#*:}"
        key="${entry%%:*}"
        entry="${entry#*:}"
        type="${entry%%:*}"
        expected="$(_macos::normalise_default_value "$type" "${entry#*:}")"
        actual="$(_macos::normalise_default_value "$type" "$(_macos::read_default "$domain" "$key")")"
        [[ "$actual" == "$expected" ]] || drifted=$(( drifted + 1 ))
    done <<< "$(mod_config defaults)"

    screenshot_location="$(_macos::screenshot_location)"
    if [[ -n "$screenshot_location" ]]; then
        [[ -d "$screenshot_location" ]] || missing=$(( missing + 1 ))
        actual="$(_macos::read_default com.apple.screencapture location)"
        [[ "$actual" == "$screenshot_location" ]] || drifted=$(( drifted + 1 ))
    fi

    if [[ -n "$(mod_config dock_apps)" ]]; then
        if ! command -v dockutil >/dev/null 2>&1; then
            missing=$(( missing + 1 ))
        else
            while IFS= read -r app; do
                [[ -z "$app" ]] && continue
                [[ -e "$app" ]] || continue
                dockutil --find "$(_macos::app_name "$app")" >/dev/null 2>&1 || drifted=$(( drifted + 1 ))
            done <<< "$(mod_config dock_apps)"
        fi
    fi

    if [[ -n "$(mod_config dns_servers)" ]]; then
        if ! command -v networksetup >/dev/null 2>&1; then
            missing=$(( missing + 1 ))
        else
            while IFS= read -r service; do
                [[ -z "$service" ]] && continue
                _macos::dns_matches "$service" || drifted=$(( drifted + 1 ))
            done <<< "$(_macos::network_services)"
        fi
    fi

    if [[ -n "$(_macos::default_browser)" ]]; then
        _macos::default_browser_matches || drifted=$(( drifted + 1 ))
    fi

    if (( missing == 0 && drifted == 0 )); then
        primer::status_msg "configured"
        return 0
    fi

    local parts=()
    (( missing > 0 )) && parts+=("${missing} missing")
    (( drifted > 0 )) && parts+=("${drifted} drifted")
    primer::status_msg "${(j: · :)parts}"
    return 1
}
