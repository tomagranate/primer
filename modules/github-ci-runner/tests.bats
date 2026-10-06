#!/usr/bin/env bats

load '../../tests/helpers/common'

setup() {
    export TEST_HOME="$(mktemp -d)"
    export TEST_CONF="$(mktemp)"
    export MOCK_DIR="$TEST_HOME/mock"
    export MOCK_LOG="$TEST_HOME/calls"
    export GITHUB_CI_SYSTEMD_DIR="$TEST_HOME/etc/systemd/system"
    export GITHUB_CI_RUNNER_HOME="$TEST_HOME/var/lib/github-ci-runner"
    export GITHUB_CI_LIBEXEC_DIR="$TEST_HOME/usr/local/libexec"
    mkdir -p "$MOCK_DIR" "$GITHUB_CI_SYSTEMD_DIR" "$GITHUB_CI_RUNNER_HOME" "$GITHUB_CI_LIBEXEC_DIR"
    : > "$MOCK_LOG"

    cat > "$TEST_CONF" <<EOF
[github-ci-runner]
home = $GITHUB_CI_RUNNER_HOME
user_prefix = gha-ci-
labels = self-hosted,linux,ci-stateless,{machine}
runner_version = 2.337.0
runner_sha256 = 70920811a4f8ad4328818682bca5c6469c1c942fab52448868071d0063816613
seed_dist = $TEST_HOME/seed
repos =
    tomagranate/nerve
    tomagranate/relaunch
EOF
    mkdir -p "$TEST_HOME/seed"
    printf tarball > "$TEST_HOME/seed/actions-runner-linux-x64-2.337.0.tar.gz"

    cat > "$MOCK_DIR/getent" <<'EOF'
#!/bin/sh
[ "$1" = passwd ] && [ -f "$GITHUB_CI_RUNNER_HOME/.user-$2" ]
EOF
    cat > "$MOCK_DIR/useradd" <<'EOF'
#!/bin/sh
echo "useradd $*" >> "$MOCK_LOG"
for last in "$@"; do :; done
user="$last"
touch "$GITHUB_CI_RUNNER_HOME/.user-$user"
EOF
    cat > "$MOCK_DIR/install" <<'EOF'
#!/bin/sh
echo "install $*" >> "$MOCK_LOG"
args=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o|-g) shift 2 ;;
    *) args="$args '$1'"; shift ;;
  esac
done
eval "/usr/bin/install $args"
EOF
    cat > "$MOCK_DIR/hostname" <<'EOF'
#!/bin/sh
echo tomputer
EOF
    cat > "$MOCK_DIR/sha256sum" <<'EOF'
#!/bin/sh
echo "70920811a4f8ad4328818682bca5c6469c1c942fab52448868071d0063816613  $1"
EOF
    cat > "$MOCK_DIR/tar" <<'EOF'
#!/bin/sh
dest=""
while [ "$#" -gt 0 ]; do
  [ "$1" = -C ] && { dest="$2"; break; }
  shift
done
printf '#!/bin/sh\ntouch .runner .credentials .credentials_rsaparams\n' > "$dest/config.sh"
printf '#!/bin/sh\nexit 0\n' > "$dest/run.sh"
chmod +x "$dest/config.sh" "$dest/run.sh"
EOF
    cat > "$MOCK_DIR/gh" <<'EOF'
#!/bin/sh
echo "gh $*" >> "$MOCK_LOG"
echo registration-token
EOF
    cat > "$MOCK_DIR/systemctl" <<'EOF'
#!/bin/sh
echo "systemctl $*" >> "$MOCK_LOG"
[ "$1" = is-active ] && exit 1
exit 0
EOF
    cat > "$MOCK_DIR/tee" <<'EOF'
#!/bin/sh
cat > "$1"
EOF
    cat > "$MOCK_DIR/chown" <<'EOF'
#!/bin/sh
echo "chown $*" >> "$MOCK_LOG"
EOF
    chmod +x "$MOCK_DIR"/*
}

teardown() {
    rm -rf "$TEST_HOME" "$TEST_CONF"
}

run_module() {
    local code="$1"
    run zsh -c "
        export PRIMER_DIR='${PRIMER_DIR}'
        export DRY_RUN='${DRY_RUN:-false}'
        export MOD_DIR='${PRIMER_DIR}/modules/github-ci-runner'
        export MOD_NAME='github-ci-runner'
        export MOD_STATUS_FILE='$(mktemp)'
        export HOME='${TEST_HOME}'
        export PATH='${MOCK_DIR}:/usr/bin:/bin'
        export MOCK_LOG='${MOCK_LOG}'
        export GITHUB_CI_SYSTEMD_DIR='${GITHUB_CI_SYSTEMD_DIR}'
        export GITHUB_CI_RUNNER_HOME='${GITHUB_CI_RUNNER_HOME}'
        export GITHUB_CI_LIBEXEC_DIR='${GITHUB_CI_LIBEXEC_DIR}'
        source \"\$PRIMER_DIR/lib/module.zsh\"
        source \"\$PRIMER_DIR/tests/helpers/module-config.zsh\"
        test::load_module_config '${TEST_CONF}'
        source \"\$MOD_DIR/module.zsh\"
        ${code}
    "
}

@test "github-ci-runner: dry-run is scoped to new CI units" {
    export DRY_RUN=true
    run_module "mod_update"
    assert_success
    assert_output --partial "register tomputer-ci-nerve"
    assert_output --partial "register tomputer-ci-relaunch"
    refute_output --partial "github-runner@tomagranate"
    [ ! -f "$GITHUB_CI_SYSTEMD_DIR/github-ci-runner@.service" ]
}

@test "github-ci-runner: installs isolated users, units, and registrations" {
    run_module "mod_update"
    assert_success
    [ -f "$GITHUB_CI_SYSTEMD_DIR/github-ci-runner@.service" ]
    [ -f "$GITHUB_CI_SYSTEMD_DIR/gha-ci-stateless.slice" ]
    [ -x "$GITHUB_CI_LIBEXEC_DIR/primer-github-ci-runner-cleanup.sh" ]
    grep -F "ACTIONS_RUNNER_HOOK_JOB_COMPLETED=/usr/local/libexec/primer-github-ci-runner-cleanup.sh" \
        "$GITHUB_CI_SYSTEMD_DIR/github-ci-runner@.service"
    if grep -F "ACTIONS_RUNNER_HOOK_JOB_STARTED" "$GITHUB_CI_SYSTEMD_DIR/github-ci-runner@.service"; then
        echo "Job-start cleanup must not delete actions GitHub prepared for the current job" >&2
        return 1
    fi
    grep -F "User=gha-ci-%i" "$GITHUB_CI_SYSTEMD_DIR/github-ci-runner@.service"
    grep -F "MemoryMax=4G" "$GITHUB_CI_SYSTEMD_DIR/github-ci-runner@.service"
    grep -F "Environment=HOME=/var/lib/github-ci-runner/%i/_work/_home" \
        "$GITHUB_CI_SYSTEMD_DIR/github-ci-runner@.service"
    grep -F "MemoryMax=6G" "$GITHUB_CI_SYSTEMD_DIR/gha-ci-stateless.slice"
    grep -F "useradd --system --create-home --home-dir $GITHUB_CI_RUNNER_HOME/nerve --shell /usr/sbin/nologin gha-ci-nerve" "$MOCK_LOG"
    grep -F "useradd --system --create-home --home-dir $GITHUB_CI_RUNNER_HOME/relaunch --shell /usr/sbin/nologin gha-ci-relaunch" "$MOCK_LOG"
    grep -F "gh api -X POST repos/tomagranate/nerve/actions/runners/registration-token" "$MOCK_LOG"
    grep -F "systemctl start github-ci-runner@nerve.service" "$MOCK_LOG"
    grep -F "systemctl start github-ci-runner@relaunch.service" "$MOCK_LOG"
    grep -F "chown root:gha-ci-nerve $GITHUB_CI_RUNNER_HOME/nerve" "$MOCK_LOG"
    grep -F "chown root:gha-ci-relaunch $GITHUB_CI_RUNNER_HOME/relaunch" "$MOCK_LOG"
    [ "$(stat -c %a "$GITHUB_CI_RUNNER_HOME/nerve")" = 750 ]
    [ "$(stat -c %a "$GITHUB_CI_RUNNER_HOME/relaunch")" = 750 ]
    [ "$(stat -c %a "$GITHUB_CI_RUNNER_HOME/nerve/.credentials")" = 600 ]
    [ "$(stat -c %a "$GITHUB_CI_RUNNER_HOME/relaunch/.credentials_rsaparams")" = 600 ]
    if grep -E "usermod|docker|github-runner@tomagranate" "$MOCK_LOG"; then
        echo "CI setup must not grant Docker or touch Fleet units" >&2
        return 1
    fi
}

@test "github-ci-runner: cleanup removes only the selected workspace" {
    mkdir -p "$GITHUB_CI_RUNNER_HOME/nerve/_work/a" "$GITHUB_CI_RUNNER_HOME/relaunch/_work/b"
    touch "$GITHUB_CI_RUNNER_HOME/nerve/_work/a/file" "$GITHUB_CI_RUNNER_HOME/relaunch/_work/b/file"
    run env GITHUB_CI_RUNNER_HOME="$GITHUB_CI_RUNNER_HOME" \
        "$PRIMER_DIR/modules/github-ci-runner/files/usr/local/libexec/primer-github-ci-runner-cleanup.sh" nerve
    assert_success
    [ ! -e "$GITHUB_CI_RUNNER_HOME/nerve/_work/a" ]
    [ -d "$GITHUB_CI_RUNNER_HOME/nerve/_work/_home" ]
    [ -e "$GITHUB_CI_RUNNER_HOME/relaunch/_work/b/file" ]
}

@test "github-ci-runner: cleanup hook derives its workspace from HOME" {
    mkdir -p "$GITHUB_CI_RUNNER_HOME/nerve/_work/a" "$GITHUB_CI_RUNNER_HOME/relaunch/_work/b"
    touch "$GITHUB_CI_RUNNER_HOME/nerve/_work/a/file" "$GITHUB_CI_RUNNER_HOME/relaunch/_work/b/file"
    run env GITHUB_CI_RUNNER_HOME="$GITHUB_CI_RUNNER_HOME" HOME="$GITHUB_CI_RUNNER_HOME/nerve/_work/_home" \
        "$PRIMER_DIR/modules/github-ci-runner/files/usr/local/libexec/primer-github-ci-runner-cleanup.sh"
    assert_success
    [ ! -e "$GITHUB_CI_RUNNER_HOME/nerve/_work/a" ]
    [ -d "$GITHUB_CI_RUNNER_HOME/nerve/_work/_home" ]
    [ -e "$GITHUB_CI_RUNNER_HOME/relaunch/_work/b/file" ]
}

@test "github-ci-runner: cleanup rejects a path-shaped instance" {
    run env GITHUB_CI_RUNNER_HOME="$GITHUB_CI_RUNNER_HOME" \
        "$PRIMER_DIR/modules/github-ci-runner/files/usr/local/libexec/primer-github-ci-runner-cleanup.sh" ../etc
    assert_failure
}
