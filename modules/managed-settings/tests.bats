#!/usr/bin/env bats
# modules/managed-settings/tests.bats

load '../../tests/helpers/common'

setup() {
    TEST_HOME="$(mktemp -d)"
    TEST_CONF="$(mktemp)"
    cat > "$TEST_CONF" <<'EOF'
[managed-settings]
label = Managed settings
json =
    ~/.claude/settings.json|permissions.defaultMode|"bypassPermissions"
    ~/.claude/settings.json|permissions.skipDangerousModePermissionPrompt|true
    ~/.claude/settings.json|permissions.disableBypassPermissionsMode|delete
    ~/.config/opencode/opencode.jsonc|$schema|"https://opencode.ai/config.json"
    ~/.config/opencode/opencode.jsonc|permission|"allow"
toml =
    ~/.codex/config.toml|approval_policy|"never"
    ~/.codex/config.toml|sandbox_mode|"danger-full-access"
    ~/.codex/config.toml|notice.hide_full_access_warning|true
EOF
}

teardown() {
    rm -rf "$TEST_HOME"
    rm -f "$TEST_CONF"
}

run_managed_settings_module() {
    local code="$1"
    run zsh -c "
        export PRIMER_DIR='${PRIMER_DIR}'
        export DRY_RUN='${DRY_RUN:-false}'
        export MOD_DIR='${PRIMER_DIR}/modules/managed-settings'
        export MOD_NAME='managed-settings'
        export MOD_STATUS_FILE='$(mktemp)'
        export HOME='${TEST_HOME}'
        source \"\$PRIMER_DIR/lib/module.zsh\"
        source \"\$PRIMER_DIR/tests/helpers/module-config.zsh\"
        test::load_module_config '${TEST_CONF}'
        source \"\$MOD_DIR/module.zsh\"
        $code
    "
}

@test "managed-settings: dry-run prints target config files" {
    export DRY_RUN=true
    run_managed_settings_module "mod_update"
    assert_success
    assert_output --partial "[dry-run] configure $TEST_HOME/.claude/settings.json"
    assert_output --partial "[dry-run] configure $TEST_HOME/.config/opencode/opencode.jsonc"
    assert_output --partial "[dry-run] configure $TEST_HOME/.codex/config.toml"
}

@test "managed-settings: update merges JSON and TOML settings" {
    mkdir -p "$TEST_HOME/.claude" "$TEST_HOME/.config/opencode" "$TEST_HOME/.codex"
    cat > "$TEST_HOME/.claude/settings.json" <<'EOF'
{
  "theme": "dark",
  "permissions": {
    "defaultMode": "manual",
    "disableBypassPermissionsMode": "disable"
  }
}
EOF
    cat > "$TEST_HOME/.config/opencode/opencode.jsonc" <<'EOF'
{
  "$schema": "https://opencode.ai/config.json",
  "username": "tom",
  "permission": "ask"
}
EOF
    cat > "$TEST_HOME/.codex/config.toml" <<'EOF'
approval_policy = "on-request"
model = "gpt-5.5"

[projects."/tmp/app"]
trust_level = "trusted"

[notice]
other = true
hide_full_access_warning = false
EOF

    run_managed_settings_module "mod_update"
    assert_success

    run jq -e '.theme == "dark" and .permissions.defaultMode == "bypassPermissions" and .permissions.skipDangerousModePermissionPrompt == true and (.permissions.disableBypassPermissionsMode | not)' "$TEST_HOME/.claude/settings.json"
    assert_success
    run jq -e '.username == "tom" and .permission == "allow"' "$TEST_HOME/.config/opencode/opencode.jsonc"
    assert_success

    run grep -q 'approval_policy = "never"' "$TEST_HOME/.codex/config.toml"
    assert_success
    run grep -q 'sandbox_mode = "danger-full-access"' "$TEST_HOME/.codex/config.toml"
    assert_success
    run grep -q 'trust_level = "trusted"' "$TEST_HOME/.codex/config.toml"
    assert_success
    run grep -c 'approval_policy =' "$TEST_HOME/.codex/config.toml"
    assert_output "1"
    run awk '/^\[notice\]/{in_notice=1; next} /^\[/{in_notice=0} in_notice && /hide_full_access_warning = true/{found=1} END{exit found ? 0 : 1}' "$TEST_HOME/.codex/config.toml"
    assert_success
}

@test "managed-settings: status succeeds after update and fails after drift" {
    run_managed_settings_module "mod_update"
    assert_success

    run_managed_settings_module "mod_status"
    assert_success

    jq '.permission = "ask"' "$TEST_HOME/.config/opencode/opencode.jsonc" > "$TEST_HOME/opencode.tmp"
    mv "$TEST_HOME/opencode.tmp" "$TEST_HOME/.config/opencode/opencode.jsonc"

    run_managed_settings_module "mod_status"
    assert_failure
}
