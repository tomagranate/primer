#!/usr/bin/env bats
# tests/unit/items.bats -- Unit tests for primer::items_init and primer::item_update

load '../helpers/common'

setup() {
    export ITEMS_FILE="$(mktemp)"
}

teardown() {
    rm -f "$ITEMS_FILE"
}

items_run() {
    run zsh -c "
        export PRIMER_DIR='${PRIMER_DIR}'
        export MOD_ITEMS_FILE='${ITEMS_FILE}'
        source \"\$PRIMER_DIR/lib/ui.zsh\"
        $1
    "
}

@test "items_init: writes all names as pending" {
    items_run "primer::items_init alpha bravo charlie"
    assert_success
    run grep "pending:alpha" "$ITEMS_FILE"
    assert_success
    run grep "pending:bravo" "$ITEMS_FILE"
    assert_success
    run grep "pending:charlie" "$ITEMS_FILE"
    assert_success
}

@test "items_init: preserves insertion order" {
    items_run "primer::items_init first second third"
    assert_success
    run awk -F: '{print $2}' "$ITEMS_FILE"
    assert_success
    assert_output "$(printf 'first\nsecond\nthird')"
}

@test "item_update: changes state of the named item" {
    items_run "primer::items_init alpha bravo && primer::item_update alpha running"
    assert_success
    run grep "running:alpha" "$ITEMS_FILE"
    assert_success
    # bravo remains pending
    run grep "pending:bravo" "$ITEMS_FILE"
    assert_success
}

@test "item_update: can mark item as done" {
    items_run "primer::items_init alpha && primer::item_update alpha done"
    assert_success
    run grep "done:alpha" "$ITEMS_FILE"
    assert_success
}

@test "item_update: can mark item as failed" {
    items_run "primer::items_init alpha && primer::item_update alpha failed"
    assert_success
    run grep "failed:alpha" "$ITEMS_FILE"
    assert_success
    refute_output --partial "pending:alpha"
}

@test "item_update: does not duplicate lines" {
    items_run "primer::items_init alpha && primer::item_update alpha running && primer::item_update alpha done"
    assert_success
    run wc -l "$ITEMS_FILE"
    assert_success
    # File should have exactly 1 line
    [[ "$output" =~ ^[[:space:]]*1 ]]
}

@test "items_init: no-op when MOD_ITEMS_FILE is unset" {
    run zsh -c "
        export PRIMER_DIR='${PRIMER_DIR}'
        unset MOD_ITEMS_FILE
        source \"\$PRIMER_DIR/lib/ui.zsh\"
        primer::items_init alpha bravo
    "
    assert_success
}
