#!/usr/bin/env bats
# Tests for `local` (per-directory pinning).

load "../helpers/common"

@test "local writes .claude-profile in cwd" {
  write_profile work
  run bash "$CVP_SCRIPT" local work
  assert_success
  [ -f "$TEST_WORKDIR/.claude-profile" ]
  [ "$(cat "$TEST_WORKDIR/.claude-profile")" = "work" ]
}

@test "local --unset removes .claude-profile" {
  write_profile work
  echo "work" > "$TEST_WORKDIR/.claude-profile"
  run bash "$CVP_SCRIPT" local --unset
  assert_success
  [ ! -f "$TEST_WORKDIR/.claude-profile" ]
}

@test "local --unset when none is a success no-op" {
  run bash "$CVP_SCRIPT" local --unset
  assert_success
}

@test "local warns but writes when profile does not exist yet" {
  run bash "$CVP_SCRIPT" local future
  assert_success
  [ -f "$TEST_WORKDIR/.claude-profile" ]
  [ "$(cat "$TEST_WORKDIR/.claude-profile")" = "future" ]
  assert_contains "does not exist"
}

@test "local does not change the global alias" {
  write_profile work
  write_profile prod
  set_global_profile prod
  run bash "$CVP_SCRIPT" local work
  assert_success
  [ "$(cat "$CVM_DIR/active-profile")" = "prod" ]
}

@test "local overrides global for current" {
  write_profile work
  write_profile prod
  set_global_profile prod
  echo "work" > "$TEST_WORKDIR/.claude-profile"
  run bash "$CVP_SCRIPT" current
  assert_success
  [ "$output" = "work" ]
}
