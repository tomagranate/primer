#!/bin/zsh
# modules/github-ci-runner -- isolated repository runners for trusted CI.

_github_ci::config() {
    local key="$1" fallback="$2" value
    value="$(mod_config "$key" | head -1)"
    print -r -- "${value:-$fallback}"
}

_github_ci::home() { _github_ci::config home /var/lib/github-ci-runner }
_github_ci::prefix() { _github_ci::config user_prefix gha-ci- }
_github_ci::version() { _github_ci::config runner_version 2.337.0 }
_github_ci::sha256() { _github_ci::config runner_sha256 70920811a4f8ad4328818682bca5c6469c1c942fab52448868071d0063816613 }
_github_ci::seed_dist() { _github_ci::config seed_dist /var/lib/github-runner/_dist }
_github_ci::systemd_dir() { print -r -- "${GITHUB_CI_SYSTEMD_DIR:-/etc/systemd/system}" }
_github_ci::libexec_dir() { print -r -- "${GITHUB_CI_LIBEXEC_DIR:-/usr/local/libexec}" }
_github_ci::machine() { hostname -s 2>/dev/null | tr '[:upper:]' '[:lower:]' }

_github_ci::arch() {
    case "$(uname -m)" in
        x86_64|amd64) print x64 ;;
        aarch64|arm64) print arm64 ;;
        *) print "unsupported runner architecture" >&2; return 1 ;;
    esac
}

_github_ci::repos() {
    local line
    while IFS= read -r line; do
        [[ -n "$line" ]] && print -r -- "$line"
    done < <(mod_config repos)
}

_github_ci::repo_ok() { [[ "$1" =~ '^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$' ]] }
_github_ci::instance() { print -r -- "${1##*/}" }
_github_ci::user() { print -r -- "$(_github_ci::prefix)$(_github_ci::instance "$1")" }

_github_ci::labels() {
    local raw
    raw="$(mod_config labels | head -1)"
    [[ -n "$raw" ]] || raw="self-hosted,linux,ci-stateless,{machine}"
    print -r -- "${raw//\{machine\}/$(_github_ci::machine)}"
}

_github_ci::in_test() { [[ -n "${GITHUB_CI_SYSTEMD_DIR:-}" ]] }

_github_ci::root() {
    if _github_ci::in_test || (( EUID == 0 )); then
        [[ "$DRY_RUN" == true ]] && { printf '[dry-run] sudo %s\n' "$*"; return 0; }
        "$@"
        return $?
    fi
    [[ "$DRY_RUN" == true ]] && { printf '[dry-run] sudo %s\n' "$*"; return 0; }
    primer::run_as_root "Stateless GitHub Actions runners" "$@"
}

_github_ci::as_user() {
    local user="$1" home="$2"
    shift 2
    if _github_ci::in_test || (( EUID == 0 )); then
        [[ "$DRY_RUN" == true ]] && { printf '[dry-run] %s %s\n' "$user" "$*"; return 0; }
        env HOME="$home" "$@"
        return $?
    fi
    [[ "$DRY_RUN" == true ]] && { printf '[dry-run] sudo -u %s %s\n' "$user" "$*"; return 0; }
    primer::run_as_root "Stateless GitHub Actions runners" -u "$user" env HOME="$home" "$@"
}

_github_ci::tarball() { print -r -- "actions-runner-linux-$(_github_ci::arch)-$(_github_ci::version).tar.gz" }

_github_ci::ensure_dist() {
    local home dist tar seed actual
    home="$(_github_ci::home)"
    dist="$home/_dist"
    tar="$dist/$(_github_ci::tarball)"
    seed="$(_github_ci::seed_dist)/$(_github_ci::tarball)"
    _github_ci::root install -d -m 0755 -o root -g root "$home" "$dist" || return 1
    if [[ -f "$tar" ]]; then
        actual="$(sha256sum "$tar" | awk '{print $1}')"
        [[ "$actual" == "$(_github_ci::sha256)" ]] && return 0
    fi
    if [[ -f "$seed" ]]; then
        actual="$(sha256sum "$seed" | awk '{print $1}')"
        if [[ "$actual" == "$(_github_ci::sha256)" ]]; then
            _github_ci::root install -m 0644 -o root -g root "$seed" "$tar"
            return $?
        fi
    fi
    [[ "$DRY_RUN" == true ]] && { print "[dry-run] download runner $(_github_ci::version)"; return 0; }
    _github_ci::root curl -fsSL \
        "https://github.com/actions/runner/releases/download/v$(_github_ci::version)/$(_github_ci::tarball)" \
        -o "$tar" || return 1
    actual="$(sha256sum "$tar" | awk '{print $1}')"
    [[ "$actual" == "$(_github_ci::sha256)" ]] || { print "runner checksum mismatch" >&2; return 1; }
}

_github_ci::ensure_user() {
    local repo="$1" instance user dest
    instance="$(_github_ci::instance "$repo")"
    user="$(_github_ci::user "$repo")"
    dest="$(_github_ci::home)/$instance"
    if getent passwd "$user" >/dev/null 2>&1; then
        return 0
    fi
    _github_ci::root useradd --system --create-home --home-dir "$dest" \
        --shell /usr/sbin/nologin "$user"
}

_github_ci::ensure_files() {
    local repo="$1" instance user dest tar
    instance="$(_github_ci::instance "$repo")"
    user="$(_github_ci::user "$repo")"
    dest="$(_github_ci::home)/$instance"
    tar="$(_github_ci::home)/_dist/$(_github_ci::tarball)"
    _github_ci::root install -d -m 0700 -o "$user" -g "$user" "$dest" || return 1
    _github_ci::root chmod 0700 "$dest" || return 1
    if [[ -x "$dest/run.sh" && -f "$dest/.primer-runner-version" ]] \
        && [[ "$(<"$dest/.primer-runner-version")" == "$(_github_ci::version)" ]]; then
        return 0
    fi
    [[ "$DRY_RUN" == true ]] && { print "[dry-run] extract runner into $dest"; return 0; }
    _github_ci::root tar -xzf "$tar" -C "$dest" || return 1
    print -r -- "$(_github_ci::version)" | _github_ci::root tee "$dest/.primer-runner-version" >/dev/null || return 1
    _github_ci::root chown -R "$user:$user" "$dest" || return 1
    command -v restorecon >/dev/null 2>&1 && _github_ci::root restorecon -RF "$dest" || true
}

_github_ci::ensure_selinux() {
    local home="$(_github_ci::home)" work_pattern
    _github_ci::in_test && return 0
    command -v semanage >/dev/null 2>&1 || return 0
    command -v restorecon >/dev/null 2>&1 || return 0
    work_pattern="${home}/[^/]+/_work(/.*)?"
    if ! semanage fcontext -l | grep -F "$home(/.*)?" >/dev/null 2>&1; then
        _github_ci::root semanage fcontext -a -t bin_t "${home}(/.*)?" || return 1
    fi
    if ! semanage fcontext -l | grep -F "${home}/[^/]+/_work" >/dev/null 2>&1; then
        _github_ci::root semanage fcontext -a -t var_lib_t "$work_pattern" || return 1
    fi
    _github_ci::root restorecon -RF "$home"
}

_github_ci::register() {
    local repo="$1" instance user dest token name
    instance="$(_github_ci::instance "$repo")"
    user="$(_github_ci::user "$repo")"
    dest="$(_github_ci::home)/$instance"
    [[ -f "$dest/.runner" ]] && return 0
    name="$(_github_ci::machine)-ci-$instance"
    if [[ "$DRY_RUN" == true ]]; then
        print "[dry-run] register $name for $repo with $(_github_ci::labels)"
        return 0
    fi
    token="$(gh api -X POST "repos/$repo/actions/runners/registration-token" --jq .token)" || return 1
    [[ -n "$token" ]] || return 1
    (
        cd "$dest" || exit 1
        _github_ci::as_user "$user" "$dest" ./config.sh --unattended --replace --disableupdate \
            --url "https://github.com/$repo" --token "$token" --name "$name" \
            --labels "$(_github_ci::labels)" --work _work
    )
    local rc=$?
    unset token
    (( rc == 0 )) || return "$rc"
    _github_ci::root chmod 0600 \
        "$dest/.runner" "$dest/.credentials" "$dest/.credentials_rsaparams"
}

_github_ci::lock_home() {
    local repo="$1" instance user dest
    instance="$(_github_ci::instance "$repo")"
    user="$(_github_ci::user "$repo")"
    dest="$(_github_ci::home)/$instance"
    # Runner.Listener relaxes a user-owned install directory to 0755 at start.
    # Root ownership keeps the repository-specific group boundary durable.
    _github_ci::root chown "root:$user" "$dest" || return 1
    _github_ci::root chmod 0750 "$dest"
}

_github_ci::install_units() {
    local systemd="$(_github_ci::systemd_dir)" libexec="$(_github_ci::libexec_dir)" name
    for name in gha-ci-stateless.slice github-ci-runner@.service; do
        _github_ci::root install -D -m 0644 "$MOD_DIR/files/etc/systemd/system/$name" "$systemd/$name" || return 1
    done
    _github_ci::root install -D -m 0755 \
        "$MOD_DIR/files/usr/local/libexec/primer-github-ci-runner-cleanup.sh" \
        "$libexec/primer-github-ci-runner-cleanup.sh" || return 1
    # Remove the pre-pilot hook name that GitHub rejects because it has no script extension.
    _github_ci::root rm -f "$libexec/primer-github-ci-runner-cleanup"
}

_github_ci::enable() {
    local instance="$(_github_ci::instance "$1")" unit="github-ci-runner@$(_github_ci::instance "$1").service"
    _github_ci::root systemctl daemon-reload || return 1
    _github_ci::root systemctl enable "$unit" || return 1
    if _github_ci::root systemctl is-active --quiet "$unit"; then
        return 0
    fi
    _github_ci::root systemctl start "$unit"
}

mod_update() {
    [[ "$(uname -s)" == Linux ]] || { primer::status_msg "Linux only"; return 1; }
    local -a repos=()
    local repo
    while IFS= read -r repo; do repos+=("$repo"); done < <(_github_ci::repos)
    (( ${#repos[@]} > 0 )) || { primer::status_msg "no repos configured"; return 1; }

    _github_ci::install_units || { primer::status_msg "unit install failed"; return 1; }
    _github_ci::ensure_dist || { primer::status_msg "runner download failed"; return 1; }

    for repo in "${repos[@]}"; do
        _github_ci::repo_ok "$repo" || { primer::status_msg "invalid repo $repo"; return 1; }
        _github_ci::ensure_user "$repo" || return 1
        _github_ci::ensure_files "$repo" || return 1
        _github_ci::register "$repo" || return 1
        _github_ci::lock_home "$repo" || return 1
    done
    _github_ci::ensure_selinux || { primer::status_msg "SELinux setup failed"; return 1; }
    for repo in "${repos[@]}"; do
        _github_ci::enable "$repo" || return 1
    done
    # Runner.Listener creates _work on first start, after the initial relabel.
    _github_ci::ensure_selinux || { primer::status_msg "SELinux setup failed"; return 1; }
    primer::status_msg "CI runners online"
}

mod_status() {
    local issues=0 repo instance user dest name
    for name in gha-ci-stateless.slice github-ci-runner@.service; do
        cmp -s "$MOD_DIR/files/etc/systemd/system/$name" "$(_github_ci::systemd_dir)/$name" \
            || (( issues++ ))
    done
    cmp -s "$MOD_DIR/files/usr/local/libexec/primer-github-ci-runner-cleanup.sh" \
        "$(_github_ci::libexec_dir)/primer-github-ci-runner-cleanup.sh" || (( issues++ ))
    while IFS= read -r repo; do
        instance="$(_github_ci::instance "$repo")"
        user="$(_github_ci::user "$repo")"
        dest="$(_github_ci::home)/$instance"
        getent passwd "$user" >/dev/null 2>&1 || (( issues++ ))
        id -Gn "$user" 2>/dev/null | tr ' ' '\n' | grep -Fx docker >/dev/null && (( issues++ ))
        [[ "$(stat -c '%U:%G:%a' "$dest" 2>/dev/null)" == "root:$user:750" ]] || (( issues++ ))
        [[ -f "$dest/.runner" ]] || (( issues++ ))
        if ! _github_ci::in_test; then
            systemctl is-active --quiet "github-ci-runner@$instance.service" || (( issues++ ))
        fi
    done < <(_github_ci::repos)
    (( issues == 0 )) && { primer::status_msg "configured"; return 0; }
    primer::status_msg "$issues issue(s)"
    return 1
}
