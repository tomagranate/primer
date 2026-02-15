#!/bin/zsh
# lib/ui.zsh -- Terminal UI: colors, box drawing, spinners, and module helpers

# ── Colors ────────────────────────────────────────────────────────────────────

typeset -g C_RESET=$'\e[0m'
typeset -g C_BOLD=$'\e[1m'
typeset -g C_DIM=$'\e[2m'
typeset -g C_RED=$'\e[31m'
typeset -g C_GREEN=$'\e[32m'
typeset -g C_YELLOW=$'\e[33m'
typeset -g C_BLUE=$'\e[34m'
typeset -g C_CYAN=$'\e[36m'
typeset -g C_BOLD_RED=$'\e[1;31m'
typeset -g C_BOLD_GREEN=$'\e[1;32m'
typeset -g C_BOLD_YELLOW=$'\e[1;33m'
typeset -g C_BOLD_BLUE=$'\e[1;34m'
typeset -g C_BOLD_CYAN=$'\e[1;36m'

# ── Glyphs ────────────────────────────────────────────────────────────────────

typeset -g GLYPH_OK="✓"
typeset -g GLYPH_FAIL="✗"
typeset -g GLYPH_WAIT="◌"
typeset -g GLYPH_SKIP="▸"

typeset -ga SPINNER=(⠋ ⠙ ⠹ ⠸ ⠼ ⠴ ⠦ ⠧ ⠇ ⠏)
typeset -gi SPIN_IDX=0

# ── Box Drawing ───────────────────────────────────────────────────────────────

typeset -gi BOX_W=52  # inner width between │ and │ (including 1-char padding each side)

# Print a horizontal border line: ╭───╮ or ╰───╯
# Usage: ui::hline <corner_left> <corner_right> [color] [label]
ui::hline() {
    local cl="$1" cr="$2" color="${3:-$C_BLUE}" label="$4"
    if [[ -n "$label" ]]; then
        local fill_len=$(( BOX_W - ${#label} ))
        printf '  %s%s%s%s%s%s\n' \
            "$color" "$cl" "$label" "$(printf '─%.0s' {1..$fill_len})" "$cr" "$C_RESET"
    else
        printf '  %s%s%s%s%s\n' \
            "$color" "$cl" "$(printf '─%.0s' {1..$BOX_W})" "$cr" "$C_RESET"
    fi
}

# Print a 3-line box with text
# Usage: ui::box <text> [color]
ui::box() {
    local text="$1" color="${2:-$C_BLUE}"
    local pad=$(( BOX_W - 2 - ${#text} ))

    ui::hline "╭" "╮" "$color"
    printf '  %s│%s %s%s%s%*s %s│%s\n' \
        "$color" "$C_RESET" "$C_BOLD" "$text" "$C_RESET" "$pad" "" "$color" "$C_RESET"
    ui::hline "╰" "╯" "$color"
}

# ── Frame Management (cursor control for redraws) ────────────────────────────

typeset -gi _frame_lines=0
typeset -g  _frame_active=false

ui::frame_begin() {
    if $_frame_active && (( _frame_lines > 0 )); then
        printf '\e[%dA' $_frame_lines
    fi
    _frame_active=true
    _frame_lines=0
}

ui::frame_line() {
    printf '\e[2K%s\n' "$1"
    _frame_lines=$(( _frame_lines + 1 ))
}

# ── Module Line Formatting ────────────────────────────────────────────────────

# Format a single module status line (returns via stdout)
# Usage: ui::module_line <state> <name> <detail> [elapsed]
ui::module_line() {
    local state="$1" name="$2" detail="$3" elapsed="$4"
    local glyph color

    case "$state" in
        done)    glyph="$GLYPH_OK";                       color="$C_GREEN"     ;;
        failed)  glyph="$GLYPH_FAIL";                     color="$C_BOLD_RED"  ;;
        running) glyph="${SPINNER[SPIN_IDX + 1]}";         color="$C_BLUE"      ;;
        pending) glyph="$GLYPH_WAIT";                     color="$C_DIM"       ;;
        skipped) glyph="$GLYPH_SKIP";                     color="$C_YELLOW"    ;;
        *)       glyph="?";                               color="$C_DIM"       ;;
    esac

    # Truncate long values, then pad (so ANSI codes don't affect alignment)
    (( ${#name} > 18 ))   && name="${name[1,17]}…"
    (( ${#detail} > 22 )) && detail="${detail[1,21]}…"
    local padded_name=$(printf '%-18s' "$name")
    local padded_detail=$(printf '%-22s' "$detail")
    local time_str=""
    [[ -n "$elapsed" ]] && time_str=$(printf '%6s' "$elapsed")

    printf '   %s%s%s  %s  %s%s%s  %s%s%s' \
        "$color" "$glyph" "$C_RESET" \
        "$padded_name" \
        "$color" "$padded_detail" "$C_RESET" \
        "$C_DIM" "$time_str" "$C_RESET"
}

# ── Error Output Box ─────────────────────────────────────────────────────────

# Display a module's error output in a red-bordered box
# Usage: ui::error_box <title> <logfile_path>
ui::error_box() {
    local title="$1" logfile="$2"
    local color="$C_RED"
    local usable=$(( BOX_W - 2 ))   # text width inside box (1 char padding each side)
    local label="─ ${title} ── error output "

    print ""
    ui::hline "╭" "╮" "$color" "$label"

    while IFS= read -r line || [[ -n "$line" ]]; do
        # Strip carriage returns
        line="${line//$'\r'/}"
        # Truncate long lines
        if (( ${#line} > usable )); then
            line="${line[1,$((usable - 1))]}…"
        fi
        local pad=$(( usable - ${#line} ))
        printf '  %s│%s %s%*s %s│%s\n' \
            "$color" "$C_RESET" "$line" "$pad" "" "$color" "$C_RESET"
    done < "$logfile"

    ui::hline "╰" "╯" "$color"
}

# ── Module Helpers (available inside module subshells) ────────────────────────

# Execute a command, or print it in dry-run mode
run() {
    if [[ "$DRY_RUN" == true ]]; then
        printf '[dry-run] %s\n' "$*"
    else
        "$@"
    fi
}

# Set the one-line status message displayed next to the module name
primer::status_msg() {
    [[ -n "$MOD_STATUS_FILE" ]] && print -n "$1" > "$MOD_STATUS_FILE"
}

# Ensure Homebrew is on PATH (for modules that depend on brew packages)
ensure_brew() {
    if [[ -x /opt/homebrew/bin/brew ]] && ! command -v brew &>/dev/null; then
        eval "$(/opt/homebrew/bin/brew shellenv)"
    fi
}

# ── Config Helper ─────────────────────────────────────────────────────────────

# Read a config key for the current module, one item per line
# Usage: mod_config <key>
mod_config() {
    local raw="${_mod_config[${MOD_NAME}.$1]}"
    print "$raw" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | grep -v '^$'
}

# ── File Deployment Helpers ──────────────────────────────────────────────────

# Copy all files from $MOD_DIR/files/ to a target directory, preserving structure
# Usage: deploy_files <target_dir>
deploy_files() {
    local target="$1"
    if [[ "$DRY_RUN" == true ]]; then
        echo "[dry-run] deploy $MOD_DIR/files/ -> $target"
        return 0
    fi
    local src rel
    for src in "$MOD_DIR"/files/**/*(D.N); do
        rel="${src#$MOD_DIR/files/}"
        mkdir -p "$target/${rel:h}"
        cp "$src" "$target/$rel"
    done
}

# Check all files from $MOD_DIR/files/ exist at target, set status message
# Usage: check_files <target_dir>
check_files() {
    local target="$1"
    local missing=0 total=0
    local src rel
    for src in "$MOD_DIR"/files/**/*(D.N); do
        rel="${src#$MOD_DIR/files/}"
        total=$(( total + 1 ))
        [[ -f "$target/$rel" ]] || missing=$(( missing + 1 ))
    done
    if (( missing == 0 )); then
        primer::status_msg "synced ($total files)"
        return 0
    fi
    primer::status_msg "$missing of $total missing"
    return 1
}

# Copy all executables from $MOD_DIR/bin/ to a target directory
# Usage: deploy_scripts <target_dir>
deploy_scripts() {
    local target="$1"
    mkdir -p "$target"
    if [[ "$DRY_RUN" == true ]]; then
        echo "[dry-run] deploy scripts to $target"
        return 0
    fi
    local src
    for src in "$MOD_DIR"/bin/*(N); do
        cp "$src" "$target/${src:t}"
        chmod +x "$target/${src:t}"
    done
}
