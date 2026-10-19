#!/usr/bin/env bats

load '../../tests/helpers/common'

setup() {
    export TEST_HOME="$BATS_TEST_TMPDIR/home"
    export MOCK_DIR="$BATS_TEST_TMPDIR/bin"
    export MOCK_LOG="$BATS_TEST_TMPDIR/commands"
    export TEST_CONF="$BATS_TEST_TMPDIR/module.conf"
    mkdir -p "$TEST_HOME" "$MOCK_DIR"
    export PATH="$MOCK_DIR:$PATH"
    cat > "$TEST_CONF" <<CONF
[command-center]
repo_path = $TEST_HOME/code/command-center
CONF
    cat > "$MOCK_DIR/systemctl" <<'SCRIPT'
#!/bin/sh
printf 'systemctl %s\n' "$*" >> "$MOCK_LOG"
SCRIPT
    cat > "$MOCK_DIR/mise" <<'SCRIPT'
#!/bin/sh
[ "$1" = env ] && exit 0
printf 'mise %s\n' "$*" >> "$MOCK_LOG"
[ "$*" != 'exec -- pnpm build' ]
SCRIPT
    chmod +x "$MOCK_DIR/systemctl" "$MOCK_DIR/mise"
}

run_module() {
    run zsh -c "
        export PRIMER_DIR='$PRIMER_DIR' DRY_RUN='${DRY_RUN:-false}' MOD_NAME=command-center
        export MOD_STATUS_FILE='$BATS_TEST_TMPDIR/status' HOME='$TEST_HOME'
        source '$PRIMER_DIR/lib/module.zsh'
        source '$PRIMER_DIR/tests/helpers/module-config.zsh'
        test::load_module_config '$TEST_CONF'
        source '$PRIMER_DIR/modules/command-center/module.zsh'
        $1
    "
}

make_repo() {
    local repo="$TEST_HOME/code/command-center"
    mkdir -p "$repo"
    git -C "$repo" init -b master
    git -C "$repo" -c user.name=Test -c user.email=test@example.com commit --allow-empty -m initial
    git -C "$repo" remote add origin git@github.com:tomagranate/command-center.git
    # Redirect the network boundary to a real local Git remote.
    git clone --bare "$repo" "$BATS_TEST_TMPDIR/origin.git"
    export GIT_CONFIG_COUNT=1
    export GIT_CONFIG_KEY_0="url.$BATS_TEST_TMPDIR/origin.git.insteadOf"
    export GIT_CONFIG_VALUE_0=git@github.com:tomagranate/command-center.git
}

@test "command-center: dry-run reports the update without changing source or services" {
    export DRY_RUN=true
    run_module mod_update
    assert_success
    assert_output --partial 'fast-forward'
    assert_output --partial 'pnpm install --frozen-lockfile; pnpm build'
    assert_output --partial 'install Caddy route command-center'
    [ ! -d "$TEST_HOME/code/command-center" ]
    [ ! -e "$MOCK_LOG" ]
}

@test "command-center: refuses a dirty checkout before build or restart" {
    make_repo
    touch "$TEST_HOME/code/command-center/local-work"
    run_module mod_update
    assert_failure
    assert_output --partial 'checkout is dirty'
    [ -f "$TEST_HOME/code/command-center/local-work" ]
    [ ! -e "$MOCK_LOG" ]
}

@test "command-center: a failed build does not install a unit or restart the service" {
    make_repo
    run_module mod_update
    assert_failure
    assert_output --partial 'build failed. The service was not restarted.'
    grep -Fx 'mise exec -- pnpm install --frozen-lockfile' "$MOCK_LOG"
    grep -Fx 'mise exec -- pnpm build' "$MOCK_LOG"
    ! grep -F 'systemctl' "$MOCK_LOG"
    [ ! -e "$TEST_HOME/.config/systemd/user/command-center.service" ]
}
