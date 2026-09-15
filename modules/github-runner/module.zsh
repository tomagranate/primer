#!/bin/zsh
# modules/github-runner -- self-hosted GitHub Actions runners as gha-runner

_github_runner::user() {
    local value
    value="$(mod_config user | head -1)"
    print -r -- "${value:-gha-runner}"
}

_github_runner::home() {
    local value
    value="$(mod_config home | head -1)"
    print -r -- "${value:-/var/lib/github-runner}"
}

_github_runner::runner_version() {
    local value
    value="$(mod_config runner_version | head -1)"
    print -r -- "${value:-2.337.0}"
}

_github_runner::runner_sha256() {
    local value
    value="$(mod_config runner_sha256 | head -1)"
    print -r -- "${value:-70920811a4f8ad4328818682bca5c6469c1c942fab52448868071d0063816613}"
}

_github_runner::jbot_image() {
    local value
    value="$(mod_config jbot_image | head -1)"
    print -r -- "${value:-ghcr.io/pgup-ai/jbot-review:latest-slim}"
}

_github_runner::machine() {
    local name
    name="$(hostname -s 2>/dev/null || hostname 2>/dev/null || print unknown)"
    print -r -- "${(L)name}"
}

_github_runner::arch() {
    case "$(uname -m)" in
        x86_64|amd64) print x64 ;;
        aarch64|arm64) print arm64 ;;
        *) print x64 ;;
    esac
}

_github_runner::systemd_dir() {
    print -r -- "${GITHUB_RUNNER_SYSTEMD_DIR:-/etc/systemd/system}"
}

_github_runner::in_test() {
    [[ -n "${GITHUB_RUNNER_SYSTEMD_DIR:-}" ]]
}

_github_runner::run_as_root() {
    if _github_runner::in_test; then
        if [[ "$DRY_RUN" == true ]]; then
            printf '[dry-run] sudo %s\n' "$*"
            return 0
        fi
        "$@"
        return $?
    fi
    if [[ "$DRY_RUN" == true ]]; then
        printf '[dry-run] sudo %s\n' "$*"
        return 0
    fi
    primer::run_as_root "GitHub Actions fleet runner" "$@"
}

_github_runner::as_runner() {
    local user="$(_github_runner::user)"
    if _github_runner::in_test || [[ "$EUID" == 0 ]]; then
        if [[ "$DRY_RUN" == true ]]; then
            printf '[dry-run] %s\n' "$*"
            return 0
        fi
        "$@"
        return $?
    fi
    if [[ "$DRY_RUN" == true ]]; then
        printf '[dry-run] sudo -u %s %s\n' "$user" "$*"
        return 0
    fi
    primer::run_as_root "GitHub Actions fleet runner" -u "$user" "$@"
}

_github_runner::labels() {
    local raw machine
    machine="$(_github_runner::machine)"
    raw="$(mod_config labels | head -1)"
    [[ -n "$raw" ]] || raw="self-hosted,linux,fleet,{machine}"
    print -r -- "${raw//\{machine\}/$machine}"
}

_github_runner::repos() {
    local line
    while IFS= read -r line; do
        [[ -n "$line" ]] && print -r -- "$line"
    done < <(mod_config repos)
}

_github_runner::instance() {
    print -r -- "${1//\//--}"
}

_github_runner::repo_ok() {
    [[ "$1" =~ '^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$' ]]
}

_github_runner::unit_source() {
    print -r -- "$MOD_DIR/files/etc/systemd/system/$1"
}

_github_runner::unit_dest() {
    print -r -- "$(_github_runner::systemd_dir)/$1"
}

_github_runner::libexec_dir() {
    print -r -- "${GITHUB_RUNNER_LIBEXEC_DIR:-/usr/local/libexec}"
}

_github_runner::cleanup_name() {
    print -r -- primer-github-runner-cleanup
}

_github_runner::install_units() {
    local name dest src
    for name in gha-runner.slice github-runner@.service; do
        src="$(_github_runner::unit_source "$name")"
        dest="$(_github_runner::unit_dest "$name")"
        _github_runner::run_as_root install -D -m 0644 "$src" "$dest" || return 1
    done
    src="$MOD_DIR/files/usr/local/libexec/$(_github_runner::cleanup_name)"
    dest="$(_github_runner::libexec_dir)/$(_github_runner::cleanup_name)"
    _github_runner::run_as_root install -D -m 0755 "$src" "$dest" || return 1
}

_github_runner::units_match() {
    local name dest src
    for name in gha-runner.slice github-runner@.service; do
        src="$(_github_runner::unit_source "$name")"
        dest="$(_github_runner::unit_dest "$name")"
        [[ -f "$dest" ]] && cmp -s "$src" "$dest" || return 1
    done
    src="$MOD_DIR/files/usr/local/libexec/$(_github_runner::cleanup_name)"
    dest="$(_github_runner::libexec_dir)/$(_github_runner::cleanup_name)"
    [[ -f "$dest" ]] && cmp -s "$src" "$dest" || return 1
}

_github_runner::ensure_user() {
    local user home
    user="$(_github_runner::user)"
    home="$(_github_runner::home)"

    if [[ "$user" == "$(id -un)" ]]; then
        print "github-runner refuses to run as the login user ($user)" >&2
        return 1
    fi
    if [[ "$user" != gha-runner ]]; then
        print "github-runner user must be gha-runner (got $user)" >&2
        return 1
    fi

    if getent passwd "$user" >/dev/null 2>&1; then
        return 0
    fi

    _github_runner::run_as_root useradd --system --create-home \
        --home-dir "$home" --shell /usr/sbin/nologin "$user" || return 1
    if getent group docker >/dev/null 2>&1; then
        _github_runner::run_as_root usermod -aG docker "$user" || return 1
    fi
}

_github_runner::tarball_name() {
    print -r -- "actions-runner-linux-$(_github_runner::arch)-$(_github_runner::runner_version).tar.gz"
}

_github_runner::tarball_url() {
    print -r -- "https://github.com/actions/runner/releases/download/v$(_github_runner::runner_version)/$(_github_runner::tarball_name)"
}

_github_runner::selinux_label() {
    local home="$(_github_runner::home)"
    _github_runner::in_test && return 0
    command -v semanage >/dev/null 2>&1 || return 0
    command -v restorecon >/dev/null 2>&1 || return 0
    if [[ "$DRY_RUN" == true ]]; then
        printf '[dry-run] semanage fcontext -a -t bin_t %s\n' "${home}(/.*)?"
        return 0
    fi
    if ! semanage fcontext -l | grep -F "$home(/.*)?" >/dev/null 2>&1; then
        _github_runner::run_as_root semanage fcontext -a -t bin_t "${home}(/.*)?" || return 1
    fi
    local work_pat="${home}/[^/]+/_work(/.*)?"
    if ! semanage fcontext -l | grep -F "${home}/[^/]+/_work" >/dev/null 2>&1; then
        _github_runner::run_as_root semanage fcontext -a -t container_file_t "$work_pat" || return 1
    fi
    _github_runner::run_as_root restorecon -RF "$home"
}

_github_runner::ensure_dist() {
    local home dist tar expected actual
    home="$(_github_runner::home)"
    dist="$home/_dist"
    tar="$dist/$(_github_runner::tarball_name)"
    expected="$(_github_runner::runner_sha256)"

    _github_runner::run_as_root install -d -m 0755 "$home" "$dist" || return 1
    _github_runner::run_as_root chown "$(_github_runner::user):$(_github_runner::user)" "$home" "$dist" || return 1

    if [[ "$DRY_RUN" == true ]]; then
        printf '[dry-run] download %s\n' "$(_github_runner::tarball_url)"
        return 0
    fi

    if [[ -f "$tar" ]]; then
        actual="$(sha256sum "$tar" | awk '{print $1}')"
        [[ "$actual" == "$expected" ]] && return 0
    fi

    _github_runner::run_as_root curl -fsSL "$(_github_runner::tarball_url)" -o "$tar" || return 1
    actual="$(sha256sum "$tar" | awk '{print $1}')"
    if [[ "$actual" != "$expected" ]]; then
        print "GitHub runner tarball checksum mismatch" >&2
        return 1
    fi
    _github_runner::run_as_root chown "$(_github_runner::user):$(_github_runner::user)" "$tar"
}

_github_runner::ensure_instance_files() {
    local repo="$1" instance home dest tar version
    instance="$(_github_runner::instance "$repo")"
    home="$(_github_runner::home)"
    dest="$home/$instance"
    tar="$home/_dist/$(_github_runner::tarball_name)"
    version="$(_github_runner::runner_version)"

    _github_runner::run_as_root install -d -m 0755 "$dest" || return 1
    _github_runner::run_as_root chown "$(_github_runner::user):$(_github_runner::user)" "$dest" || return 1

    if [[ "$DRY_RUN" == true ]]; then
        printf '[dry-run] extract runner into %s\n' "$dest"
        return 0
    fi

    if [[ -x "$dest/run.sh" && -f "$dest/.primer-runner-version" ]] \
        && [[ "$(<"$dest/.primer-runner-version")" == "$version" ]]; then
        return 0
    fi

    _github_runner::run_as_root tar -xzf "$tar" -C "$dest" || return 1
    print -r -- "$version" | _github_runner::run_as_root tee "$dest/.primer-runner-version" >/dev/null || return 1
    _github_runner::run_as_root chown -R "$(_github_runner::user):$(_github_runner::user)" "$dest" || return 1
    if ! _github_runner::in_test && command -v restorecon >/dev/null 2>&1; then
        _github_runner::run_as_root restorecon -RF "$dest" || return 1
    fi
}

_github_runner::configured() {
    local dest="$(_github_runner::home)/$(_github_runner::instance "$1")"
    [[ -f "$dest/.runner" ]]
}

_github_runner::register() {
    local repo="$1" instance dest token labels name machine
    instance="$(_github_runner::instance "$repo")"
    dest="$(_github_runner::home)/$instance"
    labels="$(_github_runner::labels)"
    machine="$(_github_runner::machine)"
    name="${machine}-${repo##*/}"

    if _github_runner::configured "$repo"; then
        return 0
    fi

    if [[ "$DRY_RUN" == true ]]; then
        printf '[dry-run] register runner %s for %s labels %s\n' "$name" "$repo" "$labels"
        return 0
    fi

    if ! command -v gh >/dev/null 2>&1; then
        print "gh is required to register $repo" >&2
        return 1
    fi

    token="$(gh api -X POST "repos/$repo/actions/runners/registration-token" --jq .token)" || {
        print "failed to mint a registration token for $repo" >&2
        return 1
    }
    [[ -n "$token" ]] || return 1

    (
        cd "$dest" || exit 1
        _github_runner::as_runner ./config.sh \
            --unattended \
            --replace \
            --disableupdate \
            --url "https://github.com/$repo" \
            --token "$token" \
            --name "$name" \
            --labels "$labels" \
            --work _work
    )
    local rc=$?
    unset token
    return "$rc"
}

_github_runner::enable_instance() {
    local repo="$1" instance
    instance="$(_github_runner::instance "$repo")"
    if [[ "$DRY_RUN" == true ]]; then
        printf '[dry-run] systemctl enable --now github-runner@%s.service\n' "$instance"
        return 0
    fi
    _github_runner::run_as_root systemctl daemon-reload || return 1
    _github_runner::run_as_root systemctl enable --now "github-runner@${instance}.service"
}

_github_runner::pull_image() {
    local image="$(_github_runner::jbot_image)"
    if [[ "$DRY_RUN" == true ]]; then
        printf '[dry-run] docker pull %s\n' "$image"
        return 0
    fi
    if ! command -v docker >/dev/null 2>&1; then
        print "docker is not installed; the first review job will pull $image" >&2
        return 1
    fi
    docker pull "$image"
}

mod_update() {
    if [[ "$(uname -s)" != Linux ]]; then
        primer::status_msg "Linux only"
        return 1
    fi

    local -a repos=()
    local repo
    while IFS= read -r repo; do
        repos+=("$repo")
    done < <(_github_runner::repos)

    if (( ${#repos[@]} == 0 )); then
        primer::status_msg "no repos configured"
        return 1
    fi

    local -a items=(user units dist)
    for repo in "${repos[@]}"; do
        items+=("repo:$repo")
    done
    items+=(selinux image)
    primer::items_init "${items[@]}"

    primer::item_update user running
    if ! _github_runner::ensure_user; then
        primer::item_update user failed "user setup failed"
        primer::status_msg "user failed"
        return 1
    fi
    primer::item_update user done

    primer::item_update units running
    if ! _github_runner::install_units; then
        primer::item_update units failed "unit install failed"
        primer::status_msg "units failed"
        return 1
    fi
    primer::item_update units done

    primer::item_update dist running
    if ! _github_runner::ensure_dist; then
        primer::item_update dist failed "runner download failed"
        primer::status_msg "download failed"
        return 1
    fi
    primer::item_update dist done

    primer::item_update selinux running
    if ! _github_runner::selinux_label; then
        primer::item_update selinux failed "fcontext failed"
        primer::status_msg "selinux failed"
        return 1
    fi
    primer::item_update selinux done

    local failed=0
    for repo in "${repos[@]}"; do
        primer::item_update "repo:$repo" running
        if ! _github_runner::repo_ok "$repo"; then
            primer::item_update "repo:$repo" failed "invalid repo id"
            failed=1
            continue
        fi
        if ! _github_runner::ensure_instance_files "$repo"; then
            primer::item_update "repo:$repo" failed "extract failed"
            failed=1
            continue
        fi
        if ! _github_runner::register "$repo"; then
            primer::item_update "repo:$repo" failed "register failed"
            failed=1
            continue
        fi
        if ! _github_runner::enable_instance "$repo"; then
            primer::item_update "repo:$repo" failed "enable failed"
            failed=1
            continue
        fi
        primer::item_update "repo:$repo" done
    done

    primer::item_update image running
    if _github_runner::pull_image; then
        primer::item_update image done
    else
        primer::item_update image failed "pre-pull failed; first job will retry"
    fi

    if (( failed > 0 )); then
        primer::status_msg "runner setup had failures"
        return 1
    fi
    primer::status_msg "runners online"
}

mod_status() {
    if [[ "$(uname -s)" != Linux ]]; then
        primer::status_msg "Linux only"
        return 1
    fi

    local issues=0 user home repo instance
    user="$(_github_runner::user)"
    home="$(_github_runner::home)"

    [[ "$user" != "$(id -un)" ]] || (( issues++ ))
    getent passwd "$user" >/dev/null 2>&1 || (( issues++ ))
    _github_runner::units_match || (( issues++ ))
    [[ -d "$home" ]] || (( issues++ ))

    while IFS= read -r repo; do
        [[ -n "$repo" ]] || continue
        instance="$(_github_runner::instance "$repo")"
        [[ -f "$home/$instance/.runner" ]] || (( issues++ ))
        if ! _github_runner::in_test; then
            systemctl is-active --quiet "github-runner@${instance}.service" || (( issues++ ))
        fi
    done < <(_github_runner::repos)

    if (( issues == 0 )); then
        primer::status_msg "configured"
        return 0
    fi
    primer::status_msg "$issues issue(s)"
    return 1
}
