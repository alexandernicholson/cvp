#!/usr/bin/env bats
# Tests for list / show / remove / env output.

load "../helpers/common"

@test "ls lists profiles and marks the active one" {
  write_profile work
  write_profile prod
  set_global_profile work
  run bash "$CVP_SCRIPT" ls
  assert_success
  assert_contains "work"
  assert_contains "prod"
  assert_contains "active"
}

@test "ls with no profiles says so" {
  run bash "$CVP_SCRIPT" ls
  assert_success
  assert_contains "No profiles"
}

@test "show displays the active profile with masked secrets" {
  write_profile work \
    "ANTHROPIC_BASE_URL=https://gw.example.com" \
    "CLAUDE_CODE_OAUTH_TOKEN=sk-secret-123"
  set_global_profile work
  run bash "$CVP_SCRIPT" show
  assert_success
  assert_contains "https://gw.example.com"
  assert_contains "CLAUDE_CODE_OAUTH_TOKEN=***"
  assert_not_contains "sk-secret-123"
}

@test "show of a named non-secret var prints the value" {
  write_profile work "ANTHROPIC_BASE_URL=https://gw.example.com" "CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1"
  run bash "$CVP_SCRIPT" show work
  assert_success
  assert_contains "ANTHROPIC_BASE_URL=https://gw.example.com"
  assert_contains "CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1"
}

@test "show of a non-existent profile fails" {
  run bash "$CVP_SCRIPT" show nope
  assert_failure
  assert_contains "does not exist"
}

@test "show with no active profile and no name fails" {
  run bash "$CVP_SCRIPT" show
  assert_failure
  assert_contains "No profile active"
}

@test "remove deletes a profile" {
  write_profile work
  run bash "$CVP_SCRIPT" remove work
  assert_success
  [ ! -f "$CVM_DIR/profiles/work.env" ]
}

@test "remove clears the global alias if it was active" {
  write_profile work
  set_global_profile work
  run bash "$CVP_SCRIPT" remove work
  assert_success
  [ ! -f "$CVM_DIR/active-profile" ]
  assert_contains "alias cleared"
}

@test "remove leaves the alias if a different profile was active" {
  write_profile work
  write_profile prod
  set_global_profile prod
  run bash "$CVP_SCRIPT" remove work
  assert_success
  [ "$(cat "$CVM_DIR/active-profile")" = "prod" ]
}

@test "env prints real export lines (no masking)" {
  write_profile work \
    "ANTHROPIC_BASE_URL=https://gw.example.com" \
    "CLAUDE_CODE_OAUTH_TOKEN=sk-real-123"
  set_global_profile work
  run bash "$CVP_SCRIPT" env
  assert_success
  assert_contains "export ANTHROPIC_BASE_URL='https://gw.example.com'"
  assert_contains "export CLAUDE_CODE_OAUTH_TOKEN='sk-real-123'"
}

@test "env with no active profile prints nothing and succeeds" {
  run bash "$CVP_SCRIPT" env
  assert_success
  [ -z "$output" ]
}

@test "env safely quotes single quotes in values" {
  write_profile work "ANTHROPIC_BASE_URL=https://gw.example.com/?q=it's"
  set_global_profile work
  run bash "$CVP_SCRIPT" env
  assert_success
  # The value should be safely single-quote-escaped for eval.
  # shellcheck disable=SC2185
  eval "$output" >/dev/null 2>&1
  [ "${ANTHROPIC_BASE_URL}" = "https://gw.example.com/?q=it's" ]
}
