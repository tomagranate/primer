#!/usr/bin/env bats
# modules/dnf/tests.bats

load '../../tests/helpers/common'

setup() {
    export TEST_CONF="$(mktemp)"
    export TEST_HOME="$(mktemp -d)"
    export MOCK_DIR="$(mktemp -d)"
    export MOCK_LOG="$(mktemp)"
    export MOD_ITEMS_FILE="$(mktemp)"
    cat > "$TEST_CONF" <<'EOF'
[dnf]
label = DNF packages
bootstrap_packages =
    dnf5-plugins
coprs =
    example/tools
packages =
    zsh
    git
EOF
}

teardown() {
    rm -rf "$TEST_CONF" "$TEST_HOME" "$MOCK_DIR" "$MOCK_LOG" "$MOD_ITEMS_FILE"
}

run_dnf_module() {
    local code="$1"
    run zsh -c "
        export PRIMER_DIR='${PRIMER_DIR}'
        export DRY_RUN='${DRY_RUN:-false}'
        export MOD_DIR='${PRIMER_DIR}/modules/dnf'
        export MOD_NAME='dnf'
        export MOD_STATUS_FILE='$(mktemp)'
        export MOD_ITEMS_FILE='${MOD_ITEMS_FILE}'
        export HOME='${TEST_HOME}'
        export PATH='${MOCK_DIR}:/usr/bin:/bin:/usr/sbin:/sbin'
        source \"\$PRIMER_DIR/lib/module.zsh\"
        source \"\$PRIMER_DIR/tests/helpers/module-config.zsh\"
        test::load_module_config '${TEST_CONF}'
        source \"\$MOD_DIR/module.zsh\"
        ${code}
    "
}

@test "dnf: dry-run prints plugin, COPR, and package commands" {
    export DRY_RUN=true
    run_dnf_module "mod_update"
    assert_success
    assert_output --partial "sudo dnf install -y dnf5-plugins"
    assert_output --partial "sudo dnf copr enable -y example/tools"
    assert_output --partial "sudo dnf install -y zsh git"
}

@test "dnf: wet run enables COPR and installs missing packages" {
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
    cat > "$MOCK_DIR/dnf" <<'EOF'
#!/bin/sh
echo "dnf $*" >> "$MOCK_LOG"
exit 0
EOF
    chmod +x "$MOCK_DIR/dnf"
    cat > "$MOCK_DIR/rpm" <<'EOF'
#!/bin/sh
if [ "$2" = "dnf5-plugins" ]; then
    exit 0
fi
if grep -q "dnf install -y zsh git" "$MOCK_LOG"; then
    exit 0
fi
exit 1
EOF
    chmod +x "$MOCK_DIR/rpm"

    run_dnf_module "mod_update"
    assert_success
    run grep -F "dnf copr enable -y example/tools" "$MOCK_LOG"
    assert_success
    run grep -F "dnf install -y zsh git" "$MOCK_LOG"
    assert_success
    run grep -F "dnf install -y dnf5-plugins" "$MOCK_LOG"
    assert_failure
}

@test "dnf: wet run skips enabled COPRs and installed packages" {
    cat > "$MOCK_DIR/dnf" <<'EOF'
#!/bin/sh
echo "dnf $*" >> "$MOCK_LOG"
if [ "$1" = "repolist" ]; then
    echo "copr:copr.fedorainfracloud.org:example:tools"
fi
exit 0
EOF
    chmod +x "$MOCK_DIR/dnf"
    cat > "$MOCK_DIR/rpm" <<'EOF'
#!/bin/sh
exit 0
EOF
    chmod +x "$MOCK_DIR/rpm"

    run_dnf_module "mod_update"
    assert_success
    run grep -F "dnf install" "$MOCK_LOG"
    assert_failure
    run grep -F "dnf copr enable" "$MOCK_LOG"
    assert_failure
}
