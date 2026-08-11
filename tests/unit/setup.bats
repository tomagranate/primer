#!/usr/bin/env bats
# tests/unit/setup.bats -- bootstrap behavior

load '../helpers/common'

@test "setup: installs primer command shim before running update" {
    local test_home fakebin pathbin log
    test_home="$(mktemp -d)"
    fakebin="$(mktemp -d)"
    pathbin="$test_home/path-bin"
    log="$(mktemp)"
    mkdir -p "$pathbin"

    cat > "$fakebin/curl" <<'EOF'
#!/bin/sh
out=""
while [ "$#" -gt 0 ]; do
    if [ "$1" = "-o" ]; then
        out="$2"
        shift 2
        continue
    fi
    shift
done
[ -n "$out" ] || exit 64
cat > "$out" <<'PRIMER'
#!/bin/sh
echo primer cli
PRIMER
EOF
    chmod +x "$fakebin/curl"

    cat > "$fakebin/zsh" <<'EOF'
#!/bin/sh
echo "zsh $*" >> "$MOCK_LOG"
command -v primer >> "$MOCK_LOG" || exit 65
exit 42
EOF
    chmod +x "$fakebin/zsh"

    cat > "$fakebin/bun" <<'EOF'
#!/bin/sh
exit 0
EOF
    chmod +x "$fakebin/bun"

    run env HOME="$test_home" MOCK_LOG="$log" PATH="$fakebin:$pathbin:/usr/bin:/bin" sh "$PRIMER_DIR/setup.sh"
    assert_failure 42
    assert_output --partial "primer command available at $pathbin/primer"
    [ -L "$pathbin/primer" ]
    [ "$(readlink "$pathbin/primer")" = "$test_home/bin/primer" ]
    run grep "zsh $test_home/bin/primer update" "$log"
    assert_success
    run env PATH="$pathbin:/usr/bin:/bin" primer
    assert_success
    assert_output "primer cli"

    rm -rf "$test_home" "$fakebin" "$log"
}
