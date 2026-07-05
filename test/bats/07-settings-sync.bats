#!/usr/bin/env bats
# Tests for the ~/.claude/settings.json env sync (the teammate path).

load "../helpers/common"

settings_env() {
  [[ -f "$CVP_CLAUDE_DIR/settings.json" ]] || { echo "{}"; return; }
  python3 -c 'import sys,json; d=json.load(open(sys.argv[1])); print(json.dumps(d.get("env",{})))' "$CVP_CLAUDE_DIR/settings.json"
}

@test "use writes the profile vars into settings.json env" {
  write_profile work "ANTHROPIC_BASE_URL=https://gw.example.com" "ANTHROPIC_AUTH_TOKEN=sk-1"
  run bash "$CVP_SCRIPT" use work
  assert_success
  env_json=$(settings_env)
  echo "$env_json" | grep -q 'ANTHROPIC_BASE_URL.*gw.example.com'
  echo "$env_json" | grep -q 'ANTHROPIC_AUTH_TOKEN.*sk-1'
}

@test "use preserves non-env keys in settings.json" {
  printf '{\n  "model": "claude-fable-5",\n  "env": {"OTEL_METRICS_EXPORTER": "otlp"},\n  "permissions": {"defaultMode": "bypassPermissions"}\n}\n' \
    > "$CVP_CLAUDE_DIR/settings.json"
  write_profile work "ANTHROPIC_BASE_URL=https://gw.example.com"
  run bash "$CVP_SCRIPT" use work
  assert_success
  grep -q '"model": "claude-fable-5"' "$CVP_CLAUDE_DIR/settings.json"
  grep -q 'bypassPermissions' "$CVP_CLAUDE_DIR/settings.json"
  # User-added env var not in the profile is preserved.
  settings_env | grep -q 'OTEL_METRICS_EXPORTER'
}

@test "switching profiles replaces managed vars without losing user env vars" {
  printf '{\n  "env": {"MY_USER_VAR": "keep"}\n}\n' > "$CVP_CLAUDE_DIR/settings.json"
  write_profile a "ANTHROPIC_BASE_URL=https://a.example.com" "ANTHROPIC_AUTH_TOKEN=sk-a"
  write_profile b "ANTHROPIC_BASE_URL=https://b.example.com"
  bash "$CVP_SCRIPT" use a >/dev/null
  settings_env | grep -q 'a.example.com'
  settings_env | grep -q 'MY_USER_VAR'
  bash "$CVP_SCRIPT" use b >/dev/null
  # a's AUTH_TOKEN is gone (was managed), b's BASE_URL is in, user var kept.
  settings_env | grep -q 'b.example.com'
  settings_env | grep -q 'MY_USER_VAR'
  ! settings_env | grep -q 'sk-a'
}

@test "use creates a one-time backup of settings.json" {
  printf '{\n  "env": {"FOO": "1"}\n}\n' > "$CVP_CLAUDE_DIR/settings.json"
  write_profile work "ANTHROPIC_BASE_URL=https://gw.example.com"
  bash "$CVP_SCRIPT" use work >/dev/null
  [ -f "$CVP_CLAUDE_DIR/settings.json.cvp-backup" ]
  grep -q '"FOO"' "$CVP_CLAUDE_DIR/settings.json.cvp-backup"
  # Second use does NOT overwrite the backup.
  local first; first=$(cat "$CVP_CLAUDE_DIR/settings.json.cvp-backup")
  bash "$CVP_SCRIPT" use work >/dev/null
  [ "$(cat "$CVP_CLAUDE_DIR/settings.json.cvp-backup")" = "$first" ]
}

@test "remove of the active profile clears managed vars from settings.json" {
  write_profile work "ANTHROPIC_BASE_URL=https://gw.example.com"
  bash "$CVP_SCRIPT" use work >/dev/null
  settings_env | grep -q 'gw.example.com'
  bash "$CVP_SCRIPT" remove work >/dev/null
  ! settings_env | grep -q 'gw.example.com'
  [ ! -f "$CVM_DIR/profiles/.settings-managed" ]
}

@test "remove leaves user env vars intact" {
  printf '{\n  "env": {"MY_USER_VAR": "keep"}\n}\n' > "$CVP_CLAUDE_DIR/settings.json"
  write_profile work "ANTHROPIC_BASE_URL=https://gw.example.com"
  bash "$CVP_SCRIPT" use work >/dev/null
  bash "$CVP_SCRIPT" remove work >/dev/null
  settings_env | grep -q 'MY_USER_VAR'
  ! settings_env | grep -q 'gw.example.com'
}

@test "CVP_NO_SETTINGS_SYNC=1 disables settings sync" {
  write_profile work "ANTHROPIC_BASE_URL=https://gw.example.com"
  CVP_NO_SETTINGS_SYNC=1 run bash "$CVP_SCRIPT" use work
  assert_success
  [[ ! -f "$CVP_CLAUDE_DIR/settings.json" ]] || ! settings_env | grep -q 'gw.example.com'
}

@test "sync command re-syncs the active profile" {
  write_profile work "ANTHROPIC_BASE_URL=https://gw.example.com"
  bash "$CVP_SCRIPT" use work >/dev/null
  rm -f "$CVP_CLAUDE_DIR/settings.json"
  run bash "$CVP_SCRIPT" sync
  assert_success
  settings_env | grep -q 'gw.example.com'
}

@test "apply syncs settings too" {
  write_profile work "ANTHROPIC_BASE_URL=https://gw.example.com"
  set_global_profile work
  run bash "$CVP_SCRIPT" apply
  assert_success
  settings_env | grep -q 'gw.example.com'
}

@test "init syncs settings for the active profile" {
  write_profile work "ANTHROPIC_BASE_URL=https://gw.example.com"
  set_global_profile work
  run bash "$CVP_SCRIPT" init
  assert_success
  settings_env | grep -q 'gw.example.com'
}

@test "init with no active profile seeds default (no gateway) into settings" {
  run bash "$CVP_SCRIPT" init
  assert_success
  settings_env | grep -q 'CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS'
  ! settings_env | grep -q 'ANTHROPIC_BASE_URL'
}
