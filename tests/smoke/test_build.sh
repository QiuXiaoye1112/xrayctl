#!/usr/bin/env bash

set -Eeuo pipefail

readonly TEST_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
readonly REPO_ROOT=$(cd "${TEST_DIR}/../.." && pwd)
readonly TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/xrayctl-build-test.XXXXXX")

cleanup_test_root() {
  [[ -n ${TEST_ROOT:-} && $TEST_ROOT == "${TMPDIR:-/tmp}"/xrayctl-build-test.* ]] || return 1
  rm -rf "$TEST_ROOT"
}
trap cleanup_test_root EXIT

# shellcheck source=../helpers/assert.sh
source "${REPO_ROOT}/tests/helpers/assert.sh"

recorded_commit=$(sed -n 's/^readonly XRAYCTL_BUILD_COMMIT="\([^"]*\)"/\1/p' "${REPO_ROOT}/dist/xrayctl" | head -1)
[[ -n $recorded_commit ]] || recorded_commit=$(git -C "$REPO_ROOT" rev-parse --short=12 HEAD)
XRAYCTL_BUILD_COMMIT="$recorded_commit" bash "${REPO_ROOT}/scripts/build.sh" >/dev/null
bash -n "${REPO_ROOT}/dist/xrayctl"
NO_COLOR=1 bash "${REPO_ROOT}/dist/xrayctl" help >"${TEST_ROOT}/help.txt"
assert_file_eq "${REPO_ROOT}/tests/fixtures/cli/help.txt" "${TEST_ROOT}/help.txt" "dist help differs from development entry"

version=$(NO_COLOR=1 bash "${REPO_ROOT}/dist/xrayctl" version)
[[ $version =~ ^xrayctl[[:space:]]+1[.]2[.]29[[:space:]]+\(commit[[:space:]][0-9a-f]+\)$ ]] \
  || fail "dist version does not contain source commit: ${version}"

if rg -n 'source "\$\{XRAYCTL_SOURCE_DIR\}' "${REPO_ROOT}/dist/xrayctl"; then
  fail "dist still depends on source modules"
fi

pass "standalone distribution builds and matches the development CLI"
