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
    unset PRIMER_PROFILE
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
    assert_output --partial ".zshenv"
}

@test "zsh: dry-run plans creating hushlogin" {
    export DRY_RUN=true
    zsh_run_module zsh "mod_update"
    assert_success
    assert_output --partial "[dry-run] touch"
    assert_output --partial ".hushlogin"
}

@test "zsh: managed startup runs the cached agents update check" {
    run grep -Fq 'agents _shell-check' "$PRIMER_DIR/modules/zsh/files/.zshrc.managed"
    assert_success
}

@test "zsh: managed primer wrapper reloads current shell after successful update" {
    mkdir -p "$TEST_HOME/.zim" "$TEST_HOME/bin"
    touch "$TEST_HOME/.zim/zimfw.zsh" "$TEST_HOME/.zim/init.zsh"
    printf '%s\n' 'typeset -gi PRIMER_RELOAD_COUNT=$(( ${PRIMER_RELOAD_COUNT:-0} + 1 ))' > "$TEST_HOME/.zshrc"
    cat > "$TEST_HOME/bin/primer" <<'EOF'
#!/bin/sh
exit 0
EOF
    chmod +x "$TEST_HOME/bin/primer"

    zsh_run_module zsh "mod_update"
    assert_success
    run env HOME="$TEST_HOME" ZDOTDIR="$TEST_HOME" PATH="$TEST_HOME/bin:$PATH" zsh -c '
        source "$ZDOTDIR/.zshrc"
        primer update
        print "$PRIMER_RELOAD_COUNT"
    '
    assert_success
    assert_output --partial "2"
}

@test "zsh: managed primer wrapper does not reload for dry-run or status" {
    mkdir -p "$TEST_HOME/.zim" "$TEST_HOME/bin"
    touch "$TEST_HOME/.zim/zimfw.zsh" "$TEST_HOME/.zim/init.zsh"
    printf '%s\n' 'typeset -gi PRIMER_RELOAD_COUNT=$(( ${PRIMER_RELOAD_COUNT:-0} + 1 ))' > "$TEST_HOME/.zshrc"
    cat > "$TEST_HOME/bin/primer" <<'EOF'
#!/bin/sh
exit 0
EOF
    chmod +x "$TEST_HOME/bin/primer"

    zsh_run_module zsh "mod_update"
    assert_success
    run env HOME="$TEST_HOME" ZDOTDIR="$TEST_HOME" PATH="$TEST_HOME/bin:$PATH" zsh -c '
        source "$ZDOTDIR/.zshrc"
        primer update --dry-run
        primer status
        print "$PRIMER_RELOAD_COUNT"
    '
    assert_success
    assert_output --partial "1"
}

@test "zsh: update removes stale compiled managed configs in HOME" {
    mkdir -p "$TEST_HOME/.zim"
    touch "$TEST_HOME/.zim/zimfw.zsh"
    touch "$TEST_HOME/.zshenv.zwc" "$TEST_HOME/.zshrc.zwc" "$TEST_HOME/.zimrc.zwc"

    zsh_run_module zsh "mod_update"
    assert_success
    [ ! -e "$TEST_HOME/.zshenv.zwc" ]
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
    [ -f "$TEST_HOME/.zshenv" ]
    [ -f "$TEST_HOME/.zimrc" ]
    run grep -q "PRIMER MANAGED START (modules/zsh/files/.zshrc.managed)" "$TEST_HOME/.zshrc"
    assert_success
    run grep -q "PRIMER MANAGED START (modules/zsh/files/.zshenv.managed)" "$TEST_HOME/.zshenv"
    assert_success
    run grep -q "^skip_global_compinit=1$" "$TEST_HOME/.zshenv"
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

@test "zsh: update preserves user zshenv lines outside managed section" {
    mkdir -p "$TEST_HOME/.zim"
    touch "$TEST_HOME/.zim/zimfw.zsh"
    cat > "$TEST_HOME/.zshenv" <<'EOF'
export USER_ZSHENV_VALUE=1
# >>> PRIMER MANAGED START (modules/zsh/files/.zshenv.managed) >>>
old content should be replaced
# <<< PRIMER MANAGED END (modules/zsh/files/.zshenv.managed) <<<
export USER_ZSHENV_AFTER=1
EOF

    zsh_run_module zsh "mod_update"
    assert_success
    run grep -q "^export USER_ZSHENV_VALUE=1$" "$TEST_HOME/.zshenv"
    assert_success
    run grep -q "^export USER_ZSHENV_AFTER=1$" "$TEST_HOME/.zshenv"
    assert_success
    run grep -q "^skip_global_compinit=1$" "$TEST_HOME/.zshenv"
    assert_success
    run grep -q "old content should be replaced" "$TEST_HOME/.zshenv"
    assert_failure
}

@test "zsh: ubuntu-desktop profile writes zshrc addendum" {
    export PRIMER_PROFILE=ubuntu-desktop
    mkdir -p "$TEST_HOME/.zim"
    touch "$TEST_HOME/.zim/zimfw.zsh"

    zsh_run_module zsh "mod_update"
    assert_success

    run grep -q "PRIMER MANAGED START (modules/zsh/files/zshrc-addenda/ubuntu-desktop.zsh)" "$TEST_HOME/.zshrc"
    assert_success
    run grep -q "bindkey '\\^W' backward-kill-word" "$TEST_HOME/.zshrc"
    assert_success
    run grep -q "bindkey '\\\\ew' backward-kill-line" "$TEST_HOME/.zshrc"
    assert_failure
}

@test "zsh: mac profile writes only mac zshrc addendum" {
    export PRIMER_PROFILE=mac
    mkdir -p "$TEST_HOME/.zim"
    touch "$TEST_HOME/.zim/zimfw.zsh"

    zsh_run_module zsh "mod_update"
    assert_success

    run grep -q "PRIMER MANAGED START (modules/zsh/files/zshrc-addenda/mac.zsh)" "$TEST_HOME/.zshrc"
    assert_success
    run grep -q "zshrc-addenda/ubuntu-desktop.zsh" "$TEST_HOME/.zshrc"
    assert_failure
    run grep -q "bindkey '\\^W' backward-kill-word" "$TEST_HOME/.zshrc"
    assert_failure
    run grep -q "bindkey '\\\\ew' backward-kill-line" "$TEST_HOME/.zshrc"
    assert_success
}

@test "zsh: mod_status fails when profile zshrc addendum is drifted" {
    export PRIMER_PROFILE=ubuntu-desktop
    mkdir -p "$TEST_HOME/.zim"
    touch "$TEST_HOME/.zim/zimfw.zsh"
    zsh_run_module zsh "mod_update"
    assert_success

    sed 's/backward-kill-word/backward-delete-char/' "$TEST_HOME/.zshrc" >"$TEST_HOME/.zshrc.tmp"
    mv "$TEST_HOME/.zshrc.tmp" "$TEST_HOME/.zshrc"

    zsh_run_module zsh "mod_status"
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

@test "zsh: mod_status fails when managed zshenv section is drifted" {
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
    ' "$TEST_HOME/.zshenv" > "$TEST_HOME/.zshenv.tmp"
    mv "$TEST_HOME/.zshenv.tmp" "$TEST_HOME/.zshenv"

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
case "$*" in
  *"zimfw.zsh check"*) exit 1 ;;
esac
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

@test "zsh: managed zshrc runs zimfw install action" {
    mkdir -p "$TEST_HOME/.zim"
    touch "$TEST_HOME/.zim/zimfw.zsh"

    zsh_run_module zsh "mod_update"
    assert_success

    run grep -qE "zsh .*zimfw\\.zsh install" "$TEST_HOME/.zshrc"
    assert_success

    run grep -qE "^  source .*zimfw\\.zsh$" "$TEST_HOME/.zshrc"
    assert_failure
}

@test "zsh: managed zshrc adds local bin paths before Zim init" {
    mkdir -p "$TEST_HOME/.zim"
    touch "$TEST_HOME/.zim/zimfw.zsh"

    zsh_run_module zsh "mod_update"
    assert_success

    local local_bin_line zim_init_line
    local_bin_line="$(grep -n 'HOME/.local/bin' "$TEST_HOME/.zshrc" | head -1 | cut -d: -f1)"
    zim_init_line="$(grep -n 'source .*ZIM_HOME.*/init.zsh' "$TEST_HOME/.zshrc" | head -1 | cut -d: -f1)"

    [[ -n "$local_bin_line" ]]
    [[ -n "$zim_init_line" ]]
    [[ "$local_bin_line" -lt "$zim_init_line" ]]
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
