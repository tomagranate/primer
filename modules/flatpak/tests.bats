#!/usr/bin/env bats
# modules/flatpak/tests.bats

load '../../tests/helpers/common'

setup() {
    export TEST_CONF="$(mktemp)"
    export TEST_HOME="$(mktemp -d)"
    export MOCK_DIR="$(mktemp -d)"
    export MOCK_LOG="$(mktemp)"
    export MOD_ITEMS_FILE="$(mktemp)"
    cat > "$TEST_CONF" <<'EOF'
[flatpak]
label = Flatpak apps
remote = flathub
apps =
    com.spotify.Client
    com.discordapp.Discord
EOF
}

teardown() {
    rm -rf "$TEST_CONF" "$TEST_HOME" "$MOCK_DIR" "$MOCK_LOG" "$MOD_ITEMS_FILE"
}

run_flatpak_module() {
    local code="$1"
    run zsh -c "
        export PRIMER_DIR='${PRIMER_DIR}'
        export DRY_RUN='${DRY_RUN:-false}'
        export MOD_DIR='${PRIMER_DIR}/modules/flatpak'
        export MOD_NAME='flatpak'
        export MOD_STATUS_FILE='$(mktemp)'
        export MOD_ITEMS_FILE='${MOD_ITEMS_FILE}'
        export HOME='${TEST_HOME}'
        export PATH='${MOCK_DIR}:/usr/bin:/bin:/usr/sbin:/sbin'
        source \"\$PRIMER_DIR/lib/ui.zsh\"
        source \"\$PRIMER_DIR/lib/engine.zsh\"
        engine::load_config '${TEST_CONF}'
        source \"\$MOD_DIR/module.zsh\"
        ${code}
    "
}

@test "flatpak: dry-run prints remote and install commands" {
    export DRY_RUN=true
    run_flatpak_module "mod_update"
    assert_success
    assert_output --partial "flatpak remote-add --if-not-exists flathub"
    assert_output --partial "flatpak install -y flathub com.spotify.Client com.discordapp.Discord"
}

@test "flatpak: wet run configures remote through sudo and installs apps" {
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
    cat > "$MOCK_DIR/flatpak" <<'EOF'
#!/bin/sh
echo "flatpak $*" >> "$MOCK_LOG"
exit 0
EOF
    chmod +x "$MOCK_DIR/flatpak"

    run_flatpak_module "mod_update"
    assert_success
    run grep "flatpak remote-add --if-not-exists flathub" "$MOCK_LOG"
    assert_success
    run grep "flatpak install -y flathub com.spotify.Client com.discordapp.Discord" "$MOCK_LOG"
    assert_success
}

@test "flatpak: wet run fails clearly when sudo is not authenticated" {
    cat > "$MOCK_DIR/sudo" <<'EOF'
#!/bin/sh
echo "sudo $*" >> "$MOCK_LOG"
if [ "$1" = "-n" ] && [ "$2" = "true" ]; then
    exit 1
fi
exit 1
EOF
    chmod +x "$MOCK_DIR/sudo"
    cat > "$MOCK_DIR/flatpak" <<'EOF'
#!/bin/sh
echo "flatpak $*" >> "$MOCK_LOG"
exit 0
EOF
    chmod +x "$MOCK_DIR/flatpak"

    run_flatpak_module "mod_update"
    assert_failure
    assert_output --partial "sudo authentication is required for Flatpak remotes."
    assert_output --partial "authenticate first with: sudo -v"
}
