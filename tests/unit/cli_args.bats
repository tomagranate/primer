#!/usr/bin/env bats
# tests/unit/cli_args.bats -- CLI argument parsing tests for bin/primer

load '../helpers/common'

setup() {
    export PRIMER_LOCAL="$PRIMER_DIR"
}

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

@test "cli: --skip alone (no command) shows help" {
    run zsh "$PRIMER_DIR/bin/primer" --skip mac-app-store
    assert_success
    assert_output --partial "Usage"
}

@test "cli: --only alone (no command) shows help" {
    run zsh "$PRIMER_DIR/bin/primer" --only homebrew
    assert_success
    assert_output --partial "Usage"
}

@test "cli: --skip is rejected for status" {
    run zsh "$PRIMER_DIR/bin/primer" status --skip mac-app-store
    assert_failure
    assert_output --partial "only valid with 'update'"
}

@test "cli: --only is rejected for status" {
    run zsh "$PRIMER_DIR/bin/primer" status --only homebrew
    assert_failure
    assert_output --partial "only valid with 'update'"
}

@test "cli: --skip without argument exits 1" {
    run zsh "$PRIMER_DIR/bin/primer" update --skip
    assert_failure
    assert_output --partial "Missing argument for --skip"
}

@test "cli: --only without argument exits 1" {
    run zsh "$PRIMER_DIR/bin/primer" update --only
    assert_failure
    assert_output --partial "Missing argument for --only"
}

@test "cli: --skip and --only together exits 1" {
    run zsh "$PRIMER_DIR/bin/primer" update --skip mac-app-store --only homebrew
    assert_failure
    assert_output --partial "cannot be used together"
}

@test "cli: --profile without argument exits 1" {
    run zsh "$PRIMER_DIR/bin/primer" update --profile
    assert_failure
    assert_output --partial "Missing argument for --profile"
}

@test "cli: --addon without argument exits 1" {
    run zsh "$PRIMER_DIR/bin/primer" update --addon
    assert_failure
    assert_output --partial "Missing argument for --addon"
}

@test "cli: unknown --profile lists the profiles found on disk" {
    run env PRIMER_LOCAL="$PRIMER_DIR" zsh "$PRIMER_DIR/bin/primer" update --dry-run --profile bogus
    assert_failure
    assert_output --partial "Unknown profile: bogus"
    assert_output --partial "Valid profiles: fedora-kde, linux-vps, mac"
}

@test "cli: --log is accepted without a command and shows help" {
    run zsh "$PRIMER_DIR/bin/primer" --log
    assert_success
    assert_output --partial "Usage"
}

@test "cli: profile set persists addons and profile shows them" {
    run zsh "$PRIMER_DIR/bin/primer" profile set fedora-kde gaming
    assert_success
    assert_output --partial "Saved profile 'fedora-kde' with addons: gaming."

    run zsh "$PRIMER_DIR/bin/primer" profile
    assert_success
    assert_output --partial "Profile: fedora-kde"
    assert_output --partial "Source: machine.conf"
    assert_output --partial "Addons: gaming"
    assert_output --partial "gaming (active)"
}

@test "cli: profile set rejects an unknown addon" {
    run zsh "$PRIMER_DIR/bin/primer" profile set fedora-kde bogus
    assert_failure
    assert_output --partial "Unknown addon: bogus"
    [ ! -e "$PRIMER_MACHINE_CONF" ]
}
