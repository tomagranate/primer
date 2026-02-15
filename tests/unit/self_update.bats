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
    assert_output --partial "Failed to self-update primer CLI"
}
