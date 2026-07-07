#!/usr/bin/env bats
# tests/unit/profile.bats -- profile detection and config composition

load '../helpers/common'

setup() {
    TEST_OS_RELEASE="$(mktemp)"
}

teardown() {
    rm -f "$TEST_OS_RELEASE"
}

@test "profile: explicit profile wins" {
    run zsh -c "
        export PRIMER_SOURCE_ONLY=1
        source '$PRIMER_DIR/bin/primer'
        PRIMER_PROFILE=linux-vps
        primer::detect_profile
    "
    assert_success
    assert_output "linux-vps"
}

@test "profile: macOS detects mac" {
    run zsh -c "
        export PRIMER_SOURCE_ONLY=1
        export PRIMER_TEST_UNAME=Darwin
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
        [[ ${_mod_order[(Ie)tailscale]} -gt 0 ]] || { echo "missing tailscale"; exit 1; }
        [[ ${_mod_order[(Ie)homebrew]} -eq 0 ]] || { echo "unexpected homebrew"; exit 1; }
        [[ "${_mod_deps[zsh]}" == "apt" ]] || { echo "wrong zsh dep"; exit 1; }
        [[ "${_mod_deps[tailscale]}" == "apt" ]] || { echo "wrong tailscale dep"; exit 1; }
        [[ "${_mod_config[logins.github_depends_on]}" == "ssh, apt" ]] || { echo "wrong login dep"; exit 1; }
        [[ "${_mod_config[apt.packages]}" == *"docker-compose-v2"* ]] || { echo "missing compose v2"; exit 1; }
        [[ "${_mod_config[apt.packages]}" != *"docker-compose-plugin"* ]] || { echo "unexpected docker plugin package"; exit 1; }
        [[ "${_mod_config[shell-installers.installers]}" != *"darkbloom"* ]] || { echo "unexpected darkbloom"; exit 1; }
        [[ "${_mod_config[shell-installers.installers]}" == *"shell: sh"* ]] || { echo "missing sh installer shell"; exit 1; }
        echo "ok"
    '
    assert_success
    assert_output "ok"
}

@test "profile: ubuntu-desktop config includes apt and desktop app modules" {
    zsh_run '
        engine::load_config "$PRIMER_DIR/configs/common.conf" "$PRIMER_DIR/configs/profiles/ubuntu-desktop.conf"
        [[ ${_mod_order[(Ie)apt]} -gt 0 ]] || { echo "missing apt"; exit 1; }
        [[ ${_mod_order[(Ie)tailscale]} -gt 0 ]] || { echo "missing tailscale"; exit 1; }
        [[ ${_mod_order[(Ie)flatpak]} -gt 0 ]] || { echo "missing flatpak"; exit 1; }
        [[ ${_mod_order[(Ie)macos]} -eq 0 ]] || { echo "unexpected macos"; exit 1; }
        [[ "${_mod_deps[tailscale]}" == "apt" ]] || { echo "wrong tailscale dep"; exit 1; }
        [[ "${_mod_deps[ghostty]}" == "shell-installers" ]] || { echo "wrong ghostty dep"; exit 1; }
        [[ "${_mod_config[apt.packages]}" == *"ubuntu-desktop-minimal"* ]] || { echo "missing desktop"; exit 1; }
        [[ "${_mod_config[apt.packages]}" == *"docker-compose-v2"* ]] || { echo "missing compose v2"; exit 1; }
        [[ "${_mod_config[apt.packages]}" != *"docker-compose-plugin"* ]] || { echo "unexpected docker plugin package"; exit 1; }
        [[ "${_mod_config[shell-installers.installers]}" != *"darkbloom"* ]] || { echo "unexpected darkbloom"; exit 1; }
        [[ "${_mod_config[shell-installers.installers]}" == *"shell: sh"* ]] || { echo "missing sh installer shell"; exit 1; }
        [[ "${_mod_config[shell-installers.installers]}" == *"privileged: true"* ]] || { echo "missing privileged installer"; exit 1; }
        echo "ok"
    '
    assert_success
    assert_output "ok"
}

@test "profile: mac config includes darkbloom shell installer" {
    zsh_run '
        engine::load_config "$PRIMER_DIR/configs/common.conf" "$PRIMER_DIR/configs/profiles/mac.conf"
        [[ "${_mod_config[shell-installers.installers]}" == *"darkbloom"* ]] || { echo "missing darkbloom"; exit 1; }
        echo "ok"
    '
    assert_success
    assert_output "ok"
}
