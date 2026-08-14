#!/bin/sh
# primer -- https://github.com/tomagranate/primer
#
# Bootstrap: installs the primer CLI, then runs `primer update`.
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/tomagranate/primer/master/setup.sh | sh
#   curl -fsSL https://raw.githubusercontent.com/tomagranate/primer/master/setup.sh | sh -s -- --dry-run
set -e

REPO_RAW="https://raw.githubusercontent.com/tomagranate/primer/master"
BIN_DIR="$HOME/bin"

run_as_root() {
    if [ "$(id -u)" -eq 0 ]; then
        "$@"
    elif command -v sudo >/dev/null 2>&1; then
        sudo "$@"
    else
        printf "sudo is required for this setup step\n" >&2
        return 1
    fi
}

path_has_dir() {
    case ":$PATH:" in
        *":$1:"*) return 0 ;;
        *) return 1 ;;
    esac
}

write_primer_shim() {
    shim="$1/primer"

    if [ -e "$shim" ] && [ ! -L "$shim" ]; then
        return 1
    fi

    ln -sf "$BIN_DIR/primer" "$shim"
}

write_primer_shim_as_root() {
    dir="$1"
    shim="$dir/primer"

    if [ -e "$shim" ] && [ ! -L "$shim" ]; then
        return 1
    fi

    run_as_root ln -sf "$BIN_DIR/primer" "$shim"
}

ensure_primer_command() {
    if command -v primer >/dev/null 2>&1; then
        return 0
    fi

    # A piped bootstrap cannot update the parent shell's PATH. Install a shim
    # into an existing PATH directory so `primer update` works after failures.
    old_ifs="$IFS"
    IFS=:
    for dir in $PATH; do
        IFS="$old_ifs"
        [ -n "$dir" ] || continue
        case "$dir" in
            "$HOME"/*|/usr/local/bin)
                if [ -d "$dir" ] && [ -w "$dir" ] && write_primer_shim "$dir"; then
                    printf "\033[1;32m  ✓\033[0m primer command available at %s/primer\n" "$dir"
                    return 0
                fi
                ;;
        esac
        IFS=:
    done
    IFS="$old_ifs"

    if path_has_dir /usr/local/bin; then
        if [ ! -d /usr/local/bin ]; then
            run_as_root install -d -m 0755 /usr/local/bin || true
        fi
        if [ -d /usr/local/bin ] && write_primer_shim_as_root /usr/local/bin; then
            printf "\033[1;32m  ✓\033[0m primer command available at /usr/local/bin/primer\n"
            return 0
        fi
    fi

    printf "\033[1;33m  !\033[0m primer installed at %s/primer, but no writable PATH directory was available\n" "$BIN_DIR"
}

ensure_zsh() {
    if command -v zsh >/dev/null 2>&1; then
        return 0
    fi

    case "$(uname -s 2>/dev/null || printf unknown)" in
        Darwin)
            printf "zsh is required but was not found\n" >&2
            return 1
            ;;
        Linux)
            if command -v apt-get >/dev/null 2>&1; then
                printf "\033[1;34m==>\033[0m Installing zsh with apt\n"
                run_as_root apt-get update
                run_as_root env DEBIAN_FRONTEND=noninteractive apt-get install -y zsh curl tar
                return 0
            fi
            if command -v dnf >/dev/null 2>&1; then
                printf "\033[1;34m==>\033[0m Installing zsh with DNF\n"
                run_as_root dnf install -y zsh curl tar
                return 0
            fi
            printf "zsh is required and no supported package manager was found\n" >&2
            return 1
            ;;
        *)
            printf "zsh is required on this system\n" >&2
            return 1
            ;;
    esac
}

# ── Install primer CLI ────────────────────────────────────────────────────────

printf "\033[1;34m==>\033[0m Installing primer CLI to %s\n" "$BIN_DIR"
mkdir -p "$BIN_DIR"
curl -fsSL "$REPO_RAW/bin/primer" -o "$BIN_DIR/primer"
chmod +x "$BIN_DIR/primer"
printf "\033[1;32m  ✓\033[0m primer installed\n"
ensure_primer_command

# ── Ensure ~/bin is on PATH ──────────────────────────────────────────────────

case ":$PATH:" in
    *":$BIN_DIR:"*) ;;
    *) export PATH="$BIN_DIR:$PATH" ;;
esac

# ── Run primer update ─────────────────────────────────────────────────────────

ensure_zsh
if [ -t 1 ] && [ -r /dev/tty ] && [ -w /dev/tty ]; then
    exec "$(command -v zsh)" "$BIN_DIR/primer" update "$@" </dev/tty
fi
exec "$(command -v zsh)" "$BIN_DIR/primer" update "$@"
