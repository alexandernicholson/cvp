# Common setup/teardown and helpers for cvp bats tests.

# Path to cvp.sh (test/bats/ -> repo root)
CVP_SCRIPT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)/cvp.sh"

setup() {
  # Isolated cvm/cvp home per test
  export CVM_DIR
  CVM_DIR=$(mktemp -d)
  mkdir -p "$CVM_DIR"

  # Isolate ~/.claude/settings.json so tests never touch the real one.
  export CVP_CLAUDE_DIR
  CVP_CLAUDE_DIR="$CVM_DIR/claude"
  mkdir -p "$CVP_CLAUDE_DIR"
  unset CVP_NO_SETTINGS_SYNC 2>/dev/null || true

  # Working directory per test (prevents leaking .claude-profile files)
  export TEST_WORKDIR
  TEST_WORKDIR=$(mktemp -d)
  cd "$TEST_WORKDIR"
}

teardown() {
  rm -rf "${CVM_DIR:-}"
  rm -rf "${TEST_WORKDIR:-}"
}

# Write a profile file directly (bypass the interactive `add`).
write_profile() {
  local name="$1"; shift
  mkdir -p "$CVM_DIR/profiles"
  : > "$CVM_DIR/profiles/$name.env"
  echo "# Profile: $name" >> "$CVM_DIR/profiles/$name.env"
  for pair in "$@"; do
    printf "%s\n" "$pair" >> "$CVM_DIR/profiles/$name.env"
  done
}

set_global_profile() {
  local name="$1"
  mkdir -p "$CVM_DIR"
  printf '%s\n' "$name" > "$CVM_DIR/active-profile"
}

# Assert output contains a substring.
assert_contains() {
  local needle="$1"
  if ! echo "$output" | grep -qF "$needle"; then
    echo "Expected output to contain: $needle"
    echo "Actual output: $output"
    return 1
  fi
}

assert_not_contains() {
  local needle="$1"
  if echo "$output" | grep -qF "$needle"; then
    echo "Expected output NOT to contain: $needle"
    echo "Actual output: $output"
    return 1
  fi
}

assert_success() {
  if [[ "$status" -ne 0 ]]; then
    echo "Expected exit 0, got $status"
    echo "Output: $output"
    return 1
  fi
}

assert_failure() {
  if [[ "$status" -eq 0 ]]; then
    echo "Expected non-zero exit, got 0"
    echo "Output: $output"
    return 1
  fi
}
