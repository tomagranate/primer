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
typeset -gi UI_TOTAL_W=56
typeset -gi UI_MAX_TOTAL_W=80
typeset -gi UI_NAME_W=18
typeset -gi UI_DETAIL_W=22
typeset -gi UI_TIME_W=6
typeset -gi UI_SUBITEM_W=36

ui::refresh_layout() {
    local cols="${COLUMNS:-}"
    if [[ -z "$cols" || "$cols" != <-> ]]; then
        if [[ -t 1 ]]; then
            cols="$(tput cols 2>/dev/null)"
        fi
    fi
    [[ -z "$cols" || "$cols" != <-> ]] && cols=80

    local min_total=40
    local total="$cols"
    (( total < min_total )) && total=$min_total
    (( total > UI_MAX_TOTAL_W )) && total=$UI_MAX_TOTAL_W

    UI_TOTAL_W=$total
    BOX_W=$(( UI_TOTAL_W - 4 ))

    # "   X  {name}  {detail}  {time}" => fixed chars = 10 + time width.
    local remaining=$(( UI_TOTAL_W - 10 - UI_TIME_W ))
    (( remaining < 8 )) && remaining=8

    if (( remaining >= 24 )); then
        UI_NAME_W=$(( remaining * 45 / 100 ))
        UI_DETAIL_W=$(( remaining - UI_NAME_W ))
        (( UI_NAME_W < 10 )) && UI_NAME_W=10
        (( UI_DETAIL_W < 12 )) && UI_DETAIL_W=12
    else
        # Very narrow terminal: prioritize keeping both columns visible.
        UI_NAME_W=$(( remaining * 45 / 100 ))
        (( UI_NAME_W < 4 )) && UI_NAME_W=4
        UI_DETAIL_W=$(( remaining - UI_NAME_W ))
        (( UI_DETAIL_W < 4 )) && UI_DETAIL_W=4
        UI_NAME_W=$(( remaining - UI_DETAIL_W ))
    fi

    UI_SUBITEM_W=$(( UI_TOTAL_W - 12 ))
    (( UI_SUBITEM_W < 12 )) && UI_SUBITEM_W=12
    return 0
}

# Print a horizontal border line: ╭───╮ or ╰───╯
# Usage: ui::hline <corner_left> <corner_right> [color] [label]
ui::hline() {
    ui::refresh_layout
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
    ui::refresh_layout
    local text="$1" color="${2:-$C_BLUE}"
    local pad=$(( BOX_W - 2 - ${#text} ))

    ui::hline "╭" "╮" "$color"
    printf '  %s│%s %s%s%s%*s %s│%s\n' \
        "$color" "$C_RESET" "$C_BOLD" "$text" "$C_RESET" "$pad" "" "$color" "$C_RESET"
    ui::hline "╰" "╯" "$color"
}

# ── Frame Management (cursor control for redraws) ────────────────────────────

typeset -gi _frame_lines=0
typeset -gi _prev_frame_lines=0
typeset -g  _frame_active=false

ui::frame_begin() {
    if $_frame_active && (( _frame_lines > 0 )); then
        printf '\e[%dA' $_frame_lines
    fi
    _frame_active=true
    _prev_frame_lines=$_frame_lines
    _frame_lines=0
}

ui::frame_line() {
    printf '\e[2K%s\n' "$1"
    _frame_lines=$(( _frame_lines + 1 ))
}

# Call at the end of each render pass to clean up two categories of pollution:
#   1. Ghost lines from a previous taller frame (frame shrank, e.g. sub-items
#      disappeared when a module finished).
#   2. Any content written to the terminal by external processes (brew, sudo)
#      below the current frame position.
ui::frame_end() {
    local extra=$(( _prev_frame_lines - _frame_lines ))
    local i
    for (( i = 0; i < extra; i++ )); do
        printf '\e[2K\n'
    done
    if (( extra > 0 )); then
        printf '\e[%dA' "$extra"
    fi
    # Erase everything below the current frame in case any external process
    # (brew progress, sudo prompt via /dev/tty) wrote lines beneath us.
    printf '\e[J'
}

# ── Module Line Formatting ────────────────────────────────────────────────────

# Format a single module status line (returns via stdout)
# Usage: ui::module_line <state> <name> <detail> [elapsed]
ui::module_line() {
    ui::refresh_layout
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
    (( ${#name} > UI_NAME_W ))   && name="${name[1,$(( UI_NAME_W - 1 ))]}…"
    (( ${#detail} > UI_DETAIL_W )) && detail="${detail[1,$(( UI_DETAIL_W - 1 ))]}…"
    local padded_name
    local padded_detail
    padded_name=$(printf "%-${UI_NAME_W}s" "$name")
    padded_detail=$(printf "%-${UI_DETAIL_W}s" "$detail")
    local time_str=""
    [[ -n "$elapsed" ]] && time_str=$(printf '%6s' "$elapsed")

    printf '   %s%s%s  %s  %s%s%s  %s%s%s' \
        "$color" "$glyph" "$C_RESET" \
        "$padded_name" \
        "$color" "$padded_detail" "$C_RESET" \
        "$C_DIM" "$time_str" "$C_RESET"
}

# Format a single sub-item line shown under a module
# Usage: ui::sub_item_line <state> <name> [detail]
ui::sub_item_line() {
    ui::refresh_layout
    local state="$1" name="$2" detail="${3:-}"
    local glyph color detail_color

    case "$state" in
        done)    glyph="$GLYPH_OK";                color="$C_GREEN";    detail_color="$C_GREEN"    ;;
        failed)  glyph="$GLYPH_FAIL";              color="$C_BOLD_RED"; detail_color="$C_BOLD_RED" ;;
        running) glyph="${SPINNER[SPIN_IDX + 1]}"; color="$C_BLUE";     detail_color="$C_BLUE"     ;;
        skipped) glyph="$GLYPH_SKIP";              color="$C_YELLOW";   detail_color="$C_YELLOW"   ;;
        *)       glyph="$GLYPH_WAIT";              color="$C_DIM";      detail_color="$C_DIM"      ;;
    esac

    local display_name="  $name"
    (( ${#display_name} > UI_NAME_W )) && display_name="${display_name[1,$(( UI_NAME_W - 1 ))]}…"
    local padded_name
    padded_name=$(printf "%-${UI_NAME_W}s" "$display_name")

    if [[ -n "$detail" ]]; then
        (( ${#detail} > UI_DETAIL_W )) && detail="${detail[1,$(( UI_DETAIL_W - 1 ))]}…"
        local padded_detail
        padded_detail=$(printf "%-${UI_DETAIL_W}s" "$detail")
        printf '   %s%s%s  %s%s%s  %s%s%s' \
            "$color" "$glyph" "$C_RESET" \
            "$C_DIM" "$padded_name" "$C_RESET" \
            "$detail_color" "$padded_detail" "$C_RESET"
    else
        printf '   %s%s%s  %s%s%s' "$color" "$glyph" "$C_RESET" "$C_DIM" "$padded_name" "$C_RESET"
    fi
}

# ── Error Output Box ─────────────────────────────────────────────────────────

# Display a module's error output with top/bottom separators.
# We intentionally avoid side borders and truncation so long lines remain readable.
# Usage: ui::error_box <title> <logfile_path>
ui::error_box() {
    local title="$1" logfile="$2"
    local color="$C_RED"
    local label=" ${title} -- error output "
    local bar_len=$(( ${#label} > BOX_W ? ${#label} : BOX_W ))
    local bar
    bar="$(printf '─%.0s' {1..$bar_len})"

    print ""
    printf '  %s%s%s\n' "$color" "$bar" "$C_RESET"
    printf '  %s%s%s\n' "$color" "$label" "$C_RESET"
    printf '  %s%s%s\n' "$color" "$bar" "$C_RESET"

    while IFS= read -r line || [[ -n "$line" ]]; do
        # Strip carriage returns
        line="${line//$'\r'/}"
        printf '  %s\n' "$line"
    done < "$logfile"

    printf '  %s%s%s\n' "$color" "$bar" "$C_RESET"
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

# Initialise the sub-items list with every name in "pending" state.
# Call once before the install loop begins.
# Usage: primer::items_init name1 name2 ...
primer::items_init() {
    [[ -z "$MOD_ITEMS_FILE" ]] && return
    local name
    for name in "$@"; do
        printf 'pending:%s\n' "$name"
    done > "$MOD_ITEMS_FILE"
}

# Update the state of one item in the sub-items list.
# Usage: primer::item_update <name> <state> [detail]
# detail is optional human-readable context, shown in final subtask lines.
primer::item_update() {
    [[ -z "$MOD_ITEMS_FILE" || ! -f "$MOD_ITEMS_FILE" ]] && return
    local name="$1" state="$2" detail="${3:-}"
    local tmp="${MOD_ITEMS_FILE}.tmp.$$"
    while IFS=: read -r s n d; do
        if [[ "$n" == "$name" ]]; then
            if [[ -n "$detail" ]]; then
                printf '%s:%s:%s\n' "$state" "$name" "$detail"
            else
                printf '%s:%s\n' "$state" "$name"
            fi
        else
            if [[ -n "$d" ]]; then
                printf '%s:%s:%s\n' "$s" "$n" "$d"
            else
                printf '%s:%s\n' "$s" "$n"
            fi
        fi
    done < "$MOD_ITEMS_FILE" > "$tmp"
    mv "$tmp" "$MOD_ITEMS_FILE"
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
