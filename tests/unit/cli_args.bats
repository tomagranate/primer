#!/usr/bin/env bats
# tests/unit/cli_args.bats -- CLI argument parsing tests for bin/primer

load '../helpers/common'

# ── Help ─────────────────────────────────────────────────────────────────────

@test "cli: --help exits 0 and shows usage" {
    run zsh "$PRIMER_DIR/bin/primer" --help
    assert_success
    assert_output --partial "Usage"
    assert_output --partial "Commands"
}

@test "cli: -h exits 0 and shows usage" {
    run zsh "$PRIMER_DIR/bin/primer" -h
    assert_success
    assert_output --partial "Usage"
}

@test "cli: help (positional) exits 0 and shows usage" {
    run zsh "$PRIMER_DIR/bin/primer" help
    assert_success
    assert_output --partial "Usage"
}

@test "cli: no args shows help and exits 0" {
    run zsh "$PRIMER_DIR/bin/primer"
    assert_success
    assert_output --partial "primer"
}

# ── Invalid arguments ────────────────────────────────────────────────────────

@test "cli: unknown flag exits 1" {
    run zsh "$PRIMER_DIR/bin/primer" --garbage
    assert_failure
    assert_output --partial "Unknown argument"
}

@test "cli: unknown command exits 1" {
    run zsh "$PRIMER_DIR/bin/primer" foobar
    assert_failure
    assert_output --partial "Unknown argument"
}

# ── Dry-run flag ─────────────────────────────────────────────────────────────

@test "cli: --dry-run alone (no command) shows help" {
    run zsh "$PRIMER_DIR/bin/primer" --dry-run
    assert_success
    assert_output --partial "Usage"
}
