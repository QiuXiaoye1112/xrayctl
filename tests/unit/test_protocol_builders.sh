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
  printf -v "$2" '%s' '{"network":"raw","security":"none","rawSettings":{"acceptProxyProtocol":false,"header":{"type":"none"}}}'
  printf -v "$3" '%s' ''
}

prompt_tag() { printf -v "$1" '%s' "${TEST_PROTOCOL}-node"; }
prompt_value() {
  case ${2-} in 用户名) printf -v "$1" '%s' 'alice';; *) printf -v "$1" '%s' '0.0.0.0';; esac
}
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
run_fixture socks 2
run_fixture http 3
assert_failure protocol_build_socks ignored socks-node 0.0.0.0 1080 '' ''
assert_failure protocol_build_http ignored http-node 0.0.0.0 8080 alice ''

# Creating an authenticated account on another inbound must reject an
# existing global StatsService username and explain why before accepting a new
# one. The same check is also exercised through add-client in
# test_account_user_traffic.sh.
CONFIG_FILE=$(mktemp "${TMPDIR:-/tmp}/xrayctl-existing-account.XXXXXX")
jq -n '{inbounds:[{tag:"existing",protocol:"http",settings:{accounts:[{user:"taken",pass:"secret"}]}}]}' >"$CONFIG_FILE"
TEST_PROTOCOL_CHOICE=2
TEST_ACCOUNT_NAMES=(taken available)
prompted_inbound=''
prompted_host=''
prompted_key=''
prompt_validated_value() {
  local __var=$1 prompt=$2 value
  if [[ $prompt == 用户名 ]]; then
    value=${TEST_ACCOUNT_NAMES[0]}
    TEST_ACCOUNT_NAMES=("${TEST_ACCOUNT_NAMES[@]:1}")
  else
    value=${3-}
  fi
  "$4" "$value" || return 1
  printf -v "$__var" '%s' "$value"
}
duplicate_log=$(mktemp "${TMPDIR:-/tmp}/xrayctl-duplicate-prompt.XXXXXX")
build_inbound prompted_inbound prompted_host prompted_key >"$duplicate_log" 2>&1
duplicate_output=$(<"$duplicate_log")
[[ $duplicate_output == *'警告 · 此用户名已存在'* ]]
[[ $(jq -r '.settings.accounts[0].user' <<<"$prompted_inbound") == available ]]
unset -f prompt_validated_value
rm -f "$duplicate_log"
rm -f "$CONFIG_FILE"

assert_eq $'vless\nsocks\nhttp' "$(protocol_list)" "protocol registry changed"
assert_success protocol_is_supported vless
assert_failure protocol_is_supported vmess
assert_failure protocol_is_supported trojan
assert_success protocol_supports_stream vless
assert_failure protocol_supports_stream socks
assert_success protocol_supports_reality vless
assert_failure protocol_supports_reality socks
declare -F protocol_build_vmess >/dev/null && fail 'VMess builder still exists'
declare -F protocol_build_trojan >/dev/null && fail 'Trojan builder still exists'
assert_eq id "$(protocol_client_credential_field vless)" "VLESS credential capability changed"
assert_eq pass "$(protocol_client_credential_field http)" "HTTP credential capability changed"

pass "supported protocol builders match fixtures and removed protocols stay unavailable"
