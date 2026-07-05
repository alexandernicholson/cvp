#!/usr/bin/env bats
# Tests for `use` (global alias) and the decoupling guarantee.

load "../helpers/common"

@test "use sets the global alias file" {
  write_profile work "ANTHROPIC_BASE_URL=https://gw.example.com"
  run bash "$CVP_SCRIPT" use work
  assert_success
  [ "$(cat "$CVM_DIR/active-profile")" = "work" ]
}

@test "use installs the env.d resolver" {
  write_profile work
  run bash "$CVP_SCRIPT" use work
  assert_success
  [ -f "$CVM_DIR/env.d/cvp.sh" ]
}

@test "use on a non-existent profile fails" {
  run bash "$CVP_SCRIPT" use nope
  assert_failure
  assert_contains "does not exist"
}

@test "use rejects invalid profile names" {
  run bash "$CVP_SCRIPT" use "../escape"
  assert_failure
  assert_contains "Invalid profile name"
}

@test "switching profiles only rewrites the alias (settings untouched)" {
  write_profile work "ANTHROPIC_BASE_URL=https://a.example.com" "ANTHROPIC_AUTH_TOKEN=sk-a"
  write_profile prod "ANTHROPIC_BASE_URL=https://b.example.com" "ANTHROPIC_AUTH_TOKEN=sk-b"

  bash "$CVP_SCRIPT" use work >/dev/null
  local before; before=$(cat "$CVM_DIR/profiles/work.env")
  bash "$CVP_SCRIPT" use prod >/dev/null
  local after; after=$(cat "$CVM_DIR/profiles/work.env")

  # work's definition file must be byte-identical after switching away.
  [ "$before" = "$after" ]
  [ "$(cat "$CVM_DIR/active-profile")" = "prod" ]
}

@test "switching back restores the alias without data loss" {
  write_profile work "ANTHROPIC_AUTH_TOKEN=sk-a"
  bash "$CVP_SCRIPT" use work >/dev/null
  bash "$CVP_SCRIPT" use prod >/dev/null || true
  # prod doesn't exist, so create it and switch
  write_profile prod "ANTHROPIC_AUTH_TOKEN=sk-b"
  bash "$CVP_SCRIPT" use prod >/dev/null
  bash "$CVP_SCRIPT" use work >/dev/null
  [ "$(cat "$CVM_DIR/active-profile")" = "work" ]
  grep -q "sk-a" "$CVM_DIR/profiles/work.env"
}
