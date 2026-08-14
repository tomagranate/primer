#!/usr/bin/env bats
# tests/unit/items.bats -- Unit tests for primer::items_init and primer::item_update

load '../helpers/common'

setup() {
    export ITEMS_FILE="$(mktemp)"
    export ITEM_LOG_DIR="$(mktemp -d)"
}

teardown() {
    rm -rf "$ITEMS_FILE" "$ITEM_LOG_DIR"
}

items_run() {
    run zsh -c "
        export PRIMER_DIR='${PRIMER_DIR}'
        export MOD_ITEMS_FILE='${ITEMS_FILE}'
        export MOD_ITEM_LOG_DIR='${ITEM_LOG_DIR}'
        source \"\$PRIMER_DIR/lib/module.zsh\"
        $1
    "
}

@test "items_init: registers durable logs for every item" {
    items_run "primer::items_init alpha bravo"
    assert_success
    run cat "$ITEM_LOG_DIR/manifest"
    assert_success
    assert_output "$(printf '1\talpha\n2\tbravo')"
    [ -f "$ITEM_LOG_DIR/1.log" ]
    [ -f "$ITEM_LOG_DIR/2.log" ]
}

@test "item_log: appends output to the named item" {
    items_run "primer::items_init alpha bravo && primer::item_log bravo 'installing bravo'"
    assert_success
    run cat "$ITEM_LOG_DIR/2.log"
    assert_success
    assert_output "installing bravo"
}

@test "item_state: returns the named item's current state" {
    items_run "primer::items_init alpha bravo && primer::item_update bravo running && primer::item_state bravo"
    assert_success
    assert_output "running"
}

@test "items_init: writes all names as pending" {
    items_run "primer::items_init alpha bravo charlie"
    assert_success
    run grep "$(printf 'pending\talpha')" "$ITEMS_FILE"
    assert_success
    run grep "$(printf 'pending\tbravo')" "$ITEMS_FILE"
    assert_success
    run grep "$(printf 'pending\tcharlie')" "$ITEMS_FILE"
    assert_success
}

@test "items_init: preserves insertion order" {
    items_run "primer::items_init first second third"
    assert_success
    run awk -F'\t' '{print $2}' "$ITEMS_FILE"
    assert_success
    assert_output "$(printf 'first\nsecond\nthird')"
}

@test "item_update: changes state of the named item" {
    items_run "primer::items_init alpha bravo && primer::item_update alpha running"
    assert_success
    run grep "$(printf 'running\talpha')" "$ITEMS_FILE"
    assert_success
    # bravo remains pending
    run grep "$(printf 'pending\tbravo')" "$ITEMS_FILE"
    assert_success
}

@test "item_update: can mark item as done" {
    items_run "primer::items_init alpha && primer::item_update alpha done"
    assert_success
    run grep "$(printf 'done\talpha')" "$ITEMS_FILE"
    assert_success
}

@test "item_update: can mark item as failed" {
    items_run "primer::items_init alpha && primer::item_update alpha failed"
    assert_success
    run grep "$(printf 'failed\talpha')" "$ITEMS_FILE"
    assert_success
    refute_output --partial "$(printf 'pending\talpha')"
}

@test "item_update: does not duplicate lines" {
    items_run "primer::items_init alpha && primer::item_update alpha running && primer::item_update alpha done"
    assert_success
    run wc -l "$ITEMS_FILE"
    assert_success
    # File should have exactly 1 line
    [[ "$output" =~ ^[[:space:]]*1 ]]
}

@test "item_update: stores optional detail text" {
    items_run "primer::items_init alpha && primer::item_update alpha skipped 'already installed outside brew cask'"
    assert_success
    run grep "$(printf 'skipped\talpha\talready installed outside brew cask')" "$ITEMS_FILE"
    assert_success
}

@test "items_init: no-op when MOD_ITEMS_FILE is unset" {
    run zsh -c "
        export PRIMER_DIR='${PRIMER_DIR}'
        unset MOD_ITEMS_FILE
        source \"\$PRIMER_DIR/lib/module.zsh\"
        primer::items_init alpha bravo
    "
    assert_success
}

@test "parallel_items: quiet workers still produce an inspectable item log" {
    local log_dir="$BATS_TEST_TMPDIR/item-logs"
    run zsh -c "
        export PRIMER_DIR='${PRIMER_DIR}'
        export MOD_ITEMS_FILE='${ITEMS_FILE}'
        export MOD_ITEM_LOG_DIR='${log_dir}'
        source \"\$PRIMER_DIR/lib/module.zsh\"
        quiet_worker() { primer::parallel_item_result done; }
        primer::items_init alpha
        primer::parallel_items 1 checking quiet_worker alpha
    "
    assert_success
    run grep -R "alpha: done" "$log_dir"
    assert_success
}
