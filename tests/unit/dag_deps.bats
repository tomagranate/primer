#!/usr/bin/env bats
# tests/unit/dag_deps.bats -- DAG dependency resolution tests

load '../helpers/common'

# ── engine::_deps_met ────────────────────────────────────────────────────────

@test "deps_met: true when all deps are done" {
    zsh_run '
        engine::load_config "$PRIMER_DIR/configs/common.conf" "$PRIMER_DIR/configs/profiles/mac.conf"
        _state[xcode-cli-tools]=done
        engine::_deps_met homebrew && echo YES || echo NO
    '
    assert_output "YES"
}

@test "deps_met: false when a dep is still running" {
    zsh_run '
        engine::load_config "$PRIMER_DIR/configs/common.conf" "$PRIMER_DIR/configs/profiles/mac.conf"
        _state[xcode-cli-tools]=running
        engine::_deps_met homebrew && echo YES || echo NO
    '
    assert_output "NO"
}

@test "deps_met: false when a dep is pending" {
    zsh_run '
        engine::load_config "$PRIMER_DIR/configs/common.conf" "$PRIMER_DIR/configs/profiles/mac.conf"
        _state[xcode-cli-tools]=pending
        engine::_deps_met homebrew && echo YES || echo NO
    '
    assert_output "NO"
}

@test "deps_met: false when a dep is failed" {
    zsh_run '
        engine::load_config "$PRIMER_DIR/configs/common.conf" "$PRIMER_DIR/configs/profiles/mac.conf"
        _state[xcode-cli-tools]=failed
        engine::_deps_met homebrew && echo YES || echo NO
    '
    assert_output "NO"
}

@test "deps_met: true when module has no deps" {
    zsh_run '
        engine::load_config "$PRIMER_DIR/configs/common.conf" "$PRIMER_DIR/configs/profiles/mac.conf"
        engine::_deps_met touchid && echo YES || echo NO
    '
    assert_output "YES"
}

@test "deps_met: true when module has no deps (xcode-cli-tools)" {
    zsh_run '
        engine::load_config "$PRIMER_DIR/configs/common.conf" "$PRIMER_DIR/configs/profiles/mac.conf"
        engine::_deps_met xcode-cli-tools && echo YES || echo NO
    '
    assert_output "YES"
}

# ── engine::_deps_failed ─────────────────────────────────────────────────────

@test "deps_failed: true when a dep is failed" {
    zsh_run '
        engine::load_config "$PRIMER_DIR/configs/common.conf" "$PRIMER_DIR/configs/profiles/mac.conf"
        _state[xcode-cli-tools]=failed
        engine::_deps_failed homebrew && echo YES || echo NO
    '
    assert_output "YES"
}

@test "deps_failed: true when a dep is skipped" {
    zsh_run '
        engine::load_config "$PRIMER_DIR/configs/common.conf" "$PRIMER_DIR/configs/profiles/mac.conf"
        _state[xcode-cli-tools]=skipped
        engine::_deps_failed homebrew && echo YES || echo NO
    '
    assert_output "YES"
}

@test "deps_failed: false when deps are all done" {
    zsh_run '
        engine::load_config "$PRIMER_DIR/configs/common.conf" "$PRIMER_DIR/configs/profiles/mac.conf"
        _state[xcode-cli-tools]=done
        engine::_deps_failed homebrew && echo YES || echo NO
    '
    assert_output "NO"
}

@test "deps_failed: false when deps are running" {
    zsh_run '
        engine::load_config "$PRIMER_DIR/configs/common.conf" "$PRIMER_DIR/configs/profiles/mac.conf"
        _state[xcode-cli-tools]=running
        engine::_deps_failed homebrew && echo YES || echo NO
    '
    assert_output "NO"
}

@test "deps_failed: false when module has no deps" {
    zsh_run '
        engine::load_config "$PRIMER_DIR/configs/common.conf" "$PRIMER_DIR/configs/profiles/mac.conf"
        engine::_deps_failed touchid && echo YES || echo NO
    '
    assert_output "NO"
}

# ── Login dependencies ───────────────────────────────────────────────────────

@test "deps_met: false when login dep is still pending" {
    zsh_run '
        _mod_deps[agents]=homebrew
        _mod_login_deps[agents]=github
        _state[homebrew]=done
        _login_state[github]=pending
        DRY_RUN=false
        engine::_deps_met agents && echo YES || echo NO
    '
    assert_output "NO"
}

@test "deps_met: true when login dep is done" {
    zsh_run '
        _mod_deps[agents]=homebrew
        _mod_login_deps[agents]=github
        _state[homebrew]=done
        _login_state[github]=done
        DRY_RUN=false
        engine::_deps_met agents && echo YES || echo NO
    '
    assert_output "YES"
}

@test "deps_met: true for login deps during dry run" {
    zsh_run '
        _mod_deps[agents]=homebrew
        _mod_login_deps[agents]=github
        _state[homebrew]=done
        _login_state[github]=pending
        DRY_RUN=true
        engine::_deps_met agents && echo YES || echo NO
    '
    assert_output "YES"
}

@test "deps_failed: true when login dep is skipped" {
    zsh_run '
        _mod_deps[agents]=homebrew
        _mod_login_deps[agents]=github
        _state[homebrew]=done
        _login_state[github]=skipped
        DRY_RUN=false
        engine::_deps_failed agents && echo YES || echo NO
    '
    assert_output "YES"
}

@test "deps_failed: true when login dep failed" {
    zsh_run '
        _mod_login_deps[agents]=github
        _login_state[github]=failed
        DRY_RUN=false
        engine::_deps_failed agents && echo YES || echo NO
    '
    assert_output "YES"
}

@test "runnable_logins_needed_by_pending: lists gate logins" {
    zsh_run '
        _mod_order=(homebrew agents)
        _mod_deps[agents]=homebrew
        _mod_login_deps[agents]=github
        _state[homebrew]=done
        _state[agents]=pending
        _login_all_order=(github tailscale)
        _login_state[github]=pending
        _login_state[tailscale]=pending
        _mod_config[logins.github_depends_on]="ssh, git, homebrew"
        _state[ssh]=done
        _state[git]=done
        engine::_runnable_logins_needed_by_pending
    '
    assert_success
    assert_output "github"
}

@test "runnable_logins_needed_by_pending: waits until login module deps finish" {
    zsh_run '
        _mod_order=(agents)
        _mod_login_deps[agents]=github
        _state[agents]=pending
        _login_all_order=(github)
        _login_state[github]=pending
        _mod_config[logins.github_depends_on]=homebrew
        _state[homebrew]=pending
        engine::_runnable_logins_needed_by_pending && echo YES || echo NO
    '
    assert_output "NO"
}

# ── engine::_has_active ──────────────────────────────────────────────────────

@test "has_active: true when a module is pending" {
    zsh_run '
        engine::load_config "$PRIMER_DIR/configs/common.conf" "$PRIMER_DIR/configs/profiles/mac.conf"
        local m; for m in $_mod_order; do _state[$m]=done; done
        _state[touchid]=pending
        engine::_has_active && echo YES || echo NO
    '
    assert_output "YES"
}

@test "has_active: true when a module is running" {
    zsh_run '
        engine::load_config "$PRIMER_DIR/configs/common.conf" "$PRIMER_DIR/configs/profiles/mac.conf"
        local m; for m in $_mod_order; do _state[$m]=done; done
        _state[mise]=running
        engine::_has_active && echo YES || echo NO
    '
    assert_output "YES"
}

@test "has_active: false when all modules are done" {
    zsh_run '
        engine::load_config "$PRIMER_DIR/configs/common.conf" "$PRIMER_DIR/configs/profiles/mac.conf"
        local m; for m in $_mod_order; do _state[$m]=done; done
        engine::_has_active && echo YES || echo NO
    '
    assert_output "NO"
}

@test "has_active: false when all modules are done/failed/skipped" {
    zsh_run '
        engine::load_config "$PRIMER_DIR/configs/common.conf" "$PRIMER_DIR/configs/profiles/mac.conf"
        local m; for m in $_mod_order; do _state[$m]=done; done
        _state[touchid]=failed
        _state[scripts]=skipped
        engine::_has_active && echo YES || echo NO
    '
    assert_output "NO"
}

# ── Transitive dependency scenarios ──────────────────────────────────────────

@test "deps_met: zsh requires homebrew done (transitive through xcode-cli-tools)" {
    zsh_run '
        engine::load_config "$PRIMER_DIR/configs/common.conf" "$PRIMER_DIR/configs/profiles/mac.conf"
        _state[homebrew]=done
        engine::_deps_met zsh && echo YES || echo NO
    '
    assert_output "YES"
}

@test "deps_met: zsh blocked when homebrew is not done" {
    zsh_run '
        engine::load_config "$PRIMER_DIR/configs/common.conf" "$PRIMER_DIR/configs/profiles/mac.conf"
        _state[homebrew]=running
        engine::_deps_met zsh && echo YES || echo NO
    '
    assert_output "NO"
}

# ── engine::_module_needs_sudo ────────────────────────────────────────────────

@test "needs_sudo: config key marks the module" {
    zsh_run '
        _mod_config[demo.needs_sudo]=true
        engine::_module_needs_sudo demo && echo YES || echo NO
    '
    assert_output "YES"
}

@test "needs_sudo: false value clears the module" {
    zsh_run '
        _mod_config[demo.needs_sudo]=false
        engine::_module_needs_sudo demo && echo YES || echo NO
    '
    assert_output "NO"
}

@test "needs_sudo: module without the key does not need sudo" {
    zsh_run '
        _mod_config[demo.label]="Demo"
        engine::_module_needs_sudo demo && echo YES || echo NO
    '
    assert_output "NO"
}

@test "needs_sudo: privileged step marks any module" {
    zsh_run '
        _mod_config[demo.installers]="- name: x
      privileged: true"
        engine::_module_needs_sudo demo && echo YES || echo NO
    '
    assert_output "YES"
}

@test "needs_sudo: privileged step in another module does not leak" {
    zsh_run '
        _mod_config[demo.installers]="- name: x
      privileged: true"
        engine::_module_needs_sudo other && echo YES || echo NO
    '
    assert_output "NO"
}

@test "needs_sudo: mac profile marks Homebrew bootstrap, Xcode, and Touch ID" {
    zsh_run '
        engine::load_config "$PRIMER_DIR/configs/common.conf" "$PRIMER_DIR/configs/profiles/mac.conf"
        local m
        local -a out=()
        for m in $_mod_order; do
            engine::_module_needs_sudo $m && out+=($m)
        done
        print -r -- "${out[*]}"
    '
    assert_output "homebrew xcode touchid"
}

@test "needs_sudo: linux-vps profile marks apt, tailscale, login-shell" {
    zsh_run '
        engine::load_config "$PRIMER_DIR/configs/common.conf" "$PRIMER_DIR/configs/profiles/linux-vps.conf"
        local m
        local -a out=()
        for m in $_mod_order; do
            engine::_module_needs_sudo $m && out+=($m)
        done
        print -r -- "${out[*]}"
    '
    assert_output "apt tailscale login-shell"
}

@test "needs_sudo: ubuntu-desktop adds flatpak and privileged shell-installers" {
    zsh_run '
        engine::load_config "$PRIMER_DIR/configs/common.conf" "$PRIMER_DIR/configs/profiles/ubuntu-desktop.conf"
        local m
        local -a out=()
        for m in $_mod_order; do
            engine::_module_needs_sudo $m && out+=($m)
        done
        print -r -- "${out[*]}"
    '
    assert_output "apt tailscale flatpak shell-installers login-shell"
}

@test "needs_sudo: linux-vps shell-installers stays unprivileged" {
    zsh_run '
        engine::load_config "$PRIMER_DIR/configs/common.conf" "$PRIMER_DIR/configs/profiles/linux-vps.conf"
        engine::_module_needs_sudo shell-installers && echo YES || echo NO
    '
    assert_output "NO"
}

# ── engine::_needs_sudo ───────────────────────────────────────────────────────

@test "needs_sudo: run needs sudo when a sudo module is active" {
    [ "$(id -u)" -ne 0 ] || skip "root never prompts for sudo"
    zsh_run '
        engine::load_config "$PRIMER_DIR/configs/common.conf" "$PRIMER_DIR/configs/profiles/mac.conf"
        local m; for m in $_mod_order; do _state[$m]=pending; done
        engine::_needs_sudo && echo YES || echo NO
    '
    assert_output "YES"
}

@test "needs_sudo: run skips sudo when every sudo module is skipped" {
    [ "$(id -u)" -ne 0 ] || skip "root never prompts for sudo"
    zsh_run '
        engine::load_config "$PRIMER_DIR/configs/common.conf" "$PRIMER_DIR/configs/profiles/mac.conf"
        local m; for m in $_mod_order; do _state[$m]=pending; done
        _state[homebrew]=skipped
        _state[touchid]=skipped
        _state[xcode]=skipped
        engine::_needs_sudo && echo YES || echo NO
    '
    assert_output "NO"
}

# ── engine::_apply_filters ────────────────────────────────────────────────────

@test "apply_filters: PRIMER_SKIP marks named module as skipped" {
    zsh_run '
        PRIMER_SKIP="macos"
        engine::load_config "$PRIMER_DIR/configs/common.conf" "$PRIMER_DIR/configs/profiles/mac.conf"
        local m; for m in $_mod_order; do _state[$m]=pending; done
        engine::_apply_filters
        echo "${_state[macos]}"
    '
    assert_output "skipped"
}

@test "apply_filters: PRIMER_SKIP leaves other modules pending" {
    zsh_run '
        PRIMER_SKIP="macos"
        engine::load_config "$PRIMER_DIR/configs/common.conf" "$PRIMER_DIR/configs/profiles/mac.conf"
        local m; for m in $_mod_order; do _state[$m]=pending; done
        engine::_apply_filters
        echo "${_state[homebrew]}"
    '
    assert_output "pending"
}

@test "apply_filters: PRIMER_SKIP accepts multiple space-separated modules" {
    zsh_run '
        PRIMER_SKIP="macos homebrew-apps"
        engine::load_config "$PRIMER_DIR/configs/common.conf" "$PRIMER_DIR/configs/profiles/mac.conf"
        local m; for m in $_mod_order; do _state[$m]=pending; done
        engine::_apply_filters
        echo "${_state[macos]} ${_state[homebrew-apps]}"
    '
    assert_output "skipped skipped"
}

@test "apply_filters: PRIMER_ONLY marks all other modules as skipped" {
    zsh_run '
        PRIMER_ONLY="homebrew"
        engine::load_config "$PRIMER_DIR/configs/common.conf" "$PRIMER_DIR/configs/profiles/mac.conf"
        local m; for m in $_mod_order; do _state[$m]=pending; done
        engine::_apply_filters
        echo "${_state[homebrew]} ${_state[macos]}"
    '
    assert_output "pending skipped"
}

@test "apply_filters: PRIMER_ONLY keeps listed modules pending" {
    zsh_run '
        PRIMER_ONLY="homebrew homebrew-apps"
        engine::load_config "$PRIMER_DIR/configs/common.conf" "$PRIMER_DIR/configs/profiles/mac.conf"
        local m; for m in $_mod_order; do _state[$m]=pending; done
        engine::_apply_filters
        echo "${_state[homebrew]} ${_state[homebrew-apps]} ${_state[macos]}"
    '
    assert_output "pending pending skipped"
}

@test "apply_filters: empty PRIMER_SKIP and PRIMER_ONLY leaves all pending" {
    zsh_run '
        PRIMER_SKIP=""
        PRIMER_ONLY=""
        engine::load_config "$PRIMER_DIR/configs/common.conf" "$PRIMER_DIR/configs/profiles/mac.conf"
        local m; for m in $_mod_order; do _state[$m]=pending; done
        engine::_apply_filters
        local any_skipped=false
        for m in $_mod_order; do
            [[ "${_state[$m]}" == "skipped" ]] && any_skipped=true
        done
        echo "$any_skipped"
    '
    assert_output "false"
}
