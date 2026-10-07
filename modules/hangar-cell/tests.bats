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
echo "op $* (token=$OP_SERVICE_ACCOUNT_TOKEN)" >> "$MOCK_LOG"
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
# "id -nG tom" reads the group file; plain "id -nG" is this login session.
if [ "$#" -eq 1 ]; then
  [ -f "$TEST_HOME/.session" ] && echo "tom hangar" || echo tom
  exit 0
fi
[ -f "$TEST_HOME/.member" ] && echo "tom hangar" || echo tom
EOF
    cat > "$MOCK_DIR/chown" <<'EOF'
#!/bin/sh
echo "chown $*" >> "$MOCK_LOG"
EOF
    cat > "$MOCK_DIR/gamemoded" <<'EOF'
#!/bin/sh
EOF
    cat > "$MOCK_DIR/firewall-cmd" <<'EOF'
#!/bin/sh
echo "firewall-cmd $*" >> "$MOCK_LOG"
# Like the real tool: a service and a port in one call is a usage error.
case "$*" in *--add-service=*--add-port=*|*--add-port=*--add-service=*) exit 2 ;; esac
[ -n "$FW_FAIL" ] && case "$*" in *--set-target*) exit 1 ;; esac
case "$*" in
  *--get-zone-of-interface=eno1*) echo FedoraWorkstation ;;
  *--get-zones*) echo "FedoraWorkstation trusted" ;;
  *--get-policies*) echo "allow-host-ipv6" ;;
esac
EOF
    cat > "$MOCK_DIR/virsh" <<'EOF'
#!/bin/sh
echo "virsh $*" >> "$MOCK_LOG"
case "$*" in
  *net-info*) [ -f "$TEST_HOME/.net" ] && echo "Active:         yes" ;;
  *net-define*) touch "$TEST_HOME/.net" ;;
esac
EOF
    cat > "$MOCK_DIR/systemctl" <<'EOF'
#!/bin/sh
echo "systemctl $*" >> "$MOCK_LOG"
EOF
    cat > "$MOCK_DIR/systemd-tmpfiles" <<'EOF'
#!/bin/sh
echo "systemd-tmpfiles $*" >> "$MOCK_LOG"
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
        export MOCK_LOG='${MOCK_LOG}' TEST_HOME='${TEST_HOME}' FW_FAIL='${FW_FAIL:-}'
        ${OP_UNSET:+unset OP_SERVICE_ACCOUNT_TOKEN}
        ${OP_UNSET:-export OP_SERVICE_ACCOUNT_TOKEN=ticket}
        export PRIMER_OP_TICKET='${TEST_HOME}/op-ticket'
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

    # Guests: DHCP, DNS, and the four cache ports on the host; nothing else.
    local fw="firewall-cmd -q --permanent"
    grep -Fx "$fw --new-zone=ci-guests" "$MOCK_LOG"
    grep -Fx "$fw --zone=ci-guests --set-target=DROP" "$MOCK_LOG"
    grep -Fx "$fw --zone=ci-guests --change-interface=virbr-ci" "$MOCK_LOG"
    grep -Fx "$fw --zone=ci-guests --add-port=3000/tcp --add-port=5000/tcp --add-port=3142/tcp --add-port=4873/tcp" "$MOCK_LOG"
    # Out: 443 and 5432 to the internet only; home network and tailnet rejected.
    grep -Fx "$fw --policy=ci-guests-egress --set-target=DROP" "$MOCK_LOG"
    grep -Fx "$fw --policy=ci-guests-egress --add-egress-zone=FedoraWorkstation" "$MOCK_LOG"
    grep -Fx "$fw --policy=ci-guests-egress --add-service=https" "$MOCK_LOG"
    grep -Fx "$fw --policy=ci-guests-egress --add-port=5432/tcp" "$MOCK_LOG"
    grep -F 'destination address="192.168.0.0/16" reject' "$MOCK_LOG"
    grep -F 'destination address="100.64.0.0/10" reject' "$MOCK_LOG"
    grep -Fx "$fw --direct --add-rule ipv4 filter FORWARD 0 -i virbr-ci -d 192.168.0.0/16 -j REJECT" "$MOCK_LOG"
    grep -Fx "$fw --direct --add-rule ipv4 filter FORWARD 0 -i eno1 -o virbr-ci -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT" "$MOCK_LOG"
    if grep -E "add-port=(22|80|8782)/" "$MOCK_LOG"; then
        echo "guests must not reach other host ports" >&2
        return 1
    fi

    # libvirt network, services, and the first image build.
    grep -F "virsh -c qemu:///system net-define $PRIMER_DIR/modules/hangar-cell/files/libvirt/ci-isolated.xml" "$MOCK_LOG"
    grep -F "virsh -c qemu:///system net-autostart ci-isolated" "$MOCK_LOG"
    grep -Fx "systemctl enable --now hangar-stack.service" "$MOCK_LOG"
    grep -Fx "systemctl enable --now hangar-image.timer" "$MOCK_LOG"
    grep -Fx "systemctl start --no-block hangar-image.service" "$MOCK_LOG"
    grep -Fx "systemctl restart hangar-cell.service" "$MOCK_LOG"

    # This login session predates the group, so games cannot pause CI yet.
    run_module 'mod_status; rc=$?; cat "$MOD_STATUS_FILE"; exit $rc'
    assert_failure
    assert_output --partial "log out and in so games can pause CI"

    touch "$TEST_HOME/.session"
    mkdir -p "$ROOT/var/lib/libvirt/images/hangar" && touch "$ROOT/var/lib/libvirt/images/hangar/current"
    run_module 'mod_status; rc=$?; cat "$MOD_STATUS_FILE"; exit $rc'
    assert_success
}

@test "hangar-cell: dry-run changes nothing" {
    export DRY_RUN=true
    run_module "mod_update"
    assert_success
    assert_output --partial "[dry-run] install hangar 0.1.0"
    [ ! -e "$ROOT/usr/local/bin/hangar" ]
    [ ! -e "$ROOT/etc/hangar" ]
    [ ! -e "$TEST_HOME/.config/gamemode.ini" ]
    if grep -E "^(gh|curl|op|groupadd|usermod) |net-define|--permanent --zone|systemctl (enable|start|restart)" "$MOCK_LOG"; then
        echo "dry-run must not change the machine" >&2
        return 1
    fi
}

@test "hangar-cell: a second run downloads nothing and keeps your gamemode.ini" {
    run_module "mod_update"
    assert_success
    echo "[general]" > "$TEST_HOME/.config/gamemode.ini"
    : > "$MOCK_LOG"

    run_module "mod_update"
    assert_success
    if grep -E "^(gh|curl|op) |net-define|restart hangar-cell" "$MOCK_LOG"; then
        echo "nothing should download, define, or restart again" >&2
        return 1
    fi
    grep -Fx "systemctl start hangar-cell.service" "$MOCK_LOG"
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

@test "hangar-cell: reads the cell token with the agents sudo ticket" {
    export OP_UNSET=1
    run_module "mod_update"
    assert_failure
    assert_output --partial "Run agents sudo"
    [ ! -e "$ROOT/etc/hangar/secrets/cell-token" ]

    echo from-ticket > "$TEST_HOME/op-ticket"
    run_module "mod_update"
    assert_success
    grep -F "op read op://Dev/hangar/cell-token (token=from-ticket)" "$MOCK_LOG"
}

@test "hangar-cell: a firewall error stops the update before the cell starts" {
    export FW_FAIL=1
    run_module 'mod_update; rc=$?; cat "$MOD_STATUS_FILE"; exit $rc'
    assert_failure
    assert_output --partial "firewall setup failed"
    if grep -F "hangar-cell.service" "$MOCK_LOG" | grep -E "enable|start|restart"; then
        echo "the cell must not start with a half-built firewall" >&2
        return 1
    fi
}
