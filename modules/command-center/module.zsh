#!/bin/zsh
# modules/command-center -- build the app and register its gateway route.

_command_center::repo() {
    local repo_path
    repo_path="$(mod_config repo_path | head -1)"
    print -r -- "${repo_path/#\~/$HOME}"
}

_command_center::route_helper() {
    print -r -- "${CADDY_ROUTE_HELPER:-/usr/local/libexec/primer-caddy-route}"
}

_command_center::root() {
    local reason="$1"
    shift
    primer::run_as_root "$reason" "$@"
}

# Keep local work and unexpected repositories intact.
_command_center::update_source() {
    local repo="$(_command_center::repo)" remote branch dirty
    if [[ ! -e "$repo" ]]; then
        mkdir -p "${repo:h}" || return 1
        git clone --branch master --single-branch git@github.com:tomagranate/command-center.git "$repo" || return 1
    fi
    [[ -d "$repo/.git" || -f "$repo/.git" ]] || { print 'Command Center path is not a checkout.' >&2; return 1; }
    remote="$(git -C "$repo" config --get-all remote.origin.url)" || return 1
    case "$remote" in
        git@github.com:tomagranate/command-center.git|https://github.com/tomagranate/command-center.git) ;;
        *) print 'Command Center has an unexpected remote.' >&2; return 1 ;;
    esac
    dirty="$(git -C "$repo" status --porcelain)" || {
        print 'Cannot read Command Center checkout status.' >&2
        return 1
    }
    [[ -z "$dirty" ]] || { print 'Command Center checkout is dirty.' >&2; return 1; }
    branch="$(git -C "$repo" branch --show-current)" || return 1
    [[ "$branch" == master ]] || { print 'Command Center checkout must use master.' >&2; return 1; }
    git -C "$repo" fetch origin master || return 1
    git -C "$repo" merge-base --is-ancestor HEAD origin/master || {
        print 'Command Center has local commits. Cannot fast-forward.' >&2
        return 1
    }
    git -C "$repo" merge --ff-only origin/master
}

_command_center::build() {
    (
        cd "$(_command_center::repo)" || exit 1
        mise trust .mise.toml && mise install \
            && mise exec -- pnpm install --frozen-lockfile \
            && mise exec -- pnpm build
    )
}

# Build before changing the running service or its route.
mod_update() {
    local repo="$(_command_center::repo)" unit_dir="$HOME/.config/systemd/user"
    if [[ "$DRY_RUN" == true ]]; then
        print "[dry-run] verify clean source and fast-forward $repo on master"
        print '[dry-run] pnpm install --frozen-lockfile; pnpm build'
        print '[dry-run] install changed command-center.service and restart it'
        print '[dry-run] install Caddy route command-center'
        primer::status_msg 'update planned'
        return 0
    fi
    _command_center::update_source || return 1
    _command_center::build || {
        print 'Command Center build failed. The service was not restarted.' >&2
        primer::status_msg 'build failed'
        return 1
    }
    [[ -f "$repo/dist/server.mjs" && -f "$repo/deploy/command-center.service" && -f "$repo/deploy/command-center.caddy" ]] || {
        print 'Command Center build or deploy files are missing.' >&2
        return 1
    }
    mkdir -p "$unit_dir" || return 1
    if ! cmp -s "$repo/deploy/command-center.service" "$unit_dir/command-center.service"; then
        install -m 0644 "$repo/deploy/command-center.service" "$unit_dir/command-center.service" || return 1
        systemctl --user daemon-reload || return 1
    fi
    _command_center::root 'enable Command Center at boot' loginctl enable-linger "${USER:-$LOGNAME}" || return 1
    systemctl --user enable command-center.service || return 1
    systemctl --user restart command-center.service || return 1
    systemctl --user is-active --quiet command-center.service || {
        print 'Command Center service is not active.' >&2
        return 1
    }
    _command_center::root 'install Command Center route' \
        "$(_command_center::route_helper)" install command-center "$repo/deploy/command-center.caddy" || return 1
    primer::status_msg 'Command Center ready'
}

# Check service and route state without using the host's own Tailscale identity.
mod_status() {
    local repo="$(_command_center::repo)"
    if systemctl --user is-active --quiet command-center.service \
        && "$(_command_center::route_helper)" status command-center "$repo/deploy/command-center.caddy"; then
        primer::status_msg 'Command Center ready'
        return 0
    fi
    primer::status_msg 'service or route not ready'
    return 1
}
