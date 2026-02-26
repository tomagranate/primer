#!/bin/zsh
# modules/zsh -- Zsh configuration + Zim plugin manager

_zshrc_managed_block_file() {
    print "$MOD_DIR/files/.zshrc.managed"
}

_zshrc_start_marker() {
    print "# >>> PRIMER MANAGED START (modules/zsh/files/.zshrc.managed) >>>"
}

_zshrc_end_marker() {
    print "# <<< PRIMER MANAGED END (modules/zsh/files/.zshrc.managed) <<<"
}

_zsh::managed_zshrc_needs_update() {
    local zshrc="$HOME/.zshrc"
    local block_file="$(_zshrc_managed_block_file)"
    local start_marker="$(_zshrc_start_marker)"
    local end_marker="$(_zshrc_end_marker)"
    local extracted
    extracted="$(mktemp)"

    # Missing files definitely need an update.
    if [[ ! -f "$zshrc" || ! -f "$block_file" ]]; then
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
    ' "$zshrc" > "$extracted" 2>/dev/null
    local awk_rc=$?
    if (( awk_rc != 0 )); then
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

_zsh::zim_modules_need_sync() {
    local zim_home="$HOME/.zim"
    [[ -f "$zim_home/zimfw.zsh" ]] || return 0
    if ZDOTDIR="$HOME" ZIM_HOME="$zim_home" \
        zsh -c "source \"$zim_home/zimfw.zsh\" && zimfw check" >/dev/null 2>&1; then
        return 1
    fi
    return 0
}

_upsert_managed_zshrc_section() {
    local zshrc="$HOME/.zshrc"
    local block_file="$(_zshrc_managed_block_file)"
    local start_marker="$(_zshrc_start_marker)"
    local end_marker="$(_zshrc_end_marker)"
    local tmp="${zshrc}.tmp.$$"

    if [[ ! -f "$zshrc" ]]; then
        cp "$block_file" "$zshrc"
        return 0
    fi

    # Replace the existing managed section, or append it if not present.
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
    ' "$zshrc" > "$tmp"
    mv "$tmp" "$zshrc"
}

mod_update() {
    primer::status_msg "updating ~/.zshrc managed section..."
    if [[ "$DRY_RUN" == true ]]; then
        echo "[dry-run] update managed section in $HOME/.zshrc"
        echo "[dry-run] copy $MOD_DIR/files/.zimrc -> $HOME/.zimrc"
    else
        _upsert_managed_zshrc_section
        cp "$MOD_DIR/files/.zimrc" "$HOME/.zimrc"
    fi

    # Remove stale compiled managed configs so zsh reads fresh source files.
    local stale_zwc
    for stale_zwc in "$HOME/.zshrc.zwc" "$HOME/.zimrc.zwc"; do
        if [[ "$DRY_RUN" == true ]]; then
            echo "[dry-run] rm -f $stale_zwc"
        else
            rm -f "$stale_zwc"
        fi
    done

    # Hide "Last login ..." banner in new terminal sessions.
    local hushlogin="$HOME/.hushlogin"
    if [[ "$DRY_RUN" == true ]]; then
        echo "[dry-run] touch $hushlogin"
    else
        [[ -f "$hushlogin" ]] || touch "$hushlogin"
    fi

    # Install/update Zim
    local zim_home="$HOME/.zim"
    if [[ -d "$zim_home" ]]; then
        primer::status_msg "updating modules..."
        if [[ "$DRY_RUN" != true ]]; then
            ZDOTDIR="$HOME" ZIM_HOME="$zim_home" \
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
            ZDOTDIR="$HOME" ZIM_HOME="$zim_home" \
                zsh -c "source \"$zim_home/zimfw.zsh\" && zimfw init -q && zimfw install && zimfw compile"
        fi
        primer::status_msg "installed"
    fi
}

mod_status() {
    local missing=0 drifted=0 stale=0
    local zshrc="$HOME/.zshrc"
    local start_marker="$(_zshrc_start_marker)"
    local end_marker="$(_zshrc_end_marker)"
    local zimrc="$HOME/.zimrc"
    local zimrc_src="$MOD_DIR/files/.zimrc"
    local block_file="$(_zshrc_managed_block_file)"
    local hushlogin="$HOME/.hushlogin"

    [[ -f "$zimrc" ]] || missing=$(( missing + 1 ))
    [[ -f "$zshrc" ]] || missing=$(( missing + 1 ))
    [[ -f "$hushlogin" ]] || missing=$(( missing + 1 ))
    if [[ -f "$zshrc" ]]; then
        grep -Fq "$start_marker" "$zshrc" || missing=$(( missing + 1 ))
        grep -Fq "$end_marker" "$zshrc" || missing=$(( missing + 1 ))
    fi
    if [[ -f "$zimrc" && -f "$zimrc_src" ]] && ! cmp -s "$zimrc_src" "$zimrc"; then
        drifted=$(( drifted + 1 ))
    fi
    if [[ -f "$block_file" ]] && _zsh::managed_zshrc_needs_update; then
        drifted=$(( drifted + 1 ))
    fi
    [[ -f "$HOME/.zshrc.zwc" ]] && stale=$(( stale + 1 ))
    [[ -f "$HOME/.zimrc.zwc" ]] && stale=$(( stale + 1 ))

    # Check Zim
    local zim_home="$HOME/.zim"
    if [[ ! -d "$zim_home" ]] || [[ ! -f "$zim_home/zimfw.zsh" ]]; then
        local parts=()
        (( missing > 0 )) && parts+=("${missing} missing")
        (( drifted > 0 )) && parts+=("${drifted} drifted")
        (( stale > 0 )) && parts+=("${stale} stale")
        parts+=("zim missing")
        primer::status_msg "${(j: · :)parts}"
        return 1
    fi

    local zim_sync=0
    _zsh::zim_modules_need_sync && zim_sync=1

    if (( missing > 0 || drifted > 0 || stale > 0 || zim_sync > 0 )); then
        local parts=()
        (( missing > 0 )) && parts+=("${missing} missing")
        (( drifted > 0 )) && parts+=("${drifted} drifted")
        (( stale > 0 )) && parts+=("${stale} stale")
        (( zim_sync > 0 )) && parts+=("zim sync")
        primer::status_msg "${(j: · :)parts}"
        return 1
    fi

    primer::status_msg "up to date"
    return 0
}
