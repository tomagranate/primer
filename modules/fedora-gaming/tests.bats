#!/usr/bin/env bats

load '../../tests/helpers/common'

setup() {
    export TEST_HOME="$(mktemp -d)"
    export MOCK_DIR="$TEST_HOME/mock"
    export MOCK_LOG="$TEST_HOME/calls"
    export MOCK_INSTALLED="$TEST_HOME/installed"
    export MOCK_GROUPS="$TEST_HOME/groups"
    export FEDORA_GAMING_ROOT="$TEST_HOME/root"
    export MOD_STATUS_FILE="$TEST_HOME/status"
    export MOD_ITEMS_FILE="$TEST_HOME/items"
    mkdir -p "$MOCK_DIR" "$FEDORA_GAMING_ROOT/etc"
    printf 'ID=fedora\n' > "$FEDORA_GAMING_ROOT/etc/os-release"
    : > "$MOCK_LOG"
    : > "$MOCK_INSTALLED"
    : > "$MOCK_GROUPS"

    cat > "$MOCK_DIR/sudo" <<'EOF'
#!/bin/sh
[ "$1" = -n ] && [ "$2" = true ] && exit 0
[ "$1" = -n ] && shift
exec "$@"
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
    steam|steam-devices|gamemode.x86_64|gamemode.i686|mangohud.x86_64|mangohud.i686|gamescope|vulkan-tools) echo "$arg" >> "$MOCK_INSTALLED" ;;
  esac
done
EOF
    cat > "$MOCK_DIR/gamemoded" <<'EOF'
#!/bin/sh
echo "gamemoded $*" >> "$MOCK_LOG"
[ "${GAMEMODE_READY:-1}" = 1 ]
EOF
    cat > "$MOCK_DIR/vulkaninfo" <<'EOF'
#!/bin/sh
echo "vulkaninfo $*" >> "$MOCK_LOG"
[ "${VULKAN_READY:-1}" = 1 ] || exit 1
echo 'deviceType         = PHYSICAL_DEVICE_TYPE_DISCRETE_GPU'
EOF
    cat > "$MOCK_DIR/udevadm" <<'EOF'
#!/bin/sh
echo "udevadm $*" >> "$MOCK_LOG"
EOF
    cat > "$MOCK_DIR/id" <<'EOF'
#!/bin/sh
[ "$1" = -un ] && { echo "${USER:-primer}"; exit 0; }
[ "$1" = -nG ] || exit 2
printf 'tomagranate wheel'
[ -s "$MOCK_GROUPS" ] && printf ' gamemode'
printf '\n'
EOF
    cat > "$MOCK_DIR/usermod" <<'EOF'
#!/bin/sh
echo "usermod $*" >> "$MOCK_LOG"
echo gamemode > "$MOCK_GROUPS"
EOF
    chmod +x "$MOCK_DIR"/*
}

teardown() { rm -rf "$TEST_HOME"; }

module_script() {
    cat <<EOF
export PRIMER_DIR='$PRIMER_DIR' MOD_DIR='$PRIMER_DIR/modules/fedora-gaming'
export MOD_NAME='fedora-gaming' MOD_STATUS_FILE='$MOD_STATUS_FILE' MOD_ITEMS_FILE='$MOD_ITEMS_FILE'
export DRY_RUN='${DRY_RUN:-false}' FEDORA_GAMING_ROOT='$FEDORA_GAMING_ROOT'
export MOCK_LOG='$MOCK_LOG' MOCK_INSTALLED='$MOCK_INSTALLED'
export MOCK_GROUPS='$MOCK_GROUPS' USER='tomagranate'
export GAMEMODE_READY='${GAMEMODE_READY:-1}' VULKAN_READY='${VULKAN_READY:-1}'
export PATH='$MOCK_DIR:/usr/bin:/bin:/usr/sbin:/sbin'
source '$PRIMER_DIR/lib/module.zsh'
source '$PRIMER_DIR/modules/fedora-gaming/module.zsh'
$1
EOF
}

run_module() { run zsh -c "$(module_script "$1")"; }

complete_fixture() {
    printf '%s\n' rpmfusion-free-release rpmfusion-nonfree-release \
        steam steam-devices gamemode.x86_64 gamemode.i686 \
        mangohud.x86_64 mangohud.i686 gamescope vulkan-tools > "$MOCK_INSTALLED"
    echo gamemode > "$MOCK_GROUPS"
}

@test "fedora-gaming: rejects non-Fedora systems" {
    printf 'ID=ubuntu\n' > "$FEDORA_GAMING_ROOT/etc/os-release"
    run_module mod_update
    assert_failure
    [ ! -s "$MOCK_LOG" ]
}

@test "fedora-gaming: dry-run lists the complete stack" {
    export DRY_RUN=true
    run_module mod_update
    assert_success
    assert_output --partial "rpmfusion-nonfree-release"
    assert_output --partial "install steam steam-devices gamemode.x86_64 gamemode.i686 mangohud.x86_64 mangohud.i686 gamescope vulkan-tools"
    assert_output --partial "usermod -aG gamemode tomagranate"
    assert_output --partial "gamemoded -t"
    assert_output --partial "vulkaninfo --summary"
    assert_output --partial "udevadm control --reload-rules"
}

@test "fedora-gaming: installs repositories and packages" {
    run_module mod_update
    assert_success
    grep -F 'rpmfusion-free-release-44.noarch.rpm' "$MOCK_LOG"
    grep -F 'rpmfusion-nonfree-release-44.noarch.rpm' "$MOCK_LOG"
    grep -F 'install steam steam-devices gamemode.x86_64 gamemode.i686 mangohud.x86_64 mangohud.i686 gamescope vulkan-tools' "$MOCK_LOG"
    grep -Fx 'usermod -aG gamemode tomagranate' "$MOCK_LOG"
    grep -Fx 'gamemoded -t' "$MOCK_LOG"
    grep -Fx 'vulkaninfo --summary' "$MOCK_LOG"
    grep -Fx 'udevadm control --reload-rules' "$MOCK_LOG"
}

@test "fedora-gaming: repairs missing GameMode group membership" {
    complete_fixture
    : > "$MOCK_GROUPS"
    run_module mod_update
    assert_success
    grep -Fx 'usermod -aG gamemode tomagranate' "$MOCK_LOG"
    [ -s "$MOCK_GROUPS" ]
}

@test "fedora-gaming: second update skips package work" {
    complete_fixture
    run_module mod_update
    assert_success
    ! grep -q '^dnf5 ' "$MOCK_LOG"
}

@test "fedora-gaming: fails a GameMode self-test" {
    complete_fixture
    export GAMEMODE_READY=0
    run_module mod_update
    assert_failure
    assert_equal "$(cat "$MOD_STATUS_FILE")" "GameMode self-test failed"
}

@test "fedora-gaming: fails without hardware Vulkan" {
    complete_fixture
    export VULKAN_READY=0
    run_module mod_update
    assert_failure
    assert_equal "$(cat "$MOD_STATUS_FILE")" "hardware Vulkan unavailable"
}

@test "fedora-gaming: status succeeds for a ready system" {
    complete_fixture
    run_module mod_status
    assert_success
    assert_equal "$(cat "$MOD_STATUS_FILE")" "ready"
}

@test "fedora-gaming: status counts package and runtime issues" {
    complete_fixture
    grep -v '^steam-devices$' "$MOCK_INSTALLED" > "$MOCK_INSTALLED.new"
    mv "$MOCK_INSTALLED.new" "$MOCK_INSTALLED"
    export GAMEMODE_READY=0 VULKAN_READY=0
    : > "$MOCK_GROUPS"
    run_module mod_status
    assert_failure
    assert_equal "$(cat "$MOD_STATUS_FILE")" "4 issue(s)"
}
