#!/usr/bin/env bash

set -Eeuo pipefail

readonly REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
readonly TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/xrayctl-ss2022.XXXXXX")
cleanup() { rm -rf "$TEST_ROOT"; }
trap cleanup EXIT

export XRAYCTL_CONFIG_DIR="$TEST_ROOT"
export XRAYCTL_CONFIG_FILE="$TEST_ROOT/config.json"
export XRAYCTL_META_FILE="$TEST_ROOT/xrayctl.meta.json"
export XRAYCTL_CERT_DIR="$TEST_ROOT/certs"
export XRAYCTL_TMP_DIR="$TEST_ROOT/tmp"
export XRAYCTL_TRAFFIC_FILE="$TEST_ROOT/traffic.json"
export XRAYCTL_XRAY_BIN=${XRAYCTL_REAL_XRAY_BIN:-$TEST_ROOT/missing-xray}
export XRAYCTL_RUNTIME_OWNER XRAYCTL_RUNTIME_GROUP
XRAYCTL_RUNTIME_OWNER=$(id -un)
XRAYCTL_RUNTIME_GROUP=$(id -gn)

source "$REPO_ROOT/tests/helpers/assert.sh"
source "$REPO_ROOT/xrayctl.sh"
trap - ERR
trap cleanup EXIT

ensure_runtime_dependencies() { :; }
setup_runtime_access() { :; }
service_is_active() { return 1; }
require_xray_installed() { :; }
traffic_after_config_change() { :; }
traffic_user_choose_address() { printf '%s\n' '127.0.0.1:39083'; }
choose() {
  assert_eq 'VLESS SS2022 SOCKS5 HTTP' "$3 $4 $5 $6" "inbound protocol menu order"
  printf -v "$1" '%s' 2
}
prompt_tag() { printf -v "$1" '%s' ss2022-test; }
prompt_value() { printf -v "$1" '%s' '127.0.0.1'; }
prompt_port() { printf -v "$1" '%s' 39082; }
prompt_public_host() { printf -v "$1" '%s' '2001:db8::1'; }
prompt_client_label() { printf -v "$1" '%s' "$next_user"; }

jq -n '{inbounds:[],outbounds:[{protocol:"freedom",tag:"direct"}],routing:{rules:[]}}' >"$CONFIG_FILE"
next_user=alice
dispatch inbound add >"$TEST_ROOT/add.out"
validate_candidate "$CONFIG_FILE"
assert_eq $'tcp\nudp' "$(traffic_protocols_for_inbound shadowsocks)" "SS2022 must count both transports"
jq -e '.inbounds[0].settings | .network=="tcp,udp" and .method=="2022-blake3-aes-256-gcm" and .password!=.clients[0].password' "$CONFIG_FILE" >/dev/null
alice_id=$(traffic_user_id ss2022-test alice)
[[ $alice_id == xrayctl-user-* ]]
assert_eq "$alice_id" "$(_outbound_user_identity identity ss2022-test alice; printf '%s' "$identity")" "routing and statistics must share the identity"

cp "$CONFIG_FILE" "$TEST_ROOT/before.json"
assert_failure dispatch client delete ss2022-test alice --yes
assert_file_eq "$TEST_ROOT/before.json" "$CONFIG_FILE" "deleting the last user changed the inbound"
candidate="$TEST_ROOT/candidate.json"
jq '.inbounds[0].settings.clients=[]' "$CONFIG_FILE" >"$candidate"
assert_failure validate_supported_capabilities "$candidate"
jq '.inbounds[0].settings.method="aes-256-gcm"' "$CONFIG_FILE" >"$candidate"
assert_failure validate_supported_capabilities "$candidate"

next_user=bob
dispatch client add ss2022-test >/dev/null
dispatch client rename ss2022-test alice alicia >/dev/null
assert_eq "$alice_id" "$(traffic_user_id ss2022-test alicia)" "renaming changed the statistics identity"
before_rotation=$(jq -c '.inbounds[0].settings' "$CONFIG_FILE")
dispatch client rotate ss2022-test alicia --yes </dev/null >/dev/null
jq -e --argjson before "$before_rotation" '.inbounds[0].settings |
  .password==$before.password and .clients[1]==$before.clients[1] and
  .clients[0].email==$before.clients[0].email and .clients[0].password!=$before.clients[0].password
' "$CONFIG_FILE" >/dev/null
dispatch client delete ss2022-test bob --yes >/dev/null
assert_eq alicia "$(jq -r '.inbounds[0].settings.clients[].xrayctlLabel' "$CONFIG_FILE")" "deleting a user affected the remaining account"

jq --slurpfile inbound "$REPO_ROOT/tests/fixtures/protocols/shadowsocks.json" '.inbounds=$inbound' "$CONFIG_FILE" >"$candidate"
cp "$candidate" "$CONFIG_FILE"
expected='ss://2022-blake3-aes-256-gcm:AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8%3D%3A0NHS09TV1tfY2drb3N3e3%2BDh4uPk5ebn6Onq6%2Bzt7u8%3D@[2001:db8::1]:39082#ss2022-test-alice'
assert_eq "$expected" "$(dispatch subscription ss2022-test | base64 --decode)" "SS2022 URI must percent-encode the combined keys"
jq '.inbounds = [{tag:"legacy-ss", protocol:"shadowsocks", settings:{method:"aes-256-gcm"}}] + .inbounds' "$CONFIG_FILE" >"$candidate"
cp "$candidate" "$CONFIG_FILE"
assert_eq "$expected" "$(dispatch subscription | base64 --decode)" "all-inbound subscription omitted SS2022"

pass "SS2022 menu order, validated config, independent keys, user lifecycle and share links"
