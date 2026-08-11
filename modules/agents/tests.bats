#!/usr/bin/env bats
# modules/agents/tests.bats

load '../../tests/helpers/common'

setup() {
    export TEST_HOME="$(mktemp -d)"
    export HOME="$TEST_HOME"
    export AGENTS_HOME="$TEST_HOME/.agents"
    export AGENTS_ARCHIVE="$TEST_HOME/.agents-archive"
    mkdir -p "$TEST_HOME/bin"
    export PATH="$TEST_HOME/bin:$PATH"

    # Stub agents CLI
    cat >"$TEST_HOME/bin/agents" <<'EOF'
#!/bin/sh
echo "agents stub: $*"
exit 0
EOF
    chmod +x "$TEST_HOME/bin/agents"
}

teardown() {
    rm -rf "$TEST_HOME"
}

@test "agents: dry-run succeeds with CLI present" {
    export DRY_RUN=true
    # seed a fake git home so clone path is not taken in dry-run status paths
    zsh_run_module agents "mod_update"
    assert_success
    assert_output --partial "agents init --no-apply"
    assert_output --partial "agents archive init"
}

@test "agents: mod_status fails without git home" {
    zsh_run_module agents "mod_status"
    assert_failure
}

@test "agents: mod_status succeeds with git home + scoped content" {
    mkdir -p "$AGENTS_HOME/shared/skills/foo"
    git -C "$AGENTS_HOME" init -b main >/dev/null 2>&1
    git -C "$AGENTS_HOME" remote add origin git@github.com:tomagranate/agents-home.git
    echo "# test" >"$AGENTS_HOME/shared/AGENTS.md"
    git -C "$AGENTS_HOME" add shared/AGENTS.md
    git -C "$AGENTS_HOME" -c user.email=t@t -c user.name=t commit -m init >/dev/null 2>&1
    git -C "$AGENTS_ARCHIVE" init -b main >/dev/null 2>&1
    git -C "$AGENTS_ARCHIVE" remote add origin git@github.com:tomagranate/chat-archive.git
    zsh_run_module agents "mod_status"
    assert_success
}
