#!/usr/bin/env bash

set -Eeuo pipefail

readonly TEST_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
readonly REPO_ROOT=$(cd "${TEST_DIR}/../.." && pwd)

# shellcheck source=../helpers/assert.sh
source "${REPO_ROOT}/tests/helpers/assert.sh"
# shellcheck source=../../xrayctl.sh
source "${REPO_ROOT}/xrayctl.sh"
trap - ERR
trap - EXIT

assert_success validate_port 1
assert_success validate_port 65535
assert_failure validate_port 0
assert_failure validate_port 65536
assert_failure validate_port abc

assert_success validate_domain example.com
assert_success validate_domain sub.example.com
assert_failure validate_domain localhost
assert_failure validate_domain '-bad.example'

assert_success validate_uuid 123e4567-e89b-12d3-a456-426614174000
assert_failure validate_uuid 123e4567-e89b-12d3-a456

assert_success validate_reality_target example.com:443
assert_failure validate_reality_target example.com
assert_failure validate_reality_target example.com:70000

assert_success validate_path /transport/path
assert_failure validate_path relative/path
assert_failure validate_path '/bad path'

pass "validators preserve the pre-refactor contract"
