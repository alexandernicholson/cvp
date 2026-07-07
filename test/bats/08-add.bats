#!/usr/bin/env bats
# Tests for `cvm profile add` — the interactive profile creator.
#
# Regression guard for the macOS bug where `declare -A` (bash 4+ associative
# arrays) crashed on stock bash 3.2:
#   cvp.sh: line 360: declare: -A: invalid option
#   cvp.sh: line 370: ANTHROPIC_BASE_URL: unbound variable
# `add` now uses an ordered key/value store built from plain indexed arrays,
# which works on bash 3.2 (macOS) through 5.x (Linux).

load "../helpers/common"

setup() {
  # Reuse the common isolation, then make sure settings sync never runs during
  # `add` tests (add only syncs when the profile is the active global one, but
  # be explicit so the tests don't depend on that).
  export CVP_NO_SETTINGS_SYNC=1
  # common.bash setup()
  CVM_DIR=$(mktemp -d); export CVM_DIR
  CVP_CLAUDE_DIR="$CVM_DIR/claude"; export CVP_CLAUDE_DIR
  mkdir -p "$CVP_CLAUDE_DIR"
  local _v
  for _v in $(compgen -e ANTHROPIC_ || true); do unset "$_v"; done
  TEST_WORKDIR=$(mktemp -d); export TEST_WORKDIR
  cd "$TEST_WORKDIR"
}

@test "add creates a profile from piped answers (regression: no declare -A crash)" {
  # base URL, api key, teams flag, blank to finish custom vars
  run bash "$CVP_SCRIPT" add pantheon <<< $'https://gw.example.com\nsk-secret\n1\n'
  assert_success
  assert_contains "Saved profile 'pantheon'"
  # No bash-4-only error leaked through.
  assert_not_contains "declare: -A"
  assert_not_contains "unbound variable"
  assert_not_contains "invalid option"
  [ -f "$CVM_DIR/profiles/pantheon.env" ]
}

@test "add writes known vars in declared order with single-quoted values" {
  bash "$CVP_SCRIPT" add work <<< $'https://gw.example.com\nsk-abc\n1\n' >/dev/null
  run cat "$CVM_DIR/profiles/work.env"
  assert_contains "ANTHROPIC_BASE_URL='https://gw.example.com'"
  assert_contains "ANTHROPIC_API_KEY='sk-abc'"
  assert_contains "CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS='1'"
  # Order: base url before api key before teams flag.
  local body; body=$(grep -n '=' "$CVM_DIR/profiles/work.env")
  local l_url l_key
  l_url=$(grep -n 'ANTHROPIC_BASE_URL=' "$CVM_DIR/profiles/work.env" | cut -d: -f1)
  l_key=$(grep -n 'ANTHROPIC_API_KEY=' "$CVM_DIR/profiles/work.env" | cut -d: -f1)
  [ "$l_url" -lt "$l_key" ]
}

@test "add blank answers skip the corresponding var" {
  # Only supply an api key; base URL + teams blank.
  bash "$CVP_SCRIPT" add sparse <<< $'\nsk-only\n\n' >/dev/null
  run cat "$CVM_DIR/profiles/sparse.env"
  assert_contains "ANTHROPIC_API_KEY='sk-only'"
  assert_not_contains "ANTHROPIC_BASE_URL="
  assert_not_contains "CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS="
}

@test "add supports custom variables" {
  # known vars blank, then one custom var, then blank to finish
  bash "$CVP_SCRIPT" add custom <<< $'\n\n\nMY_CUSTOM\ncustomval\n\n' >/dev/null
  run cat "$CVM_DIR/profiles/custom.env"
  assert_contains "MY_CUSTOM='customval'"
}

@test "add with only a custom var works (empty known-var set)" {
  # Exercises the empty 'written' array path (bash 3.2 set -u safety).
  bash "$CVP_SCRIPT" add conly <<< $'\n\n\nZZ_ONLY\nzval\n\n' >/dev/null
  run cat "$CVM_DIR/profiles/conly.env"
  assert_success
  assert_contains "ZZ_ONLY='zval'"
  assert_not_contains "ANTHROPIC_BASE_URL="
}

@test "add with all-blank answers writes just the header (no crash)" {
  # Exercises both empty 'written' and empty 'extras' arrays.
  run bash "$CVP_SCRIPT" add blankprof <<< $'\n\n\n\n'
  assert_success
  [ -f "$CVM_DIR/profiles/blankprof.env" ]
  assert_not_contains "unbound variable"
}

@test "add editing an existing profile keeps values on blank (Enter to keep)" {
  bash "$CVP_SCRIPT" add work <<< $'https://gw.example.com\nsk-orig\n1\n' >/dev/null
  # Re-run: keep base url (blank), change key, keep teams (blank), no customs.
  bash "$CVP_SCRIPT" add work <<< $'\nsk-new\n\n\n' >/dev/null
  run cat "$CVM_DIR/profiles/work.env"
  assert_contains "ANTHROPIC_BASE_URL='https://gw.example.com'"
  assert_contains "ANTHROPIC_API_KEY='sk-new'"
  assert_contains "CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS='1'"
}

@test "add editing an existing profile preserves custom vars" {
  bash "$CVP_SCRIPT" add work <<< $'https://a.example.com\n\n\nKEEP_ME\nkept\n\n' >/dev/null
  # Re-run with all blanks — the custom var must survive.
  bash "$CVP_SCRIPT" add work <<< $'\n\n\n\n' >/dev/null
  run cat "$CVM_DIR/profiles/work.env"
  assert_contains "KEEP_ME='kept'"
  assert_contains "ANTHROPIC_BASE_URL='https://a.example.com'"
}

@test "add single-quote-escapes values (identical across bash 3.2 and 5.x)" {
  # api key value = it's-a-key (contains a single quote). add must write a
  # correctly shell-escaped line: '\'' for each embedded quote. This is the
  # regression guard for the bash-3.2 vs 4.3+ ${//} replacement-escaping bug.
  local q="it's-a-key"
  bash "$CVP_SCRIPT" add tricky <<< $'\n'"$q"$'\n\n' >/dev/null
  run grep '^ANTHROPIC_API_KEY=' "$CVM_DIR/profiles/tricky.env"
  assert_success
  # Expect exactly: ANTHROPIC_API_KEY='it'\''s-a-key'
  [ "$output" = "ANTHROPIC_API_KEY='it'\\''s-a-key'" ]
  # And a POSIX shell must eval that line back to the original value.
  run sh -c "eval \"\$1\"; printf '%s' \"\$ANTHROPIC_API_KEY\"" _ "$output"
  assert_success
  [ "$output" = "$q" ]
}

@test "add rejects invalid profile names" {
  run bash "$CVP_SCRIPT" add "../escape" <<< $'\n\n\n\n'
  assert_failure
  assert_contains "Invalid profile name"
}

@test "add requires a name" {
  run bash "$CVP_SCRIPT" add < /dev/null
  assert_failure
  assert_contains "Usage"
}

@test "add skips invalid custom var names" {
  bash "$CVP_SCRIPT" add work <<< $'\n\n\n1BAD\nGOOD\ngoodval\n\n' >/dev/null
  run cat "$CVM_DIR/profiles/work.env"
  assert_contains "GOOD='goodval'"
  assert_not_contains "1BAD"
}

@test "add installs the env.d resolver" {
  bash "$CVP_SCRIPT" add work <<< $'\n\n1\n' >/dev/null
  [ -f "$CVM_DIR/env.d/cvp.sh" ]
}
