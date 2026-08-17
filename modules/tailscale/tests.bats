#!/usr/bin/env bats
# modules/tailscale/tests.bats

load '../../tests/helpers/common'

setup() {
    export TEST_CONF="$(mktemp)"
    export TEST_HOME="$(mktemp -d)"
    export MOCK_DIR="$(mktemp -d)"
    export MOCK_LOG="$(mktemp)"
    export MOD_ITEMS_FILE="$(mktemp)"
    cat > "$TEST_CONF" <<'EOF'
[tailscale]
label = Tailscale
url = https://tailscale.com/install.sh
EOF
}

teardown() {
    rm -rf "$TEST_CONF" "$TEST_HOME" "$MOCK_DIR" "$MOCK_LOG" "$MOD_ITEMS_FILE"
}

run_tailscale_module() {
    local code="$1"
    run zsh -c "
        export PRIMER_DIR='${PRIMER_DIR}'
        export DRY_RUN='${DRY_RUN:-false}'
        export MOD_DIR='${PRIMER_DIR}/modules/tailscale'
        export MOD_NAME='tailscale'
        export MOD_STATUS_FILE='$(mktemp)'
        export MOD_ITEMS_FILE='${MOD_ITEMS_FILE}'
        export HOME='${TEST_HOME}'
        export TEST_HOME='${TEST_HOME}'
        export PATH='${MOCK_DIR}:${TEST_HOME}/bin:/usr/bin:/bin:/usr/sbin:/sbin'
        source \"\$PRIMER_DIR/lib/module.zsh\"
        source \"\$PRIMER_DIR/tests/helpers/module-config.zsh\"
        test::load_module_config '${TEST_CONF}'
        source \"\$MOD_DIR/module.zsh\"
        ${code}
    "
}

@test "tailscale: dry-run prints official installer command" {
    export DRY_RUN=true
    run_tailscale_module "mod_update"
    assert_success
    assert_output --partial "curl -fsSL https://tailscale.com/install.sh | sudo -n sh"
    assert_output --partial "sudo tailscale set --ssh"
}

@test "tailscale: wet run pipes official installer through sudo sh" {
    cat > "$MOCK_DIR/tailscale" <<'EOF'
#!/bin/sh
exit 1
EOF
    chmod +x "$MOCK_DIR/tailscale"
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
    cat > "$MOCK_DIR/curl" <<'EOF'
#!/bin/sh
echo "curl $*" >> "$MOCK_LOG"
cat <<'SCRIPT'
#!/bin/sh
rm -f "$MOCK_DIR/tailscale"
mkdir -p "$TEST_HOME/bin"
cat > "$TEST_HOME/bin/tailscale" <<'TAILSCALE'
#!/bin/sh
if [ "$1" = "version" ]; then
    echo "1.0.0"
    exit 0
fi
if [ "$1" = "status" ]; then
    exit 1
fi
exit 0
TAILSCALE
chmod +x "$TEST_HOME/bin/tailscale"
SCRIPT
EOF
    chmod +x "$MOCK_DIR/curl"

    run_tailscale_module "mod_update"
    assert_success
    run grep "curl -fsSL https://tailscale.com/install.sh" "$MOCK_LOG"
    assert_success
    run grep "sudo -n sh" "$MOCK_LOG"
    assert_success
}

@test "tailscale: enables ssh when the client is already connected" {
    cat > "$MOCK_DIR/tailscale" <<'EOF'
#!/bin/sh
echo "tailscale $*" >> "$MOCK_LOG"
case "$1 $2" in
    "version ")
        echo "1.0.0"
        exit 0
        ;;
    "status ")
        exit 0
        ;;
    "debug prefs")
        if [ -s "$MOCK_DIR/ssh-on" ]; then
            echo '{"RunSSH": true}'
        else
            echo '{"RunSSH": false}'
        fi
        exit 0
        ;;
    "set --ssh")
        echo on > "$MOCK_DIR/ssh-on"
        exit 0
        ;;
esac
exit 0
EOF
    chmod +x "$MOCK_DIR/tailscale"
    cat > "$MOCK_DIR/sudo" <<'EOF'
#!/bin/sh
if [ "$1" = "-n" ] && [ "$2" = "true" ]; then
    exit 0
fi
if [ "$1" = "-n" ]; then
    shift
fi
exec "$@"
EOF
    chmod +x "$MOCK_DIR/sudo"

    run_tailscale_module "mod_update"
    assert_success
    run grep "tailscale set --ssh" "$MOCK_LOG"
    assert_success
}

@test "tailscale: skips ssh until the machine is connected" {
    cat > "$MOCK_DIR/tailscale" <<'EOF'
#!/bin/sh
if [ "$1" = "version" ]; then
    echo "1.0.0"
    exit 0
fi
if [ "$1" = "status" ]; then
    exit 1
fi
exit 0
EOF
    chmod +x "$MOCK_DIR/tailscale"

    run_tailscale_module "mod_update"
    assert_success
    run grep "$(printf 'skipped\tssh\twaiting for login')" "$MOD_ITEMS_FILE"
    assert_success
}

@test "tailscale: mod_status succeeds when tailscale is installed" {
    mkdir -p "$MOCK_DIR"
    cat > "$MOCK_DIR/tailscale" <<'EOF'
#!/bin/sh
if [ "$1" = "version" ]; then
    echo "1.0.0"
    exit 0
fi
if [ "$1" = "status" ]; then
    exit 1
fi
exit 0
EOF
    chmod +x "$MOCK_DIR/tailscale"

    run_tailscale_module "mod_status"
    assert_success
}

@test "tailscale: mod_status fails when connected without ssh" {
    cat > "$MOCK_DIR/tailscale" <<'EOF'
#!/bin/sh
if [ "$1" = "version" ]; then
    echo "1.0.0"
    exit 0
fi
if [ "$1" = "status" ]; then
    exit 0
fi
if [ "$1" = "debug" ]; then
    echo '{"RunSSH": false}'
    exit 0
fi
exit 0
EOF
    chmod +x "$MOCK_DIR/tailscale"

    run_tailscale_module "mod_status"
    assert_failure
}

@test "tailscale: mod_status fails when tailscale is missing" {
    cat > "$MOCK_DIR/tailscale" <<'EOF'
#!/bin/sh
exit 1
EOF
    chmod +x "$MOCK_DIR/tailscale"

    run_tailscale_module "mod_status"
    assert_failure
}
