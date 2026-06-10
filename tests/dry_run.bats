#!/usr/bin/env bats
# tests/dry_run.bats -- Smoke tests using primer's --dry-run mode

load 'helpers/common'

@test "primer update --dry-run completes without error" {
    export PRIMER_LOCAL="$PRIMER_DIR"
    run zsh "$PRIMER_DIR/bin/primer" update --dry-run
    assert_success
}

@test "primer update supports GNU script during dry-run" {
    local fakebin
    fakebin="$(mktemp -d)"
    cat > "$fakebin/script" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "--version" ]]; then
    echo "script from util-linux"
    exit 0
fi
if [[ "$1" != "-q" || "$2" != "-e" || "$3" != "-c" || -z "${4:-}" || -z "${5:-}" ]]; then
    echo "expected GNU script invocation" >&2
    exit 64
fi
bash -c "$4" > "$5" 2>&1
EOF
    chmod +x "$fakebin/script"

    export PRIMER_LOCAL="$PRIMER_DIR"
    PATH="$fakebin:$PATH" run zsh "$PRIMER_DIR/bin/primer" update --dry-run --only ghostty
    rm -rf "$fakebin"

    assert_success
}

@test "primer status runs without crashing" {
    export PRIMER_LOCAL="$PRIMER_DIR"
    run zsh "$PRIMER_DIR/bin/primer" status
    # status may return 1 if things aren't installed -- that's fine
    # just verify it doesn't crash (exit code 0 or 1, not 2+)
    [[ "$status" -le 1 ]]
}
