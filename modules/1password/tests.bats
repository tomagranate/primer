#!/usr/bin/env bats
# modules/1password/tests.bats

load '../../tests/helpers/common'

setup() {
    export TEST_CONF="$(mktemp)"
    export TEST_HOME="$(mktemp -d)"
    export MOCK_DIR="$(mktemp -d)"
    export MOCK_LOG="$(mktemp)"
    export MOCK_INSTALLED="$(mktemp)"
    export MOD_STATUS_FILE="$(mktemp)"
    export MOD_ITEMS_FILE="$(mktemp)"
    export REPO_PATH="$TEST_HOME/1password.repo"

    cat > "$TEST_CONF" <<EOF
[1password]
label = 1Password
key_url = https://example.com/1password.asc
repo_path = ${REPO_PATH}
packages =
    1password
    1password-cli
app_command = 1password
cli_command = op
EOF

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

    cat > "$MOCK_DIR/rpm" <<'EOF'
#!/bin/sh
echo "rpm $*" >> "$MOCK_LOG"
if [ "$1" = "--import" ]; then
    exit 0
fi
if [ "$1" = "-q" ]; then
    grep -Fxq "$2" "$MOCK_INSTALLED" && exit 0
    exit 1
fi
exit 0
EOF
    chmod +x "$MOCK_DIR/rpm"
}

teardown() {
    rm -rf \
        "$TEST_CONF" "$TEST_HOME" "$MOCK_DIR" "$MOCK_LOG" \
        "$MOCK_INSTALLED" "$MOD_STATUS_FILE" "$MOD_ITEMS_FILE"
}

run_1password_module() {
    local code="$1"
    run zsh -c "
        export PRIMER_DIR='${PRIMER_DIR}'
        export DRY_RUN='${DRY_RUN:-false}'
        export MOD_DIR='${PRIMER_DIR}/modules/1password'
        export MOD_NAME='1password'
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

@test "1password: dry-run prints official repository and install commands" {
    export DRY_RUN=true

    run_1password_module "mod_update"

    assert_success
    assert_output --partial "sudo rpm --import https://example.com/1password.asc"
    assert_output --partial "write ${REPO_PATH}"
    assert_output --partial "sudo dnf5 -y --color=never install 1password 1password-cli"
}

@test "1password: wet run imports the key, writes the repo, and installs both packages" {
    cat > "$MOCK_DIR/dnf5" <<'EOF'
#!/bin/sh
echo "dnf5 $*" >> "$MOCK_LOG"
printf '%s\n' 1password 1password-cli > "$MOCK_INSTALLED"
cat > "$MOCK_DIR/1password" <<'APP'
#!/bin/sh
exit 0
APP
chmod +x "$MOCK_DIR/1password"
cat > "$MOCK_DIR/op" <<'OP'
#!/bin/sh
exit 0
OP
chmod +x "$MOCK_DIR/op"
EOF
    chmod +x "$MOCK_DIR/dnf5"

    cat > "$MOCK_DIR/install" <<'EOF'
#!/bin/sh
echo "install $*" >> "$MOCK_LOG"
src=""
dest=""
while [ "$#" -gt 0 ]; do
    case "$1" in
        -m)
            shift
            ;;
        *)
            if [ -z "$src" ]; then
                src="$1"
            else
                dest="$1"
            fi
            ;;
    esac
    shift
done
if [ -n "$src" ] && [ -n "$dest" ]; then
    cp "$src" "$dest"
fi
EOF
    chmod +x "$MOCK_DIR/install"

    run_1password_module "mod_update"

    assert_success
    run grep -F "rpm --import https://example.com/1password.asc" "$MOCK_LOG"
    assert_success
    run grep -F "install -m 0644" "$MOCK_LOG"
    assert_success
    run grep -F "dnf5 -y --color=never install 1password 1password-cli" "$MOCK_LOG"
    assert_success
    run grep -F "gpgkey=https://downloads.1password.com/linux/keys/1password.asc" "$REPO_PATH"
    assert_success
    refute_output --partial 'gpgkey="'
}

@test "1password: skips package install when both packages are present" {
    printf '%s\n' 1password 1password-cli > "$MOCK_INSTALLED"
    cat > "$MOCK_DIR/1password" <<'EOF'
#!/bin/sh
exit 0
EOF
    chmod +x "$MOCK_DIR/1password"
    cat > "$MOCK_DIR/op" <<'EOF'
#!/bin/sh
exit 0
EOF
    chmod +x "$MOCK_DIR/op"
    cat > "$MOCK_DIR/install" <<'EOF'
#!/bin/sh
echo "install $*" >> "$MOCK_LOG"
src=""
dest=""
while [ "$#" -gt 0 ]; do
    case "$1" in
        -m)
            shift
            ;;
        *)
            if [ -z "$src" ]; then
                src="$1"
            else
                dest="$1"
            fi
            ;;
    esac
    shift
done
if [ -n "$src" ] && [ -n "$dest" ]; then
    cp "$src" "$dest"
fi
EOF
    chmod +x "$MOCK_DIR/install"
    cat > "$MOCK_DIR/dnf5" <<'EOF'
#!/bin/sh
echo "dnf5 $*" >> "$MOCK_LOG"
exit 0
EOF
    chmod +x "$MOCK_DIR/dnf5"

    run_1password_module "mod_update"

    assert_success
    run grep -F "dnf5 -y --color=never install" "$MOCK_LOG"
    assert_failure
    run grep "$(printf 'skipped\t1password\talready installed')" "$MOD_ITEMS_FILE"
    assert_success
}

@test "1password: mod_status fails when packages are missing" {
    run_1password_module "mod_status"
    assert_failure
}

@test "1password: mod_status succeeds when repo, packages, and commands exist" {
    printf '%s\n' 1password 1password-cli > "$MOCK_INSTALLED"
    : > "$REPO_PATH"
    cat > "$MOCK_DIR/1password" <<'EOF'
#!/bin/sh
exit 0
EOF
    chmod +x "$MOCK_DIR/1password"
    cat > "$MOCK_DIR/op" <<'EOF'
#!/bin/sh
exit 0
EOF
    chmod +x "$MOCK_DIR/op"

    run_1password_module "mod_status"
    assert_success
}
