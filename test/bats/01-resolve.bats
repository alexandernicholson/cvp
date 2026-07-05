#!/usr/bin/env bats
# Tests for profile resolution order.

load "../helpers/common"

@test "current prints none when nothing is set" {
  run bash "$CVP_SCRIPT" current
  assert_contains "none"
}

@test "current picks up the global alias" {
  write_profile work "ANTHROPIC_BASE_URL=https://gw.example.com"
  set_global_profile work
  run bash "$CVP_SCRIPT" current
  assert_success
  [ "$output" = "work" ]
}

@test "current respects .claude-profile over global" {
  write_profile work
  write_profile prod
  set_global_profile work
  echo "prod" > "$TEST_WORKDIR/.claude-profile"
  run bash "$CVP_SCRIPT" current
  assert_success
  [ "$output" = "prod" ]
}

@test "current respects CVM_PROFILE env over .claude-profile" {
  write_profile work
  write_profile prod
  set_global_profile work
  echo "prod" > "$TEST_WORKDIR/.claude-profile"
  CVM_PROFILE=work run bash "$CVP_SCRIPT" current
  assert_success
  [ "$output" = "work" ]
}

@test "current walks up to parent .claude-profile" {
  write_profile prod
  mkdir -p "$TEST_WORKDIR/sub/deep"
  echo "prod" > "$TEST_WORKDIR/.claude-profile"
  cd "$TEST_WORKDIR/sub/deep"
  run bash "$CVP_SCRIPT" current
  assert_success
  [ "$output" = "prod" ]
}
