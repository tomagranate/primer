#!/usr/bin/env bats
# modules/dnf/tests.bats

load '../../tests/helpers/common'

setup() {
    export TEST_CONF="$(mktemp)"
    export TEST_HOME="$(mktemp -d)"
    export MOCK_DIR="$(mktemp -d)"
    export MOCK_LOG="$(mktemp)"
    export MOCK_INSTALLED="$(mktemp)"
    export MOD_STATUS_FILE="$(mktemp)"
    export MOD_ITEMS_FILE="$(mktemp)"
    export MOD_ITEM_LOG_DIR="$(mktemp -d)"

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

    cat > "$MOCK_DIR/rpm" <<'EOF'
#!/bin/sh
[ "$1" = "-q" ] || exit 2
[ "$2" = "dnf5-plugins" ] && exit 0
grep -Fxq "$2" "$MOCK_INSTALLED"
EOF
    chmod +x "$MOCK_DIR/rpm"
}

teardown() {
    rm -rf \
        "$TEST_CONF" "$TEST_HOME" "$MOCK_DIR" "$MOCK_LOG" "$MOCK_INSTALLED" \
        "$MOD_STATUS_FILE" "$MOD_ITEMS_FILE" "$MOD_ITEM_LOG_DIR"
}

dnf_module_script() {
    cat <<EOF
export PRIMER_DIR='${PRIMER_DIR}'
export DRY_RUN='${DRY_RUN:-false}'
export MOD_DIR='${PRIMER_DIR}/modules/dnf'
export MOD_NAME='dnf'
export MOD_STATUS_FILE='${MOD_STATUS_FILE}'
export MOD_ITEMS_FILE='${MOD_ITEMS_FILE}'
export MOD_ITEM_LOG_DIR='${MOD_ITEM_LOG_DIR}'
export MOCK_LOG='${MOCK_LOG}'
export MOCK_INSTALLED='${MOCK_INSTALLED}'
export HOME='${TEST_HOME}'
export PATH='${MOCK_DIR}:/usr/bin:/bin:/usr/sbin:/sbin'
source "\$PRIMER_DIR/lib/module.zsh"
source "\$PRIMER_DIR/tests/helpers/module-config.zsh"
test::load_module_config '${TEST_CONF}'
source "\$MOD_DIR/module.zsh"
mod_update
EOF
}

run_dnf_module() {
    run zsh -c "$(dnf_module_script)"
}

@test "dnf5: dry-run prints plugin, COPR, and package batches" {
    cat > "$MOCK_DIR/dnf5" <<'EOF'
#!/bin/sh
exit 0
EOF
    chmod +x "$MOCK_DIR/dnf5"
    export DRY_RUN=true

    run_dnf_module

    assert_success
    assert_output --partial "sudo dnf5 -y --color=never install dnf5-plugins"
    assert_output --partial "sudo dnf5 -y --color=never copr enable example/tools"
    assert_output --partial "sudo dnf5 -y --color=never install zsh git"
}

@test "dnf5: one batch publishes package-specific output and final states" {
    cat > "$MOCK_DIR/dnf5" <<'EOF'
#!/bin/sh
echo "dnf5 $*" >> "$MOCK_LOG"
if [ "$1" = "repolist" ]; then
    echo "copr:copr.fedorainfracloud.org:example:tools"
    exit 0
fi
echo "[1/2] zsh-5.9.x86_64 100%"
echo "Running transaction"
echo "zsh" >> "$MOCK_INSTALLED"
echo "[1/2] Installing zsh-5.9.x86_64 100%"
echo "git" >> "$MOCK_INSTALLED"
echo "[2/2] Installing git-2.50.x86_64 100%"
echo "Complete!"
EOF
    chmod +x "$MOCK_DIR/dnf5"

    run_dnf_module

    assert_success
    run grep -F "dnf5 -y --color=never install zsh git" "$MOCK_LOG"
    assert_success
    run grep "$(printf 'done\tzsh\tinstalled')" "$MOD_ITEMS_FILE"
    assert_success
    run grep "$(printf 'done\tgit\tinstalled')" "$MOD_ITEMS_FILE"
    assert_success
    run grep -R "Installing zsh" "$MOD_ITEM_LOG_DIR"
    assert_success
    run grep -R "Installing git" "$MOD_ITEM_LOG_DIR"
    assert_success
}

@test "dnf5: publishes one completed item while another remains active" {
    cat > "$MOCK_DIR/dnf5" <<'EOF'
#!/bin/sh
if [ "$1" = "repolist" ]; then
    echo "copr:copr.fedorainfracloud.org:example:tools"
    exit 0
fi
echo "Running transaction"
echo "zsh" >> "$MOCK_INSTALLED"
echo "[1/2] Installing zsh-5.9.x86_64 100%"
sleep 0.5
echo "git" >> "$MOCK_INSTALLED"
echo "[2/2] Installing git-2.50.x86_64 100%"
EOF
    chmod +x "$MOCK_DIR/dnf5"

    zsh -c "$(dnf_module_script)" > "$TEST_HOME/output" 2>&1 &
    local module_pid=$!
    local observed=false
    for _ in {1..40}; do
        if grep -q "$(printf 'done\tzsh\tinstalled')" "$MOD_ITEMS_FILE" \
            && grep -q "$(printf 'running\tgit')" "$MOD_ITEMS_FILE"; then
            observed=true
            break
        fi
        sleep 0.05
    done
    wait "$module_pid"

    "$observed"
}

@test "dnf5: copies shared batch errors into each failed item log" {
    cat > "$MOCK_DIR/dnf5" <<'EOF'
#!/bin/sh
if [ "$1" = "repolist" ]; then
    echo "copr:copr.fedorainfracloud.org:example:tools"
    exit 0
fi
echo "Failed to download repository metadata" >&2
exit 42
EOF
    chmod +x "$MOCK_DIR/dnf5"

    run_dnf_module

    assert_failure
    run grep "$(printf 'failed\tzsh\tbatch exit 42')" "$MOD_ITEMS_FILE"
    assert_success
    run grep "$(printf 'failed\tgit\tbatch exit 42')" "$MOD_ITEMS_FILE"
    assert_success
    run grep -Rl "Failed to download repository metadata" "$MOD_ITEM_LOG_DIR"
    assert_success
    [ "$(grep -Rl "Failed to download repository metadata" "$MOD_ITEM_LOG_DIR" | wc -l)" -eq 2 ]
    run cat "$MOD_STATUS_FILE"
    assert_output "Packages: 2 failed"
}

@test "dnf5: preserves a command failure after every package installs" {
    cat > "$MOCK_DIR/dnf5" <<'EOF'
#!/bin/sh
if [ "$1" = "repolist" ]; then
    echo "copr:copr.fedorainfracloud.org:example:tools"
    exit 0
fi
echo "Running transaction"
echo "zsh" >> "$MOCK_INSTALLED"
echo "git" >> "$MOCK_INSTALLED"
echo "[1/2] Installing zsh-5.9.x86_64 100%"
echo "[2/2] Installing git-2.50.x86_64 100%"
exit 17
EOF
    chmod +x "$MOCK_DIR/dnf5"

    run_dnf_module

    assert_failure
    run grep "$(printf 'done\tzsh\tinstalled')" "$MOD_ITEMS_FILE"
    assert_success
    run grep "$(printf 'done\tgit\tinstalled')" "$MOD_ITEMS_FILE"
    assert_success
    run cat "$MOD_STATUS_FILE"
    assert_output "Packages: command exit 17"
}

@test "dnf5: COPR failure reports the failed repository" {
    printf 'zsh\ngit\n' > "$MOCK_INSTALLED"
    cat > "$MOCK_DIR/dnf5" <<'EOF'
#!/bin/sh
if [ "$1" = "repolist" ]; then
    exit 0
fi
if [ "$1" = "-y" ] && [ "$3" = "copr" ]; then
    echo "COPR enable failed" >&2
    exit 42
fi
exit 0
EOF
    chmod +x "$MOCK_DIR/dnf5"

    run_dnf_module

    assert_failure
    assert_output --partial "COPR enable failed"
    run cat "$MOD_STATUS_FILE"
    assert_output "failed to enable example/tools"
}

@test "dnf5: skips one batch when every package is installed" {
    printf 'zsh\ngit\n' > "$MOCK_INSTALLED"
    cat > "$MOCK_DIR/dnf5" <<'EOF'
#!/bin/sh
echo "dnf5 $*" >> "$MOCK_LOG"
if [ "$1" = "repolist" ]; then
    echo "copr:copr.fedorainfracloud.org:example:tools"
fi
exit 0
EOF
    chmod +x "$MOCK_DIR/dnf5"

    run_dnf_module

    assert_success
    run grep -F " install " "$MOCK_LOG"
    assert_failure
    run grep "$(printf 'skipped\tzsh\talready installed')" "$MOD_ITEMS_FILE"
    assert_success
}
