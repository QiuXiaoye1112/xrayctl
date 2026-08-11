#!/usr/bin/env bash

set -Eeuo pipefail

readonly TEST_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
readonly REPO_ROOT=$(cd "${TEST_DIR}/../.." && pwd)
readonly TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/xrayctl-cli.XXXXXX")

cleanup_test_root() {
  [[ -n ${TEST_ROOT:-} && $TEST_ROOT == "${TMPDIR:-/tmp}"/xrayctl-cli.* ]] || return 1
  rm -rf "$TEST_ROOT"
}
trap cleanup_test_root EXIT

# shellcheck source=../helpers/assert.sh
source "${REPO_ROOT}/tests/helpers/assert.sh"

NO_COLOR=1 bash "${REPO_ROOT}/xrayctl.sh" help >"${TEST_ROOT}/help.txt"
NO_COLOR=1 bash "${REPO_ROOT}/xrayctl.sh" version >"${TEST_ROOT}/version.txt"
NO_COLOR=1 bash "${REPO_ROOT}/alpine/xrayctl.sh" help >"${TEST_ROOT}/alpine-help.txt"
NO_COLOR=1 bash "${REPO_ROOT}/alpine/xrayctl.sh" version >"${TEST_ROOT}/alpine-version.txt"

assert_file_eq "${REPO_ROOT}/tests/fixtures/cli/help.txt" "${TEST_ROOT}/help.txt" "systemd help changed"
assert_file_eq "${REPO_ROOT}/tests/fixtures/cli/version.txt" "${TEST_ROOT}/version.txt" "systemd version changed"
assert_file_eq "${REPO_ROOT}/tests/fixtures/cli/alpine-help.txt" "${TEST_ROOT}/alpine-help.txt" "Alpine help changed"
assert_file_eq "${REPO_ROOT}/tests/fixtures/cli/alpine-version.txt" "${TEST_ROOT}/alpine-version.txt" "Alpine version changed"

if NO_COLOR=1 bash "${REPO_ROOT}/xrayctl.sh" definitely-unknown >"${TEST_ROOT}/unknown.out" 2>"${TEST_ROOT}/unknown.err"; then
  fail "unknown CLI command unexpectedly succeeded"
else
  status=$?
  assert_eq 2 "$status" "unknown CLI command exit status changed"
fi

pass "CLI help, version, and failure semantics match the recorded baseline"
