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

@test "login picker: renders alternate-screen selection view" {
    zsh_run '
        export COLUMNS=80
        export LINES=18
        _login_order=(github npm)
        _login_selected[github]=true
        _login_selected[npm]=false
        _mod_config[logins.github_label]="GitHub CLI"
        _mod_config[logins.npm_label]="npm"
        _login_notice_lines=("  notice line")
        engine::_render_login_selection_tui 1
    '
    assert_success
    assert_output --partial "login setup"
    assert_output --partial "GitHub CLI"
    assert_output --partial "npm"
    assert_output --partial "Ctrl-C skips"
}

@test "login runner: renders alternate-screen command panel" {
    zsh_run '
        export COLUMNS=80
        export LINES=18
        engine::_render_login_command_tui "GitHub CLI" "Authenticate with GitHub."
    '
    assert_success
    assert_output --partial "login: GitHub CLI"
    assert_output --partial "Authenticate with GitHub."
    assert_output --partial "Complete the prompt above."
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

@test "login selection: shell status can require gh auth and ssh protocol" {
    local fakebin
    fakebin="$(mktemp -d)"
    cat > "$fakebin/gh" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  "auth status --hostname github.com") exit 0 ;;
  "config get git_protocol --host github.com") echo ssh; exit 0 ;;
esac
exit 1
EOF
    chmod +x "$fakebin/gh"

    PATH="$fakebin:$PATH" zsh_run '
        DRY_RUN=false
        _login_order=(github)
        _mod_config[logins.github_label]="GitHub CLI"
        _mod_config[logins.github_requires]=gh
        _mod_config[logins.github_status]="gh auth status --hostname github.com && test \"$(gh config get git_protocol --host github.com 2>/dev/null)\" = ssh"
        engine::_select_interactive_logins
        echo "remaining=${#_login_order[@]}"
    '
    rm -rf "$fakebin"

    assert_success
    assert_output --partial "GitHub CLI already logged in"
    assert_output --partial "remaining=0"
}

@test "login selection: shell status can require registered GitHub SSH key" {
    local fakebin test_home
    fakebin="$(mktemp -d)"
    test_home="$(mktemp -d)"
    mkdir -p "$test_home/.ssh"
    cat > "$test_home/.ssh/id_ed25519.pub" <<'EOF'
ssh-ed25519 AAAATESTKEY primer-test
EOF
    cat > "$fakebin/gh" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  "auth status --hostname github.com") exit 0 ;;
  "config get git_protocol --host github.com") echo ssh; exit 0 ;;
  "ssh-key list") echo "primer-test AAAATESTKEY"; exit 0 ;;
esac
exit 1
EOF
    chmod +x "$fakebin/gh"

    PATH="$fakebin:$PATH" HOME="$test_home" zsh_run '
        DRY_RUN=false
        _login_order=(github)
        _mod_config[logins.github_label]="GitHub CLI"
        _mod_config[logins.github_requires]=gh
        _mod_config[logins.github_status]="gh auth status --hostname github.com && test \"$(gh config get git_protocol --host github.com 2>/dev/null)\" = ssh && key_body=\"$(awk '\''NF >= 2 { print $2; exit }'\'' \"$HOME/.ssh/id_ed25519.pub\")\" && gh ssh-key list | grep -F \"$key_body\""
        engine::_select_interactive_logins
        echo "remaining=${#_login_order[@]}"
    '
    rm -rf "$fakebin" "$test_home"

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
        _mod_config[logins.github_depends_on]="ssh, git, homebrew"
        engine::_select_interactive_logins
        echo "remaining=${#_login_order[@]}"
    '
    assert_success
    assert_output --partial "GitHub CLI unavailable (waiting on: git, homebrew)"
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
        _mod_config[logins.github_command]="gh auth login --hostname github.com --git-protocol ssh"
        engine::_run_interactive_logins
    '
    rm -rf "$fakebin"

    assert_success
    assert_output --partial "GitHub CLI already logged in"
}

@test "login runner: shell command can refresh scope and add GitHub SSH key" {
    local fakebin test_home mock_log
    fakebin="$(mktemp -d)"
    test_home="$(mktemp -d)"
    mock_log="$(mktemp)"
    mkdir -p "$test_home/.ssh"
    cat > "$test_home/.ssh/id_ed25519.pub" <<'EOF'
ssh-ed25519 AAAATESTKEY primer-test
EOF
    cat > "$fakebin/gh" <<'EOF'
#!/usr/bin/env bash
echo "gh $*" >> "${MOCK_LOG:-/dev/null}"
case "$*" in
  "auth status --hostname github.com") exit 0 ;;
  "auth refresh --hostname github.com --scopes admin:public_key") exit 0 ;;
  "config set git_protocol ssh --host github.com") exit 0 ;;
  "ssh-key list") exit 1 ;;
  "ssh-key add "*"--title "*) exit 0 ;;
esac
exit 1
EOF
    chmod +x "$fakebin/gh"

    PATH="$fakebin:$PATH" HOME="$test_home" MOCK_LOG="$mock_log" zsh_run '
        DRY_RUN=false
        PRIMER_TMPDIR="$(mktemp -d)"
        _login_order=(github)
        _login_selected[github]=true
        _state[ssh]=done
        _state[git]=done
        _mod_config[logins.github_label]="GitHub CLI"
        _mod_config[logins.github_depends_on]="ssh git"
        _mod_config[logins.github_requires]=gh
        _mod_config[logins.github_command]="(gh auth status --hostname github.com >/dev/null 2>&1 && gh auth refresh --hostname github.com --scopes admin:public_key || gh auth login --hostname github.com --git-protocol ssh --scopes admin:public_key) && gh config set git_protocol ssh --host github.com && key_body=\"$(awk '\''NF >= 2 { print $2; exit }'\'' \"$HOME/.ssh/id_ed25519.pub\")\" && if gh ssh-key list | grep -F \"$key_body\" >/dev/null; then echo \"SSH key already registered with GitHub.\"; else gh ssh-key add \"$HOME/.ssh/id_ed25519.pub\" --title \"$(hostname -s 2>/dev/null || hostname 2>/dev/null || echo primer)\"; fi"
        engine::_run_interactive_logins
        rc=$?
        rm -rf "$PRIMER_TMPDIR"
        exit $rc
    '
    assert_success
    run grep -q "gh auth refresh --hostname github.com --scopes admin:public_key" "$mock_log"
    assert_success
    run grep -q "gh config set git_protocol ssh --host github.com" "$mock_log"
    assert_success
    run grep -q "gh ssh-key add $test_home/.ssh/id_ed25519.pub --title" "$mock_log"
    assert_success
    rm -rf "$fakebin" "$test_home" "$mock_log"
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
        _login_order=(webaccount)
        _login_selected[webaccount]=true
        _state[homebrew-apps]=done
        _mod_config[logins.webaccount_label]="Web account"
        _mod_config[logins.webaccount_depends_on]=homebrew-apps
        _mod_config[logins.webaccount_instruction]="Sign in to the web account."
        _mod_config[logins.webaccount_command]=true
        engine::_run_interactive_logins
    '
    assert_failure
    assert_output --partial "Sign in to the web account."
    assert_output --partial "Web account failed"
}

@test "login errors: failed command output is printed after summary" {
    local fakebin
    fakebin="$(mktemp -d)"
    cat > "$fakebin/fail-login" <<'EOF'
#!/usr/bin/env bash
echo "login went sideways" >&2
exit 7
EOF
    chmod +x "$fakebin/fail-login"

    PATH="$fakebin:$PATH" zsh_run '
        DRY_RUN=false
        PRIMER_TMPDIR="$(mktemp -d)"
        _login_all_order=(github)
        _login_order=(github)
        _login_selected[github]=true
        _mod_config[logins.github_label]="GitHub CLI"
        _mod_config[logins.github_requires]=fail-login
        _mod_config[logins.github_command]=fail-login
        engine::_run_interactive_logins
        rc=$?
        engine::_render_login_summary
        engine::_render_login_error_output
        rm -rf "$PRIMER_TMPDIR"
        exit $rc
    '
    rm -rf "$fakebin"

    assert_failure
    assert_output --partial "GitHub CLI"
    assert_output --partial "login output"
    assert_output --partial "login went sideways"
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
        _login_all_order=(npm github)
        _mod_config[logins.npm_label]=npm
        _mod_config[logins.github_label]="GitHub CLI"
        _login_state[npm]=skipped
        _login_detail[npm]="not selected"
        _login_state[github]=failed
        _login_detail[github]=failed
        engine::_render_login_summary
    '
    assert_success
    assert_output --partial "npm"
    assert_output --partial "not selected"
    assert_output --partial "GitHub CLI"
    assert_output --partial "failed"
}
