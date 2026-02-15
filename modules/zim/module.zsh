#!/bin/zsh
# modules/zim -- Zsh configuration + Zim plugin manager

mod_update() {
    # Deploy zsh config files to ZDOTDIR
    primer::status_msg "deploying configs..."
    deploy_files "$ZSH_CONFIG_DIR"

    # Hide "Last login ..." banner in new terminal sessions.
    local hushlogin="$HOME/.hushlogin"
    if [[ "$DRY_RUN" == true ]]; then
        echo "[dry-run] touch $hushlogin"
    else
        [[ -f "$hushlogin" ]] || touch "$hushlogin"
    fi

    # Symlink ~/.zshenv -> $ZSH_CONFIG_DIR/.zshenv
    local target="$ZSH_CONFIG_DIR/.zshenv" link="$HOME/.zshenv"
    if [[ ! -L "$link" ]] || [[ "$(readlink "$link")" != "$target" ]]; then
        if [[ -f "$link" && ! -L "$link" ]]; then
            echo "Backing up existing .zshenv to .zshenv.bak"
            mv "$link" "${link}.bak"
        fi
        ln -sf "$target" "$link"
    fi

    # Install/update Zim
    local zim_home="$HOME/.zim"
    if [[ -d "$zim_home" ]]; then
        primer::status_msg "updating modules..."
        if [[ "$DRY_RUN" != true ]]; then
            ZDOTDIR="$ZSH_CONFIG_DIR" ZIM_HOME="$zim_home" \
                zsh -c "source \"$zim_home/zimfw.zsh\" && zimfw install && zimfw compile" \
                2>/dev/null || true
        else
            echo "[dry-run] zimfw install && zimfw compile"
        fi
        primer::status_msg "modules updated"
    else
        primer::status_msg "installing..."
        if [[ "$DRY_RUN" == true ]]; then
            echo "[dry-run] Install Zim"
        else
            mkdir -p "$zim_home"
            curl -fsSL --create-dirs -o "$zim_home/zimfw.zsh" \
                https://github.com/zimfw/zimfw/releases/latest/download/zimfw.zsh
            ZDOTDIR="$ZSH_CONFIG_DIR" ZIM_HOME="$zim_home" \
                zsh -c "source \"$zim_home/zimfw.zsh\" && zimfw init -q && zimfw install && zimfw compile"
        fi
        primer::status_msg "installed"
    fi
}

mod_status() {
    # Check zsh config files
    local missing=0
    local src rel
    for src in "$MOD_DIR"/files/*(.N); do
        rel="${src:t}"
        [[ -f "$ZSH_CONFIG_DIR/$rel" ]] || missing=$(( missing + 1 ))
    done

    # Check .zshenv symlink
    local target="$ZSH_CONFIG_DIR/.zshenv" link="$HOME/.zshenv"
    if [[ ! -L "$link" ]] || [[ "$(readlink "$link")" != "$target" ]]; then
        missing=$(( missing + 1 ))
    fi

    # Check Zim
    local zim_home="$HOME/.zim"
    if [[ ! -d "$zim_home" ]] || [[ ! -f "$zim_home/zimfw.zsh" ]]; then
        primer::status_msg "not installed"
        return 1
    fi

    if (( missing > 0 )); then
        primer::status_msg "$missing configs missing"
        return 1
    fi

    primer::status_msg "installed"
    return 0
}
