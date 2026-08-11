#!/bin/zsh
# modules/agents -- agents CLI + private home and chat archive repositories

_agents::expand_path() {
    local configured="$1"
    configured="${configured##[[:space:]]#}"
    configured="${configured%%[[:space:]]#}"
    if [[ "$configured" == '~' ]]; then
        configured="$HOME"
    elif [[ "$configured" == '~/'* ]]; then
        configured="${HOME}/${configured:2}"
    fi
    print -r -- "$configured"
}

_agents::home_path() {
    local configured
    configured="$(mod_config path)"
    configured="${configured:-$HOME/.agents}"
    _agents::expand_path "$configured"
}

_agents::repo() {
    local repo
    repo="$(mod_config repo)"
    print -r -- "${repo:-tomagranate/agents-home}"
}

_agents::archive_path() {
    local configured
    configured="$(mod_config archive_path)"
    _agents::expand_path "${configured:-$HOME/.agents-archive}"
}

_agents::archive_repo() {
    local repo
    repo="$(mod_config archive_repo)"
    print -r -- "${repo:-tomagranate/chat-archive}"
}

_agents::formula() {
    local formula
    formula="$(mod_config formula)"
    print -r -- "${formula:-agents}"
}

_agents::install_method() {
    local method
    method="$(mod_config install_method)"
    method="${method:-auto}"
    print -r -- "$method"
}

_agents::cli_ok() {
    command -v agents >/dev/null 2>&1
}

_agents::install_cli() {
    local method formula
    method="$(_agents::install_method)"
    formula="$(_agents::formula)"

    if _agents::cli_ok; then
        primer::status_msg "CLI present"
        return 0
    fi

    if [[ "$DRY_RUN" == true ]]; then
        case "$method" in
            brew) echo "[dry-run] brew install tomagranate/tap/$formula" ;;
            script) echo "[dry-run] curl install.sh | SKIP_INIT=1 sh" ;;
            auto)
                if command -v brew >/dev/null 2>&1; then
                    echo "[dry-run] brew install tomagranate/tap/$formula"
                else
                    echo "[dry-run] curl install.sh | SKIP_INIT=1 sh"
                fi
                ;;
            *)
                primer::status_msg "unknown install_method: $method"
                return 1
                ;;
        esac
        return 0
    fi

    case "$method" in
        brew)
            command -v brew >/dev/null 2>&1 || {
                primer::status_msg "brew not found"
                return 1
            }
            brew install "tomagranate/tap/$formula" || return 1
            ;;
        script)
            curl -fsSL https://raw.githubusercontent.com/tomagranate/agents/main/install.sh \
                | SKIP_INIT=1 sh || return 1
            ;;
        auto)
            if command -v brew >/dev/null 2>&1; then
                brew install "tomagranate/tap/$formula" || return 1
            else
                curl -fsSL https://raw.githubusercontent.com/tomagranate/agents/main/install.sh \
                    | SKIP_INIT=1 sh || return 1
            fi
            ;;
        *)
            primer::status_msg "unknown install_method: $method"
            return 1
            ;;
    esac

    _agents::cli_ok || {
        primer::status_msg "agents CLI not on PATH after install"
        return 1
    }
}

_agents::ensure_home() {
    local home repo ssh_url https_url
    home="$(_agents::home_path)"
    repo="$(_agents::repo)"
    ssh_url="git@github.com:${repo}.git"
    https_url="https://github.com/${repo}.git"

    if [[ "$DRY_RUN" == true ]]; then
        if [[ ! -d "$home/.git" ]]; then
            echo "[dry-run] git clone $ssh_url $home"
        fi
        return 0
    fi

    if [[ -d "$home/.git" ]]; then
        primer::status_msg "agents-home present"
        return 0
    fi

    if [[ -e "$home" ]] && [[ -n "$(ls -A "$home" 2>/dev/null)" ]]; then
        # Non-empty path without .git — refuse to clobber
        primer::status_msg "exists non-git: $home"
        return 1
    fi

    mkdir -p "$(dirname "$home")"
    primer::status_msg "cloning agents-home..."
    if git clone "$ssh_url" "$home" 2>/dev/null; then
        return 0
    fi
    # Fallback for environments without SSH github access yet
    git clone "$https_url" "$home" || return 1
}

_agents::init_home() {
    if [[ "$DRY_RUN" == true ]]; then
        echo "[dry-run] AGENTS_HOME=$(_agents::home_path) agents init --no-apply"
        return 0
    fi
    AGENTS_HOME="$(_agents::home_path)" agents init --no-apply || return 1
}

_agents::ensure_archive() {
    local archive repo ssh_url
    archive="$(_agents::archive_path)"
    repo="$(_agents::archive_repo)"
    ssh_url="git@github.com:${repo}.git"

    if [[ "$DRY_RUN" == true ]]; then
        if [[ ! -d "$archive/.git" ]]; then
            echo "[dry-run] agents archive init --path $archive --remote $ssh_url"
        fi
        return 0
    fi

    if [[ -d "$archive/.git" ]]; then
        primer::status_msg "chat archive present"
        return 0
    fi
    if [[ -e "$archive" ]] && [[ -n "$(ls -A "$archive" 2>/dev/null)" ]]; then
        primer::status_msg "exists non-git: $archive"
        return 1
    fi

    mkdir -p "$(dirname "$archive")"
    primer::status_msg "initializing chat archive..."
    agents archive init --path "$archive" --remote "$ssh_url" || return 1
}

_agents::sync() {
    if [[ "$DRY_RUN" == true ]]; then
        echo "[dry-run] agents sync"
        return 0
    fi
    command -v agents >/dev/null 2>&1 || return 1
    AGENTS_HOME="$(_agents::home_path)" agents sync || return 1
}

mod_update() {
    primer::status_msg "installing CLI..."
    _agents::install_cli || return 1

    primer::status_msg "checking agents-home..."
    _agents::ensure_home || return 1

    primer::status_msg "initializing agents-home..."
    _agents::init_home || return 1

    primer::status_msg "checking chat archive..."
    _agents::ensure_archive || return 1

    primer::status_msg "syncing and wiring content..."
    _agents::sync || return 1

    primer::status_msg "configured"
}

mod_status() {
    local home repo archive archive_repo parts=()
    home="$(_agents::home_path)"
    repo="$(_agents::repo)"
    archive="$(_agents::archive_path)"
    archive_repo="$(_agents::archive_repo)"

    if ! _agents::cli_ok; then
        primer::status_msg "CLI missing"
        return 1
    fi

    if [[ ! -d "$home/.git" ]]; then
        primer::status_msg "home not a git repo"
        return 1
    fi

    if [[ ! -d "$archive/.git" ]]; then
        primer::status_msg "archive not a git repo"
        return 1
    fi

    local remote
    remote="$(git -C "$home" remote get-url origin 2>/dev/null || true)"
    if [[ "$remote" != *"$repo"* ]]; then
        parts+=("remote≠$repo")
    fi

    local archive_remote
    archive_remote="$(git -C "$archive" remote get-url origin 2>/dev/null || true)"
    if [[ "$archive_remote" != *"$archive_repo"* ]]; then
        parts+=("archive remote≠$archive_repo")
    fi

    if ! git -C "$home" diff --quiet 2>/dev/null || ! git -C "$home" diff --cached --quiet 2>/dev/null; then
        parts+=("dirty")
    fi

    # Expect shared AGENTS.md in the scoped content layout.
    if [[ ! -f "$home/shared/AGENTS.md" ]]; then
        parts+=("no shared/AGENTS.md")
    fi

    if (( ${#parts} > 0 )); then
        primer::status_msg "${(j: · :)parts}"
        return 1
    fi

    local skill_count=0
    if [[ -d "$home/shared/skills" ]]; then
        skill_count="$(find "$home/shared/skills" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l | tr -d ' ')"
    fi
    primer::status_msg "ok · ${skill_count} skills"
    return 0
}
