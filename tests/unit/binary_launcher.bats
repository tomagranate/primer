#!/usr/bin/env bats
# tests/unit/binary_launcher.bats -- native release selection and cache

load '../helpers/common'

setup() {
    export TEST_HOME="$(mktemp -d)"
    export FAKEBIN="$(mktemp -d)"
    export MOCK_BINARY="$TEST_HOME/primer-binary"
    export MOCK_VERSION="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    export MOCK_CURL_LOG="$TEST_HOME/curl.log"

    cat > "$MOCK_BINARY" <<'EOF'
#!/bin/sh
echo "native primer: $*"
EOF
    chmod +x "$MOCK_BINARY"
    if command -v shasum >/dev/null 2>&1; then
        export MOCK_HASH="$(shasum -a 256 "$MOCK_BINARY" | awk '{print $1}')"
    else
        export MOCK_HASH="$(sha256sum "$MOCK_BINARY" | awk '{print $1}')"
    fi

    cat > "$FAKEBIN/uname" <<'EOF'
#!/bin/sh
case "$1" in
    -s) echo Darwin ;;
    -m) echo arm64 ;;
esac
EOF
    chmod +x "$FAKEBIN/uname"

    cat > "$FAKEBIN/curl" <<'EOF'
#!/bin/sh
echo "$*" >> "$MOCK_CURL_LOG"
out=""
url=""
while [ "$#" -gt 0 ]; do
    case "$1" in
        -o) out="$2"; shift 2 ;;
        -*) shift ;;
        *) url="$1"; shift ;;
    esac
done
case "$url" in
    */primer-version.txt) printf '%s\n' "$MOCK_VERSION" ;;
    */primer-darwin-arm64.sha256) printf '%s  primer-darwin-arm64\n' "$MOCK_HASH" ;;
    */primer-darwin-arm64) cp "$MOCK_BINARY" "$out" ;;
    *) exit 64 ;;
esac
EOF
    chmod +x "$FAKEBIN/curl"
}

teardown() {
    rm -rf "$TEST_HOME" "$FAKEBIN"
}

@test "binary launcher downloads, verifies, and executes the native asset" {
    run env HOME="$TEST_HOME" PRIMER_LOCAL="$PRIMER_DIR" PRIMER_APP_SOURCE=0 \
        PATH="$FAKEBIN:$PATH" zsh "$PRIMER_DIR/bin/primer" --help
    assert_success
    assert_output "native primer: --help"
    [ -x "$TEST_HOME/.cache/primer/bin/primer-darwin-arm64-$MOCK_VERSION" ]
    run grep -F "releases/download/latest/primer-darwin-arm64" "$MOCK_CURL_LOG"
    assert_success
}

@test "binary launcher reuses the verified versioned cache" {
    env HOME="$TEST_HOME" PRIMER_LOCAL="$PRIMER_DIR" PRIMER_APP_SOURCE=0 \
        PATH="$FAKEBIN:$PATH" zsh "$PRIMER_DIR/bin/primer" --help >/dev/null
    : > "$MOCK_CURL_LOG"

    run env HOME="$TEST_HOME" PRIMER_LOCAL="$PRIMER_DIR" PRIMER_APP_SOURCE=0 \
        PATH="$FAKEBIN:$PATH" zsh "$PRIMER_DIR/bin/primer" status
    assert_success
    assert_output "native primer: status"
    run grep -F "primer-darwin-arm64 -o" "$MOCK_CURL_LOG"
    assert_failure
}

@test "binary launcher rejects a checksum mismatch" {
    export MOCK_HASH="bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
    run env HOME="$TEST_HOME" PRIMER_LOCAL="$PRIMER_DIR" PRIMER_APP_SOURCE=0 \
        PATH="$FAKEBIN:$PATH" zsh "$PRIMER_DIR/bin/primer" --help
    assert_failure
    assert_output --partial "Checksum verification failed"
    [ ! -e "$TEST_HOME/.cache/primer/bin/primer-darwin-arm64-$MOCK_VERSION" ]
}
