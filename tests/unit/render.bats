#!/usr/bin/env bats
# tests/unit/render.bats -- Tests for engine::_render sub-item filtering

load '../helpers/common'

setup() {
    export TEST_ITEMS_DIR="$(mktemp -d)"
}

teardown() {
    rm -rf "$TEST_ITEMS_DIR"
}

# Helper: run engine::_render with a single fake "running" module whose items
# file is pre-populated. PRIMER_TMPDIR must be set AFTER sourcing engine.zsh
# because engine.zsh resets it with typeset -g PRIMER_TMPDIR="".
_render_with_items() {
    local items_content="$1"
    local items_dir="$TEST_ITEMS_DIR"
    printf '%s' "$items_content" > "${items_dir}/fake-mod.items"

    run zsh -c "
        export PRIMER_DIR='${PRIMER_DIR}'
        source \"\$PRIMER_DIR/lib/ui.zsh\"
        source \"\$PRIMER_DIR/lib/engine.zsh\"
        PRIMER_TMPDIR='${items_dir}'
        _mod_order=(fake-mod)
        _mod_desc[fake-mod]='Fake Module'
        _state[fake-mod]=running
        _start[fake-mod]=\$EPOCHREALTIME
        engine::_render
    "
}

@test "render: pending sub-items are not shown in frame" {
    _render_with_items $'pending:waiting-pkg\nrunning:active-pkg\n'
    assert_success
    [[ "$output" == *"active-pkg"* ]] || {
        echo "Expected active-pkg in output: $output"; false
    }
    [[ "$output" != *"waiting-pkg"* ]] || {
        echo "Did not expect waiting-pkg in output: $output"; false
    }
}

@test "render: done sub-items are not shown in frame" {
    _render_with_items $'done:finished-pkg\nrunning:active-pkg\n'
    assert_success
    [[ "$output" == *"active-pkg"* ]] || {
        echo "Expected active-pkg in output: $output"; false
    }
    [[ "$output" != *"finished-pkg"* ]] || {
        echo "Did not expect finished-pkg in output: $output"; false
    }
}

@test "render: failed sub-items are shown in frame" {
    _render_with_items $'failed:broken-pkg\nrunning:active-pkg\n'
    assert_success
    [[ "$output" == *"broken-pkg"* ]] || {
        echo "Expected broken-pkg in output: $output"; false
    }
    [[ "$output" == *"active-pkg"* ]] || {
        echo "Expected active-pkg in output: $output"; false
    }
}

@test "render: done modules show resolved sub-items" {
    printf 'done:some-pkg\npending:waiting-pkg\nskipped:warn-pkg:already installed outside brew cask\n' > "${TEST_ITEMS_DIR}/fake-mod.items"

    run zsh -c "
        export PRIMER_DIR='${PRIMER_DIR}'
        source \"\$PRIMER_DIR/lib/ui.zsh\"
        source \"\$PRIMER_DIR/lib/engine.zsh\"
        PRIMER_TMPDIR='${TEST_ITEMS_DIR}'
        _mod_order=(fake-mod)
        _mod_desc[fake-mod]='Fake Module'
        _state[fake-mod]=done
        _elapsed[fake-mod]=1.2
        engine::_render
    "
    assert_success
    [[ "$output" == *"some-pkg"* ]] || {
        echo "Expected some-pkg in output when module is done: $output"; false
    }
    [[ "$output" == *"warn-pkg"* ]] || {
        echo "Expected warn-pkg in output when module is done: $output"; false
    }
    [[ "$output" == *"already installed"* ]] || {
        echo "Expected warning detail in output when module is done: $output"; false
    }
    [[ "$output" != *"waiting-pkg"* ]] || {
        echo "Did not expect waiting-pkg in output when module is done: $output"; false
    }
}

@test "render: does not print local declaration noise" {
    _render_with_items $'running:active-pkg\nfailed:broken-pkg\n'
    assert_success
    [[ "$output" != *"item_state='"* ]] || {
        echo "Did not expect local declaration output for item_state: $output"; false
    }
    [[ "$output" != *"item_name='"* ]] || {
        echo "Did not expect local declaration output for item_name: $output"; false
    }
}

# ── ui::frame_end ghost-line tests ───────────────────────────────────────────

@test "frame_end: emits erase-to-end-of-screen escape after every render" {
    # \e[J must appear in render output so external writes below the frame
    # are cleared on each cycle.
    run zsh -c "
        export PRIMER_DIR='${PRIMER_DIR}'
        source \"\$PRIMER_DIR/lib/ui.zsh\"
        source \"\$PRIMER_DIR/lib/engine.zsh\"
        PRIMER_TMPDIR='${TEST_ITEMS_DIR}'
        _mod_order=(fake-mod)
        _mod_desc[fake-mod]='Fake Module'
        _state[fake-mod]=done
        _elapsed[fake-mod]=0.1
        engine::_render
    "
    assert_success
    # \e[J is the CSI erase-to-end-of-screen sequence
    [[ "$output" == *$'\e[J'* ]] || {
        echo "Expected ESC[J in render output"; false
    }
}

@test "frame_end: clears extra lines when frame shrinks" {
    # Simulate: first render with 1 sub-item (frame N+1 lines), second render
    # with module done and no sub-item (frame N lines). The second render must
    # emit a \e[2K blank-line to erase the orphaned sub-item line.
    printf 'running:active-pkg\n' > "${TEST_ITEMS_DIR}/fake-mod.items"

    run zsh -c "
        export PRIMER_DIR='${PRIMER_DIR}'
        source \"\$PRIMER_DIR/lib/ui.zsh\"
        source \"\$PRIMER_DIR/lib/engine.zsh\"
        PRIMER_TMPDIR='${TEST_ITEMS_DIR}'
        _mod_order=(fake-mod)
        _mod_desc[fake-mod]='Fake Module'

        # First render: module running with 1 sub-item → _frame_lines = N+1
        _state[fake-mod]=running
        _start[fake-mod]=\$EPOCHREALTIME
        engine::_render

        # Second render: module done, no sub-items → frame shrank by 1
        _state[fake-mod]=done
        _elapsed[fake-mod]=1.0
        engine::_render

        # Emit a sentinel so we can see the second render's output
        printf 'SENTINEL'
    "
    assert_success
    # The output must contain \e[J (frame_end erase-below) from both renders
    local count
    count=$(printf '%s' "$output" | grep -o $'\e\[J' | wc -l | tr -d ' ')
    (( count >= 2 )) || {
        echo "Expected at least 2 ESC[J sequences (one per render), got: $count"; false
    }
}

@test "module_line: widens columns on wider terminals" {
    run zsh -c '
        export PRIMER_DIR="'"$PRIMER_DIR"'"
        source "$PRIMER_DIR/lib/ui.zsh"
        name="Extremely Long Module Name For Width Testing"
        detail="Detail should truncate on narrow terminals, not on wide."
        COLUMNS=56
        narrow="$(ui::module_line running "$name" "$detail" "0.1s")"
        COLUMNS=80
        wide="$(ui::module_line running "$name" "$detail" "0.1s")"
        print "$narrow"
        print "$wide"
    '
    assert_success

    local narrow_line
    local wide_line
    narrow_line="$(printf '%s\n' "$output" | sed -n '1p')"
    wide_line="$(printf '%s\n' "$output" | sed -n '2p')"
    local narrow_plain
    local wide_plain
    narrow_plain="$(printf '%s' "$narrow_line" | sed -E "s/\x1B\\[[0-9;]*[A-Za-z]//g")"
    wide_plain="$(printf '%s' "$wide_line" | sed -E "s/\x1B\\[[0-9;]*[A-Za-z]//g")"

    [[ "$narrow_line" == *"…"* ]] || {
        echo "Expected truncation on narrow line: $narrow_line"; false
    }
    (( ${#wide_plain} > ${#narrow_plain} )) || {
        echo "Expected wide line to have more visible content"; false
    }
}

@test "sub_item_line: warning detail uses yellow detail column" {
    run zsh -c '
        export PRIMER_DIR="'"$PRIMER_DIR"'"
        source "$PRIMER_DIR/lib/ui.zsh"
        COLUMNS=80
        out="$(ui::sub_item_line skipped "cursor" "already installed outside brew cask")"
        print "$out"
    '
    assert_success
    [[ "$output" == *$'\e[33m'* ]] || {
        echo "Expected yellow ANSI color for warning detail: $output"; false
    }
    [[ "$output" == *"already installed outside brew"* ]] || {
        echo "Expected warning detail text in sub-item output: $output"; false
    }
}
