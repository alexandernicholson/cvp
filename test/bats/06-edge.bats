#!/usr/bin/env bats
# Edge cases: invalid names, malformed profile files, parsing robustness.

load "../helpers/common"

@test "use rejects names starting with a dot" {
  run bash "$CVP_SCRIPT" use ".hidden"
  assert_failure
}

@test "use rejects path-like names" {
  run bash "$CVP_SCRIPT" use "a/b"
  assert_failure
}

@test "current handles a dangling global alias gracefully" {
  set_global_profile ghost
  run bash "$CVP_SCRIPT" current
  # current reports the alias name (resolution is by name only); it's show/env
  # that detect the missing file. current should still print "ghost".
  assert_success
  [ "$output" = "ghost" ]
}

@test "env parses unquoted values" {
  write_profile work "ANTHROPIC_BASE_URL=https://gw.example.com"
  set_global_profile work
  run bash "$CVP_SCRIPT" env
  assert_success
  assert_contains "export ANTHROPIC_BASE_URL='https://gw.example.com'"
}

@test "env parses double-quoted values and strips the quotes" {
  write_profile work 'ANTHROPIC_BASE_URL="https://gw.example.com"'
  set_global_profile work
  run bash "$CVP_SCRIPT" env
  assert_success
  assert_contains "export ANTHROPIC_BASE_URL='https://gw.example.com'"
}

@test "env parses single-quoted values and strips the quotes" {
  write_profile work "ANTHROPIC_BASE_URL='https://gw.example.com'"
  set_global_profile work
  run bash "$CVP_SCRIPT" env
  assert_success
  assert_contains "export ANTHROPIC_BASE_URL='https://gw.example.com'"
}

@test "env ignores blank lines and comments in profile files" {
  mkdir -p "$CVM_DIR/profiles"
  cat > "$CVM_DIR/profiles/work.env" <<'EOF'
# a comment

ANTHROPIC_BASE_URL=https://gw.example.com
   # indented comment (not stripped — no leading =, so skipped anyway)
CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1
EOF
  set_global_profile work
  run bash "$CVP_SCRIPT" env
  assert_success
  assert_contains "ANTHROPIC_BASE_URL='https://gw.example.com'"
  assert_contains "CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS='1'"
  assert_not_contains "comment"
}

@test "show masks variables whose name contains KEY" {
  write_profile work "MY_API_KEY=abc123" "MY_TOKEN=xyz"
  run bash "$CVP_SCRIPT" show work
  assert_success
  assert_contains "MY_API_KEY=***"
  assert_contains "MY_TOKEN=***"
  assert_not_contains "abc123"
  assert_not_contains "xyz"
}

@test "apply is idempotent" {
  write_profile work
  run bash "$CVP_SCRIPT" apply
  assert_success
  local first; first=$(cat "$CVM_DIR/env.d/cvp.sh")
  run bash "$CVP_SCRIPT" apply
  assert_success
  local second; second=$(cat "$CVM_DIR/env.d/cvp.sh")
  [ "$first" = "$second" ]
}

@test "CVM_DIR override changes where profiles live" {
  local alt; alt=$(mktemp -d)
  CVM_DIR="$alt" run bash "$CVP_SCRIPT" apply
  assert_success
  [ -f "$alt/env.d/cvp.sh" ]
  rm -rf "$alt"
}

# ── init / default profile seeding ────────────────────────────────────────────

@test "init seeds the default profile" {
  run bash "$CVP_SCRIPT" init
  assert_success
  [ -f "$CVM_DIR/profiles/default.env" ]
  assert_contains "cvp initialised"
}

@test "default profile uses official endpoints (no base URL / token)" {
  bash "$CVP_SCRIPT" init >/dev/null
  run bash "$CVP_SCRIPT" show default
  assert_success
  assert_contains "CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1"
  assert_not_contains "ANTHROPIC_BASE_URL"
  assert_not_contains "ANTHROPIC_AUTH_TOKEN"
}

@test "init activates default only when no profile is active" {
  bash "$CVP_SCRIPT" init >/dev/null
  [ "$(cat "$CVM_DIR/active-profile")" = "default" ]
}

@test "init does not overwrite an existing active profile" {
  write_profile pantheon "ANTHROPIC_BASE_URL=https://gw.example.com"
  set_global_profile pantheon
  bash "$CVP_SCRIPT" init >/dev/null
  [ "$(cat "$CVM_DIR/active-profile")" = "pantheon" ]
}

@test "seed does not overwrite an existing default.env" {
  mkdir -p "$CVM_DIR/profiles"
  printf '# custom default\nCUSTOM=keep\n' > "$CVM_DIR/profiles/default.env"
  bash "$CVP_SCRIPT" init >/dev/null
  [ "$(cat "$CVM_DIR/profiles/default.env")" = $'# custom default\nCUSTOM=keep' ]
}

@test "apply also seeds the default profile" {
  run bash "$CVP_SCRIPT" apply
  assert_success
  [ -f "$CVM_DIR/profiles/default.env" ]
}

@test "plugin.sh defines cvm_plugin_init" {
  local plugin_sh; plugin_sh="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)/plugin.sh"
  bash -c 'source "$1" 2>/dev/null && declare -F cvm_plugin_init >/dev/null 2>&1' _ "$plugin_sh"
  [ $? -eq 0 ]
}
