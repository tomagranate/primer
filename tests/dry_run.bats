#!/usr/bin/env bats
# tests/dry_run.bats -- Smoke tests using primer's --dry-run mode

load 'helpers/common'

@test "primer update --dry-run completes without error" {
    export PRIMER_LOCAL="$PRIMER_DIR"
    run zsh "$PRIMER_DIR/bin/primer" update --dry-run
    assert_success
}

@test "primer update --dry-run supports linux-vps profile" {
    export PRIMER_LOCAL="$PRIMER_DIR"
    run zsh "$PRIMER_DIR/bin/primer" update --dry-run --log --profile linux-vps
    assert_success
    assert_output --partial "APT packages"
    assert_output --partial "sudo apt-get install -y"
    assert_output --partial "docker-compose-v2"
    assert_output --partial "Tailscale"
    assert_output --partial "curl -fsSL https://tailscale.com/install.sh | sudo -n sh"
    assert_output --partial "curl -fsSL https://starship.rs/install.sh | sh -s -- -y -b $HOME/.local/bin"
    refute_output --partial "docker-compose-plugin"
}

@test "primer update --dry-run supports ubuntu-desktop profile" {
    export PRIMER_LOCAL="$PRIMER_DIR"
    run zsh "$PRIMER_DIR/bin/primer" update --dry-run --log --profile ubuntu-desktop
    assert_success
    assert_output --partial "APT packages"
    assert_output --partial "ubuntu-desktop-minimal"
    assert_output --partial "docker-compose-v2"
    assert_output --partial "Tailscale"
    assert_output --partial "curl -fsSL https://tailscale.com/install.sh | sudo -n sh"
    assert_output --partial "curl -fsSL https://starship.rs/install.sh | sh -s -- -y -b $HOME/.local/bin"
    assert_output --partial "curl -fsSL https://raw.githubusercontent.com/mkasberg/ghostty-ubuntu/HEAD/install.sh | sudo -n bash"
    refute_output --partial "docker-compose-plugin"
    assert_output --partial "Flatpak apps"
}

@test "primer update --log streams plain output without TUI escapes" {
    export PRIMER_LOCAL="$PRIMER_DIR"
    run zsh "$PRIMER_DIR/bin/primer" update --dry-run --log --profile mac --only ghostty
    assert_success
    assert_output --partial "==> Ghostty terminal"
    assert_output --partial "primer: 1 modules done"
    refute_output --partial $'\e[?1049h'
    refute_output --partial $'\e[?1049l'
    refute_output --partial $'\e[?25l'
    refute_output --partial $'\e[?25h'
}

@test "primer update supports GNU script during dry-run" {
    local fakebin
    fakebin="$(mktemp -d)"
    cat > "$fakebin/script" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "--version" ]]; then
    echo "script from util-linux"
    exit 0
fi
if [[ "$1" != "-q" || "$2" != "-e" || "$3" != "-c" || -z "${4:-}" || -z "${5:-}" ]]; then
    echo "expected GNU script invocation" >&2
    exit 64
fi
bash -c "$4" > "$5" 2>&1
EOF
    chmod +x "$fakebin/script"

    export PRIMER_LOCAL="$PRIMER_DIR"
    PATH="$fakebin:$PATH" run zsh "$PRIMER_DIR/bin/primer" update --dry-run --profile mac --only ghostty
    rm -rf "$fakebin"

    assert_success
}

@test "primer update does not run sudo modules through script" {
    local fakebin
    fakebin="$(mktemp -d)"
    cat > "$fakebin/script" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "--version" ]]; then
    echo "script from util-linux"
    exit 0
fi
echo "script should not wrap sudo modules" >&2
exit 64
EOF
    chmod +x "$fakebin/script"

    export PRIMER_LOCAL="$PRIMER_DIR"
    PATH="$fakebin:$PATH" run zsh "$PRIMER_DIR/bin/primer" update --dry-run --log --profile linux-vps --only apt
    rm -rf "$fakebin"

    assert_success
    assert_output --partial "APT packages"
    refute_output --partial "script should not wrap sudo modules"
}

@test "primer update does not run privileged shell installers through script" {
    local fakebin
    fakebin="$(mktemp -d)"
    cat > "$fakebin/script" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "--version" ]]; then
    echo "script from util-linux"
    exit 0
fi
echo "script should not wrap privileged shell installers" >&2
exit 64
EOF
    chmod +x "$fakebin/script"

    export PRIMER_LOCAL="$PRIMER_DIR"
    PATH="$fakebin:$PATH" run zsh "$PRIMER_DIR/bin/primer" update --dry-run --log --profile ubuntu-desktop --only apt --only shell-installers
    rm -rf "$fakebin"

    assert_success
    assert_output --partial "Shell installers"
    assert_output --partial "sudo -n bash"
    refute_output --partial "script should not wrap privileged shell installers"
}

@test "primer status runs without crashing" {
    export PRIMER_LOCAL="$PRIMER_DIR"
    run zsh "$PRIMER_DIR/bin/primer" status
    # status may return 1 if things aren't installed -- that's fine
    # just verify it doesn't crash (exit code 0 or 1, not 2+)
    [[ "$status" -le 1 ]]
}
