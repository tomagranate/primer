#!/usr/bin/env bats

load '../../tests/helpers/common'

setup() {
    export TEST_HOME="$(mktemp -d)"
    export MOCK_DIR="$TEST_HOME/mock"
    export MOCK_LOG="$TEST_HOME/calls"
    export MOCK_INSTALLED="$TEST_HOME/installed"
    export MOCK_SERVICES="$TEST_HOME/services"
    export FEDORA_DESKTOP_HARDWARE_ROOT="$TEST_HOME/root"
    export MOD_STATUS_FILE="$TEST_HOME/status"
    mkdir -p "$MOCK_DIR" "$FEDORA_DESKTOP_HARDWARE_ROOT/etc" "$FEDORA_DESKTOP_HARDWARE_ROOT/sys/power"
    printf 'ID=fedora\n' > "$FEDORA_DESKTOP_HARDWARE_ROOT/etc/os-release"
    : > "$MOCK_LOG"; : > "$MOCK_INSTALLED"; : > "$MOCK_SERVICES"

    cat > "$MOCK_DIR/sudo" <<'EOF'
#!/bin/sh
[ "$1" = -n ] && [ "$2" = true ] && exit 0
[ "$1" = -n ] && shift
exec "$@"
EOF
    cat > "$MOCK_DIR/lspci" <<'EOF'
#!/bin/sh
[ "${NO_NVIDIA:-0}" = 1 ] && exit 0
echo '01:00.0 VGA compatible controller [0300]: NVIDIA Device [10de:2206]'
[ "$1" = -nnk ] && [ "${ACTIVE_NVIDIA:-1}" = 1 ] && echo 'Kernel driver in use: nvidia'
EOF
    cat > "$MOCK_DIR/mokutil" <<'EOF'
#!/bin/sh
[ "${SECURE_BOOT:-0}" = 1 ] && echo 'SecureBoot enabled' || echo 'SecureBoot disabled'
EOF
    cat > "$MOCK_DIR/rpm" <<'EOF'
#!/bin/sh
[ "$1" = -E ] && { echo 44; exit 0; }
[ "$1" = -q ] || exit 2
grep -Fxq "$2" "$MOCK_INSTALLED"
EOF
    cat > "$MOCK_DIR/dnf5" <<'EOF'
#!/bin/sh
echo "dnf5 $*" >> "$MOCK_LOG"
for arg in "$@"; do
  case "$arg" in
    *rpmfusion-free-release*) echo rpmfusion-free-release >> "$MOCK_INSTALLED" ;;
    *rpmfusion-nonfree-release*) echo rpmfusion-nonfree-release >> "$MOCK_INSTALLED" ;;
    akmod-nvidia|xorg-x11-drv-nvidia|xorg-x11-drv-nvidia-libs.i686|xorg-x11-drv-nvidia-power|xorg-x11-drv-nvidia-cuda|kernel-devel-matched|vulkan-tools) echo "$arg" >> "$MOCK_INSTALLED" ;;
  esac
done
EOF
    cat > "$MOCK_DIR/systemctl" <<'EOF'
#!/bin/sh
echo "systemctl $*" >> "$MOCK_LOG"
if [ "$1" = enable ]; then shift; printf '%s\n' "$@" >> "$MOCK_SERVICES"; exit 0; fi
[ "$1" = is-enabled ] && grep -Fxq "${3:-$2}" "$MOCK_SERVICES"
EOF
    cat > "$MOCK_DIR/akmods" <<'EOF'
#!/bin/sh
echo "akmods $*" >> "$MOCK_LOG"
EOF
    cat > "$MOCK_DIR/modinfo" <<'EOF'
#!/bin/sh
[ "${MODULE_READY:-1}" = 1 ]
EOF
    cat > "$MOCK_DIR/systemd-analyze" <<'EOF'
#!/bin/sh
echo 'MemorySleepMode=s2idle'
EOF
    for command in systemd-tmpfiles udevadm; do
        cat > "$MOCK_DIR/$command" <<EOF
#!/bin/sh
echo "$command \$*" >> "\$MOCK_LOG"
EOF
    done
    chmod +x "$MOCK_DIR"/*
}

teardown() { rm -rf "$TEST_HOME"; }

module_script() {
    cat <<EOF
export PRIMER_DIR='$PRIMER_DIR' MOD_DIR='$PRIMER_DIR/modules/fedora-desktop-hardware'
export MOD_STATUS_FILE='$MOD_STATUS_FILE' DRY_RUN='${DRY_RUN:-false}'
export FEDORA_DESKTOP_HARDWARE_ROOT='$FEDORA_DESKTOP_HARDWARE_ROOT'
export MOCK_LOG='$MOCK_LOG' MOCK_INSTALLED='$MOCK_INSTALLED' MOCK_SERVICES='$MOCK_SERVICES'
export NO_NVIDIA='${NO_NVIDIA:-0}' SECURE_BOOT='${SECURE_BOOT:-0}' MODULE_READY='${MODULE_READY:-1}' ACTIVE_NVIDIA='${ACTIVE_NVIDIA:-1}'
export PATH='$MOCK_DIR:/usr/bin:/bin:/usr/sbin:/sbin'
source '$PRIMER_DIR/lib/module.zsh'
source '$PRIMER_DIR/modules/fedora-desktop-hardware/module.zsh'
$1
EOF
}

run_module() { run zsh -c "$(module_script "$1")"; }

complete_fixture() {
    printf '%s\n' rpmfusion-free-release rpmfusion-nonfree-release \
        akmod-nvidia xorg-x11-drv-nvidia xorg-x11-drv-nvidia-libs.i686 \
        xorg-x11-drv-nvidia-power xorg-x11-drv-nvidia-cuda kernel-devel-matched vulkan-tools > "$MOCK_INSTALLED"
    printf '%s\n' nvidia-suspend.service nvidia-resume.service nvidia-hibernate.service > "$MOCK_SERVICES"
    local relative
    while IFS= read -r relative; do
        mkdir -p "$FEDORA_DESKTOP_HARDWARE_ROOT/$(dirname "$relative")"
        cp "$PRIMER_DIR/modules/fedora-desktop-hardware/files/$relative" "$FEDORA_DESKTOP_HARDWARE_ROOT/$relative"
    done <<EOF
etc/systemd/sleep.conf.d/10-reliable-suspend.conf
etc/tmpfiles.d/60-suspend-diagnostics.conf
etc/udev/rules.d/80-usb-wake.rules
usr/local/bin/sleep-diagnostics
EOF
    printf '1\n' > "$FEDORA_DESKTOP_HARDWARE_ROOT/sys/power/pm_debug_messages"
    printf '1\n' > "$FEDORA_DESKTOP_HARDWARE_ROOT/sys/power/pm_print_times"
}

@test "non-Fedora returns failure without changes" {
    printf 'ID=ubuntu\n' > "$FEDORA_DESKTOP_HARDWARE_ROOT/etc/os-release"
    run_module mod_update
    assert_failure
    [ ! -s "$MOCK_LOG" ]
}

@test "Fedora without NVIDIA is not applicable" {
    export NO_NVIDIA=1
    run_module mod_update
    assert_success
    assert_equal "$(cat "$MOD_STATUS_FILE")" "not applicable"
}

@test "Secure Boot stops before package changes" {
    export SECURE_BOOT=1
    run_module mod_update
    assert_failure
    assert_output --partial "enroll an akmods key"
    [ ! -s "$MOCK_LOG" ]
}

@test "dry-run lists every planned action without writing files" {
    export DRY_RUN=true
    run_module mod_update
    assert_success
    assert_output --partial "rpmfusion-free-release"
    assert_output --partial "akmod-nvidia"
    assert_output --partial "10-reliable-suspend.conf"
    assert_output --partial "nvidia-suspend.service"
    assert_output --partial "akmods --force --kernels"
    assert_output --partial "systemd-tmpfiles"
    assert_output --partial "udevadm trigger"
    [ ! -e "$FEDORA_DESKTOP_HARDWARE_ROOT/etc/systemd/sleep.conf.d/10-reliable-suspend.conf" ]
}

@test "update enables RPM Fusion and installs the exact package set" {
    run_module mod_update
    assert_success
    grep -F 'rpmfusion-free-release-44.noarch.rpm' "$MOCK_LOG"
    grep -F 'rpmfusion-nonfree-release-44.noarch.rpm' "$MOCK_LOG"
    grep -F 'install akmod-nvidia xorg-x11-drv-nvidia xorg-x11-drv-nvidia-libs.i686 xorg-x11-drv-nvidia-power xorg-x11-drv-nvidia-cuda kernel-devel-matched vulkan-tools' "$MOCK_LOG"
}

@test "update installs all files with correct modes" {
    run_module mod_update
    assert_success
    [ "$(stat -c %a "$FEDORA_DESKTOP_HARDWARE_ROOT/usr/local/bin/sleep-diagnostics")" = 755 ]
    [ "$(stat -c %a "$FEDORA_DESKTOP_HARDWARE_ROOT/etc/udev/rules.d/80-usb-wake.rules")" = 644 ]
    [ "$(find "$FEDORA_DESKTOP_HARDWARE_ROOT" -type f | wc -l)" -ge 5 ]
}

@test "update enables NVIDIA sleep services" {
    run_module mod_update
    assert_success
    grep -F 'systemctl enable nvidia-suspend.service nvidia-resume.service nvidia-hibernate.service' "$MOCK_LOG"
}

@test "update runs akmods for the current kernel" {
    run_module mod_update
    assert_success
    grep -F "akmods --force --kernels $(uname -r)" "$MOCK_LOG"
}

@test "update fails without the current kernel module" {
    export MODULE_READY=0
    run_module mod_update
    assert_failure
    assert_output --partial "module is unavailable"
}

@test "status succeeds for a complete fixture" {
    complete_fixture
    run_module mod_status
    assert_success
    assert_equal "$(cat "$MOD_STATUS_FILE")" "configured"
}

@test "status reports incomplete configuration" {
    complete_fixture
    grep -v '^akmod-nvidia$' "$MOCK_INSTALLED" > "$MOCK_INSTALLED.new" && mv "$MOCK_INSTALLED.new" "$MOCK_INSTALLED"
    export MODULE_READY=0
    grep -v '^nvidia-suspend.service$' "$MOCK_SERVICES" > "$MOCK_SERVICES.new" && mv "$MOCK_SERVICES.new" "$MOCK_SERVICES"
    printf 'drift\n' > "$FEDORA_DESKTOP_HARDWARE_ROOT/etc/udev/rules.d/80-usb-wake.rules"
    run_module mod_status
    assert_failure
    assert_equal "$(cat "$MOD_STATUS_FILE")" "4 issue(s)"
}

@test "second update does not reinstall RPM Fusion" {
    run_module mod_update
    assert_success
    : > "$MOCK_LOG"
    run_module mod_update
    assert_success
    refute_output --partial "rpmfusion"
    ! grep -q rpmfusion "$MOCK_LOG"
}
