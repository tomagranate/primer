#!/usr/bin/env bats
# tests/unit/logins.bats -- interactive login selection helpers

load '../helpers/common'

@test "login answers: blank uses yes default" {
    zsh_run '
        engine::_answer_to_bool "" true
    '
    assert_success
    assert_output "true"
}

@test "login answers: blank uses no default" {
    zsh_run '
        engine::_answer_to_bool "" false
    '
    assert_success
    assert_output "false"
}

@test "login answers: explicit yes and no are accepted" {
    zsh_run '
        echo "$(engine::_answer_to_bool yes false) $(engine::_answer_to_bool n true)"
    '
    assert_success
    assert_output "true false"
}

@test "login answers: invalid answer fails" {
    zsh_run '
        engine::_answer_to_bool maybe true
    '
    assert_failure
}

@test "login selection: non-tty update skips configured logins" {
    zsh_run '
        DRY_RUN=false
        _login_order=(github)
        _mod_config[logins.github_default]=yes
        engine::_select_interactive_logins
        echo "${_login_selected[github]}"
    '
    assert_success
    assert_output "false"
}

@test "login picker: renders instructions and selected circles" {
    zsh_run '
        _login_order=(github npm)
        _login_selected[github]=true
        _login_selected[npm]=false
        _mod_config[logins.github_label]="GitHub CLI"
        _mod_config[logins.npm_label]="npm"
        engine::_render_login_picker 2
    '
    assert_success
    assert_output --partial "Use ↑/↓ to move, Space to toggle, Enter to continue."
    assert_output --partial "●"
    assert_output --partial "○"
    assert_output --partial "GitHub CLI"
    assert_output --partial "npm"
}

@test "login picker: toggle flips selected state" {
    zsh_run '
        _login_selected[github]=true
        engine::_login_toggle github
        echo "${_login_selected[github]}"
        engine::_login_toggle github
        echo "${_login_selected[github]}"
    '
    assert_success
    assert_line --index 0 "false"
    assert_line --index 1 "true"
}

@test "login runner: skips command when status says already logged in" {
    local fakebin
    fakebin="$(mktemp -d)"
    cat > "$fakebin/gh" <<'EOF'
#!/usr/bin/env bash
[[ "$1 $2" == "auth status" ]]
EOF
    chmod +x "$fakebin/gh"

    PATH="$fakebin:$PATH" zsh_run '
        DRY_RUN=false
        _login_order=(github)
        _login_selected[github]=true
        _mod_config[logins.github_label]="GitHub CLI"
        _mod_config[logins.github_requires]=gh
        _mod_config[logins.github_status]="gh auth status"
        _mod_config[logins.github_command]="gh auth login"
        engine::_run_interactive_logins
    '
    rm -rf "$fakebin"

    assert_success
    assert_output --partial "GitHub CLI already logged in"
}
