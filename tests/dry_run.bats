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
    refute_output --partial "Fedora desktop hardware"
}

@test "primer update --dry-run supports fedora-kde profile" {
    export PRIMER_LOCAL="$PRIMER_DIR"
    run zsh "$PRIMER_DIR/bin/primer" update --dry-run --log --profile fedora-kde
    assert_success
    assert_output --partial "DNF packages"
    assert_output --partial "sudo dnf5 -y --color=never install dnf5-plugins"
    assert_output --partial "sudo dnf5 -y --color=never copr enable scottames/ghostty"
    assert_output --partial "sudo dnf5 -y --color=never copr enable alternateved/keyd"
    assert_output --partial "sudo dnf5 -y --color=never copr enable imput/helium"
    assert_output --partial "sudo dnf5 -y --color=never copr enable lizardbyte/stable"
    assert_output --partial "moby-engine"
    assert_output --partial "docker-compose"
    assert_output --partial "ghostty"
    assert_output --partial "helium-bin"
    assert_output --partial "1Password"
    assert_output --partial "chatgpt.x86_64.rpm"
    assert_output --partial "sudo rpm --import https://downloads.1password.com/linux/keys/1password.asc"
    assert_output --partial "write /etc/yum.repos.d/1password.repo"
    assert_output --partial "sudo dnf5 -y --color=never install 1password 1password-cli"
    assert_output --partial "Sunshine"
    assert_output --partial "com.moonlight_stream.Moonlight"
    assert_output --partial "with qdbus-qt6"
    assert_output --partial "Flatpak apps"
    assert_output --partial "Fedora desktop hardware"
    assert_output --partial "rpmfusion-free-release"
    assert_output --partial "akmod-nvidia xorg-x11-drv-nvidia"
    assert_output --partial "10-reliable-suspend.conf"
    assert_output --partial "akmods --force --kernels"
    assert_output --partial "Fedora gaming"
    assert_output --partial "install steam steam-devices gamemode.x86_64 gamemode.i686 mangohud.x86_64 mangohud.i686 gamescope vulkan-tools"
    assert_output --partial "gamemoded -t"
    assert_output --partial "vulkaninfo --summary"
    refute_output --partial "com.valvesoftware.Steam"
    refute_output --partial "sudo apt-get"
    refute_output --partial "ghostty-ubuntu"
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

@test "primer status runs without crashing" {
    export PRIMER_LOCAL="$PRIMER_DIR"
    run zsh "$PRIMER_DIR/bin/primer" status
    # status may return 1 if things aren't installed -- that's fine
    # just verify it doesn't crash (exit code 0 or 1, not 2+)
    [[ "$status" -le 1 ]]
}
