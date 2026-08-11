#!/usr/bin/env bats
# tests/unit/profile.bats -- profile detection and config composition

load '../helpers/common'

setup() {
    TEST_OS_RELEASE="$(mktemp)"
    TEST_ROOT="$(mktemp -d)"
    mkdir -p "$TEST_ROOT/configs/profiles"
}

teardown() {
    rm -f "$TEST_OS_RELEASE"
    rm -rf "$TEST_ROOT"
}

@test "profile: explicit profile wins" {
    run zsh -c "
        export PRIMER_SOURCE_ONLY=1
        source '$PRIMER_DIR/lib/ui.zsh'
        source '$PRIMER_DIR/bin/primer'
        PRIMER_DIR='$PRIMER_DIR'
        PRIMER_PROFILE=linux-vps
        primer::detect_profile
    "
    assert_success
    assert_output "linux-vps"
}

@test "profile: a new profile config on disk is accepted" {
    touch "$TEST_ROOT/configs/profiles/acme.conf"
    run zsh -c "
        export PRIMER_SOURCE_ONLY=1
        source '$PRIMER_DIR/lib/ui.zsh'
        source '$PRIMER_DIR/bin/primer'
        PRIMER_DIR='$TEST_ROOT'
        PRIMER_PROFILE=acme
        primer::detect_profile
    "
    assert_success
    assert_output "acme"
}

@test "profile: unknown profile lists the profiles found on disk" {
    touch "$TEST_ROOT/configs/profiles/acme.conf"
    touch "$TEST_ROOT/configs/profiles/zeta.conf"
    run zsh -c "
        export PRIMER_SOURCE_ONLY=1
        source '$PRIMER_DIR/lib/ui.zsh'
        source '$PRIMER_DIR/bin/primer'
        PRIMER_DIR='$TEST_ROOT'
        PRIMER_PROFILE=bogus
        primer::detect_profile
    "
    assert_failure
    assert_output --partial "Unknown profile: bogus"
    assert_output --partial "Valid profiles: acme, zeta"
}

@test "profile: repo profiles are all valid" {
    run zsh -c "
        export PRIMER_SOURCE_ONLY=1
        source '$PRIMER_DIR/lib/ui.zsh'
        source '$PRIMER_DIR/bin/primer'
        PRIMER_DIR='$PRIMER_DIR'
        for p in mac linux-vps ubuntu-desktop; do
            primer::profile_valid \$p || { echo \"invalid: \$p\"; exit 1; }
        done
        primer::available_profiles
    "
    assert_success
    assert_line "mac"
    assert_line "linux-vps"
    assert_line "ubuntu-desktop"
}

@test "profile: path-like profile names are rejected" {
    run zsh -c "
        export PRIMER_SOURCE_ONLY=1
        source '$PRIMER_DIR/lib/ui.zsh'
        source '$PRIMER_DIR/bin/primer'
        PRIMER_DIR='$PRIMER_DIR'
        primer::profile_valid '../common' && echo YES || echo NO
    "
    assert_output "NO"
}

@test "profile: macOS detects mac" {
    run zsh -c "
        export PRIMER_SOURCE_ONLY=1
        export PRIMER_TEST_UNAME=Darwin
        source '$PRIMER_DIR/lib/ui.zsh'
        source '$PRIMER_DIR/bin/primer'
        primer::detect_profile
    "
    assert_success
    assert_output "mac"
}

@test "profile: Debian without desktop detects linux-vps" {
    cat > "$TEST_OS_RELEASE" <<'EOF'
ID=debian
ID_LIKE=debian
EOF
    run env -u DISPLAY -u WAYLAND_DISPLAY -u XDG_CURRENT_DESKTOP zsh -c "
        export PRIMER_SOURCE_ONLY=1
        export PRIMER_TEST_UNAME=Linux
        export PRIMER_OS_RELEASE_FILE='$TEST_OS_RELEASE'
        source '$PRIMER_DIR/lib/ui.zsh'
        source '$PRIMER_DIR/bin/primer'
        primer::detect_profile
    "
    assert_success
    assert_output "linux-vps"
}

@test "profile: Ubuntu desktop detects ubuntu-desktop" {
    cat > "$TEST_OS_RELEASE" <<'EOF'
ID=ubuntu
ID_LIKE=debian
EOF
    run zsh -c "
        export PRIMER_SOURCE_ONLY=1
        export PRIMER_TEST_UNAME=Linux
        export PRIMER_OS_RELEASE_FILE='$TEST_OS_RELEASE'
        export XDG_CURRENT_DESKTOP=ubuntu:GNOME
        source '$PRIMER_DIR/lib/ui.zsh'
        source '$PRIMER_DIR/bin/primer'
        primer::detect_profile
    "
    assert_success
    assert_output "ubuntu-desktop"
}

@test "profile: ambiguous non-interactive Linux fails clearly" {
    cat > "$TEST_OS_RELEASE" <<'EOF'
ID=fedora
ID_LIKE=fedora
EOF
    run env -u DISPLAY -u WAYLAND_DISPLAY -u XDG_CURRENT_DESKTOP zsh -c "
        export PRIMER_SOURCE_ONLY=1
        export PRIMER_TEST_UNAME=Linux
        export PRIMER_OS_RELEASE_FILE='$TEST_OS_RELEASE'
        source '$PRIMER_DIR/lib/ui.zsh'
        source '$PRIMER_DIR/bin/primer'
        primer::detect_profile
    "
    assert_failure
    assert_output --partial "Could not infer Linux profile non-interactively"
    assert_output --partial "--profile linux-vps"
}

@test "profile: linux-vps config composes common and profile fragments" {
    zsh_run '
        engine::load_config "$PRIMER_DIR/configs/common.conf" "$PRIMER_DIR/configs/profiles/linux-vps.conf"
        [[ ${_mod_order[(Ie)git]} -gt 0 ]] || { echo "missing git"; exit 1; }
        [[ ${_mod_order[(Ie)apt]} -gt 0 ]] || { echo "missing apt"; exit 1; }
        [[ ${_mod_order[(Ie)github-cli]} -gt 0 ]] || { echo "missing github-cli"; exit 1; }
        [[ ${_mod_order[(Ie)tailscale]} -gt 0 ]] || { echo "missing tailscale"; exit 1; }
        [[ ${_mod_order[(Ie)managed-settings]} -gt 0 ]] || { echo "missing managed-settings"; exit 1; }
        [[ ${_mod_order[(Ie)homebrew]} -eq 0 ]] || { echo "unexpected homebrew"; exit 1; }
        [[ "${_mod_deps[zsh]}" == "apt" ]] || { echo "wrong zsh dep"; exit 1; }
        [[ "${_mod_deps[tailscale]}" == "apt" ]] || { echo "wrong tailscale dep"; exit 1; }
        [[ "${_mod_deps[github-cli]}" == "apt" ]] || { echo "wrong github-cli dep"; exit 1; }
        [[ "${_mod_deps[managed-settings]}" == "shell-installers" ]] || { echo "wrong managed-settings dep"; exit 1; }
        [[ "${_login_order[*]}" == "github tailscale" ]] || { echo "wrong login order"; exit 1; }
        [[ "${_mod_config[logins.github_depends_on]}" == "ssh, git, github-cli" ]] || { echo "wrong github login dep"; exit 1; }
        [[ "${_mod_config[logins.tailscale_depends_on]}" == "tailscale" ]] || { echo "wrong tailscale login dep"; exit 1; }
        [[ "${_mod_config[logins.tailscale_requires]}" == "tailscale jq" ]] || { echo "wrong tailscale requirements"; exit 1; }
        [[ "${_mod_config[logins.tailscale_status]}" == *"OperatorUser"* ]] || { echo "missing tailscale operator status"; exit 1; }
        [[ "${_mod_config[logins.tailscale_command]}" == *"sudo tailscale set --operator"* ]] || { echo "wrong tailscale login command"; exit 1; }
        [[ "${_mod_config[managed-settings.json]}" == *"permissions.defaultMode"* ]] || { echo "missing claude settings"; exit 1; }
        [[ "${_mod_config[managed-settings.toml]}" == *"sandbox_mode|\"danger-full-access\""* ]] || { echo "missing codex settings"; exit 1; }
        [[ "${_mod_config[apt.packages]}" == *"docker-compose-v2"* ]] || { echo "missing compose v2"; exit 1; }
        apt_packages=($=_mod_config[apt.packages])
        [[ ${apt_packages[(Ie)gh]} -eq 0 ]] || { echo "unexpected distro gh package"; exit 1; }
        [[ "${_mod_config[apt.packages]}" != *"docker-compose-plugin"* ]] || { echo "unexpected docker plugin package"; exit 1; }
        [[ "${_mod_config[shell-installers.installers]}" == *"shell: sh"* ]] || { echo "missing sh installer shell"; exit 1; }
        [[ "${_mod_config[shell-installers.installers]}" == *"args: -y -b \$HOME/.local/bin"* ]] || { echo "missing user-local starship"; exit 1; }
        [[ "${_mod_config[shell-installers.installers]}" == *"name: opencode"* ]] || { echo "missing opencode"; exit 1; }
        [[ "${_mod_config[shell-installers.installers]}" == *"url: https://opencode.ai/install"* ]] || { echo "missing opencode installer"; exit 1; }
        [[ "${_mod_config[shell-installers.installers]}" == *"args: --no-modify-path"* ]] || { echo "missing opencode args"; exit 1; }
        echo "ok"
    '
    assert_success
    assert_output "ok"
}

@test "profile: ubuntu-desktop config includes apt and desktop app modules" {
    zsh_run '
        engine::load_config "$PRIMER_DIR/configs/common.conf" "$PRIMER_DIR/configs/profiles/ubuntu-desktop.conf"
        [[ ${_mod_order[(Ie)apt]} -gt 0 ]] || { echo "missing apt"; exit 1; }
        [[ ${_mod_order[(Ie)github-cli]} -gt 0 ]] || { echo "missing github-cli"; exit 1; }
        [[ ${_mod_order[(Ie)tailscale]} -gt 0 ]] || { echo "missing tailscale"; exit 1; }
        [[ ${_mod_order[(Ie)flatpak]} -gt 0 ]] || { echo "missing flatpak"; exit 1; }
        [[ ${_mod_order[(Ie)managed-settings]} -gt 0 ]] || { echo "missing managed-settings"; exit 1; }
        [[ ${_mod_order[(Ie)kde-desktop-settings]} -gt 0 ]] || { echo "missing kde-desktop-settings"; exit 1; }
        [[ ${_mod_order[(Ie)macos]} -eq 0 ]] || { echo "unexpected macos"; exit 1; }
        [[ "${_mod_deps[tailscale]}" == "apt" ]] || { echo "wrong tailscale dep"; exit 1; }
        [[ "${_mod_deps[github-cli]}" == "apt" ]] || { echo "wrong github-cli dep"; exit 1; }
        [[ "${_mod_deps[ghostty]}" == "shell-installers" ]] || { echo "wrong ghostty dep"; exit 1; }
        [[ "${_mod_deps[managed-settings]}" == "shell-installers" ]] || { echo "wrong managed-settings dep"; exit 1; }
        [[ "${_mod_deps[kde-desktop-settings]}" == "apt,ghostty" ]] || { echo "wrong kde-desktop-settings dep"; exit 1; }
        [[ "${_login_order[*]}" == "github tailscale" ]] || { echo "wrong login order"; exit 1; }
        [[ "${_mod_config[logins.github_depends_on]}" == "ssh, git, github-cli" ]] || { echo "wrong github login dep"; exit 1; }
        [[ "${_mod_config[logins.tailscale_depends_on]}" == "tailscale" ]] || { echo "wrong tailscale login dep"; exit 1; }
        [[ "${_mod_config[logins.tailscale_requires]}" == "tailscale jq" ]] || { echo "wrong tailscale requirements"; exit 1; }
        [[ "${_mod_config[logins.tailscale_status]}" == *"OperatorUser"* ]] || { echo "wrong tailscale login status"; exit 1; }
        [[ "${_mod_config[logins.tailscale_command]}" == *"sudo tailscale set --operator"* ]] || { echo "wrong tailscale login command"; exit 1; }
        [[ "${_mod_config[managed-settings.json]}" == *"opencode/opencode.jsonc|permission|\"allow\""* ]] || { echo "missing opencode settings"; exit 1; }
        [[ "${_mod_config[apt.packages]}" == *"ubuntu-desktop-minimal"* ]] || { echo "missing desktop"; exit 1; }
        [[ "${_mod_config[apt.packages]}" == *"keyd"* ]] || { echo "missing keyd"; exit 1; }
        [[ "${_mod_config[apt.packages]}" == *"docker-compose-v2"* ]] || { echo "missing compose v2"; exit 1; }
        apt_packages=($=_mod_config[apt.packages])
        [[ ${apt_packages[(Ie)gh]} -eq 0 ]] || { echo "unexpected distro gh package"; exit 1; }
        [[ "${_mod_config[apt.packages]}" != *"docker-compose-plugin"* ]] || { echo "unexpected docker plugin package"; exit 1; }
        [[ "${_mod_config[shell-installers.installers]}" == *"shell: sh"* ]] || { echo "missing sh installer shell"; exit 1; }
        [[ "${_mod_config[shell-installers.installers]}" == *"args: -y -b \$HOME/.local/bin"* ]] || { echo "missing user-local starship"; exit 1; }
        [[ "${_mod_config[shell-installers.installers]}" == *"privileged: true"* ]] || { echo "missing privileged installer"; exit 1; }
        [[ "${_mod_config[shell-installers.installers]}" == *"name: opencode"* ]] || { echo "missing opencode"; exit 1; }
        [[ "${_mod_config[shell-installers.installers]}" == *"check: opencode --version"* ]] || { echo "missing opencode check"; exit 1; }
        [[ "${_mod_config[shell-installers.installers]}" == *"args: --no-modify-path"* ]] || { echo "missing opencode args"; exit 1; }
        echo "ok"
    '
    assert_success
    assert_output "ok"
}

@test "profile: mac config includes managed settings" {
    zsh_run '
        engine::load_config "$PRIMER_DIR/configs/common.conf" "$PRIMER_DIR/configs/profiles/mac.conf"
        [[ ${_mod_order[(Ie)managed-settings]} -gt 0 ]] || { echo "missing managed-settings"; exit 1; }
        [[ "${_mod_deps[managed-settings]}" == "homebrew-apps" ]] || { echo "wrong managed-settings dep"; exit 1; }
        echo "ok"
    '
    assert_success
    assert_output "ok"
}
