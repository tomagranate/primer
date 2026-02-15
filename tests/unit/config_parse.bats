#!/usr/bin/env bats
# tests/unit/config_parse.bats -- INI parser tests for engine::load_config

load '../helpers/common'

setup() {
    TEST_CONF="$(mktemp)"
}

teardown() {
    rm -f "$TEST_CONF"
}

# ── Section headers ──────────────────────────────────────────────────────────

@test "load_config: parses section headers into _mod_order" {
    cat > "$TEST_CONF" <<'EOF'
[xcode]
label = Xcode CLT

[homebrew]
label = Homebrew
EOF
    zsh_run "
        engine::load_config '$TEST_CONF'
        echo \"\${_mod_order[*]}\"
    "
    assert_output "xcode homebrew"
}

@test "load_config: preserves config order with many sections" {
    cat > "$TEST_CONF" <<'EOF'
[alpha]
[bravo]
[charlie]
[delta]
EOF
    zsh_run "
        engine::load_config '$TEST_CONF'
        echo \"\${_mod_order[*]}\"
    "
    assert_output "alpha bravo charlie delta"
}

# ── depends_on ───────────────────────────────────────────────────────────────

@test "load_config: parses depends_on into _mod_deps" {
    cat > "$TEST_CONF" <<'EOF'
[xcode]
[homebrew]
depends_on = xcode
[mise]
depends_on = homebrew
EOF
    zsh_run "
        engine::load_config '$TEST_CONF'
        echo \"\${_mod_deps[homebrew]}\"
    "
    assert_output "xcode"
}

@test "load_config: module with no depends_on has empty deps" {
    cat > "$TEST_CONF" <<'EOF'
[xcode]
label = Xcode CLT
EOF
    zsh_run "
        engine::load_config '$TEST_CONF'
        echo \"deps=\${_mod_deps[xcode]}\"
    "
    assert_output "deps="
}

# ── Labels ───────────────────────────────────────────────────────────────────

@test "load_config: parses label into _mod_desc" {
    cat > "$TEST_CONF" <<'EOF'
[xcode]
label = Xcode CLT
[homebrew]
label = Homebrew
EOF
    zsh_run "
        engine::load_config '$TEST_CONF'
        echo \"\${_mod_desc[xcode]}\"
    "
    assert_output "Xcode CLT"
}

# ── Multi-line values (indented continuation) ────────────────────────────────

@test "load_config: parses multi-line values with indented continuation" {
    cat > "$TEST_CONF" <<'EOF'
[homebrew]
formulae =
    fzf
    bat
    jq
EOF
    zsh_run "
        engine::load_config '$TEST_CONF'
        echo \"\${_mod_config[homebrew.formulae]}\"
    "
    assert_output --partial "fzf"
    assert_output --partial "bat"
    assert_output --partial "jq"
}

@test "load_config: casks multi-line values" {
    cat > "$TEST_CONF" <<'EOF'
[homebrew]
casks =
    google-chrome
    firefox
    visual-studio-code
EOF
    zsh_run "
        engine::load_config '$TEST_CONF'
        echo \"\${_mod_config[homebrew.casks]}\"
    "
    assert_output --partial "google-chrome"
    assert_output --partial "firefox"
    assert_output --partial "visual-studio-code"
}

@test "load_config: tools multi-line values for mise" {
    cat > "$TEST_CONF" <<'EOF'
[mise]
tools =
    node:lts
    python:3.12
    bun:latest
EOF
    zsh_run "
        engine::load_config '$TEST_CONF'
        echo \"\${_mod_config[mise.tools]}\"
    "
    assert_output --partial "node:lts"
    assert_output --partial "python:3.12"
    assert_output --partial "bun:latest"
}

# ── Comments and blank lines ─────────────────────────────────────────────────

@test "load_config: skips comment lines" {
    cat > "$TEST_CONF" <<'EOF'
# This is a comment
[xcode]
# Another comment
label = Xcode CLT
EOF
    zsh_run "
        engine::load_config '$TEST_CONF'
        echo \"\${#_mod_order}\"
    "
    assert_output "1"
}

@test "load_config: skips blank lines" {
    cat > "$TEST_CONF" <<'EOF'

[xcode]

label = Xcode CLT

[homebrew]

label = Homebrew

EOF
    zsh_run "
        engine::load_config '$TEST_CONF'
        echo \"\${#_mod_order}\"
    "
    assert_output "2"
}

@test "load_config: skips indented comment lines" {
    cat > "$TEST_CONF" <<'EOF'
[xcode]
  # indented comment
label = Xcode CLT
EOF
    zsh_run "
        engine::load_config '$TEST_CONF'
        echo \"\${_mod_desc[xcode]}\"
    "
    assert_output "Xcode CLT"
}

# ── Real config sanity check ─────────────────────────────────────────────────

@test "load_config: real primer.conf is parseable and has required keys" {
    zsh_run '
        engine::load_config "$PRIMER_DIR/primer.conf"
        [[ ${_mod_order[(Ie)homebrew]} -gt 0 ]] || { echo "missing:homebrew"; exit 1; }
        [[ ${_mod_order[(Ie)mise]} -gt 0 ]] || { echo "missing:mise"; exit 1; }
        [[ -n "${_mod_config[homebrew.formulae]}" ]] || { echo "missing:homebrew.formulae"; exit 1; }
        [[ -n "${_mod_config[homebrew.casks]}" ]] || { echo "missing:homebrew.casks"; exit 1; }
        [[ -n "${_mod_config[mise.tools]}" ]] || { echo "missing:mise.tools"; exit 1; }
        echo "ok"
    '
    assert_success
    assert_output "ok"
}
