#!/usr/bin/env bats
# Cross-shell tests: the artifacts cvp produces must be consumable from zsh,
# which is the default interactive shell on macOS. `eval "$(cvm profile env)"`
# and the env.d resolver both get sourced into whatever shell the user runs.
# These tests skip cleanly when zsh isn't installed.

load "../helpers/common"

zsh_available() {
  command -v zsh >/dev/null 2>&1
}

@test "env output evals cleanly in zsh and sets the variables" {
  zsh_available || skip "zsh not installed"
  write_profile work \
    "ANTHROPIC_BASE_URL=https://gw.example.com" \
    "ANTHROPIC_API_KEY=sk-zsh"
  set_global_profile work
  # Capture the export lines from bash, then eval them in a fresh zsh.
  local env_out; env_out=$(bash "$CVP_SCRIPT" env)
  run zsh -c "eval \"\$1\"; print -r -- \"\$ANTHROPIC_BASE_URL|\$ANTHROPIC_API_KEY\"" _ "$env_out"
  assert_success
  [ "$output" = "https://gw.example.com|sk-zsh" ]
}

@test "env output with a literal-newline value evals in zsh" {
  zsh_available || skip "zsh not installed"
  write_profile work 'ANTHROPIC_CUSTOM_HEADERS="x-first: 1\nx-second: 2"'
  set_global_profile work
  local env_out; env_out=$(bash "$CVP_SCRIPT" env)
  run zsh -c "eval \"\$1\"; print -r -- \"\$ANTHROPIC_CUSTOM_HEADERS\"" _ "$env_out"
  assert_success
  [[ "$output" == *"x-first: 1"* ]]
  [[ "$output" == *"x-second: 2"* ]]
}

@test "env output with a quote-containing value evals safely in zsh" {
  zsh_available || skip "zsh not installed"
  write_profile work "ANTHROPIC_API_KEY=it's-a-key"
  set_global_profile work
  local env_out; env_out=$(bash "$CVP_SCRIPT" env)
  run zsh -c "eval \"\$1\"; print -r -- \"\$ANTHROPIC_API_KEY\"" _ "$env_out"
  assert_success
  [ "$output" = "it's-a-key" ]
}

@test "env.d resolver exports the active profile when sourced in zsh" {
  zsh_available || skip "zsh not installed"
  write_profile work \
    "ANTHROPIC_BASE_URL=https://gw.example.com" \
    "CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1"
  set_global_profile work
  bash "$CVP_SCRIPT" apply >/dev/null
  # Source the generated resolver in zsh and confirm it set the vars.
  run zsh -c "source \"\$1\"; print -r -- \"\$ANTHROPIC_BASE_URL|\$CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS\"" _ "$CVM_DIR/env.d/cvp.sh"
  assert_success
  [ "$output" = "https://gw.example.com|1" ]
}

@test "env.d resolver is a no-op in zsh when no profile is active" {
  zsh_available || skip "zsh not installed"
  bash "$CVP_SCRIPT" apply >/dev/null
  rm -f "$CVM_DIR/active-profile"
  run zsh -c "source \"\$1\" && print -r -- ok" _ "$CVM_DIR/env.d/cvp.sh"
  assert_success
  assert_contains "ok"
}
