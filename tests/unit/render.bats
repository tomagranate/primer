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

@test "render: sub-items not shown when module is done" {
    printf 'done:some-pkg\n' > "${TEST_ITEMS_DIR}/fake-mod.items"

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
    [[ "$output" != *"some-pkg"* ]] || {
        echo "Did not expect some-pkg in output when module is done: $output"; false
    }
}
