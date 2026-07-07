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
        [[ ${_mod_order[(Ie)logins]} -eq 0 ]] || { echo "logins should not be a module"; exit 1; }
        [[ ${_mod_order[(Ie)xcode-cli-tools]} -gt 0 ]] || { echo "missing:xcode-cli-tools"; exit 1; }
        [[ ${_mod_order[(Ie)xcode]} -gt 0 ]] || { echo "missing:xcode"; exit 1; }
        [[ ${_mod_order[(Ie)homebrew]} -gt 0 ]] || { echo "missing:homebrew"; exit 1; }
        [[ ${_mod_order[(Ie)homebrew-apps]} -gt 0 ]] || { echo "missing:homebrew-apps"; exit 1; }
        [[ ${_mod_order[(Ie)macos]} -gt 0 ]] || { echo "missing:macos"; exit 1; }
        [[ ${_mod_order[(Ie)ssh]} -gt 0 ]] || { echo "missing:ssh"; exit 1; }
        [[ ${_mod_order[(Ie)mise]} -gt 0 ]] || { echo "missing:mise"; exit 1; }
        [[ -n "${_mod_config[homebrew.formulae]}" ]] || { echo "missing:homebrew.formulae"; exit 1; }
        [[ -n "${_mod_config[homebrew-apps.casks]}" ]] || { echo "missing:homebrew-apps.casks"; exit 1; }
        [[ -n "${_mod_config[macos.defaults]}" ]] || { echo "missing:macos.defaults"; exit 1; }
        [[ -n "${_mod_config[macos.dock_apps]}" ]] || { echo "missing:macos.dock_apps"; exit 1; }
        [[ -n "${_mod_config[ssh.key_path]}" ]] || { echo "missing:ssh.key_path"; exit 1; }
        [[ -n "${_mod_config[mise.tools]}" ]] || { echo "missing:mise.tools"; exit 1; }
        [[ "${_mod_deps[homebrew]}" == "xcode-cli-tools" ]] || { echo "wrong homebrew dep"; exit 1; }
        [[ "${_mod_deps[ssh]}" == "xcode-cli-tools" ]] || { echo "wrong ssh dep"; exit 1; }
        [[ "${_mod_deps[shell-installers]}" == "xcode-cli-tools" ]] || { echo "wrong shell installers dep"; exit 1; }
        [[ "${_mod_deps[mac-app-store]}" == "homebrew" ]] || { echo "wrong mac app store dep"; exit 1; }
        [[ "${_mod_deps[xcode]}" == "mac-app-store" ]] || { echo "wrong xcode dep"; exit 1; }
        [[ "${_mod_config[mac-app-store.mas]}" == *"Xcode:497799835"* ]] || { echo "missing xcode app store item"; exit 1; }
        [[ "${_login_order[*]}" == "github" ]] || { echo "missing configured logins"; exit 1; }
        [[ -z "${_mod_config[logins.xcode-cli-terms_command]:-}" ]] || { echo "xcode terms should be handled by xcode module"; exit 1; }
        [[ "${_mod_config[logins.github_default]}" == "yes" ]] || { echo "missing login default"; exit 1; }
        [[ "${_mod_config[logins.github_depends_on]}" == "ssh, git, homebrew" ]] || { echo "missing login module deps"; exit 1; }
        [[ "${_mod_config[logins.github_requires]}" == "gh" ]] || { echo "missing login requirements"; exit 1; }
        [[ "${_mod_config[logins.github_status]}" == *"gh auth status --hostname github.com"* ]] || { echo "missing login status"; exit 1; }
        [[ "${_mod_config[logins.github_status]}" == *"git_protocol"* ]] || { echo "missing ssh protocol status"; exit 1; }
        [[ "${_mod_config[logins.github_status]}" == *"gh ssh-key list"* ]] || { echo "missing ssh key status"; exit 1; }
        [[ "${_mod_config[logins.github_command]}" == *"gh auth refresh --hostname github.com --scopes admin:public_key"* ]] || { echo "missing login refresh"; exit 1; }
        [[ "${_mod_config[logins.github_command]}" == *"gh auth login --hostname github.com --git-protocol ssh --scopes admin:public_key"* ]] || { echo "missing login command"; exit 1; }
        [[ "${_mod_config[logins.github_command]}" == *"gh ssh-key add"* ]] || { echo "missing ssh key add"; exit 1; }
        [[ "${_mod_config[homebrew.taps]}" == *"buildkite/buildkite"* ]] || { echo "missing:buildkite/buildkite"; exit 1; }
        echo "ok"
    '
    assert_success
    assert_output "ok"
}

@test "load_config: parses logins without adding them to module order" {
    cat > "$TEST_CONF" <<'EOF'
[logins]
order =
    github
    npm
github_label = GitHub CLI
github_default = yes
github_command = gh auth login
custom-web_label = Custom web login
custom-web_command = open https://example.com/login
npm_label = npm
npm_default = no
npm_command = npm login

[homebrew]
label = Homebrew
EOF
    zsh_run "
        engine::load_config '$TEST_CONF'
        echo \"modules=\${_mod_order[*]}\"
        echo \"logins=\${_login_order[*]}\"
        echo \"github=\${_mod_config[logins.github_command]}\"
        echo \"custom=\${_mod_config[logins.custom-web_command]}\"
        echo \"npm=\${_mod_config[logins.npm_default]}\"
    "
    assert_success
    assert_line "modules=homebrew"
    assert_line "logins=github npm"
    assert_line "github=gh auth login"
    assert_line "custom=open https://example.com/login"
    assert_line "npm=no"
}

@test "load_config: section names with hyphens are parsed correctly" {
    cat > "$TEST_CONF" <<'EOF'
[homebrew-apps]
label = Mac Apps
casks =
    fake-app

[mac-app-store]
label = App Store
mas =
    FakeApp:123456789
EOF
    zsh_run "
        engine::load_config '$TEST_CONF'
        echo \"\${_mod_order[*]}\"
    "
    assert_output "homebrew-apps mac-app-store"
}

@test "load_config: hyphenated section config values are accessible" {
    cat > "$TEST_CONF" <<'EOF'
[homebrew-apps]
casks =
    google-chrome
    spotify
EOF
    zsh_run "
        engine::load_config '$TEST_CONF'
        echo \"\${_mod_config[homebrew-apps.casks]}\"
    "
    assert_output --partial "google-chrome"
    assert_output --partial "spotify"
}
