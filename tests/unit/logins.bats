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

@test "login selection: non-tty after install skips configured logins" {
    zsh_run '
        DRY_RUN=false
        _login_order=(github)
        _mod_config[logins.github_default]=yes
        engine::_select_interactive_logins
        echo "${_login_selected[github]}"
    '
    assert_success
    assert_output --partial "false"
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
    assert_output --partial "Use Up/Down to move. Space toggles a login. Enter starts selected logins."
    assert_output --partial "●"
    assert_output --partial "○"
    assert_output --partial "GitHub CLI"
    assert_output --partial "npm"
}

@test "login selection: filters already logged-in targets" {
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
        _mod_config[logins.github_label]="GitHub CLI"
        _mod_config[logins.github_requires]=gh
        _mod_config[logins.github_status]="gh auth status"
        engine::_select_interactive_logins
        echo "remaining=${#_login_order[@]}"
    '
    rm -rf "$fakebin"

    assert_success
    assert_output --partial "GitHub CLI already logged in"
    assert_output --partial "remaining=0"
}

@test "login summary: includes already logged in targets" {
    zsh_run '
        DRY_RUN=false
        _login_all_order=(github)
        _mod_config[logins.github_label]="GitHub CLI"
        _login_state[github]=done
        _login_detail[github]="logged in"
        engine::_render_login_summary
    '
    assert_success
    assert_output --partial "login summary"
    assert_output --partial "GitHub CLI"
    assert_output --partial "logged in"
}

@test "login selection: filters targets whose module dependencies did not finish" {
    zsh_run '
        DRY_RUN=false
        _login_order=(github)
        _state[ssh]=done
        _state[homebrew]=failed
        _mod_config[logins.github_label]="GitHub CLI"
        _mod_config[logins.github_depends_on]="ssh, homebrew"
        engine::_select_interactive_logins
        echo "remaining=${#_login_order[@]}"
    '
    assert_success
    assert_output --partial "GitHub CLI unavailable (waiting on: homebrew)"
    assert_output --partial "remaining=0"
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

@test "login runner: reports missing requirements" {
    zsh_run '
        DRY_RUN=false
        _login_order=(github)
        _login_selected[github]=true
        _mod_config[logins.github_label]="GitHub CLI"
        _mod_config[logins.github_requires]=definitely-missing-gh
        _mod_config[logins.github_command]="gh auth login"
        engine::_run_interactive_logins
    '
    assert_failure
    assert_output --partial "GitHub CLI skipped (missing: definitely-missing-gh)"
}

@test "login runner: reports incomplete module dependencies" {
    zsh_run '
        DRY_RUN=false
        _login_order=(github)
        _login_selected[github]=true
        _state[ssh]=done
        _state[homebrew]=skipped
        _mod_config[logins.github_label]="GitHub CLI"
        _mod_config[logins.github_depends_on]="ssh homebrew"
        _mod_config[logins.github_command]="gh auth login"
        engine::_run_interactive_logins
    '
    assert_failure
    assert_output --partial "GitHub CLI skipped (waiting on: homebrew)"
}

@test "login runner: prints instructions before guided browser login" {
    zsh_run '
        DRY_RUN=false
        _login_order=(dashlane)
        _login_selected[dashlane]=true
        _state[homebrew-apps]=done
        _mod_config[logins.dashlane_label]=Dashlane
        _mod_config[logins.dashlane_depends_on]=homebrew-apps
        _mod_config[logins.dashlane_instruction]="Sign in to Dashlane."
        _mod_config[logins.dashlane_command]=true
        engine::_run_interactive_logins
    '
    assert_failure
    assert_output --partial "Sign in to Dashlane."
    assert_output --partial "Dashlane failed"
}

@test "login result: ctrl-c skips login and continues" {
    zsh_run '
        DRY_RUN=false
        _mod_config[logins.github_label]="GitHub CLI"
        engine::_record_login_result github "GitHub CLI" 130
        echo "state=${_login_state[github]}"
        echo "detail=${_login_detail[github]}"
        echo "interrupted=${_login_interrupted}"
    '
    assert_success
    assert_output --partial "GitHub CLI skipped"
    assert_output --partial "state=skipped"
    assert_output --partial "detail=interrupted"
    assert_output --partial "interrupted=true"
}

@test "login summary: includes skipped and failed targets" {
    zsh_run '
        DRY_RUN=false
        _login_all_order=(dashlane github)
        _mod_config[logins.dashlane_label]=Dashlane
        _mod_config[logins.github_label]="GitHub CLI"
        _login_state[dashlane]=skipped
        _login_detail[dashlane]="not selected"
        _login_state[github]=failed
        _login_detail[github]=failed
        engine::_render_login_summary
    '
    assert_success
    assert_output --partial "Dashlane"
    assert_output --partial "not selected"
    assert_output --partial "GitHub CLI"
    assert_output --partial "failed"
}
