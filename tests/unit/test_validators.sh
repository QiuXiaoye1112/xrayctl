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

width=""
display_width width "标签"
assert_eq 4 "$width" "UTF-8 table width for labels is incorrect"
(
  export LC_ALL=C
  width=""
  display_width width "匹配"
  assert_eq 4 "$width" "UTF-8 table width under C locale is incorrect"
  width=""
  display_width width "子域名"
  assert_eq 6 "$width" "UTF-8 table width for subdomain labels is incorrect"
)

assert_eq '标签    ' "$(print_table_cell '标签' 8)" "table cell padding is incorrect"
assert_eq '子域名' "$(print_table_cell '子域名' 6)" "exact-width table cells should not gain padding"
assert_eq 'abcdefghijklmnopqrst... ' \
  "$(print_table_cell_clipped 'abcdefghijklmnopqrstuvwx' 24)" \
  "24-column domain cells should expose more of long values"
assert_eq 'abcd... ' "$(print_table_cell_clipped 'abcdefghijkl' 8)" "clipped table cells are incorrect"

pass "validators preserve the pre-refactor contract"
