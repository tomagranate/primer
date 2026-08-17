#!/usr/bin/env bats
# modules/chatgpt/tests.bats

load '../../tests/helpers/common'

setup() {
    export TEST_CONF="$(mktemp)"
    export TEST_HOME="$(mktemp -d)"
    export MOCK_DIR="$(mktemp -d)"
    export MOCK_LOG="$(mktemp)"
    export MOCK_INSTALLED="$(mktemp)"
    export MOD_STATUS_FILE="$(mktemp)"
    export MOD_ITEMS_FILE="$(mktemp)"

    cat > "$TEST_CONF" <<'EOF'
[chatgpt]
label = ChatGPT
format = rpm
EOF

    cat > "$MOCK_DIR/rpm" <<'EOF'
#!/bin/sh
[ "$1" = "-q" ] || exit 2
[ -s "$MOCK_INSTALLED" ] || exit 1
exit 0
EOF
    chmod +x "$MOCK_DIR/rpm"

    cat > "$MOCK_DIR/dpkg-query" <<'EOF'
#!/bin/sh
[ -s "$MOCK_INSTALLED" ] || exit 1
echo "install ok installed"
EOF
    chmod +x "$MOCK_DIR/dpkg-query"

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

    cat > "$MOCK_DIR/curl" <<'EOF'
#!/bin/sh
echo "curl $*" >> "$MOCK_LOG"
while [ "$#" -gt 0 ]; do
    if [ "$1" = "-o" ]; then
        shift
        echo package > "$1"
        exit 0
    fi
    shift
done
exit 1
EOF
    chmod +x "$MOCK_DIR/curl"

    cat > "$MOCK_DIR/uname" <<'EOF'
#!/bin/sh
echo x86_64
EOF
    chmod +x "$MOCK_DIR/uname"
}

teardown() {
    rm -rf \
        "$TEST_CONF" "$TEST_HOME" "$MOCK_DIR" "$MOCK_LOG" \
        "$MOCK_INSTALLED" "$MOD_STATUS_FILE" "$MOD_ITEMS_FILE"
}

run_chatgpt_module() {
    local code="$1"
    run zsh -c "
        export PRIMER_DIR='${PRIMER_DIR}'
        export DRY_RUN='${DRY_RUN:-false}'
        export MOD_DIR='${PRIMER_DIR}/modules/chatgpt'
        export MOD_NAME='chatgpt'
        export MOD_STATUS_FILE='${MOD_STATUS_FILE}'
        export MOD_ITEMS_FILE='${MOD_ITEMS_FILE}'
        export MOCK_LOG='${MOCK_LOG}'
        export MOCK_INSTALLED='${MOCK_INSTALLED}'
        export HOME='${TEST_HOME}'
        export PATH='${MOCK_DIR}:/usr/bin:/bin:/usr/sbin:/sbin'
        source \"\$PRIMER_DIR/lib/module.zsh\"
        source \"\$PRIMER_DIR/tests/helpers/module-config.zsh\"
        test::load_module_config '${TEST_CONF}'
        source \"\$MOD_DIR/module.zsh\"
        ${code}
    "
}

@test "chatgpt: RPM dry-run uses OpenAI's native package" {
    export DRY_RUN=true

    run_chatgpt_module "mod_update"

    assert_success
    assert_output --partial "chatgpt.x86_64.rpm"
    assert_output --partial "sudo dnf5 -y --color=never install <package>"
}

@test "chatgpt: installs the native RPM" {
    cat > "$MOCK_DIR/dnf5" <<'EOF'
#!/bin/sh
echo "dnf5 $*" >> "$MOCK_LOG"
echo installed > "$MOCK_INSTALLED"
EOF
    chmod +x "$MOCK_DIR/dnf5"

    run_chatgpt_module "mod_update"

    assert_success
    run grep -F "dnf5 -y --color=never install" "$MOCK_LOG"
    assert_success
    run grep -F "chatgpt.x86_64.rpm" "$MOCK_LOG"
    assert_success
}

@test "chatgpt: installs the native Debian package" {
    sed -i 's/format = rpm/format = deb/' "$TEST_CONF"
    cat > "$MOCK_DIR/apt-get" <<'EOF'
#!/bin/sh
echo "apt-get $*" >> "$MOCK_LOG"
echo installed > "$MOCK_INSTALLED"
EOF
    chmod +x "$MOCK_DIR/apt-get"

    run_chatgpt_module "mod_update"

    assert_success
    run grep -F "chatgpt_amd64.deb" "$MOCK_LOG"
    assert_success
    run grep -F "apt-get install -y" "$MOCK_LOG"
    assert_success
}

@test "chatgpt: skips an installed app" {
    echo installed > "$MOCK_INSTALLED"

    run_chatgpt_module "mod_update"

    assert_success
    run grep "$(printf 'skipped\tchatgpt\talready installed')" "$MOD_ITEMS_FILE"
    assert_success
    run grep "curl" "$MOCK_LOG"
    assert_failure
}
