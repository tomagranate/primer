#!/usr/bin/env bats
# modules/zsh/tests.bats

load '../../tests/helpers/common'

setup() {
    export TEST_HOME="$(mktemp -d)"
    export TEST_CONFIG_DIR="$TEST_HOME/.config"
    export MOCK_DIR="$PRIMER_DIR/tests/helpers/mocks"
    export MOCK_LOG="$(mktemp)"
    export PATH="$MOCK_DIR:$PATH"
}

teardown() {
    rm -rf "$TEST_HOME" "$MOCK_LOG"
}

@test "zsh: dry-run does not crash" {
    export DRY_RUN=true
    zsh_run_module zsh "mod_update"
    assert_success
}

@test "zsh: dry-run prints zshrc managed section update message" {
    export DRY_RUN=true
    zsh_run_module zsh "mod_update"
    assert_output --partial "update managed section"
    assert_output --partial ".zshrc"
}

@test "zsh: dry-run plans creating hushlogin" {
    export DRY_RUN=true
    zsh_run_module zsh "mod_update"
    assert_success
    assert_output --partial "[dry-run] touch"
    assert_output --partial ".hushlogin"
}

@test "zsh: update removes stale compiled managed configs in HOME" {
    mkdir -p "$TEST_HOME/.zim"
    touch "$TEST_HOME/.zim/zimfw.zsh"
    touch "$TEST_HOME/.zshrc.zwc" "$TEST_HOME/.zimrc.zwc"

    zsh_run_module zsh "mod_update"
    assert_success
    [ ! -e "$TEST_HOME/.zshrc.zwc" ]
    [ ! -e "$TEST_HOME/.zimrc.zwc" ]
}

@test "zsh: update writes .zimrc and managed section to home dotfiles" {
    mkdir -p "$TEST_HOME/.zim"
    touch "$TEST_HOME/.zim/zimfw.zsh"
    printf '%s\n' "# user preface" > "$TEST_HOME/.zshrc"

    zsh_run_module zsh "mod_update"
    assert_success
    [ -f "$TEST_HOME/.zshrc" ]
    [ -f "$TEST_HOME/.zimrc" ]
    run grep -q "PRIMER MANAGED START (modules/zsh/files/.zshrc.managed)" "$TEST_HOME/.zshrc"
    assert_success
}

@test "zsh: update preserves user lines outside managed section" {
    mkdir -p "$TEST_HOME/.zim"
    touch "$TEST_HOME/.zim/zimfw.zsh"
    cat > "$TEST_HOME/.zshrc" <<'EOF'
# keep-before
# >>> PRIMER MANAGED START (modules/zsh/files/.zshrc.managed) >>>
old content should be replaced
# <<< PRIMER MANAGED END (modules/zsh/files/.zshrc.managed) <<<
# keep-after
EOF

    zsh_run_module zsh "mod_update"
    assert_success
    run grep -q "^# keep-before$" "$TEST_HOME/.zshrc"
    assert_success
    run grep -q "^# keep-after$" "$TEST_HOME/.zshrc"
    assert_success
    run grep -q "old content should be replaced" "$TEST_HOME/.zshrc"
    assert_failure
}

@test "zsh: mod_status reports not installed when Zim is missing" {
    zsh_run_module zsh "mod_status"
    assert_failure
}

@test "zsh: mod_status fails when managed zshrc section is drifted" {
    mkdir -p "$TEST_HOME/.zim"
    touch "$TEST_HOME/.zim/zimfw.zsh"
    zsh_run_module zsh "mod_update"
    assert_success

    awk '
        /PRIMER MANAGED START/ && !inserted {
            print
            print "# drifted line"
            inserted=1
            next
        }
        { print }
    ' "$TEST_HOME/.zshrc" > "$TEST_HOME/.zshrc.tmp"
    mv "$TEST_HOME/.zshrc.tmp" "$TEST_HOME/.zshrc"

    zsh_run_module zsh "mod_status"
    assert_failure
}

@test "zsh: mod_status fails when zim modules need sync" {
    mkdir -p "$TEST_HOME/.zim"
    cat > "$TEST_HOME/.zim/zimfw.zsh" <<'EOF'
zimfw() { return 0; }
EOF

    local fakebin
    fakebin="$(mktemp -d)"
    cat > "${fakebin}/zsh" <<'EOF'
#!/bin/sh
if [ "$1" = "-c" ] && printf '%s' "$2" | grep -q "zimfw check"; then
  exit 1
fi
exec /bin/zsh "$@"
EOF
    chmod +x "${fakebin}/zsh"
    export PATH="${fakebin}:$PATH"

    zsh_run_module zsh "mod_status"
    assert_failure
    rm -rf "$fakebin"
}

@test "zsh: managed files include primer-managed markers" {
    mkdir -p "$TEST_HOME/.zim"
    touch "$TEST_HOME/.zim/zimfw.zsh"

    zsh_run_module zsh "mod_update"
    assert_success

    run grep -q "PRIMER MANAGED START" "$TEST_HOME/.zshrc"
    assert_success
    run grep -q "PRIMER MANAGED START" "$TEST_HOME/.zimrc"
    assert_success
}

@test "zsh: install path bootstraps zimfw and avoids install script" {
    local fakebin
    fakebin="$(mktemp -d)"

    cat > "${fakebin}/curl" <<'EOF'
#!/bin/sh
echo "curl $*" >> "${MOCK_LOG:-/dev/null}"
out=""
prev=""
for arg in "$@"; do
    if [ "$prev" = "-o" ]; then
        out="$arg"
        break
    fi
    prev="$arg"
done
if [ -n "$out" ]; then
    mkdir -p "$(dirname "$out")"
    cat > "$out" <<'ZEOF'
zimfw() { return 0; }
ZEOF
fi
exit 0
EOF
    chmod +x "${fakebin}/curl"

    export PATH="${fakebin}:$PATH"
    zsh_run_module zsh "mod_update"
    assert_success

    run grep -q "install/master/install.zsh" "$MOCK_LOG"
    assert_failure
    run grep -q "releases/latest/download/zimfw.zsh" "$MOCK_LOG"
    assert_success
}

@test "zsh: managed zshrc sources zimfw with init action" {
    mkdir -p "$TEST_HOME/.zim"
    touch "$TEST_HOME/.zim/zimfw.zsh"

    zsh_run_module zsh "mod_update"
    assert_success

    run grep -qE "source .*zimfw\\.zsh init -q" "$TEST_HOME/.zshrc"
    assert_success

    run grep -qE "^  source .*zimfw\\.zsh$" "$TEST_HOME/.zshrc"
    assert_failure
}

@test "zsh: docker alias defers command substitution to invocation" {
    mkdir -p "$TEST_HOME/.zim"
    touch "$TEST_HOME/.zim/zimfw.zsh"

    zsh_run_module zsh "mod_update"
    assert_success

    run grep -q 'alias docker-kill-all="docker stop \$(docker ps -q) && docker rm \$(docker ps -aq)"' "$TEST_HOME/.zshrc"
    assert_failure

    run grep -q "alias docker-kill-all='docker stop \$(docker ps -q) && docker rm \$(docker ps -aq)'" "$TEST_HOME/.zshrc"
    assert_success
}

@test "zsh: rgf is defined as a function" {
    mkdir -p "$TEST_HOME/.zim"
    touch "$TEST_HOME/.zim/zimfw.zsh"

    zsh_run_module zsh "mod_update"
    assert_success

    run grep -q 'rgf()' "$TEST_HOME/.zshrc"
    assert_success
}

@test "zsh: port is a function not an alias" {
    mkdir -p "$TEST_HOME/.zim"
    touch "$TEST_HOME/.zim/zimfw.zsh"

    zsh_run_module zsh "mod_update"
    assert_success

    run grep -q 'alias port=' "$TEST_HOME/.zshrc"
    assert_failure

    run grep -q 'port()' "$TEST_HOME/.zshrc"
    assert_success
}
