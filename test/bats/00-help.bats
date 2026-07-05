#!/usr/bin/env bats
# Tests for cvp help / version / dispatch.

load "../helpers/common"

@test "profile help lists all commands" {
  run bash "$CVP_SCRIPT" help
  assert_success
  assert_contains "add"
  assert_contains "use"
  assert_contains "local"
  assert_contains "show"
  assert_contains "env"
  assert_contains "RESOLUTION ORDER"
}

@test "profile --help works" {
  run bash "$CVP_SCRIPT" --help
  assert_success
  assert_contains "cvp"
}

@test "profile with no args shows help" {
  run bash "$CVP_SCRIPT"
  assert_success
  assert_contains "USAGE"
}

@test "profile version prints version" {
  run bash "$CVP_SCRIPT" version
  assert_success
  assert_contains "cvp"
}

@test "unknown subcommand exits non-zero with help" {
  run bash "$CVP_SCRIPT" bogus
  assert_failure
  assert_contains "Unknown profile command"
}

@test "help mentions the known gateway vars" {
  run bash "$CVP_SCRIPT" help
  assert_success
  assert_contains "ANTHROPIC_BASE_URL"
  assert_contains "ANTHROPIC_API_KEY"
  assert_contains "CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS"
}
