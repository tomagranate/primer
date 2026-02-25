#!/usr/bin/env bats
# tests/unit/dag_deps.bats -- DAG dependency resolution tests

load '../helpers/common'

# ── engine::_deps_met ────────────────────────────────────────────────────────

@test "deps_met: true when all deps are done" {
    zsh_run '
        engine::load_config "$PRIMER_DIR/primer.conf"
        _state[xcode]=done
        engine::_deps_met homebrew && echo YES || echo NO
    '
    assert_output "YES"
}

@test "deps_met: false when a dep is still running" {
    zsh_run '
        engine::load_config "$PRIMER_DIR/primer.conf"
        _state[xcode]=running
        engine::_deps_met homebrew && echo YES || echo NO
    '
    assert_output "NO"
}

@test "deps_met: false when a dep is pending" {
    zsh_run '
        engine::load_config "$PRIMER_DIR/primer.conf"
        _state[xcode]=pending
        engine::_deps_met homebrew && echo YES || echo NO
    '
    assert_output "NO"
}

@test "deps_met: false when a dep is failed" {
    zsh_run '
        engine::load_config "$PRIMER_DIR/primer.conf"
        _state[xcode]=failed
        engine::_deps_met homebrew && echo YES || echo NO
    '
    assert_output "NO"
}

@test "deps_met: true when module has no deps" {
    zsh_run '
        engine::load_config "$PRIMER_DIR/primer.conf"
        engine::_deps_met touchid && echo YES || echo NO
    '
    assert_output "YES"
}

@test "deps_met: true when module has no deps (xcode)" {
    zsh_run '
        engine::load_config "$PRIMER_DIR/primer.conf"
        engine::_deps_met xcode && echo YES || echo NO
    '
    assert_output "YES"
}

# ── engine::_deps_failed ─────────────────────────────────────────────────────

@test "deps_failed: true when a dep is failed" {
    zsh_run '
        engine::load_config "$PRIMER_DIR/primer.conf"
        _state[xcode]=failed
        engine::_deps_failed homebrew && echo YES || echo NO
    '
    assert_output "YES"
}

@test "deps_failed: true when a dep is skipped" {
    zsh_run '
        engine::load_config "$PRIMER_DIR/primer.conf"
        _state[xcode]=skipped
        engine::_deps_failed homebrew && echo YES || echo NO
    '
    assert_output "YES"
}

@test "deps_failed: false when deps are all done" {
    zsh_run '
        engine::load_config "$PRIMER_DIR/primer.conf"
        _state[xcode]=done
        engine::_deps_failed homebrew && echo YES || echo NO
    '
    assert_output "NO"
}

@test "deps_failed: false when deps are running" {
    zsh_run '
        engine::load_config "$PRIMER_DIR/primer.conf"
        _state[xcode]=running
        engine::_deps_failed homebrew && echo YES || echo NO
    '
    assert_output "NO"
}

@test "deps_failed: false when module has no deps" {
    zsh_run '
        engine::load_config "$PRIMER_DIR/primer.conf"
        engine::_deps_failed touchid && echo YES || echo NO
    '
    assert_output "NO"
}

# ── engine::_has_active ──────────────────────────────────────────────────────

@test "has_active: true when a module is pending" {
    zsh_run '
        engine::load_config "$PRIMER_DIR/primer.conf"
        local m; for m in $_mod_order; do _state[$m]=done; done
        _state[touchid]=pending
        engine::_has_active && echo YES || echo NO
    '
    assert_output "YES"
}

@test "has_active: true when a module is running" {
    zsh_run '
        engine::load_config "$PRIMER_DIR/primer.conf"
        local m; for m in $_mod_order; do _state[$m]=done; done
        _state[mise]=running
        engine::_has_active && echo YES || echo NO
    '
    assert_output "YES"
}

@test "has_active: false when all modules are done" {
    zsh_run '
        engine::load_config "$PRIMER_DIR/primer.conf"
        local m; for m in $_mod_order; do _state[$m]=done; done
        engine::_has_active && echo YES || echo NO
    '
    assert_output "NO"
}

@test "has_active: false when all modules are done/failed/skipped" {
    zsh_run '
        engine::load_config "$PRIMER_DIR/primer.conf"
        local m; for m in $_mod_order; do _state[$m]=done; done
        _state[touchid]=failed
        _state[scripts]=skipped
        engine::_has_active && echo YES || echo NO
    '
    assert_output "NO"
}

# ── Transitive dependency scenarios ──────────────────────────────────────────

@test "deps_met: zsh requires homebrew done (transitive through xcode)" {
    zsh_run '
        engine::load_config "$PRIMER_DIR/primer.conf"
        _state[homebrew]=done
        engine::_deps_met zsh && echo YES || echo NO
    '
    assert_output "YES"
}

@test "deps_met: zsh blocked when homebrew is not done" {
    zsh_run '
        engine::load_config "$PRIMER_DIR/primer.conf"
        _state[homebrew]=running
        engine::_deps_met zsh && echo YES || echo NO
    '
    assert_output "NO"
}

# ── engine::_apply_filters ────────────────────────────────────────────────────

@test "apply_filters: PRIMER_SKIP marks named module as skipped" {
    zsh_run '
        PRIMER_SKIP="mac-app-store"
        engine::load_config "$PRIMER_DIR/primer.conf"
        local m; for m in $_mod_order; do _state[$m]=pending; done
        engine::_apply_filters
        echo "${_state[mac-app-store]}"
    '
    assert_output "skipped"
}

@test "apply_filters: PRIMER_SKIP leaves other modules pending" {
    zsh_run '
        PRIMER_SKIP="mac-app-store"
        engine::load_config "$PRIMER_DIR/primer.conf"
        local m; for m in $_mod_order; do _state[$m]=pending; done
        engine::_apply_filters
        echo "${_state[homebrew]}"
    '
    assert_output "pending"
}

@test "apply_filters: PRIMER_SKIP accepts multiple space-separated modules" {
    zsh_run '
        PRIMER_SKIP="mac-app-store homebrew-apps"
        engine::load_config "$PRIMER_DIR/primer.conf"
        local m; for m in $_mod_order; do _state[$m]=pending; done
        engine::_apply_filters
        echo "${_state[mac-app-store]} ${_state[homebrew-apps]}"
    '
    assert_output "skipped skipped"
}

@test "apply_filters: PRIMER_ONLY marks all other modules as skipped" {
    zsh_run '
        PRIMER_ONLY="homebrew"
        engine::load_config "$PRIMER_DIR/primer.conf"
        local m; for m in $_mod_order; do _state[$m]=pending; done
        engine::_apply_filters
        echo "${_state[homebrew]} ${_state[mac-app-store]}"
    '
    assert_output "pending skipped"
}

@test "apply_filters: PRIMER_ONLY keeps listed modules pending" {
    zsh_run '
        PRIMER_ONLY="homebrew homebrew-apps"
        engine::load_config "$PRIMER_DIR/primer.conf"
        local m; for m in $_mod_order; do _state[$m]=pending; done
        engine::_apply_filters
        echo "${_state[homebrew]} ${_state[homebrew-apps]} ${_state[mac-app-store]}"
    '
    assert_output "pending pending skipped"
}

@test "apply_filters: empty PRIMER_SKIP and PRIMER_ONLY leaves all pending" {
    zsh_run '
        PRIMER_SKIP=""
        PRIMER_ONLY=""
        engine::load_config "$PRIMER_DIR/primer.conf"
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
