#!/bin/sh
# primer -- machine setup, from primer/ in the private tomagranate/hangar repo
#
# Bootstrap: gets the GitHub CLI, signs in, installs the primer CLI, then runs
# `primer update`. The public tomagranate/primer repo serves a copy of this file.
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/tomagranate/primer/master/setup.sh | sh
#   curl -fsSL https://raw.githubusercontent.com/tomagranate/primer/master/setup.sh | sh -s -- --dry-run
set -e

PRIMER_REPO="tomagranate/hangar"
GH_BOOTSTRAP_DIR="$HOME/.local/share/primer/bootstrap"
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

sha256_of() {
    if command -v shasum >/dev/null 2>&1; then
        shasum -a 256 "$1" | awk '{print $1}'
    else
        sha256sum "$1" | awk '{print $1}'
    fi
}

# Hangar is private, so every download goes through gh. Primer installs gh
# properly later; this copy only gets the first run going.
ensure_gh() {
    command -v gh >/dev/null 2>&1 && return 0
    if [ -x "$GH_BOOTSTRAP_DIR/gh" ]; then
        export PATH="$GH_BOOTSTRAP_DIR:$PATH"
        return 0
    fi
    case "$(uname -s)/$(uname -m)" in
        Darwin/arm64) platform=macOS_arm64 ext=zip ;;
        Darwin/x86_64) platform=macOS_amd64 ext=zip ;;
        Linux/x86_64) platform=linux_amd64 ext=tar.gz ;;
        Linux/aarch64|Linux/arm64) platform=linux_arm64 ext=tar.gz ;;
        *) printf "No GitHub CLI build for %s\n" "$(uname -s)/$(uname -m)" >&2; return 1 ;;
    esac
    printf "\033[1;34m==>\033[0m Downloading the GitHub CLI\n"
    version="$(curl -fsSL https://api.github.com/repos/cli/cli/releases/latest \
        | sed -n 's/.*"tag_name": *"v\([^"]*\)".*/\1/p' | head -1)"
    [ -n "$version" ] || { printf "Could not find the latest GitHub CLI release\n" >&2; return 1; }
    name="gh_${version}_${platform}"
    tmp="$(mktemp -d)"
    base="https://github.com/cli/cli/releases/download/v$version"
    curl -fsSL "$base/$name.$ext" -o "$tmp/$name.$ext"
    curl -fsSL "$base/gh_${version}_checksums.txt" -o "$tmp/checksums.txt"
    expected="$(awk -v f="$name.$ext" '$2 == f {print $1}' "$tmp/checksums.txt")"
    if [ -z "$expected" ] || [ "$(sha256_of "$tmp/$name.$ext")" != "$expected" ]; then
        rm -rf "$tmp"
        printf "GitHub CLI checksum verification failed\n" >&2
        return 1
    fi
    if [ "$ext" = zip ]; then
        (cd "$tmp" && unzip -q "$name.zip")
    else
        tar -xzf "$tmp/$name.tar.gz" -C "$tmp"
    fi
    mkdir -p "$GH_BOOTSTRAP_DIR"
    mv "$tmp/$name/bin/gh" "$GH_BOOTSTRAP_DIR/gh"
    rm -rf "$tmp"
    export PATH="$GH_BOOTSTRAP_DIR:$PATH"
}

ensure_gh_login() {
    gh auth status --hostname github.com >/dev/null 2>&1 && return 0
    printf "\033[1;34m==>\033[0m Sign in to GitHub. Primer lives in a private repo.\n"
    # A piped bootstrap has no stdin. Read the login prompt from the terminal.
    if (exec </dev/tty) 2>/dev/null; then
        gh auth login --hostname github.com --git-protocol https --web </dev/tty
    else
        gh auth login --hostname github.com --git-protocol https --web
    fi
}

# ── Install primer CLI ────────────────────────────────────────────────────────

ensure_gh
ensure_gh_login
printf "\033[1;34m==>\033[0m Installing primer CLI to %s\n" "$BIN_DIR"
mkdir -p "$BIN_DIR"
gh api -H "Accept: application/vnd.github.raw" \
    "repos/$PRIMER_REPO/contents/primer/bin/primer" > "$BIN_DIR/primer.tmp"
mv "$BIN_DIR/primer.tmp" "$BIN_DIR/primer"
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
