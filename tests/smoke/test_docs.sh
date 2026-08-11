#!/usr/bin/env bash

set -Eeuo pipefail

readonly TEST_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
readonly REPO_ROOT=$(cd "${TEST_DIR}/../.." && pwd)

# shellcheck source=../helpers/assert.sh
source "${REPO_ROOT}/tests/helpers/assert.sh"

for document in "${REPO_ROOT}/README.md" "${REPO_ROOT}/tests/fixtures/cli/help.txt"; do
  rg -q 'VLESS、VMess、Trojan、SOCKS5、HTTP' "$document" \
    || fail "protocol support list is inconsistent in ${document}"
  rg -q 'RAW、XHTTP、WebSocket、gRPC' "$document" \
    || fail "transport support list is inconsistent in ${document}"
done

for builder in vless vmess trojan socks http; do
  rg -q "^protocol_build_${builder}\\(\\)" "${REPO_ROOT}/src/protocols.sh" \
    || fail "README/help advertises a protocol without builder: ${builder}"
done

rg -q 'xrayctl subscription' "${REPO_ROOT}/README.md"
rg -q 'xrayctl subscription' "${REPO_ROOT}/tests/fixtures/cli/help.txt"

pass "README, help, builders, and supported capabilities are synchronized"
