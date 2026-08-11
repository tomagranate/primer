#!/usr/bin/env bats
# tests/unit/self_update.bats -- self-update decision and failure behavior

load '../helpers/common'

@test "self-update: should run only for update without dry-run and without PRIMER_LOCAL" {
    run zsh -c "
        export PRIMER_SOURCE_ONLY=1
        source '$PRIMER_DIR/bin/primer'
        set +e

        DRY_RUN=false
        unset PRIMER_LOCAL
        primer::should_self_update update || exit 11

        DRY_RUN=true
        unset PRIMER_LOCAL
        primer::should_self_update update && exit 12

        DRY_RUN=false
        PRIMER_LOCAL='$PRIMER_DIR'
        primer::should_self_update update && exit 13

        DRY_RUN=false
        unset PRIMER_LOCAL
        primer::should_self_update status && exit 14
        exit 0
    "
    assert_success
}

@test "self-update: update fails fast when CLI download fails" {
    local fakebin test_home
    fakebin="$(mktemp -d)"
    test_home="$(mktemp -d)"

    cat > "${fakebin}/curl" <<'EOF'
#!/bin/sh
exit 1
EOF
    chmod +x "${fakebin}/curl"

    run env HOME="$test_home" PATH="${fakebin}:$PATH" zsh "$PRIMER_DIR/bin/primer" update
    assert_failure
    assert_output --partial "Failed to resolve the latest Primer version"
}

@test "self-update: re-executes the downloaded launcher immediately" {
    local fakebin test_home
    fakebin="$(mktemp -d)"
    test_home="$(mktemp -d)"

    cat > "${fakebin}/curl" <<'EOF'
#!/bin/sh
out=""
url=""
while [ "$#" -gt 0 ]; do
    if [ "$1" = "-o" ]; then out="$2"; shift 2; continue; fi
    case "$1" in -*) shift ;; *) url="$1"; shift ;; esac
done
case "$url" in
*/primer-version.txt)
    printf '%s\n' 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
    exit 0
    ;;
esac
[ -n "$out" ] || exit 64
cat > "$out" <<'LAUNCHER'
#!/bin/zsh
print "new launcher ran: $*"
LAUNCHER
EOF
    chmod +x "${fakebin}/curl"

    run env HOME="$test_home" PATH="${fakebin}:$PATH" zsh "$PRIMER_DIR/bin/primer" update --profile mac
    assert_success
    assert_output "new launcher ran: update --profile mac"
}

@test "self-update: skips launcher download for the cached release" {
    local fakebin test_home version
    fakebin="$(mktemp -d)"
    test_home="$(mktemp -d)"
    version="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    mkdir -p "$test_home/bin" "$test_home/.cache/primer"
    cp "$PRIMER_DIR/bin/primer" "$test_home/bin/primer"
    printf '%s\n' "$version" > "$test_home/.cache/primer/launcher-version"

    cat > "${fakebin}/curl" <<'EOF'
#!/bin/sh
case "$*" in
    *primer-version.txt*) printf '%s\n' 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' ;;
    *) echo "unexpected download: $*" >&2; exit 64 ;;
esac
EOF
    chmod +x "${fakebin}/curl"

    run env HOME="$test_home" BIN_DIR="$test_home/bin" PATH="${fakebin}:$PATH" \
        PRIMER_SELF_UPDATED=1 zsh -c "
            export PRIMER_SOURCE_ONLY=1
            source '$PRIMER_DIR/bin/primer'
            PRIMER_RELEASE_VERSION='$version'
            BIN_DIR='$test_home/bin'
            primer::self_update
        "
    assert_success
    refute_output --partial "unexpected download"
}

@test "framework: reuses the cache for the current release" {
    local fakebin test_home version
    fakebin="$(mktemp -d)"
    test_home="$(mktemp -d)"
    version="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    mkdir -p "$test_home/.cache/primer/framework"
    printf '%s\n' "$version" > "$test_home/.cache/primer/framework/.primer-version"

    cat > "${fakebin}/curl" <<'EOF'
#!/bin/sh
echo "unexpected download: $*" >&2
exit 64
EOF
    chmod +x "${fakebin}/curl"

    run env HOME="$test_home" PATH="${fakebin}:$PATH" zsh -c "
        export PRIMER_SOURCE_ONLY=1
        source '$PRIMER_DIR/bin/primer'
        PRIMER_RELEASE_VERSION='$version'
        primer::download_framework
        [[ \"\$PRIMER_DIR\" == '$test_home/.cache/primer/framework' ]]
    "
    assert_success
    refute_output --partial "unexpected download"
}

@test "xcode guard: accepts the license only for active full Xcode" {
    local fakebin mock_log
    fakebin="$(mktemp -d)"
    mock_log="$(mktemp)"

    cat > "$fakebin/uname" <<'EOF'
#!/bin/sh
echo Darwin
EOF
    cat > "$fakebin/id" <<'EOF'
#!/bin/sh
echo 501
EOF
    cat > "$fakebin/xcode-select" <<'EOF'
#!/bin/sh
echo /Applications/Xcode.app/Contents/Developer
EOF
    cat > "$fakebin/xcodebuild" <<'EOF'
#!/bin/sh
[ "$1 $2" = "-license check" ] && exit 1
echo "xcodebuild $*" >> "$MOCK_LOG"
EOF
    cat > "$fakebin/sudo" <<'EOF'
#!/bin/sh
echo "sudo $*" >> "$MOCK_LOG"
EOF
    chmod +x "$fakebin"/*

    run env PATH="$fakebin:$PATH" MOCK_LOG="$mock_log" zsh -c "
        export PRIMER_SOURCE_ONLY=1
        source '$PRIMER_DIR/bin/primer'
        DRY_RUN=false
        primer::accept_active_xcode_license update
    "
    assert_success
    run grep "sudo xcodebuild -license accept" "$mock_log"
    assert_success
}

@test "xcode guard: leaves Command Line Tools alone" {
    local fakebin mock_log
    fakebin="$(mktemp -d)"
    mock_log="$(mktemp)"

    cat > "$fakebin/uname" <<'EOF'
#!/bin/sh
echo Darwin
EOF
    cat > "$fakebin/xcode-select" <<'EOF'
#!/bin/sh
echo /Library/Developer/CommandLineTools
EOF
    cat > "$fakebin/xcodebuild" <<'EOF'
#!/bin/sh
echo "unexpected xcodebuild $*" >> "$MOCK_LOG"
exit 1
EOF
    chmod +x "$fakebin"/*

    run env PATH="$fakebin:$PATH" MOCK_LOG="$mock_log" zsh -c "
        export PRIMER_SOURCE_ONLY=1
        source '$PRIMER_DIR/bin/primer'
        DRY_RUN=false
        primer::accept_active_xcode_license update
    "
    assert_success
    [ ! -s "$mock_log" ]
}
