#!/usr/bin/env bats
# Tests for the env.d/cvp.sh resolver that the cvm `claude` wrapper sources.
# This is the mechanism that actually injects profile vars into claude runs.

load "../helpers/common"

# Source the resolver in a fresh subshell with the given CVM_DIR and PWD, then
# print selected env vars. $1 = cwd (optional, defaults to TEST_WORKDIR).
source_resolver_and_print() {
  local cwd="${1:-$TEST_WORKDIR}"
  CVM_DIR="$CVM_DIR" run bash -c '
    cd "$1"
    source "$0/env.d/cvp.sh"
    printf "BASE=%s\nTOKEN=%s\nTEAMS=%s\n" \
      "${ANTHROPIC_BASE_URL:-}" "${ANTHROPIC_API_KEY:-}" "${CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS:-}"
 ' "$CVM_DIR" "$cwd"
}

@test "apply installs the resolver" {
  write_profile work "ANTHROPIC_BASE_URL=https://gw.example.com"
  run bash "$CVP_SCRIPT" apply
  assert_success
  [ -f "$CVM_DIR/env.d/cvp.sh" ]
}

@test "resolver exports the global active profile's vars" {
  write_profile work \
    "ANTHROPIC_BASE_URL=https://gw.example.com" \
    "ANTHROPIC_API_KEY=sk-123" \
    "CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1"
  set_global_profile work
  bash "$CVP_SCRIPT" apply >/dev/null

  source_resolver_and_print
  assert_success
  assert_contains "BASE=https://gw.example.com"
  assert_contains "TOKEN=sk-123"
  assert_contains "TEAMS=1"
}

@test "resolver respects .claude-profile over the global alias" {
  write_profile work "ANTHROPIC_BASE_URL=https://a.example.com"
  write_profile prod "ANTHROPIC_BASE_URL=https://b.example.com"
  set_global_profile work
  echo "prod" > "$TEST_WORKDIR/.claude-profile"
  bash "$CVP_SCRIPT" apply >/dev/null

  source_resolver_and_print
  assert_success
  assert_contains "BASE=https://b.example.com"
  assert_not_contains "https://a.example.com"
}

@test "resolver respects CVM_PROFILE over .claude-profile" {
  write_profile work "ANTHROPIC_BASE_URL=https://a.example.com"
  write_profile prod "ANTHROPIC_BASE_URL=https://b.example.com"
  set_global_profile work
  echo "prod" > "$TEST_WORKDIR/.claude-profile"
  bash "$CVP_SCRIPT" apply >/dev/null

  CVM_PROFILE=work CVM_DIR="$CVM_DIR" run bash -c '
    source "$0/env.d/cvp.sh"
    printf "BASE=%s\n" "${ANTHROPIC_BASE_URL:-}"
  ' "$CVM_DIR"
  assert_success
  assert_contains "BASE=https://a.example.com"
}

@test "resolver no-ops cleanly when no profile is active" {
  bash "$CVP_SCRIPT" apply >/dev/null
  source_resolver_and_print
  assert_success
  assert_contains "BASE="
  assert_not_contains "https://"
}

@test "resolver no-ops when the alias points to a removed profile" {
  write_profile work "ANTHROPIC_BASE_URL=https://gw.example.com"
  set_global_profile work
  bash "$CVP_SCRIPT" apply >/dev/null
  # Delete the profile file but leave the alias dangling.
  rm -f "$CVM_DIR/profiles/work.env"

  source_resolver_and_print
  assert_success
  assert_not_contains "https://gw.example.com"
}

@test "resolver walks up to a parent .claude-profile" {
  write_profile prod "ANTHROPIC_BASE_URL=https://gw.example.com"
  mkdir -p "$TEST_WORKDIR/sub/deep"
  echo "prod" > "$TEST_WORKDIR/.claude-profile"
  bash "$CVP_SCRIPT" apply >/dev/null

  source_resolver_and_print "$TEST_WORKDIR/sub/deep"
  assert_success
  assert_contains "BASE=https://gw.example.com"
}

@test "resolver does not leak its internal helper variables" {
  write_profile work "ANTHROPIC_BASE_URL=https://gw.example.com"
  set_global_profile work
  bash "$CVP_SCRIPT" apply >/dev/null

  CVM_DIR="$CVM_DIR" run bash -c '
    source "$0/env.d/cvp.sh"
    printf "name=%s|file=%s\n" "${_cvp_name:-unset}" "${_cvp_file:-unset}"
  ' "$CVM_DIR"
  assert_success
  assert_contains "name=unset"
  assert_contains "file=unset"
}

@test "resolver strips surrounding quotes from values" {
  write_profile work \
    "ANTHROPIC_BASE_URL='https://gw.example.com'" \
    "ANTHROPIC_API_KEY=\"sk-quoted\""
  set_global_profile work
  bash "$CVP_SCRIPT" apply >/dev/null

  CVM_DIR="$CVM_DIR" run bash -c '
    source "$0/env.d/cvp.sh"
    printf "BASE=%s|TOKEN=%s\n" "$ANTHROPIC_BASE_URL" "$ANTHROPIC_API_KEY"
  ' "$CVM_DIR"
  assert_success
  assert_contains "BASE=https://gw.example.com"
  assert_contains "TOKEN=sk-quoted"
}
