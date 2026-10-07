#!/usr/bin/env bats

load '../../tests/helpers/common'

setup() {
    export TEST_HOME="$(mktemp -d)"
    export TEST_CONF="$(mktemp)"
    export MOCK_DIR="$TEST_HOME/mock"
    export MOCK_LOG="$TEST_HOME/calls"
    export ROOT="$TEST_HOME/root"
    mkdir -p "$MOCK_DIR" "$ROOT/sys/class/net/eno1"
    : > "$MOCK_LOG"
    echo "aa:bb:cc:dd:ee:01" > "$ROOT/sys/class/net/eno1/address"

    # A real release tarball, so install and checksum checks run for real.
    mkdir -p "$TEST_HOME/release/hangar-0.1.0/stack" "$TEST_HOME/release/hangar-0.1.0/image"
    printf '#!/bin/sh\necho hangar\n' > "$TEST_HOME/release/hangar-0.1.0/hangar"
    echo "services: {}" > "$TEST_HOME/release/hangar-0.1.0/stack/compose.yml"
    tar -czf "$TEST_HOME/release/hangar-0.1.0-x86_64-linux.tar.gz" -C "$TEST_HOME/release" hangar-0.1.0
    RELEASE_SHA="$(sha256sum "$TEST_HOME/release/hangar-0.1.0-x86_64-linux.tar.gz" | awk '{print $1}')"
    printf 'cloud image' > "$TEST_HOME/base.img"
    BASE_SHA="$(sha256sum "$TEST_HOME/base.img" | awk '{print $1}')"

    cat > "$TEST_CONF" <<EOF
[hangar-cell]
hangar_version = 0.1.0
hangar_sha256 = $RELEASE_SHA
controller_url = ws://tombook-linux.example.ts.net:8782/cell
cell_token_ref = op://Dev/hangar/cell-token
base_image_url = https://example.invalid/ubuntu.img
base_image_sha256 = $BASE_SHA
wake_on_lan = auto
EOF

    cat > "$MOCK_DIR/gh" <<'EOF'
#!/bin/sh
echo "gh $*" >> "$MOCK_LOG"
dir=""
while [ "$#" -gt 0 ]; do [ "$1" = --dir ] && dir="$2"; shift; done
cp "$TEST_HOME/release/hangar-0.1.0-x86_64-linux.tar.gz" "$dir/"
EOF
    cat > "$MOCK_DIR/curl" <<'EOF'
#!/bin/sh
echo "curl $*" >> "$MOCK_LOG"
out=""
while [ "$#" -gt 0 ]; do [ "$1" = -o ] && out="$2"; shift; done
cp "$TEST_HOME/base.img" "$out"
EOF
    cat > "$MOCK_DIR/op" <<'EOF'
#!/bin/sh
echo "op $*" >> "$MOCK_LOG"
echo cell-secret
EOF
    cat > "$MOCK_DIR/ip" <<'EOF'
#!/bin/sh
echo "default via 192.168.2.1 dev eno1 proto dhcp src 192.168.2.62 metric 100"
EOF
    cat > "$MOCK_DIR/ethtool" <<'EOF'
#!/bin/sh
echo "	Supports Wake-on: pumbg"
EOF
    cat > "$MOCK_DIR/hostname" <<'EOF'
#!/bin/sh
echo Tomputer
EOF
    cat > "$MOCK_DIR/nproc" <<'EOF'
#!/bin/sh
echo 32
EOF
    cat > "$MOCK_DIR/getent" <<'EOF'
#!/bin/sh
[ -f "$TEST_HOME/.group-$2" ]
EOF
    cat > "$MOCK_DIR/groupadd" <<'EOF'
#!/bin/sh
echo "groupadd $*" >> "$MOCK_LOG"
for last in "$@"; do :; done
touch "$TEST_HOME/.group-$last"
EOF
    cat > "$MOCK_DIR/usermod" <<'EOF'
#!/bin/sh
echo "usermod $*" >> "$MOCK_LOG"
touch "$TEST_HOME/.member"
EOF
    cat > "$MOCK_DIR/id" <<'EOF'
#!/bin/sh
[ -f "$TEST_HOME/.member" ] && echo "tom hangar" || echo tom
EOF
    cat > "$MOCK_DIR/chown" <<'EOF'
#!/bin/sh
echo "chown $*" >> "$MOCK_LOG"
EOF
    cat > "$MOCK_DIR/gamemoded" <<'EOF'
#!/bin/sh
EOF
    chmod +x "$MOCK_DIR"/*
}

teardown() {
    rm -rf "$TEST_HOME" "$TEST_CONF"
}

run_module() {
    run zsh -c "
        export PRIMER_DIR='${PRIMER_DIR}'
        export DRY_RUN='${DRY_RUN:-false}'
        export MOD_DIR='${PRIMER_DIR}/modules/hangar-cell'
        export MOD_NAME='hangar-cell'
        export MOD_STATUS_FILE='$(mktemp)'
        export HOME='${TEST_HOME}'
        export USER=tom
        export XDG_CONFIG_HOME='${TEST_HOME}/.config'
        export PATH='${MOCK_DIR}:/usr/bin:/bin'
        export MOCK_LOG='${MOCK_LOG}' TEST_HOME='${TEST_HOME}'
        export OP_SERVICE_ACCOUNT_TOKEN=ticket
        export HANGAR_SYSTEMD_DIR='${ROOT}/etc/systemd/system'
        export HANGAR_ETC_DIR='${ROOT}/etc/hangar'
        export HANGAR_SHARE_DIR='${ROOT}/usr/local/share/hangar'
        export HANGAR_BIN_DIR='${ROOT}/usr/local/bin'
        export HANGAR_IMAGES_DIR='${ROOT}/var/lib/libvirt/images/hangar'
        export HANGAR_STACK_DATA='${ROOT}/var/lib/hangar/stack'
        export HANGAR_TMPFILES_DIR='${ROOT}/etc/tmpfiles.d'
        export HANGAR_SYS_NET='${ROOT}/sys/class/net'
        source \"\$PRIMER_DIR/lib/module.zsh\"
        source \"\$PRIMER_DIR/tests/helpers/module-config.zsh\"
        test::load_module_config '${TEST_CONF}'
        source \"\$MOD_DIR/module.zsh\"
        $1
    "
}

@test "hangar-cell: a new machine gets everything it needs to join the fleet" {
    run_module "mod_update"
    assert_success

    # The pinned release, unpacked with its stack files.
    [ -x "$ROOT/usr/local/bin/hangar" ]
    [ -f "$ROOT/usr/local/share/hangar/stack/compose.yml" ]
    [ "$(cat "$ROOT/usr/local/share/hangar/VERSION")" = 0.1.0 ]

    # Units, KSM, and the base image.
    [ -f "$ROOT/etc/systemd/system/hangar-cell.service" ]
    [ -f "$ROOT/etc/systemd/system/hangar-image.timer" ]
    grep -Fx "w /sys/kernel/mm/ksm/run - - - - 1" "$ROOT/etc/tmpfiles.d/hangar-ksm.conf"
    [ "$(cat "$ROOT/var/lib/libvirt/images/hangar/base/ubuntu-24.04-server-cloudimg-amd64.img")" = "cloud image" ]

    # The token from 1Password, readable by root only.
    [ "$(cat "$ROOT/etc/hangar/secrets/cell-token")" = cell-secret ]
    [ "$(stat -c %a "$ROOT/etc/hangar/secrets/cell-token")" = 600 ]
    grep -F "op read op://Dev/hangar/cell-token" "$MOCK_LOG"

    # Config: lowercase name, thread count as priority, wired NIC can wake.
    grep -Fx 'name = "tomputer"' "$ROOT/etc/hangar/cell.toml"
    grep -Fx 'controller_url = "ws://tombook-linux.example.ts.net:8782/cell"' "$ROOT/etc/hangar/cell.toml"
    grep -Fx 'priority = 32' "$ROOT/etc/hangar/cell.toml"
    grep -Fx 'wake_mac = "aa:bb:cc:dd:ee:01"' "$ROOT/etc/hangar/cell.toml"

    # Group for the drain socket, cache data, and the GameMode hooks.
    grep -F "groupadd --system hangar" "$MOCK_LOG"
    grep -F "usermod -aG hangar tom" "$MOCK_LOG"
    [ -d "$ROOT/var/lib/hangar/stack/npm" ]
    grep -Fx "start=/usr/local/bin/hangar cell drain" "$TEST_HOME/.config/gamemode.ini"
    grep -Fx "end=/usr/local/bin/hangar cell resume" "$TEST_HOME/.config/gamemode.ini"

    run_module 'mod_status; rc=$?; cat "$MOD_STATUS_FILE"; exit $rc'
    assert_success
}

@test "hangar-cell: a second run downloads nothing and keeps your gamemode.ini" {
    run_module "mod_update"
    assert_success
    echo "[general]" > "$TEST_HOME/.config/gamemode.ini"
    : > "$MOCK_LOG"

    run_module "mod_update"
    assert_success
    if grep -E "^(gh|curl|op) " "$MOCK_LOG"; then
        echo "nothing should download again" >&2
        return 1
    fi
    [ "$(cat "$TEST_HOME/.config/gamemode.ini")" = "[general]" ]

    run_module 'mod_status; rc=$?; cat "$MOD_STATUS_FILE"; exit $rc'
    assert_failure
    assert_output --partial "gamemode.ini has no hangar hooks"
}

@test "hangar-cell: Wi-Fi machines do not offer Wake-on-LAN" {
    mkdir -p "$ROOT/sys/class/net/eno1/wireless"
    run_module "mod_update"
    assert_success
    if grep -F wake_mac "$ROOT/etc/hangar/cell.toml"; then
        echo "Wi-Fi cannot wake a powered-off machine" >&2
        return 1
    fi
}

@test "hangar-cell: a release with the wrong checksum is not installed" {
    sed -i 's/^hangar_sha256 = .*/hangar_sha256 = 0000/' "$TEST_CONF"
    run_module "mod_update"
    assert_failure
    assert_output --partial "checksum mismatch"
    [ ! -e "$ROOT/usr/local/bin/hangar" ]
}
