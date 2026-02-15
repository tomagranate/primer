#!/usr/bin/env bats
# tests/dry_run.bats -- Smoke tests using primer's --dry-run mode

load 'helpers/common'

@test "primer update --dry-run completes without error" {
    export PRIMER_LOCAL="$PRIMER_DIR"
    run zsh "$PRIMER_DIR/bin/primer" update --dry-run
    assert_success
}

@test "primer status runs without crashing" {
    export PRIMER_LOCAL="$PRIMER_DIR"
    run zsh "$PRIMER_DIR/bin/primer" status
    # status may return 1 if things aren't installed -- that's fine
    # just verify it doesn't crash (exit code 0 or 1, not 2+)
    [[ "$status" -le 1 ]]
}
