#!/usr/bin/env bats
# Unit tests for the ordered key/value store helpers that back `cvm profile add`.
# These replace the bash-4-only associative array (`declare -A`) so `add` runs
# on macOS's stock bash 3.2. Sourcing cvp.sh only defines functions — the
# `[[ "${BASH_SOURCE[0]}" == "${0}" ]]` guard keeps cvp_main from running.

load "../helpers/common"

# Run a snippet with cvp.sh sourced. Emits the snippet's stdout.
kv() {
  bash -c 'source "$1" || true; shift; eval "$*"' _ "$CVP_SCRIPT" "$@"
}

@test "kv set then get returns the value" {
  run kv '_cvp_kv_set FOO bar; _cvp_kv_get FOO'
  assert_success
  [ "$output" = "bar" ]
}

@test "kv get on a missing key returns nonzero and prints nothing" {
  # `set -e` is active (from sourcing cvp.sh), so branch explicitly on the rc.
  run kv 'if out=$(_cvp_kv_get MISSING); then echo "rc=0 out=[$out]"; else echo "rc=$? out=[$out]"; fi'
  assert_success
  [ "$output" = "rc=1 out=[]" ]
}

@test "kv has reflects presence" {
  run kv '_cvp_kv_set A 1; _cvp_kv_has A && echo yes; _cvp_kv_has B || echo no'
  assert_success
  assert_contains "yes"
  assert_contains "no"
}

@test "kv set overwrites in place without reordering" {
  run kv '_cvp_kv_set A 1; _cvp_kv_set B 2; _cvp_kv_set A 99; _cvp_kv_keys | tr "\n" ","'
  assert_success
  [ "$output" = "A,B," ]
}

@test "kv set overwrite updates the value" {
  run kv '_cvp_kv_set A 1; _cvp_kv_set A 2; _cvp_kv_get A'
  assert_success
  [ "$output" = "2" ]
}

@test "kv preserves insertion order across many keys" {
  run kv '_cvp_kv_set Z 1; _cvp_kv_set A 2; _cvp_kv_set M 3; _cvp_kv_keys | tr "\n" ","'
  assert_success
  [ "$output" = "Z,A,M," ]
}

@test "kv reset empties the store" {
  run kv '_cvp_kv_set A 1; _cvp_kv_reset; _cvp_kv_keys | wc -l | tr -d " "'
  assert_success
  [ "$output" = "0" ]
}

@test "kv keys on an empty store prints nothing (no set -u crash)" {
  run kv '_cvp_kv_reset; _cvp_kv_keys; echo "rc=$?"'
  assert_success
  [ "$output" = "rc=0" ]
}

@test "kv handles values with spaces and equals signs" {
  run kv '_cvp_kv_set H "x-first: 1=2"; _cvp_kv_get H'
  assert_success
  [ "$output" = "x-first: 1=2" ]
}

@test "kv handles empty-string values" {
  run kv '_cvp_kv_set E ""; _cvp_kv_has E && echo present; printf "[%s]" "$(_cvp_kv_get E)"'
  assert_success
  assert_contains "present"
  assert_contains "[]"
}
