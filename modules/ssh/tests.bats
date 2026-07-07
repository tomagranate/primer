#!/usr/bin/env bats
# modules/ssh/tests.bats

load '../../tests/helpers/common'

setup() {
    export TEST_HOME="$(mktemp -d)"
    export MOCK_DIR="$TEST_HOME/mocks"
    mkdir -p "$MOCK_DIR"
    export MOCK_LOG="$(mktemp)"
    export PATH="$MOCK_DIR:$PATH"

    cat > "$MOCK_DIR/ssh-keygen" <<'EOF'
#!/bin/sh
while [ $# -gt 0 ]; do
    case "$1" in
        -f) shift; key_path="$1" ;;
    esac
    shift
done
echo "ssh-keygen $*" >> "${MOCK_LOG:-/dev/null}"
mkdir -p "$(dirname "$key_path")"
printf 'private key\n' > "$key_path"
printf 'public key\n' > "${key_path}.pub"
EOF
    chmod +x "$MOCK_DIR/ssh-keygen"

    cat > "$MOCK_DIR/ssh-add" <<'EOF'
#!/bin/sh
echo "ssh-add $*" >> "${MOCK_LOG:-/dev/null}"
exit 0
EOF
    chmod +x "$MOCK_DIR/ssh-add"
}

teardown() {
    rm -rf "$TEST_HOME" "$MOCK_LOG"
}

@test "ssh: mod_update creates key and configures keychain-backed ssh config" {
    export PRIMER_PROFILE=mac
    zsh_run_module ssh "mod_update"
    assert_success
    [ -f "$TEST_HOME/.ssh/id_ed25519" ]
    [ -f "$TEST_HOME/.ssh/id_ed25519.pub" ]
    run grep "UseKeychain yes" "$TEST_HOME/.ssh/config"
    assert_success
    run grep "AddKeysToAgent yes" "$TEST_HOME/.ssh/config"
    assert_success
    run grep "IdentityFile $TEST_HOME/.ssh/id_ed25519" "$TEST_HOME/.ssh/config"
    assert_success
    run grep "ssh-add --apple-use-keychain $TEST_HOME/.ssh/id_ed25519" "$MOCK_LOG"
    assert_success
}

@test "ssh: mod_update does not replace an existing key" {
    mkdir -p "$TEST_HOME/.ssh"
    printf 'existing key\n' > "$TEST_HOME/.ssh/id_ed25519"
    printf 'existing public key\n' > "$TEST_HOME/.ssh/id_ed25519.pub"
    zsh_run_module ssh "mod_update"
    assert_success
    run grep "ssh-keygen" "$MOCK_LOG"
    assert_failure
    run grep "existing key" "$TEST_HOME/.ssh/id_ed25519"
    assert_success
}

@test "ssh: mod_status succeeds after update" {
    zsh_run_module ssh "mod_update"
    assert_success
    zsh_run_module ssh "mod_status"
    assert_success
}

@test "ssh: mod_status fails when key is missing" {
    zsh_run_module ssh "mod_status"
    assert_failure
}

@test "ssh: dry-run does not create key or config" {
    export DRY_RUN=true
    zsh_run_module ssh "mod_update"
    assert_success
    assert_output --partial "ssh-keygen"
    [ ! -f "$TEST_HOME/.ssh/id_ed25519" ]
    [ ! -f "$TEST_HOME/.ssh/config" ]
}

@test "ssh: linux config omits macOS keychain options" {
    export PRIMER_PROFILE=linux-vps
    zsh_run_module ssh "mod_update"
    assert_success
    run grep "UseKeychain yes" "$TEST_HOME/.ssh/config"
    assert_failure
    run grep "AddKeysToAgent yes" "$TEST_HOME/.ssh/config"
    assert_success
    run grep "ssh-add $TEST_HOME/.ssh/id_ed25519" "$MOCK_LOG"
    assert_success
}
