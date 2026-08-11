#!/usr/bin/env bash

fail() {
  printf 'not ok - %s\n' "$*" >&2
  return 1
}

assert_eq() {
  local expected=$1 actual=$2 message=${3:-"values differ"}
  if [[ $expected != "$actual" ]]; then
    printf 'not ok - %s\nexpected:\n%s\nactual:\n%s\n' "$message" "$expected" "$actual" >&2
    return 1
  fi
}

assert_file_eq() {
  local expected=$1 actual=$2 message=${3:-"files differ"}
  if ! diff -u "$expected" "$actual"; then
    fail "$message"
  fi
}

assert_success() {
  "$@" || fail "command failed: $*"
}

assert_failure() {
  if "$@"; then
    fail "command unexpectedly succeeded: $*"
  fi
}

pass() {
  printf 'ok - %s\n' "$*"
}
