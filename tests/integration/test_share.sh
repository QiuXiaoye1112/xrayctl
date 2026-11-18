#!/usr/bin/env bash

set -Eeuo pipefail

readonly TEST_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
readonly REPO_ROOT=$(cd "${TEST_DIR}/../.." && pwd)
readonly TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/xrayctl-share.XXXXXX")

cleanup_test_root() {
  [[ -n ${TEST_ROOT:-} && $TEST_ROOT == "${TMPDIR:-/tmp}"/xrayctl-share.* ]] || return 1
  rm -rf "$TEST_ROOT"
}
trap cleanup_test_root EXIT

export XRAYCTL_CONFIG_DIR="${TEST_ROOT}/config"
export XRAYCTL_CONFIG_FILE="${XRAYCTL_CONFIG_DIR}/config.json"
export XRAYCTL_META_FILE="${XRAYCTL_CONFIG_DIR}/meta.json"
export XRAYCTL_CERT_DIR="${XRAYCTL_CONFIG_DIR}/certs"
export XRAYCTL_LOG_DIR="${TEST_ROOT}/logs"
export XRAYCTL_BACKUP_DIR="${TEST_ROOT}/backups"
export XRAYCTL_XRAY_BIN="${TEST_ROOT}/missing-xray"
export XRAYCTL_RUNTIME_OWNER
XRAYCTL_RUNTIME_OWNER=$(id -un)
export XRAYCTL_RUNTIME_GROUP
XRAYCTL_RUNTIME_GROUP=$(id -gn)

mkdir -p "$XRAYCTL_CONFIG_DIR"
cat >"$XRAYCTL_CONFIG_FILE" <<'JSON'
{
  "log": {"loglevel": "warning"},
  "inbounds": [{
    "tag": "vless-node",
    "listen": "127.0.0.1",
    "port": 443,
    "protocol": "vless",
    "settings": {"clients": [{"id": "123e4567-e89b-12d3-a456-426614174000", "email": "alice"}], "decryption": "none"},
    "streamSettings": {"method": "raw", "security": "none", "rawSettings": {"header": {"type": "none"}}}
  }],
  "outbounds": [{"protocol": "freedom", "tag": "direct"}],
  "routing": {"rules": []}
}
JSON
cat >"$XRAYCTL_META_FILE" <<'JSON'
{"schema":2,"inbounds":{"vless-node":{"host":"edge.example.com"}},"certificates":{},"managedResources":{},"migrations":{}}
JSON

# shellcheck source=../helpers/assert.sh
source "${REPO_ROOT}/tests/helpers/assert.sh"
# shellcheck source=../../xrayctl.sh
source "${REPO_ROOT}/xrayctl.sh"
trap - ERR
trap cleanup_test_root EXIT

expected='vless://123e4567-e89b-12d3-a456-426614174000@edge.example.com:443?type=tcp&security=none#vless-node-alice'
decoded=$(print_subscription vless-node | base64 --decode)
assert_eq "$expected" "$decoded" "single-inbound subscription did not contain the generated share URI"

decoded=$(print_subscription | base64 --decode)
assert_eq "$expected" "$decoded" "all-inbound subscription did not contain the generated share URI"

pass "subscription contains raw proxy URIs instead of encoded display formatting"
