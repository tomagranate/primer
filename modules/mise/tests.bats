#!/usr/bin/env bats
# modules/mise/tests.bats

load '../../tests/helpers/common'

setup() {
    export TEST_HOME="$(mktemp -d)"
    export MOCK_DIR="$PRIMER_DIR/tests/helpers/mocks"
    export MOCK_LOG="$(mktemp)"
    export MOD_ITEMS_FILE="$(mktemp)"
    export PATH="$MOCK_DIR:$PATH"
}

teardown() {
    rm -rf "$TEST_HOME" "$MOCK_LOG" "$MOD_ITEMS_FILE"
}

@test "mise: dry-run prints mise use for each tool" {
    export DRY_RUN=true
    zsh_run_module mise "mod_update"
    assert_success
    assert_output --partial "mise use --global node@lts"
    assert_output --partial "mise use --global python@3.12"
    assert_output --partial "mise use --global bun@latest"
}

@test "mise: dry-run succeeds when mise is not installed" {
    local fakebin
    fakebin="$(mktemp -d)"

    cat > "${fakebin}/brew" <<'EOF'
#!/bin/sh
exit 0
EOF
    chmod +x "${fakebin}/brew"

    export DRY_RUN=true
    export PATH="${fakebin}:/usr/bin:/bin:/usr/sbin:/sbin"

    zsh_run_module mise "mod_update"
    assert_success
    assert_output --partial "assuming Homebrew install step provides it"
    assert_output --partial "mise use --global node@lts"
}

@test "mise: wet run calls mise use for each tool" {
    zsh_run_module mise "mod_update"
    assert_success
    run grep "mise use" "$MOCK_LOG"
    assert_success
}

@test "mise: wet run writes each tool to items file as done" {
    zsh_run_module mise "mod_update"
    assert_success
    run grep "done:node@lts" "$MOD_ITEMS_FILE"
    assert_success
    run grep "done:python@3.12" "$MOD_ITEMS_FILE"
    assert_success
}

@test "mise: mod_status succeeds when configured runtimes are installed" {
    export MOCK_MISE_INSTALLED_NAMES="node python bun"
    zsh_run_module mise "mod_status"
    assert_success
}

@test "mise: mod_status fails when configured runtimes are missing" {
    export MOCK_MISE_INSTALLED_NAMES="node"
    local status_file
    status_file="$(mktemp)"
    run zsh -c "
        export PRIMER_DIR='${PRIMER_DIR}'
        export DRY_RUN='${DRY_RUN:-false}'
        export MOD_DIR='${PRIMER_DIR}/modules/mise'
        export MOD_NAME='mise'
        export MOD_STATUS_FILE='${status_file}'
        export HOME='${TEST_HOME}'
        export PATH='${PATH}'
        source \"\$PRIMER_DIR/lib/ui.zsh\"
        source \"\$PRIMER_DIR/lib/engine.zsh\"
        engine::load_config \"\$PRIMER_DIR/primer.conf\"
        source \"\$MOD_DIR/module.zsh\"
        mod_status
    "
    assert_failure
    run grep "2 missing" "$status_file"
    assert_success
    rm -f "$status_file"
}
