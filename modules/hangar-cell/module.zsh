#!/bin/zsh
# modules/hangar-cell -- makes this machine a Hangar CI cell.
#
# A cell runs GitHub Actions jobs in throwaway VMs from a golden image, with
# local caches next to them. It connects to the Hangar controller over the
# tailnet, so a machine joins the fleet when this addon is selected.
# See https://github.com/tomagranate/hangar.

_hcell::config() {
    local value
    value="$(mod_config "$1" | head -1)"
    print -r -- "${value:-$2}"
}

# Paths. Tests point these at a temp dir.
_hcell::systemd_dir() { print -r -- "${HANGAR_SYSTEMD_DIR:-/etc/systemd/system}" }
_hcell::etc() { print -r -- "${HANGAR_ETC_DIR:-/etc/hangar}" }
_hcell::share() { print -r -- "${HANGAR_SHARE_DIR:-/usr/local/share/hangar}" }
_hcell::bin_dir() { print -r -- "${HANGAR_BIN_DIR:-/usr/local/bin}" }
_hcell::images() { print -r -- "${HANGAR_IMAGES_DIR:-/var/lib/libvirt/images/hangar}" }
_hcell::stack_data() { print -r -- "${HANGAR_STACK_DATA:-/var/lib/hangar/stack}" }
_hcell::tmpfiles_dir() { print -r -- "${HANGAR_TMPFILES_DIR:-/etc/tmpfiles.d}" }
_hcell::in_test() { [[ -n "${HANGAR_SYSTEMD_DIR:-}" ]] }

_hcell::version() { _hcell::config hangar_version }
_hcell::asset() { print -r -- "hangar-$(_hcell::version)-x86_64-linux.tar.gz" }
_hcell::machine() { hostname -s 2>/dev/null | tr '[:upper:]' '[:lower:]' }

_hcell::root() {
    [[ "$DRY_RUN" == true ]] && { printf '[dry-run] sudo %s\n' "$*"; return 0; }
    if _hcell::in_test || (( EUID == 0 )); then
        "$@"
        return $?
    fi
    primer::run_as_root "Hangar cell" "$@"
}

_hcell::op_read() {
    local ref="$1" ticket
    if [[ -n "${OP_SERVICE_ACCOUNT_TOKEN:-}" ]]; then
        op read "$ref"
        return
    fi
    ticket="${PRIMER_OP_TICKET:-${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/op-ticket}"
    [[ -s "$ticket" ]] || {
        print "Agent access is not active. Run agents sudo, then retry Primer." >&2
        return 1
    }
    OP_SERVICE_ACCOUNT_TOKEN="$(<"$ticket")" op read "$ref"
}

# Installs the pinned hangar release: the binary, plus the image, guest, and
# stack files that the image build and the cache stack use.
_hcell::install_release() {
    local version="$(_hcell::version)" share="$(_hcell::share)" tmp actual
    [[ -n "$version" ]] || { print "hangar_version is not set" >&2; return 1; }
    [[ -f "$share/VERSION" && "$(<"$share/VERSION")" == "$version" ]] && return 0
    [[ "$DRY_RUN" == true ]] && { print "[dry-run] install hangar $version"; return 0; }

    tmp="$(mktemp -d)"
    gh release download "v$version" --repo tomagranate/hangar --pattern "$(_hcell::asset)" --dir "$tmp" \
        || { rm -rf "$tmp"; return 1; }
    actual="$(sha256sum "$tmp/$(_hcell::asset)" | awk '{print $1}')"
    if [[ "$actual" != "$(_hcell::config hangar_sha256)" ]]; then
        print "hangar release checksum mismatch" >&2
        rm -rf "$tmp"
        return 1
    fi
    _hcell::root rm -rf "$share" || return 1
    _hcell::root install -d -m 0755 "$share" || return 1
    _hcell::root tar -xzf "$tmp/$(_hcell::asset)" --strip-components=1 -C "$share" || return 1
    _hcell::root install -D -m 0755 "$share/hangar" "$(_hcell::bin_dir)/hangar" || return 1
    print -r -- "$version" | _hcell::root tee "$share/VERSION" >/dev/null
    rm -rf "$tmp"
    _hcell::changed
}

# Set when the binary or config changed, so the service restarts.
_hcell::changed() { typeset -g _HCELL_RESTART=1 }

_hcell::uplink() {
    ip route show default 2>/dev/null | awk '{for (i = 1; i < NF; i++) if ($i == "dev") { print $(i + 1); exit }}'
}

_hcell::ensure_libvirt() {
    _hcell::root systemctl enable --now virtqemud.socket virtnetworkd.socket || return 1
    # The system libvirt connection needs root, even to read.
    local virsh=(virsh -c qemu:///system)
    if ! _hcell::root "${virsh[@]}" net-info ci-isolated >/dev/null 2>&1; then
        _hcell::root "${virsh[@]}" net-define "$MOD_DIR/files/libvirt/ci-isolated.xml" || return 1
    fi
    _hcell::root "${virsh[@]}" net-autostart ci-isolated >/dev/null || return 1
    if ! _hcell::root "${virsh[@]}" net-info ci-isolated 2>/dev/null | grep -Eq '^Active:[[:space:]]+yes'; then
        _hcell::root "${virsh[@]}" net-start ci-isolated || return 1
    fi
}

# Guests reach the internet on 443 (and 5432 for hosted Postgres), DHCP and
# DNS on the host, and the four cache ports. Nothing on the home network.
# Adding a rule that exists already succeeds, so every call must succeed.
_hcell::ensure_firewall() {
    local uplink zone cidr
    uplink="$(_hcell::uplink)"
    [[ -n "$uplink" ]] || { print "no default route" >&2; return 1; }
    zone="$(firewall-cmd --get-zone-of-interface="$uplink" 2>/dev/null)"
    [[ -n "$zone" ]] || zone="$(firewall-cmd --get-default-zone)"
    local fw=(firewall-cmd -q --permanent)
    local private=(0.0.0.0/8 10.0.0.0/8 100.64.0.0/10 127.0.0.0/8 169.254.0.0/16 172.16.0.0/12 192.168.0.0/16 224.0.0.0/4)

    firewall-cmd --permanent --get-zones | tr ' ' '\n' | grep -Fxq ci-guests \
        || _hcell::root "${fw[@]}" --new-zone=ci-guests || return 1
    _hcell::root "${fw[@]}" --zone=ci-guests --set-target=DROP || return 1
    _hcell::root "${fw[@]}" --zone=ci-guests --change-interface=virbr-ci || return 1
    _hcell::root "${fw[@]}" --zone=ci-guests --add-service=dhcp --add-service=dns || return 1
    _hcell::root "${fw[@]}" --zone=ci-guests \
        --add-port=3000/tcp --add-port=5000/tcp --add-port=3142/tcp --add-port=4873/tcp || return 1

    firewall-cmd --permanent --get-policies | tr ' ' '\n' | grep -Fxq ci-guests-egress \
        || _hcell::root "${fw[@]}" --new-policy=ci-guests-egress || return 1
    _hcell::root "${fw[@]}" --policy=ci-guests-egress --set-target=DROP || return 1
    _hcell::root "${fw[@]}" --policy=ci-guests-egress --add-ingress-zone=ci-guests || return 1
    _hcell::root "${fw[@]}" --policy=ci-guests-egress --add-egress-zone="$zone" || return 1
    # firewall-cmd rejects --add-service and --add-port in one call.
    _hcell::root "${fw[@]}" --policy=ci-guests-egress --add-service=https || return 1
    _hcell::root "${fw[@]}" --policy=ci-guests-egress --add-port=5432/tcp || return 1
    for cidr in "${private[@]}"; do
        _hcell::root "${fw[@]}" --policy=ci-guests-egress \
            --add-rich-rule="rule priority=\"-100\" family=\"ipv4\" destination address=\"$cidr\" reject" || return 1
    done

    # Docker sets the iptables FORWARD policy to DROP, so libvirt NAT needs
    # these rules too.
    for cidr in "${private[@]}"; do
        _hcell::root "${fw[@]}" --direct --add-rule ipv4 filter FORWARD 0 -i virbr-ci -d "$cidr" -j REJECT || return 1
    done
    _hcell::root "${fw[@]}" --direct --add-rule ipv4 filter FORWARD 1 -i virbr-ci -p tcp --dport 443 -j ACCEPT || return 1
    _hcell::root "${fw[@]}" --direct --add-rule ipv4 filter FORWARD 1 -i virbr-ci -p tcp --dport 5432 -j ACCEPT || return 1
    _hcell::root "${fw[@]}" --direct --add-rule ipv4 filter FORWARD 0 -i "$uplink" -o virbr-ci \
        -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT || return 1
    _hcell::root firewall-cmd -q --reload || return 1
}

# KSM shares identical pages between VMs booted from the same image.
_hcell::ensure_ksm() {
    local file="$(_hcell::tmpfiles_dir)/hangar-ksm.conf" line='w /sys/kernel/mm/ksm/run - - - - 1'
    [[ -f "$file" && "$(<"$file")" == "$line" ]] && return 0
    print -r -- "$line" | _hcell::root install -D -m 0644 /dev/stdin "$file" || return 1
    _hcell::root systemd-tmpfiles --create "$file"
}

# Members of group hangar may drain this cell through its local socket.
_hcell::ensure_group() {
    local user="${USER:-$LOGNAME}"
    getent group hangar >/dev/null 2>&1 || _hcell::root groupadd --system hangar || return 1
    id -nG "$user" 2>/dev/null | tr ' ' '\n' | grep -Fxq hangar && return 0
    _hcell::root usermod -aG hangar "$user"
}

# New group membership reaches only new login sessions.
_hcell::session_in_group() { id -nG 2>/dev/null | tr ' ' '\n' | grep -Fxq hangar }

_hcell::ensure_secret() {
    local dir="$(_hcell::etc)/secrets" file token
    file="$dir/cell-token"
    # The secrets folder is root-only, so check it as root.
    _hcell::root test -s "$file" && return 0
    [[ "$DRY_RUN" == true ]] && { print "[dry-run] read cell token"; return 0; }
    token="$(_hcell::op_read "$(_hcell::config cell_token_ref)")" || return 1
    [[ -n "$token" ]] || return 1
    _hcell::root install -d -m 0700 "$dir" || return 1
    print -r -- "$token" | _hcell::root install -m 0600 /dev/stdin "$file" || return 1
    unset token
    _hcell::changed
}

# A wired NIC that supports magic packets. Wi-Fi cannot wake a powered-off PC.
_hcell::wake_mac() {
    [[ "$(_hcell::config wake_on_lan auto)" == auto ]] || return 0
    local uplink="$(_hcell::uplink)" net="${HANGAR_SYS_NET:-/sys/class/net}"
    [[ -n "$uplink" && ! -e "$net/$uplink/wireless" ]] || return 0
    ethtool "$uplink" 2>/dev/null | grep -Eq 'Supports Wake-on:.*g' || return 0
    cat "$net/$uplink/address"
}

_hcell::render_config() {
    local priority wake
    priority="$(_hcell::config priority "$(nproc 2>/dev/null || print 0)")"
    wake="$(_hcell::wake_mac)"
    cat <<EOF
# Written by primer (hangar-cell addon). Edit the addon config, not this file.
name = "$(_hcell::machine)"
controller_url = "$(_hcell::config controller_url)"
token_file = "$(_hcell::etc)/secrets/cell-token"
images = "$(_hcell::images)"
# More threads, more priority: faster machines take jobs first.
priority = $priority
EOF
    [[ -n "$wake" ]] && print -r -- "wake_mac = \"$wake\""
    return 0
}

_hcell::write_config() {
    local file="$(_hcell::etc)/cell.toml" next
    next="$(_hcell::render_config)" || return 1
    [[ -f "$file" && "$(<"$file")" == "$next" ]] && return 0
    print -r -- "$next" | _hcell::root install -D -m 0644 /dev/stdin "$file" || return 1
    _hcell::changed
}

_hcell::install_units() {
    local systemd="$(_hcell::systemd_dir)" name src
    for src in "$MOD_DIR"/files/etc/systemd/system/*(N); do
        name="${src:t}"
        cmp -s "$src" "$systemd/$name" && continue
        _hcell::root install -D -m 0644 "$src" "$systemd/$name" || return 1
        _hcell::changed
    done
    _hcell::root systemctl daemon-reload
}

_hcell::ensure_stack() {
    local data="$(_hcell::stack_data)" dir
    for dir in cache registry apt npm; do
        _hcell::root install -d -m 0755 "$data/$dir" || return 1
    done
    # Verdaccio runs as uid 10001 in its image.
    _hcell::root chown 10001:65533 "$data/npm" || return 1
    _hcell::root systemctl enable --now hangar-stack.service || return 1
    # A new release can change the compose file; apply it.
    [[ -z "${_HCELL_RESTART:-}" ]] || _hcell::root systemctl restart hangar-stack.service
}

# The base Ubuntu cloud image is pinned by URL and SHA-256. The first golden
# image builds in the background; the cell boots VMs once it exists.
_hcell::ensure_image() {
    local images="$(_hcell::images)" url sha base actual
    url="$(_hcell::config base_image_url)"
    sha="$(_hcell::config base_image_sha256)"
    base="$images/base/ubuntu-24.04-server-cloudimg-amd64.img"
    _hcell::root install -d -m 0755 "$images" "$images/base" || return 1
    if [[ ! -f "$base" ]] || [[ "$(_hcell::root sha256sum "$base" | awk '{print $1}')" != "$sha" ]]; then
        [[ "$DRY_RUN" == true ]] && { print "[dry-run] download $url"; return 0; }
        _hcell::root curl -fsSL "$url" -o "$base.partial" || return 1
        actual="$(_hcell::root sha256sum "$base.partial" | awk '{print $1}')"
        [[ "$actual" == "$sha" ]] || { print "base image checksum mismatch" >&2; return 1; }
        _hcell::root mv "$base.partial" "$base" || return 1
    fi
    _hcell::root systemctl enable --now hangar-image.timer || return 1
    if [[ ! -e "$images/current" ]]; then
        _hcell::root systemctl start --no-block hangar-image.service
    fi
}

# Pauses this cell while a GameMode game runs. Only writes a new file; an
# existing gamemode.ini is yours, so status reports it instead.
_hcell::ensure_gamemode() {
    command -v gamemoded >/dev/null 2>&1 || return 0
    local ini="${XDG_CONFIG_HOME:-$HOME/.config}/gamemode.ini"
    [[ -f "$ini" ]] && return 0
    [[ "$DRY_RUN" == true ]] && { print "[dry-run] write $ini"; return 0; }
    mkdir -p "${ini:h}"
    cat > "$ini" <<'EOF'
; Written by primer (hangar-cell addon): CI pauses on this machine while you play.
[custom]
start=/usr/local/bin/hangar cell drain
end=/usr/local/bin/hangar cell resume
EOF
}

_hcell::enable() {
    _hcell::root systemctl enable hangar-cell.service || return 1
    if [[ -n "${_HCELL_RESTART:-}" ]]; then
        _hcell::root systemctl restart hangar-cell.service
    else
        _hcell::root systemctl start hangar-cell.service
    fi
}

mod_update() {
    [[ "$(uname -s)" == Linux ]] || { primer::status_msg "Linux only"; return 1; }
    typeset -g _HCELL_RESTART=""
    _hcell::install_release || { primer::status_msg "hangar install failed"; return 1; }
    _hcell::install_units || { primer::status_msg "unit install failed"; return 1; }
    _hcell::ensure_libvirt || { primer::status_msg "libvirt setup failed"; return 1; }
    _hcell::ensure_firewall || { primer::status_msg "firewall setup failed"; return 1; }
    _hcell::ensure_ksm || { primer::status_msg "KSM setup failed"; return 1; }
    _hcell::ensure_group || { primer::status_msg "group setup failed"; return 1; }
    _hcell::ensure_secret || { primer::status_msg "cell token unavailable"; return 1; }
    _hcell::write_config || { primer::status_msg "config failed"; return 1; }
    _hcell::ensure_stack || { primer::status_msg "cache stack failed"; return 1; }
    _hcell::ensure_image || { primer::status_msg "image setup failed"; return 1; }
    _hcell::ensure_gamemode || { primer::status_msg "GameMode hook failed"; return 1; }
    _hcell::enable || { primer::status_msg "service start failed"; return 1; }
    if command -v gamemoded >/dev/null 2>&1 && ! _hcell::session_in_group; then
        primer::status_msg "cell online · log out and in so games can pause CI"
        return 0
    fi
    primer::status_msg "cell online"
}

mod_status() {
    local issues=() src ini
    [[ "$(<"$(_hcell::share)/VERSION" 2>/dev/null)" == "$(_hcell::version)" ]] || issues+=("hangar $(_hcell::version) not installed")
    for src in "$MOD_DIR"/files/etc/systemd/system/*(N); do
        cmp -s "$src" "$(_hcell::systemd_dir)/${src:t}" || issues+=("${src:t} drifted")
    done
    [[ "$(<"$(_hcell::etc)/cell.toml" 2>/dev/null)" == "$(_hcell::render_config)" ]] || issues+=("cell.toml drifted")
    if command -v gamemoded >/dev/null 2>&1; then
        ini="${XDG_CONFIG_HOME:-$HOME/.config}/gamemode.ini"
        grep -q 'hangar cell drain' "$ini" 2>/dev/null || issues+=("gamemode.ini has no hangar hooks")
        _hcell::session_in_group || issues+=("log out and in so games can pause CI")
    fi
    systemctl is-active --quiet hangar-cell.service || issues+=("hangar-cell not running")
    [[ -e "$(_hcell::images)/current" ]] || issues+=("no golden image yet")
    (( ${#issues} == 0 )) && { primer::status_msg "cell online"; return 0; }
    primer::status_msg "${(j: · :)issues}"
    return 1
}
