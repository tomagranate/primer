#!/usr/bin/env bats
# modules/github-cli/tests.bats

load '../../tests/helpers/common'

setup() {
    export TEST_CONF="$(mktemp)"
    export TEST_HOME="$(mktemp -d)"
    export MOCK_DIR="$(mktemp -d)"
    export MOCK_LOG="$(mktemp)"
    export MOD_ITEMS_FILE="$(mktemp)"
    mkdir -p "$TEST_HOME/bin"
    cat > "$TEST_CONF" <<'EOF'
[github-cli]
label = GitHub CLI
key_url = https://example.com/githubcli-archive-keyring.gpg
repo = deb [arch=amd64 signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main
package = gh
EOF
}

teardown() {
    rm -rf "$TEST_CONF" "$TEST_HOME" "$MOCK_DIR" "$MOCK_LOG" "$MOD_ITEMS_FILE"
}

run_github_cli_module() {
    local code="$1"
    run zsh -c "
        export PRIMER_DIR='${PRIMER_DIR}'
        export DRY_RUN='${DRY_RUN:-false}'
        export MOD_DIR='${PRIMER_DIR}/modules/github-cli'
        export MOD_NAME='github-cli'
        export MOD_STATUS_FILE='$(mktemp)'
        export MOD_ITEMS_FILE='${MOD_ITEMS_FILE}'
        export HOME='${TEST_HOME}'
        export PATH='${MOCK_DIR}:${TEST_HOME}/bin:/usr/bin:/bin:/usr/sbin:/sbin'
        source \"\$PRIMER_DIR/lib/ui.zsh\"
        source \"\$PRIMER_DIR/lib/engine.zsh\"
        engine::load_config '${TEST_CONF}'
        source \"\$MOD_DIR/module.zsh\"
        ${code}
    "
}

@test "github-cli: dry-run prints official repository and install commands" {
    export DRY_RUN=true
    run_github_cli_module "mod_update"
    assert_success
    assert_output --partial "install GitHub CLI apt key from https://example.com/githubcli-archive-keyring.gpg"
    assert_output --partial "write /etc/apt/sources.list.d/github-cli.list"
    assert_output --partial "sudo apt-get install -y gh"
}

@test "github-cli: wet run configures official repo and installs package" {
    cat > "$MOCK_DIR/curl" <<'EOF'
#!/bin/sh
echo "curl $*" >> "$MOCK_LOG"
echo "fake-key"
EOF
    chmod +x "$MOCK_DIR/curl"
    cat > "$MOCK_DIR/sudo" <<'EOF'
#!/bin/sh
echo "sudo $*" >> "$MOCK_LOG"
if [ "$1" = "-n" ] && [ "$2" = "true" ]; then
    exit 0
fi
if [ "$1" = "-n" ]; then
    shift
fi
case "$1" in
    install)
        exit 0
        ;;
    apt-get)
        if [ "$2" = "update" ]; then
            exit 0
        fi
        if [ "$2" = "install" ]; then
            cat > "$MOCK_DIR/dpkg-query" <<'DPKG'
#!/bin/sh
echo "install ok installed"
DPKG
            chmod +x "$MOCK_DIR/dpkg-query"
            cat > "$TEST_HOME/bin/gh" <<'GH'
#!/bin/sh
if [ "$1" = "auth" ] && [ "$2" = "status" ] && [ "$3" = "--json" ] && [ "$4" = "hosts" ]; then
    echo '{"hosts":{"github.com":[{"state":"success","active":true,"host":"github.com","login":"tomagranate"}]}}'
    exit 0
fi
exit 1
GH
            chmod +x "$TEST_HOME/bin/gh"
            exit 0
        fi
        ;;
    env)
        shift
        while [ "$#" -gt 0 ] && [ "${1#*=}" != "$1" ]; do
            shift
        done
        exec "$0" "$@"
        ;;
esac
exec "$@"
EOF
    chmod +x "$MOCK_DIR/sudo"
    cat > "$MOCK_DIR/dpkg-query" <<'EOF'
#!/bin/sh
exit 1
EOF
    chmod +x "$MOCK_DIR/dpkg-query"

    run_github_cli_module "mod_update"
    assert_success
    run grep "curl -fsSL https://example.com/githubcli-archive-keyring.gpg" "$MOCK_LOG"
    assert_success
    run grep "sudo -n install -d -m 0755 /etc/apt/keyrings" "$MOCK_LOG"
    assert_success
    run grep "sudo -n install -m 0644" "$MOCK_LOG"
    assert_success
    run grep "sudo -n apt-get update" "$MOCK_LOG"
    assert_success
}

@test "github-cli: mod_status fails when gh lacks auth json support" {
    cat > "$MOCK_DIR/dpkg-query" <<'EOF'
#!/bin/sh
echo "install ok installed"
EOF
    chmod +x "$MOCK_DIR/dpkg-query"
    cat > "$MOCK_DIR/gh" <<'EOF'
#!/bin/sh
echo "unknown flag: --json" >&2
exit 1
EOF
    chmod +x "$MOCK_DIR/gh"

    run_github_cli_module "mod_status"
    assert_failure
}
