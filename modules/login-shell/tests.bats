#!/usr/bin/env bats
# modules/login-shell/tests.bats

load '../../tests/helpers/common'

setup() {
    export TEST_HOME="$(mktemp -d)"
    export MOCK_DIR="$(mktemp -d)"
    export MOCK_LOG="$(mktemp)"
    export TEST_SHELLS_FILE="$TEST_HOME/shells"
    echo "/bin/sh" > "$TEST_SHELLS_FILE"
    cat > "$MOCK_DIR/zsh" <<'EOF'
#!/bin/sh
exit 0
EOF
    chmod +x "$MOCK_DIR/zsh"
}

teardown() {
    rm -rf "$TEST_HOME" "$MOCK_DIR" "$MOCK_LOG"
}

run_login_shell_module() {
    local code="$1"
    run zsh -c "
        export PRIMER_DIR='${PRIMER_DIR}'
        export DRY_RUN='${DRY_RUN:-false}'
        export MOD_DIR='${PRIMER_DIR}/modules/login-shell'
        export MOD_NAME='login-shell'
        export MOD_STATUS_FILE='$(mktemp)'
        export HOME='${TEST_HOME}'
        export USER='primer'
        export PRIMER_SHELLS_FILE='${TEST_SHELLS_FILE}'
        export PATH='${MOCK_DIR}:/usr/bin:/bin:/usr/sbin:/sbin'
        source \"\$PRIMER_DIR/lib/module.zsh\"
        source \"\$MOD_DIR/module.zsh\"
        ${code}
    "
}

@test "login-shell: dry-run prints chsh" {
    export DRY_RUN=true
    cat > "$MOCK_DIR/getent" <<'EOF'
#!/bin/sh
echo "primer:x:1000:1000::/home/primer:/bin/bash"
EOF
    chmod +x "$MOCK_DIR/getent"

    run_login_shell_module "mod_update"
    assert_success
    assert_output --partial "sudo -n chsh -s $MOCK_DIR/zsh primer"
}

@test "login-shell: wet run calls chsh through sudo when current shell is not zsh" {
    cat > "$MOCK_DIR/getent" <<'EOF'
#!/bin/sh
echo "primer:x:1000:1000::/home/primer:/bin/bash"
EOF
    chmod +x "$MOCK_DIR/getent"
    cat > "$MOCK_DIR/chsh" <<'EOF'
#!/bin/sh
echo "chsh $*" >> "$MOCK_LOG"
exit 0
EOF
    chmod +x "$MOCK_DIR/chsh"
    cat > "$MOCK_DIR/sudo" <<'EOF'
#!/bin/sh
echo "sudo $*" >> "$MOCK_LOG"
if [ "$1" = "-n" ] && [ "$2" = "true" ]; then
    exit 0
fi
if [ "$1" = "-n" ]; then
    shift
fi
exec "$@"
EOF
    chmod +x "$MOCK_DIR/sudo"

    run_login_shell_module "mod_update"
    assert_success
    run grep "chsh -s $MOCK_DIR/zsh primer" "$MOCK_LOG"
    assert_success
    run grep "sudo -n chsh -s $MOCK_DIR/zsh primer" "$MOCK_LOG"
    assert_success
    run grep "$MOCK_DIR/zsh" "$TEST_SHELLS_FILE"
    assert_success
}
