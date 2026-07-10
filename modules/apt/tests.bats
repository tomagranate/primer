#!/usr/bin/env bats
# modules/apt/tests.bats

load '../../tests/helpers/common'

setup() {
    export TEST_CONF="$(mktemp)"
    export TEST_HOME="$(mktemp -d)"
    export MOCK_DIR="$(mktemp -d)"
    export MOCK_LOG="$(mktemp)"
    export MOD_ITEMS_FILE="$(mktemp)"
    cat > "$TEST_CONF" <<'EOF'
[apt]
label = APT packages
packages =
    zsh
    git
EOF
}

teardown() {
    rm -rf "$TEST_CONF" "$TEST_HOME" "$MOCK_DIR" "$MOCK_LOG" "$MOD_ITEMS_FILE"
}

run_apt_module() {
    local code="$1"
    run zsh -c "
        export PRIMER_DIR='${PRIMER_DIR}'
        export DRY_RUN='${DRY_RUN:-false}'
        export MOD_DIR='${PRIMER_DIR}/modules/apt'
        export MOD_NAME='apt'
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

@test "apt: dry-run prints apt update and install" {
    export DRY_RUN=true
    run_apt_module "mod_update"
    assert_success
    assert_output --partial "sudo apt-get update"
    assert_output --partial "sudo apt-get install -y zsh git"
}

@test "apt: wet run calls apt-get through sudo" {
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
    cat > "$MOCK_DIR/apt-get" <<'EOF'
#!/bin/sh
echo "apt-get $*" >> "$MOCK_LOG"
exit 0
EOF
    chmod +x "$MOCK_DIR/apt-get"
    cat > "$MOCK_DIR/dpkg-query" <<'EOF'
#!/bin/sh
exit 1
EOF
    chmod +x "$MOCK_DIR/dpkg-query"

    run_apt_module "mod_update"
    assert_success
    run grep "apt-get update" "$MOCK_LOG"
    assert_success
    run grep "apt-get install -y zsh git" "$MOCK_LOG"
    assert_success
}

@test "apt: wet run skips packages already satisfied" {
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
    cat > "$MOCK_DIR/apt-get" <<'EOF'
#!/bin/sh
echo "apt-get $*" >> "$MOCK_LOG"
exit 0
EOF
    chmod +x "$MOCK_DIR/apt-get"
    cat > "$MOCK_DIR/dpkg-query" <<'EOF'
#!/bin/sh
echo "install ok installed"
exit 0
EOF
    chmod +x "$MOCK_DIR/dpkg-query"

    run_apt_module "mod_update"
    assert_success
    run grep "apt-get update" "$MOCK_LOG"
    assert_success
    run grep "apt-get install" "$MOCK_LOG"
    assert_failure
}

@test "apt: docker compose plugin satisfies Ubuntu compose v2 package" {
    cat > "$TEST_CONF" <<'EOF'
[apt]
label = APT packages
packages =
    docker.io
    docker-compose-v2
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
    cat > "$MOCK_DIR/apt-get" <<'EOF'
#!/bin/sh
echo "apt-get $*" >> "$MOCK_LOG"
exit 0
EOF
    chmod +x "$MOCK_DIR/apt-get"
    cat > "$MOCK_DIR/dpkg-query" <<'EOF'
#!/bin/sh
case "$*" in
    *docker.io*|*docker-compose-plugin*)
        echo "install ok installed"
        exit 0
        ;;
    *) exit 1 ;;
esac
EOF
    chmod +x "$MOCK_DIR/dpkg-query"
    cat > "$MOCK_DIR/docker" <<'EOF'
#!/bin/sh
if [ "$1" = "compose" ] && [ "$2" = "version" ]; then
    exit 0
fi
exit 1
EOF
    chmod +x "$MOCK_DIR/docker"

    run_apt_module "mod_update"
    assert_success
    run grep "apt-get install" "$MOCK_LOG"
    assert_failure
}

@test "apt: wet run fails clearly when sudo is not authenticated" {
    cat > "$MOCK_DIR/sudo" <<'EOF'
#!/bin/sh
echo "sudo $*" >> "$MOCK_LOG"
if [ "$1" = "-n" ] && [ "$2" = "true" ]; then
    exit 1
fi
exit 1
EOF
    chmod +x "$MOCK_DIR/sudo"
    cat > "$MOCK_DIR/apt-get" <<'EOF'
#!/bin/sh
echo "apt-get $*" >> "$MOCK_LOG"
exit 0
EOF
    chmod +x "$MOCK_DIR/apt-get"

    run_apt_module "mod_update"
    assert_failure
    assert_output --partial "sudo authentication is required for APT packages."
    assert_output --partial "authenticate first with: sudo -v"
}
