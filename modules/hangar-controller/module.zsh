#!/bin/zsh
# modules/hangar-controller -- runs the Hangar controller on this machine.
#
# The controller gets GitHub workflow_job webhooks through Tailscale Funnel,
# asks GitHub for just-in-time runners, and sends each job to a cell. Cells
# connect to it on the tailnet. The hangar binary comes from the hangar-cell
# module. See https://github.com/tomagranate/hangar.

_hctl::config() {
    local value
    value="$(mod_config "$1" | head -1)"
    print -r -- "${value:-$2}"
}

_hctl::systemd_dir() { print -r -- "${HANGAR_SYSTEMD_DIR:-/etc/systemd/system}" }
_hctl::etc() { print -r -- "${HANGAR_ETC_DIR:-/etc/hangar}" }
_hctl::in_test() { [[ -n "${HANGAR_SYSTEMD_DIR:-}" ]] }

_hctl::root() {
    [[ "$DRY_RUN" == true ]] && { printf '[dry-run] sudo %s\n' "$*"; return 0; }
    if _hctl::in_test || (( EUID == 0 )); then
        "$@"
        return $?
    fi
    primer::run_as_root "Hangar controller" "$@"
}

_hctl::op_read() {
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

_hctl::changed() { typeset -g _HCTL_RESTART=1 }

# Writes one root-only secret file from 1Password. Existing files stay.
_hctl::secret() {
    local name="$1" ref="$2" dir="$(_hctl::etc)/secrets" value
    _hctl::root test -s "$dir/$name" && return 0
    [[ "$DRY_RUN" == true ]] && { print "[dry-run] read $ref"; return 0; }
    value="$(_hctl::op_read "$ref")" || return 1
    [[ -n "$value" ]] || return 1
    _hctl::root install -d -m 0700 "$dir" || return 1
    print -r -- "$value" | _hctl::root install -m 0600 /dev/stdin "$dir/$name" || return 1
    unset value
    _hctl::changed
}

_hctl::ensure_secrets() {
    _hctl::secret github-app.pem "$(_hctl::config github_private_key_ref)" || return 1
    _hctl::secret webhook-secret "$(_hctl::config webhook_secret_ref)" || return 1
    _hctl::secret cell-token "$(_hctl::config cell_token_ref)" || return 1
    _hctl::secret github-app-id "$(_hctl::config github_app_id_ref)"
}

_hctl::tailnet_ip() {
    print -r -- "${HANGAR_TAILNET_IP:-$(tailscale ip -4 2>/dev/null | head -1)}"
}

_hctl::render_config() {
    local ip app_id etc="$(_hctl::etc)"
    ip="$(_hctl::tailnet_ip)"
    [[ -n "$ip" ]] || { print "no Tailscale IPv4 address" >&2; return 1; }
    app_id="$(_hctl::root cat "$etc/secrets/github-app-id" 2>/dev/null)"
    [[ "$app_id" =~ '^[0-9]+$' ]] || { print "no GitHub App ID" >&2; return 1; }
    cat <<EOF
# Written by primer (hangar-controller addon). Edit the addon config, not this file.
# Tailscale Funnel forwards /github/webhook to webhook_listen.
webhook_listen = "127.0.0.1:8781"
# Cells and the status page: http://$ip:8782/
tailnet_listen = "$ip:8782"
database = "/var/lib/hangar/controller.db"
owner = "$(_hctl::config owner)"
github_app_id = $app_id
github_private_key_file = "$etc/secrets/github-app.pem"
webhook_secret_file = "$etc/secrets/webhook-secret"
cell_token_file = "$etc/secrets/cell-token"

EOF
    cat "$MOD_DIR/files/fleet.toml"
}

_hctl::write_config() {
    local file="$(_hctl::etc)/controller.toml" next
    [[ "$DRY_RUN" == true ]] && { print "[dry-run] write $file"; return 0; }
    next="$(_hctl::render_config)" || return 1
    [[ -f "$file" && "$(<"$file")" == "$next" ]] && return 0
    print -r -- "$next" | _hctl::root install -D -m 0644 /dev/stdin "$file" || return 1
    _hctl::changed
}

_hctl::install_unit() {
    local src="$MOD_DIR/files/etc/systemd/system/hangar-controller.service"
    local dst="$(_hctl::systemd_dir)/hangar-controller.service"
    cmp -s "$src" "$dst" && return 0
    _hctl::root install -D -m 0644 "$src" "$dst" || return 1
    _hctl::root systemctl daemon-reload
    _hctl::changed
}

# True when Funnel serves /github/webhook on this port. Status prints the
# port on a header line and each path on the lines under it.
_hctl::funnel_on() {
    tailscale funnel status 2>/dev/null | awk -v port=":$1 " '
        /^https:\/\// { here = index($0, port) > 0 }
        here && /\/github\/webhook proxy/ { found = 1 }
        END { exit !found }'
}

# Only /github/webhook is public. Everything else on the controller is tailnet-only.
_hctl::ensure_funnel() {
    local port="$(_hctl::config funnel_port 10000)"
    _hctl::funnel_on "$port" && return 0
    [[ "$DRY_RUN" == true ]] && { print "[dry-run] tailscale funnel /github/webhook on $port"; return 0; }
    tailscale funnel --bg --yes --https="$port" --set-path=/github/webhook \
        http://127.0.0.1:8781/github/webhook >/dev/null
}

_hctl::enable() {
    _hctl::root systemctl enable hangar-controller.service || return 1
    if [[ -n "${_HCTL_RESTART:-}" ]]; then
        _hctl::root systemctl restart hangar-controller.service
    else
        _hctl::root systemctl start hangar-controller.service
    fi
}

mod_update() {
    [[ "$(uname -s)" == Linux ]] || { primer::status_msg "Linux only"; return 1; }
    typeset -g _HCTL_RESTART=""
    _hctl::ensure_secrets || { primer::status_msg "secrets unavailable"; return 1; }
    _hctl::install_unit || { primer::status_msg "unit install failed"; return 1; }
    _hctl::write_config || { primer::status_msg "config failed"; return 1; }
    _hctl::ensure_funnel || { primer::status_msg "Funnel setup failed"; return 1; }
    _hctl::enable || { primer::status_msg "service start failed"; return 1; }
    primer::status_msg "controller online"
}

mod_status() {
    local issues=()
    cmp -s "$MOD_DIR/files/etc/systemd/system/hangar-controller.service" \
        "$(_hctl::systemd_dir)/hangar-controller.service" || issues+=("unit drifted")
    [[ -f "$(_hctl::etc)/controller.toml" ]] || issues+=("no controller.toml")
    systemctl is-active --quiet hangar-controller.service || issues+=("controller not running")
    _hctl::funnel_on "$(_hctl::config funnel_port 10000)" || issues+=("Funnel off")
    (( ${#issues} == 0 )) && { primer::status_msg "controller online"; return 0; }
    primer::status_msg "${(j: · :)issues}"
    return 1
}
