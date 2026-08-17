#!/bin/zsh
# Shell module runtime: execution, status protocol, and deployment helpers.

run() {
    if [[ "$DRY_RUN" == true ]]; then
        printf '[dry-run] %s\n' "$*"
    else
        "$@"
    fi
}
primer::run_as_root() {
    local reason="${1:-admin access}"
    shift

    (( EUID == 0 )) && {
        "$@"
        return $?
    }

    if ! command -v sudo >/dev/null 2>&1; then
        print "sudo is required for ${reason}" >&2
        return 1
    fi

    if ! sudo -n true 2>/dev/null; then
        print "sudo authentication is required for ${reason}." >&2
        print "Run Primer from an interactive terminal or authenticate first with: sudo -v" >&2
        return 1
    fi

    sudo -n "$@"
}

# Set the one-line status message displayed next to the module name.
# Write a temp file, then move it over the target. A move on one filesystem is
# atomic, so a concurrent reader always sees the old text or the new text.
# A plain redirect truncates first, which lets a reader see an empty file.
primer::status_msg() {
    [[ -z "$MOD_STATUS_FILE" ]] && return 0
    local tmp="${MOD_STATUS_FILE}.tmp.$$"
    if print -n "$1" > "$tmp" 2>/dev/null; then
        mv -f "$tmp" "$MOD_STATUS_FILE" 2>/dev/null || rm -f "$tmp"
    else
        rm -f "$tmp"
    fi
    return 0
}

# ── Sub-item Protocol ─────────────────────────────────────────────────────────
#
# The sub-items file holds one item per line: "state<TAB>name<TAB>detail".
# The detail field is optional. A tab separates the fields and a newline
# separates the records, so names and details may contain any other character,
# including a colon. Writers clean both separators out of every field.
# The TypeScript runtime reads this item-state format.

# Initialise the sub-items list with every name in "pending" state.
# Call once before the install loop begins.
# Usage: primer::items_init name1 name2 ...
primer::items_init() {
    [[ -z "$MOD_ITEMS_FILE" ]] && return
    local name clean slot=0 manifest=""
    if [[ -n "${MOD_ITEM_LOG_DIR:-}" ]]; then
        mkdir -p "$MOD_ITEM_LOG_DIR"
        manifest="$MOD_ITEM_LOG_DIR/manifest"
        : > "$manifest"
    fi
    for name in "$@"; do
        slot=$(( slot + 1 ))
        clean="${name//$'\r'/}"
        clean="${clean//[$'\t\n']/ }"
        printf 'pending\t%s\n' "$clean"
        if [[ -n "$manifest" ]]; then
            printf '%s\t%s\n' "$slot" "$clean" >> "$manifest"
            : > "$MOD_ITEM_LOG_DIR/${slot}.log"
        fi
    done > "$MOD_ITEMS_FILE"
}

# Return the durable log path for one registered item.
primer::item_log_path() {
    [[ -n "${MOD_ITEM_LOG_DIR:-}" && -f "$MOD_ITEM_LOG_DIR/manifest" ]] || return 1
    local wanted="$1" slot name
    wanted="${wanted//$'\r'/}"
    wanted="${wanted//[$'\t\n']/ }"
    while IFS=$'\t' read -r slot name; do
        if [[ "$name" == "$wanted" ]]; then
            print -r -- "$MOD_ITEM_LOG_DIR/${slot}.log"
            return 0
        fi
    done < "$MOD_ITEM_LOG_DIR/manifest"
    return 1
}

# Append one line to an item's durable log.
primer::item_log() {
    local name="$1" path
    shift
    path="$(primer::item_log_path "$name")" || return 0
    print -r -- "$*" >> "$path"
}

# Return the current state for one item.
primer::item_state() {
    [[ -n "${MOD_ITEMS_FILE:-}" && -f "$MOD_ITEMS_FILE" ]] || return 1
    local wanted="$1" state name detail
    wanted="${wanted//$'\r'/}"
    wanted="${wanted//[$'\t\n']/ }"
    while IFS=$'\t' read -r state name detail; do
        if [[ "$name" == "$wanted" ]]; then
            print -r -- "$state"
            return 0
        fi
    done < "$MOD_ITEMS_FILE"
    return 1
}

# Update the state of one item in the sub-items list.
# Usage: primer::item_update <name> <state> [detail]
# detail is optional human-readable context, shown in final subtask lines.
primer::item_update() {
    [[ -z "$MOD_ITEMS_FILE" || ! -f "$MOD_ITEMS_FILE" ]] && return
    local name="$1" state="$2" detail="${3:-}"
    # Clean the name the same way items_init did, so the match still works.
    name="${name//$'\r'/}"
    name="${name//[$'\t\n']/ }"
    detail="${detail//$'\r'/}"
    detail="${detail//[$'\t\n']/ }"
    local tmp="${MOD_ITEMS_FILE}.tmp.$$"
    while IFS=$'\t' read -r s n d; do
        if [[ "$n" == "$name" ]]; then
            if [[ -n "$detail" ]]; then
                printf '%s\t%s\t%s\n' "$state" "$name" "$detail"
            else
                printf '%s\t%s\n' "$state" "$name"
            fi
        else
            if [[ -n "$d" ]]; then
                printf '%s\t%s\t%s\n' "$s" "$n" "$d"
            else
                printf '%s\t%s\n' "$s" "$n"
            fi
        fi
    done < "$MOD_ITEMS_FILE" > "$tmp"
    mv "$tmp" "$MOD_ITEMS_FILE"
}

# Report the outcome of one parallel worker: "state<TAB>detail".
primer::parallel_item_result() {
    [[ -z "${PRIMER_ITEM_RESULT_FILE:-}" ]] && return 1
    local state="$1" detail="${2:-}"
    detail="${detail//$'\r'/}"
    detail="${detail//[$'\t\n']/ }"
    if [[ -n "$detail" ]]; then
        printf '%s\t%s\n' "$state" "$detail" > "$PRIMER_ITEM_RESULT_FILE"
    else
        printf '%s\n' "$state" > "$PRIMER_ITEM_RESULT_FILE"
    fi
}

primer::first_line() {
    local text="$1"
    local first="${text%%$'\n'*}"
    first="${first//$'\r'/}"
    print "$first"
}

primer::parallel_items() {
    local jobs="$1" label="$2" worker="$3"
    shift 3
    local -a items=("$@")
    local total=${#items[@]}
    (( total == 0 )) && return 0
    [[ "$jobs" == <-> ]] || jobs=1
    (( jobs < 1 )) && jobs=1
    (( jobs > total )) && jobs=$total

    local workdir item_log_dir manifest
    workdir="$(mktemp -d "${TMPDIR:-/tmp}/primer-items.XXXXXX")" || return 1
    item_log_dir="${MOD_ITEM_LOG_DIR:-$workdir/logs}"
    manifest="$item_log_dir/manifest"
    mkdir -p "$item_log_dir"
    [[ -f "$manifest" ]] || : > "$manifest"

    local -A pid_item=() pid_result=() pid_log=()
    local next=1 completed=0 any_failed=false
    local pid item slot result log rc state detail output first progressed

    primer::status_msg "${label} 0/${total}..."
    while (( completed < total )); do
        while (( ${#pid_item} < jobs && next <= total )); do
            item="${items[$next]}"
            slot="$next"
            result="${workdir}/${slot}.result"
            log="$(primer::item_log_path "$item" 2>/dev/null)"
            if [[ -z "$log" ]]; then
                log="${item_log_dir}/${slot}.log"
                printf '%s\t%s\n' "$slot" "$item" >> "$manifest"
            fi
            primer::item_update "$item" "running"
            (
                export PRIMER_ITEM_RESULT_FILE="$result"
                "$worker" "$item"
                rc=$?
                if [[ ! -s "$result" ]]; then
                    if (( rc == 0 )); then
                        primer::parallel_item_result "done"
                    else
                        first=""
                        [[ -s "$log" ]] && first="$(primer::first_line "$(cat "$log")")"
                        [[ -z "$first" ]] && first="${worker} failed"
                        primer::parallel_item_result "failed" "$first"
                    fi
                fi
                return "$rc"
            ) > "$log" 2>&1 &
            pid=$!
            pid_item[$pid]="$item"
            pid_result[$pid]="$result"
            pid_log[$pid]="$log"
            next=$(( next + 1 ))
        done

        progressed=false
        for pid in ${(k)pid_item}; do
            kill -0 "$pid" 2>/dev/null && continue

            rc=0
            wait "$pid" 2>/dev/null || rc=$?
            item="${pid_item[$pid]}"
            result="${pid_result[$pid]}"
            log="${pid_log[$pid]}"
            state=""
            detail=""
            if [[ -s "$result" ]]; then
                IFS=$'\t' read -r state detail < "$result"
            fi
            if [[ -z "$state" ]]; then
                state="failed"
                detail="missing item result"
                rc=1
            fi

            # A completed item should always have something useful to inspect.
            # Workers normally write command output here; quiet checks still get
            # a durable result line instead of presenting an empty log pane.
            if [[ ! -s "$log" ]]; then
                if [[ -n "$detail" ]]; then
                    printf '%s: %s (%s)\n' "$item" "$state" "$detail" > "$log"
                else
                    printf '%s: %s\n' "$item" "$state" > "$log"
                fi
            fi

            primer::item_update "$item" "$state" "$detail"
            if [[ "$state" == "failed" || "$rc" != 0 ]]; then
                any_failed=true
            fi
            if [[ -s "$log" && ( "$DRY_RUN" == true || "$state" == "failed" ) ]]; then
                cat "$log"
            fi

            unset "pid_item[$pid]" "pid_result[$pid]" "pid_log[$pid]"
            completed=$(( completed + 1 ))
            primer::status_msg "${label} ${completed}/${total}..."
            progressed=true
        done

        $progressed || sleep 0.05
    done

    rm -rf "$workdir"
    $any_failed && return 1
    return 0
}

# Ensure Homebrew is on PATH (for modules that depend on brew packages)
ensure_brew() {
    if [[ -x /opt/homebrew/bin/brew ]] && ! command -v brew &>/dev/null; then
        eval "$(/opt/homebrew/bin/brew shellenv)"
    fi
}

# Put mise and its tool bins on PATH. Later modules then see CLIs that an
# earlier module just installed with `mise exec -- npm install -g`.
ensure_mise() {
    typeset -gU path
    local dir mise_bin=""
    for dir in \
        "$HOME/bin" \
        "$HOME/.local/bin" \
        "$HOME/.mise/bin" \
        "$HOME/.local/share/mise/shims"; do
        [[ -d "$dir" ]] || continue
        path=("$dir" $path)
    done

    if command -v mise >/dev/null 2>&1; then
        mise_bin="$(command -v mise)"
    else
        for dir in \
            "$HOME/.local/bin/mise" \
            "$HOME/.mise/bin/mise" \
            "$HOME/bin/mise" \
            "/opt/homebrew/bin/mise" \
            "/usr/local/bin/mise"; do
            [[ -x "$dir" ]] || continue
            mise_bin="$dir"
            break
        done
    fi
    [[ -n "$mise_bin" ]] || return 0

    eval "$("$mise_bin" env -s zsh 2>/dev/null)" || true
}

ensure_mise

# ── Config Helper ─────────────────────────────────────────────────────────────

# Read a config key for the current module, one item per line
# Usage: mod_config <key>
mod_config() {
    local raw="${_mod_config[${MOD_NAME}.$1]}"
    local line
    while IFS= read -r line; do
        line="${line#"${line%%[![:space:]]*}"}"
        line="${line%"${line##*[![:space:]]}"}"
        [[ -n "$line" ]] && print -r -- "$line"
    done <<< "$raw"
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
    local missing=0 drifted=0 total=0
    local src rel dst
    for src in "$MOD_DIR"/files/**/*(D.N); do
        rel="${src#$MOD_DIR/files/}"
        dst="$target/$rel"
        total=$(( total + 1 ))
        if [[ ! -f "$dst" ]]; then
            missing=$(( missing + 1 ))
        elif ! cmp -s "$src" "$dst"; then
            drifted=$(( drifted + 1 ))
        fi
    done
    if (( missing == 0 && drifted == 0 )); then
        primer::status_msg "synced ($total files)"
        return 0
    fi
    local parts=()
    (( missing > 0 )) && parts+=("${missing} missing")
    (( drifted > 0 )) && parts+=("${drifted} drifted")
    primer::status_msg "${(j: · :)parts}"
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
