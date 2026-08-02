#!/usr/bin/env bats
# modules/agents/tests.bats

load '../../tests/helpers/common'

setup() {
    export TEST_HOME="$(mktemp -d)"
    export HOME="$TEST_HOME"
    export AGENTS_HOME="$TEST_HOME/.agents"
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
}

@test "agents: mod_status fails without git home" {
    zsh_run_module agents "mod_status"
    assert_failure
}

@test "agents: mod_status succeeds with git home + AGENTS.md" {
    mkdir -p "$AGENTS_HOME/skills/foo"
    git -C "$AGENTS_HOME" init -b main >/dev/null 2>&1
    git -C "$AGENTS_HOME" remote add origin git@github.com:tomagranate/agents-home.git
    echo "# test" >"$AGENTS_HOME/AGENTS.md"
    git -C "$AGENTS_HOME" add AGENTS.md
    git -C "$AGENTS_HOME" -c user.email=t@t -c user.name=t commit -m init >/dev/null 2>&1
    zsh_run_module agents "mod_status"
    assert_success
}
