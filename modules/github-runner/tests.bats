#!/usr/bin/env bats

load '../../tests/helpers/common'

setup() {
    export TEST_HOME="$(mktemp -d)"
    export TEST_CONF="$(mktemp)"
    export MOCK_DIR="$TEST_HOME/mock"
    export MOCK_LOG="$TEST_HOME/calls"
    export MOD_ITEMS_FILE="$(mktemp)"
    export GITHUB_RUNNER_SYSTEMD_DIR="$TEST_HOME/etc/systemd/system"
    export GITHUB_RUNNER_HOME="$TEST_HOME/var/lib/github-runner"
    export GITHUB_RUNNER_LIBEXEC_DIR="$TEST_HOME/usr/local/libexec"
    export DOCKER_STATE="$TEST_HOME/containers"
    mkdir -p "$MOCK_DIR" "$GITHUB_RUNNER_SYSTEMD_DIR" "$GITHUB_RUNNER_HOME" "$GITHUB_RUNNER_LIBEXEC_DIR"
    : > "$MOCK_LOG"
    : > "$DOCKER_STATE"

    cat > "$TEST_CONF" <<EOF
[github-runner]
label = GitHub Actions fleet runner
user = gha-runner
home = $GITHUB_RUNNER_HOME
labels = self-hosted,linux,fleet,{machine}
runner_version = 2.337.0
runner_sha256 = 70920811a4f8ad4328818682bca5c6469c1c942fab52448868071d0063816613
repos =
    tomagranate/relaunch
    tomagranate/primer
EOF

    cat > "$MOCK_DIR/sudo" <<'EOF'
#!/bin/sh
echo "sudo $*" >> "$MOCK_LOG"
[ "$1" = -n ] && [ "$2" = true ] && exit 0
[ "$1" = -n ] && shift
exec "$@"
EOF
    cat > "$MOCK_DIR/id" <<'EOF'
#!/bin/sh
[ "$1" = -un ] && { echo tester; exit 0; }
exec /usr/bin/id "$@"
EOF
    cat > "$MOCK_DIR/getent" <<'EOF'
#!/bin/sh
echo "getent $*" >> "$MOCK_LOG"
[ "$1" = passwd ] && [ "$2" = gha-runner ] && [ -f "$GITHUB_RUNNER_HOME/.user-exists" ] && exit 0
[ "$1" = group ] && [ "$2" = docker ] && exit 0
exit 1
EOF
    cat > "$MOCK_DIR/useradd" <<'EOF'
#!/bin/sh
echo "useradd $*" >> "$MOCK_LOG"
touch "$GITHUB_RUNNER_HOME/.user-exists"
exit 0
EOF
    cat > "$MOCK_DIR/usermod" <<'EOF'
#!/bin/sh
echo "usermod $*" >> "$MOCK_LOG"
exit 0
EOF
    cat > "$MOCK_DIR/hostname" <<'EOF'
#!/bin/sh
echo tombook-linux
EOF
    cat > "$MOCK_DIR/curl" <<'EOF'
#!/bin/sh
echo "curl $*" >> "$MOCK_LOG"
out=""
while [ "$#" -gt 0 ]; do
  [ "$1" = -o ] && { out="$2"; shift 2; continue; }
  shift
done
[ -n "$out" ] && printf 'tarball' > "$out"
exit 0
EOF
    cat > "$MOCK_DIR/sha256sum" <<'EOF'
#!/bin/sh
echo "70920811a4f8ad4328818682bca5c6469c1c942fab52448868071d0063816613  $1"
EOF
    cat > "$MOCK_DIR/tar" <<'EOF'
#!/bin/sh
echo "tar $*" >> "$MOCK_LOG"
dest=""
while [ "$#" -gt 0 ]; do
  [ "$1" = -C ] && { dest="$2"; break; }
  shift
done
[ -n "$dest" ] || exit 1
printf '#!/bin/sh\necho config $*\ntouch .runner\n' > "$dest/config.sh"
printf '#!/bin/sh\necho run\n' > "$dest/run.sh"
chmod +x "$dest/config.sh" "$dest/run.sh"
exit 0
EOF
    cat > "$MOCK_DIR/gh" <<'EOF'
#!/bin/sh
echo "gh $*" >> "$MOCK_LOG"
echo dummy-token
exit 0
EOF
    cat > "$MOCK_DIR/systemctl" <<'EOF'
#!/bin/sh
echo "systemctl $*" >> "$MOCK_LOG"
exit 0
EOF
    cat > "$MOCK_DIR/docker" <<'EOF'
#!/bin/sh
echo "docker $*" >> "$MOCK_LOG"
for last in "$@"; do :; done
case "$1" in
    ps)
        [ -n "${DOCKER_PS_OUT:-}" ] && printf '%s\n' "$DOCKER_PS_OUT"
        ;;
    inspect)
        [ -f "${DOCKER_STATE:-/dev/null}" ] || exit 0
        awk -v id="$last" '$1 == id { print $2 }' "$DOCKER_STATE"
        ;;
esac
exit 0
EOF
    cat > "$MOCK_DIR/tee" <<'EOF'
#!/bin/sh
cat > "$1"
EOF
    cat > "$MOCK_DIR/chown" <<'EOF'
#!/bin/sh
echo "chown $*" >> "$MOCK_LOG"
exit 0
EOF
    chmod +x "$MOCK_DIR"/*
}

teardown() {
    rm -rf "$TEST_HOME" "$TEST_CONF" "$MOD_ITEMS_FILE"
}

run_github_runner_module() {
    local code="$1"
    run zsh -c "
        export PRIMER_DIR='${PRIMER_DIR}'
        export DRY_RUN='${DRY_RUN:-false}'
        export MOD_DIR='${PRIMER_DIR}/modules/github-runner'
        export MOD_NAME='github-runner'
        export MOD_STATUS_FILE='$(mktemp)'
        export MOD_ITEMS_FILE='${MOD_ITEMS_FILE}'
        export HOME='${TEST_HOME}'
        export PATH='${MOCK_DIR}:/usr/bin:/bin'
        export MOCK_LOG='${MOCK_LOG}'
        export GITHUB_RUNNER_SYSTEMD_DIR='${GITHUB_RUNNER_SYSTEMD_DIR}'
        export GITHUB_RUNNER_HOME='${GITHUB_RUNNER_HOME}'
        export GITHUB_RUNNER_LIBEXEC_DIR='${GITHUB_RUNNER_LIBEXEC_DIR}'
        source \"\$PRIMER_DIR/lib/module.zsh\"
        source \"\$PRIMER_DIR/tests/helpers/module-config.zsh\"
        test::load_module_config '${TEST_CONF}'
        source \"\$MOD_DIR/module.zsh\"
        ${code}
    "
}

@test "github-runner: dry-run does not register or write units" {
    export DRY_RUN=true
    run_github_runner_module "mod_update"
    assert_success
    assert_output --partial "register runner tombook-linux-relaunch for tomagranate/relaunch"
    assert_output --partial "register runner tombook-linux-primer for tomagranate/primer"
    assert_output --partial "restart github-runner@tomagranate--relaunch.service"
    refute_output --partial "dummy-token"
    [ ! -f "$GITHUB_RUNNER_SYSTEMD_DIR/github-runner@.service" ]
}

@test "github-runner: refuses to run as the login user" {
    cat > "$TEST_CONF" <<EOF
[github-runner]
user = tester
home = $GITHUB_RUNNER_HOME
repos =
    tomagranate/relaunch
EOF
    run_github_runner_module "mod_update"
    assert_failure
    assert_output --partial "refuses to run as the login user"
}

@test "github-runner: installs units, extracts runner, and registers each repo" {
    run_github_runner_module "mod_update"
    assert_success
    [ -f "$GITHUB_RUNNER_SYSTEMD_DIR/gha-runner.slice" ]
    [ -f "$GITHUB_RUNNER_SYSTEMD_DIR/github-runner@.service" ]
    [ -x "$GITHUB_RUNNER_LIBEXEC_DIR/primer-github-runner-cleanup" ]
    grep -F "ExecStartPre=-+/usr/local/libexec/primer-github-runner-cleanup %i" \
        "$GITHUB_RUNNER_SYSTEMD_DIR/github-runner@.service"
    grep -F "ExecStopPost=-+/usr/local/libexec/primer-github-runner-cleanup %i" \
        "$GITHUB_RUNNER_SYSTEMD_DIR/github-runner@.service"
    grep -F "useradd --system" "$MOCK_LOG"
    grep -F "tomagranate--relaunch" "$MOCK_LOG"
    grep -F "tomagranate--primer" "$MOCK_LOG"
    grep -F "enable github-runner@tomagranate--relaunch.service" "$MOCK_LOG"
    grep -F "restart github-runner@tomagranate--relaunch.service" "$MOCK_LOG"
    grep -F "restart github-runner@tomagranate--primer.service" "$MOCK_LOG"
    grep -F "docker pull ghcr.io/pgup-ai/jbot-review:latest-slim" "$MOCK_LOG"
    [ -f "$GITHUB_RUNNER_HOME/tomagranate--relaunch/.runner" ]
    [ -f "$GITHUB_RUNNER_HOME/tomagranate--primer/.runner" ]
}

@test "github-runner: skips config.sh when a runner is already registered" {
    mkdir -p "$GITHUB_RUNNER_HOME/tomagranate--relaunch" "$GITHUB_RUNNER_HOME/tomagranate--primer"
    touch "$GITHUB_RUNNER_HOME/.user-exists"
    printf '2.337.0\n' > "$GITHUB_RUNNER_HOME/tomagranate--relaunch/.primer-runner-version"
    printf '2.337.0\n' > "$GITHUB_RUNNER_HOME/tomagranate--primer/.primer-runner-version"
    printf '#!/bin/sh\n' > "$GITHUB_RUNNER_HOME/tomagranate--relaunch/run.sh"
    printf '#!/bin/sh\n' > "$GITHUB_RUNNER_HOME/tomagranate--primer/run.sh"
    chmod +x "$GITHUB_RUNNER_HOME/tomagranate--relaunch/run.sh" "$GITHUB_RUNNER_HOME/tomagranate--primer/run.sh"
    touch "$GITHUB_RUNNER_HOME/tomagranate--relaunch/.runner"
    touch "$GITHUB_RUNNER_HOME/tomagranate--primer/.runner"

    run_github_runner_module "mod_update"
    assert_success
    if grep -F "config.sh" "$MOCK_LOG"; then
        echo "config.sh should not run for an existing registration" >&2
        return 1
    fi
}

run_cleanup() {
    local instance="$1"
    run env GITHUB_RUNNER_HOME="$GITHUB_RUNNER_HOME" PATH="$MOCK_DIR:$PATH" \
        "$PRIMER_DIR/modules/github-runner/files/usr/local/libexec/primer-github-runner-cleanup" \
        "$instance"
}

@test "github-runner: cleanup removes leftover jbot files for one instance" {
    instance=tomagranate--relaunch
    work="$GITHUB_RUNNER_HOME/$instance/_work/relaunch/relaunch"
    mkdir -p "$work/.jbot-review" "$GITHUB_RUNNER_HOME/$instance/_work/_temp/jbot-shard-cache"
    printf leftover > "$work/.jbot-review/telemetry.jsonl"
    printf leftover > "$GITHUB_RUNNER_HOME/$instance/_work/_temp/jbot-shard-cache/x"

    run_cleanup "$instance"
    assert_success
    [ ! -e "$work/.jbot-review" ]
    [ ! -e "$GITHUB_RUNNER_HOME/$instance/_work/_temp/jbot-shard-cache" ]
    grep -F "chown -R gha-runner:gha-runner $GITHUB_RUNNER_HOME/$instance/_work" "$MOCK_LOG"
}

@test "github-runner: cleanup kills containers that mount this instance's work tree" {
    instance=tomagranate--relaunch
    work="$GITHUB_RUNNER_HOME/$instance/_work"
    other="$GITHUB_RUNNER_HOME/tomagranate--primer/_work"
    mkdir -p "$work/relaunch/relaunch" "$other/primer/primer"
    cat > "$DOCKER_STATE" <<EOF
leftover $work/relaunch/relaunch
foreign $other/primer/primer
EOF
    export DOCKER_PS_OUT="leftover
foreign"

    run_cleanup "$instance"
    assert_success
    grep -F "docker rm -f leftover" "$MOCK_LOG"
    if grep -F "docker rm -f foreign" "$MOCK_LOG"; then
        echo "cleanup must not kill another instance's container" >&2
        return 1
    fi
}

@test "github-runner: cleanup rejects a path-shaped instance" {
    run env GITHUB_RUNNER_HOME="$GITHUB_RUNNER_HOME" \
        "$PRIMER_DIR/modules/github-runner/files/usr/local/libexec/primer-github-runner-cleanup" \
        "../etc"
    assert_failure
}

@test "github-runner: cleanup accepts a repo name with dots" {
    run_cleanup "tomagranate--relaunch..name"
    assert_success
}

@test "github-runner: mod_status fails when the cleanup helper is missing" {
    run_github_runner_module "mod_update"
    assert_success
    run_github_runner_module "mod_status"
    assert_success

    rm -f "$GITHUB_RUNNER_LIBEXEC_DIR/primer-github-runner-cleanup"
    run_github_runner_module "mod_status"
    assert_failure
}

@test "github-runner: mod_status fails when units are missing" {
    touch "$GITHUB_RUNNER_HOME/.user-exists"
    run_github_runner_module "mod_status"
    assert_failure
}
