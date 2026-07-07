#!/usr/bin/env bats
# modules/helium-browser/tests.bats

load '../../tests/helpers/common'

setup() {
    export TEST_CONF="$(mktemp)"
    export TEST_HOME="$(mktemp -d)"
    export MOCK_DIR="$(mktemp -d)"
    export MOCK_LOG="$(mktemp)"
    export MOD_ITEMS_FILE="$(mktemp)"
    cat > "$TEST_CONF" <<'EOF'
[helium-browser]
label = Helium Browser
key_url = https://example.com/pubkey.asc
repo = deb [arch=amd64,arm64 signed-by=/usr/share/keyrings/helium.gpg] https://pkg.helium.computer/deb stable main
package = helium-bin
command = helium-browser
EOF
}

teardown() {
    rm -rf "$TEST_CONF" "$TEST_HOME" "$MOCK_DIR" "$MOCK_LOG" "$MOD_ITEMS_FILE"
}

run_helium_module() {
    local code="$1"
    run zsh -c "
        export PRIMER_DIR='${PRIMER_DIR}'
        export DRY_RUN='${DRY_RUN:-false}'
        export MOD_DIR='${PRIMER_DIR}/modules/helium-browser'
        export MOD_NAME='helium-browser'
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

@test "helium-browser: dry-run prints repository and install commands" {
    export DRY_RUN=true
    run_helium_module "mod_update"
    assert_success
    assert_output --partial "curl -fsSL https://example.com/pubkey.asc | gpg --dearmor"
    assert_output --partial "write /etc/apt/sources.list.d/helium.list"
    assert_output --partial "sudo apt-get install -y helium-bin"
}

@test "helium-browser: wet run configures repo and installs package" {
    cat > "$MOCK_DIR/curl" <<'EOF'
#!/bin/sh
echo "curl $*" >> "$MOCK_LOG"
echo "fake-key"
EOF
    chmod +x "$MOCK_DIR/curl"
    cat > "$MOCK_DIR/gpg" <<'EOF'
#!/bin/sh
cat
EOF
    chmod +x "$MOCK_DIR/gpg"
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
            cat > "$TEST_HOME/bin/helium-browser" <<'HELIUM'
#!/bin/sh
exit 0
HELIUM
            chmod +x "$TEST_HOME/bin/helium-browser"
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

    run_helium_module "mod_update"
    assert_success
    run grep "curl -fsSL https://example.com/pubkey.asc" "$MOCK_LOG"
    assert_success
    run grep "sudo -n install -m 0644" "$MOCK_LOG"
    assert_success
    run grep "sudo -n apt-get update" "$MOCK_LOG"
    assert_success
}

@test "helium-browser: mod_status fails when package is missing" {
    cat > "$MOCK_DIR/dpkg-query" <<'EOF'
#!/bin/sh
exit 1
EOF
    chmod +x "$MOCK_DIR/dpkg-query"

    run_helium_module "mod_status"
    assert_failure
}
