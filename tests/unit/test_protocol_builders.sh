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

TEST_PROTOCOL_CHOICE=1
TEST_PROTOCOL=vless

choose() {
  printf -v "$1" '%s' "$TEST_PROTOCOL_CHOICE"
}

build_stream_settings() {
  printf -v "$2" '%s' '{"method":"raw","security":"none","rawSettings":{"acceptProxyProtocol":false,"header":{"type":"none"}}}'
  printf -v "$3" '%s' ''
}

prompt_tag() { printf -v "$1" '%s' "${TEST_PROTOCOL}-node"; }
prompt_value() { printf -v "$1" '%s' '0.0.0.0'; }
prompt_port() { printf -v "$1" '%s' '443'; }
prompt_public_host() { printf -v "$1" '%s' 'edge.example.com'; }
prompt_client_label() { printf -v "$1" '%s' 'alice'; }
prompt_secret() { printf -v "$1" '%s' 'fixed-password'; }
prompt_optional_value() { printf -v "$1" '%s' 'alice'; }
generate_uuid() { printf '%s\n' '123e4567-e89b-12d3-a456-426614174000'; }

run_fixture() {
  local protocol=$1 choice=$2 inbound='' host='' public_key='' actual
  TEST_PROTOCOL=$protocol
  TEST_PROTOCOL_CHOICE=$choice
  build_inbound inbound host public_key
  actual=$(mktemp "${TMPDIR:-/tmp}/xrayctl-fixture.XXXXXX")
  jq -S . <<<"$inbound" >"$actual"
  assert_file_eq "${REPO_ROOT}/tests/fixtures/protocols/${protocol}.json" "$actual" "${protocol} builder changed"
  rm -f "$actual"
  assert_eq edge.example.com "$host" "${protocol} public host changed"
}

run_fixture vless 1
run_fixture vmess 2
run_fixture trojan 3
run_fixture socks 4
run_fixture http 5

assert_eq $'vless\nvmess\ntrojan\nsocks\nhttp' "$(protocol_list)" "protocol registry changed"
assert_success protocol_supports_stream vless
assert_failure protocol_supports_stream socks
assert_success protocol_supports_reality trojan
assert_failure protocol_supports_reality vmess
assert_eq id "$(protocol_client_credential_field vless)" "VLESS credential capability changed"
assert_eq pass "$(protocol_client_credential_field http)" "HTTP credential capability changed"

pass "protocol builders match recorded JSON fixtures"
