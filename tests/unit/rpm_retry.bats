#!/usr/bin/env bats
# tests/unit/rpm_retry.bats -- RPM lock detection and retry helper

load '../helpers/common'

setup() {
    export MOCK_DIR="$(mktemp -d)"
    export MOCK_LOG="$(mktemp)"
    export MOD_STATUS_FILE="$(mktemp)"
    export PRIMER_RPM_LOCK_RETRY_DELAY=0
    export PRIMER_PACKAGE_LOCK="$MOCK_DIR/package.lock"
}

teardown() {
    rm -rf "$MOCK_DIR" "$MOCK_LOG" "$MOD_STATUS_FILE"
}

_run_helper() {
    local code="$1"
    run zsh -c "
        export PRIMER_DIR='${PRIMER_DIR}'
        export MOD_STATUS_FILE='${MOD_STATUS_FILE}'
        export PRIMER_RPM_LOCK_RETRIES='${PRIMER_RPM_LOCK_RETRIES:-5}'
        export PRIMER_RPM_LOCK_RETRY_DELAY='${PRIMER_RPM_LOCK_RETRY_DELAY:-0}'
        export PRIMER_PACKAGE_LOCK='${PRIMER_PACKAGE_LOCK}'
        export PATH='${MOCK_DIR}:/usr/bin:/bin'
        source \"\$PRIMER_DIR/lib/module.zsh\"
        ${code}
    "
}

@test "is_rpm_lock_error: matches transaction lock messages" {
    _run_helper '
        primer::is_rpm_lock_error "error: can'\''t create transaction lock on /usr/lib/sysimage/rpm/.rpm.lock (Resource temporarily unavailable)" || exit 1
        primer::is_rpm_lock_error "Failed to obtain lock" || exit 1
        primer::is_rpm_lock_error "some other failure" && exit 2
        exit 0
    '
    assert_success
}

@test "run_with_rpm_retry: retries lock errors then succeeds" {
    cat > "$MOCK_DIR/flaky" <<'EOF'
#!/bin/sh
echo "run" >> "$MOCK_LOG"
count="$(wc -l < "$MOCK_LOG" | tr -d " ")"
if [ "$count" -lt 3 ]; then
    echo "error: can't create transaction lock on /usr/lib/sysimage/rpm/.rpm.lock (Resource temporarily unavailable)" >&2
    exit 1
fi
echo "ok"
exit 0
EOF
    chmod +x "$MOCK_DIR/flaky"

    export PRIMER_RPM_LOCK_RETRIES=5
    _run_helper 'primer::run_with_rpm_retry flaky'
    assert_success
    assert_output --partial "ok"
    run grep -c '^run$' "$MOCK_LOG"
    assert_output "3"
}

@test "run_with_rpm_retry: does not retry non-lock failures" {
    cat > "$MOCK_DIR/fail" <<'EOF'
#!/bin/sh
echo "run" >> "$MOCK_LOG"
echo "fatal: bad signature" >&2
exit 1
EOF
    chmod +x "$MOCK_DIR/fail"

    export PRIMER_RPM_LOCK_RETRIES=5
    _run_helper 'primer::run_with_rpm_retry fail'
    assert_failure
    assert_output --partial "fatal: bad signature"
    run grep -c '^run$' "$MOCK_LOG"
    assert_output "1"
}
