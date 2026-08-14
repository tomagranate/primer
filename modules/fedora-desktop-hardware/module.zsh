#!/bin/zsh
# modules/fedora-desktop-hardware -- configure NVIDIA and reliable sleep on Fedora KDE

typeset -a FEDORA_DESKTOP_HARDWARE_PACKAGES=(
    akmod-nvidia
    xorg-x11-drv-nvidia
    xorg-x11-drv-nvidia-libs.i686
    xorg-x11-drv-nvidia-power
    xorg-x11-drv-nvidia-cuda
    kernel-devel-matched
    vulkan-tools
)
typeset -a FEDORA_DESKTOP_HARDWARE_SERVICES=(
    nvidia-suspend.service
    nvidia-resume.service
    nvidia-hibernate.service
)
typeset -a FEDORA_DESKTOP_HARDWARE_FILES=(
    etc/systemd/sleep.conf.d/10-reliable-suspend.conf
    etc/tmpfiles.d/60-suspend-diagnostics.conf
    etc/udev/rules.d/80-usb-wake.rules
    usr/local/bin/sleep-diagnostics
)

_fedora_desktop_hardware::root_path() {
    local path="$1" root="${FEDORA_DESKTOP_HARDWARE_ROOT:-/}"
    [[ "$root" == / ]] && print -r -- "/$path" || print -r -- "${root%/}/$path"
}

_fedora_desktop_hardware::run_as_root() {
    if [[ "$DRY_RUN" == true ]]; then
        printf '[dry-run] sudo %s\n' "$*"
        return 0
    fi
    primer::run_as_root "Fedora desktop hardware setup" "$@"
}

_fedora_desktop_hardware::is_fedora() {
    [[ "$DRY_RUN" == true ]] && return 0
    local release="$(_fedora_desktop_hardware::root_path etc/os-release)"
    [[ -r "$release" ]] && grep -Eq '^ID="?fedora"?$' "$release"
}

_fedora_desktop_hardware::has_nvidia_gpu() {
    [[ "$DRY_RUN" == true ]] && return 0
    lspci -nn 2>/dev/null | grep -Eqi '\[10de:[0-9a-f]{4}\]'
}

_fedora_desktop_hardware::rpmfusion_enabled() {
    rpm -q "rpmfusion-$1-release" >/dev/null 2>&1
}

_fedora_desktop_hardware::install_system_files() {
    local relative source destination mode
    for relative in "${FEDORA_DESKTOP_HARDWARE_FILES[@]}"; do
        source="$MOD_DIR/files/$relative"
        destination="$(_fedora_desktop_hardware::root_path "$relative")"
        mode=0644
        [[ "$relative" == usr/local/bin/sleep-diagnostics ]] && mode=0755
        _fedora_desktop_hardware::run_as_root install -D -m "$mode" "$source" "$destination" || return 1
    done
}

_fedora_desktop_hardware::system_files_match() {
    local relative source destination mode
    for relative in "${FEDORA_DESKTOP_HARDWARE_FILES[@]}"; do
        source="$MOD_DIR/files/$relative"
        destination="$(_fedora_desktop_hardware::root_path "$relative")"
        [[ -f "$destination" ]] && cmp -s "$source" "$destination" || return 1
        mode=644
        [[ "$relative" == usr/local/bin/sleep-diagnostics ]] && mode=755
        [[ "$(stat -c '%a' "$destination" 2>/dev/null)" == "$mode" ]] || return 1
    done
}

_fedora_desktop_hardware::current_kernel_module_ready() {
    modinfo -k "$(uname -r)" nvidia >/dev/null 2>&1
}

mod_update() {
    if [[ "$(uname -s)" != Linux ]] || ! _fedora_desktop_hardware::is_fedora; then
        primer::status_msg "Fedora Linux only"
        return 1
    fi
    if ! _fedora_desktop_hardware::has_nvidia_gpu; then
        primer::status_msg "not applicable"
        return 0
    fi

    if [[ "$DRY_RUN" != true ]] && mokutil --sb-state 2>/dev/null | grep -qi 'SecureBoot enabled'; then
        print "Secure Boot is enabled. Disable Secure Boot or enroll an akmods key." >&2
        primer::status_msg "Secure Boot blocks setup"
        return 1
    fi

    local version
    if [[ "$DRY_RUN" == true ]]; then
        version='$(rpm -E %fedora)'
        _fedora_desktop_hardware::run_as_root dnf5 -y install \
            "https://mirrors.rpmfusion.org/free/fedora/rpmfusion-free-release-${version}.noarch.rpm" \
            "https://mirrors.rpmfusion.org/nonfree/fedora/rpmfusion-nonfree-release-${version}.noarch.rpm" || return 1
    else
        version="$(rpm -E %fedora)" || return 1
        if ! _fedora_desktop_hardware::rpmfusion_enabled free; then
            _fedora_desktop_hardware::run_as_root dnf5 -y install \
                "https://mirrors.rpmfusion.org/free/fedora/rpmfusion-free-release-${version}.noarch.rpm" || return 1
        fi
        if ! _fedora_desktop_hardware::rpmfusion_enabled nonfree; then
            _fedora_desktop_hardware::run_as_root dnf5 -y install \
                "https://mirrors.rpmfusion.org/nonfree/fedora/rpmfusion-nonfree-release-${version}.noarch.rpm" || return 1
        fi
    fi

    _fedora_desktop_hardware::run_as_root dnf5 -y install "${FEDORA_DESKTOP_HARDWARE_PACKAGES[@]}" || return 1
    _fedora_desktop_hardware::install_system_files || return 1
    _fedora_desktop_hardware::run_as_root systemctl enable "${FEDORA_DESKTOP_HARDWARE_SERVICES[@]}" || return 1
    _fedora_desktop_hardware::run_as_root akmods --force --kernels "$(uname -r)" || return 1
    if [[ "$DRY_RUN" != true ]] && ! _fedora_desktop_hardware::current_kernel_module_ready; then
        print "The NVIDIA module is unavailable for kernel $(uname -r)." >&2
        primer::status_msg "NVIDIA kernel module unavailable"
        return 1
    fi
    local tmpfiles="$(_fedora_desktop_hardware::root_path etc/tmpfiles.d/60-suspend-diagnostics.conf)"
    _fedora_desktop_hardware::run_as_root systemd-tmpfiles --create "$tmpfiles" || return 1
    _fedora_desktop_hardware::run_as_root udevadm control --reload-rules || return 1
    _fedora_desktop_hardware::run_as_root udevadm trigger --action=add --subsystem-match=pci || return 1
    _fedora_desktop_hardware::run_as_root udevadm trigger --action=add --subsystem-match=usb || return 1
    _fedora_desktop_hardware::run_as_root udevadm settle || return 1

    if [[ "$DRY_RUN" != true ]] && ! lspci -nnk 2>/dev/null | grep -A3 -Ei '\[10de:[0-9a-f]{4}\]' | grep -q 'Kernel driver in use: nvidia'; then
        primer::status_msg "configured; restart required"
    else
        primer::status_msg "configured"
    fi
}

mod_status() {
    if [[ "$(uname -s)" != Linux ]] || ! _fedora_desktop_hardware::is_fedora; then
        primer::status_msg "Fedora Linux only"
        return 1
    fi
    if ! _fedora_desktop_hardware::has_nvidia_gpu; then
        primer::status_msg "not applicable"
        return 0
    fi

    local issues=0 item relative source destination mode active=true
    _fedora_desktop_hardware::rpmfusion_enabled free || (( issues++ ))
    _fedora_desktop_hardware::rpmfusion_enabled nonfree || (( issues++ ))
    for item in "${FEDORA_DESKTOP_HARDWARE_PACKAGES[@]}"; do
        rpm -q "$item" >/dev/null 2>&1 || (( issues++ ))
    done
    _fedora_desktop_hardware::current_kernel_module_ready || (( issues++ ))
    for item in "${FEDORA_DESKTOP_HARDWARE_SERVICES[@]}"; do
        systemctl is-enabled --quiet "$item" || (( issues++ ))
    done
    for relative in "${FEDORA_DESKTOP_HARDWARE_FILES[@]}"; do
        source="$MOD_DIR/files/$relative"
        destination="$(_fedora_desktop_hardware::root_path "$relative")"
        mode=644
        [[ "$relative" == usr/local/bin/sleep-diagnostics ]] && mode=755
        if [[ ! -f "$destination" ]] || ! cmp -s "$source" "$destination" \
            || [[ "$(stat -c '%a' "$destination" 2>/dev/null)" != "$mode" ]]; then
            (( issues++ ))
        fi
    done
    systemd-analyze cat-config systemd/sleep.conf 2>/dev/null | grep -Eq '^MemorySleepMode[[:space:]]*=[[:space:]]*s2idle[[:space:]]*$' || (( issues++ ))
    for relative in sys/power/pm_debug_messages sys/power/pm_print_times; do
        [[ "$(cat "$(_fedora_desktop_hardware::root_path "$relative")" 2>/dev/null)" == 1 ]] || (( issues++ ))
    done

    lspci -nnk 2>/dev/null | grep -A3 -Ei '\[10de:[0-9a-f]{4}\]' | grep -q 'Kernel driver in use: nvidia' || active=false
    if (( issues == 0 )); then
        [[ "$active" == true ]] && primer::status_msg "configured" || primer::status_msg "configured; restart required"
        return 0
    fi
    primer::status_msg "$issues issue(s)"
    return 1
}
