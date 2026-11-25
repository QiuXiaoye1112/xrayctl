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

ensure_system_context() { :; }
setup_runtime_access() { :; }
service_is_active() { return 0; }
traffic_user_has_clients() { return 1; }
port_in_use_os() { return 1; }
detect_local_ips() {
  printf '%s\t%s\teth0\n' IPv4 192.0.2.10 IPv4 192.0.2.20 IPv6 2001:db8::10 IPv6 2001:db8::20
}
restart_service() {
  inbound_effective_listen vless-node >>"$TEST_ROOT/restarts"
  if [[ -f $TEST_ROOT/force-restart-failure ]]; then
    rm -f "$TEST_ROOT/force-restart-failure"
    return 1
  fi
}
cp "$CONFIG_FILE" "$TEST_ROOT/original.json"
cp "$META_FILE" "$TEST_ROOT/original-meta.json"

(
  pause() { :; }
  clear_screen() { :; }
  modify_inbound_menu vless-node vless
) <<<$'2\n[2001:db8::10]\n0' >"$TEST_ROOT/address-menu.out"
grep -Fq '修改客户端连接地址' "$TEST_ROOT/address-menu.out"
if grep -Fq '修改地址/端口' "$TEST_ROOT/address-menu.out"; then fail "the edit menu still exposes the old address/port entry"; fi
assert_eq '2001:db8::10' "$(inbound_effective_listen vless-node)" "the address edit must change the listener to IPv6"
assert_eq '2001:db8::10' "$(jq -r '.inbounds["vless-node"].host' "$META_FILE")" "IPv6 must be stored without URI brackets"
assert_eq "${expected/@edge.example.com:/@[2001:db8::10]:}" "$(print_subscription vless-node | base64 --decode)" "IPv6 subscription did not use a bracketed address"
assert_eq "${expected/@edge.example.com:/@[2001:db8::10]:}" "$(print_links vless-node | sed -n 's/^链接: //p')" "interactive share link did not change"
jq -S 'del(.inbounds["vless-node"].host)' "$TEST_ROOT/original-meta.json" >"$TEST_ROOT/old-other.json"
jq -S 'del(.inbounds["vless-node"].host)' "$META_FILE" >"$TEST_ROOT/new-other.json"
assert_file_eq "$TEST_ROOT/old-other.json" "$TEST_ROOT/new-other.json" "the address edit changed unrelated metadata"

modify_inbound_client_address vless-node <<<'192.0.2.10' >/dev/null
assert_eq '192.0.2.10' "$(inbound_effective_listen vless-node)" "IPv6-to-IPv4 edit must rebind the original port"
assert_eq "${expected/@edge.example.com:/@192.0.2.10:}" "$(print_subscription | base64 --decode)" "IPv6-to-IPv4 edit did not update the combined subscription"

# An unrelated inbound on IPv6 can share 443, but prevents the IPv4 listener
# from expanding to a wildcard (or changing to that occupied IPv6 address).
cp "$CONFIG_FILE" "$TEST_ROOT/single.json"
jq '.inbounds += [{tag:"existing-v6",listen:"2001:db8::20",port:443,protocol:"vless"}]' "$TEST_ROOT/single.json" >"$CONFIG_FILE"
cp "$CONFIG_FILE" "$TEST_ROOT/conflict.json"
cp "$META_FILE" "$TEST_ROOT/conflict-meta.json"
assert_failure modify_inbound_client_address vless-node <<<'replacement.example.com'
assert_failure modify_inbound_client_address vless-node <<<'2001:db8::20'
assert_file_eq "$TEST_ROOT/conflict.json" "$CONFIG_FILE" "a conflicting listener changed config"
assert_file_eq "$TEST_ROOT/conflict-meta.json" "$META_FILE" "a conflicting listener changed the share address"
assert_eq 2 "$(wc -l <"$TEST_ROOT/restarts" | tr -d '[:space:]')" "conflict restarted Xray"

cp "$TEST_ROOT/single.json" "$CONFIG_FILE"
touch "$TEST_ROOT/force-restart-failure"
assert_failure modify_inbound_client_address vless-node <<<'replacement.example.com'
assert_file_eq "$TEST_ROOT/single.json" "$CONFIG_FILE" "restart failure did not restore the original listener"
assert_file_eq "$TEST_ROOT/conflict-meta.json" "$META_FILE" "restart failure did not restore metadata"
modify_inbound_client_address vless-node <<<'replacement.example.com' >/dev/null
assert_eq '::' "$(inbound_effective_listen vless-node)" "a domain on a dual-stack host should bind the wildcard"
assert_eq "${expected/@edge.example.com:/@replacement.example.com:}" "$(print_subscription vless-node | base64 --decode)" "IPv4-to-domain edit did not update the subscription"
modify_inbound_client_address vless-node <<<'another.example.com' >/dev/null
assert_eq 5 "$(wc -l <"$TEST_ROOT/restarts" | tr -d '[:space:]')" "a domain-to-domain edit on the same listener should not restart"
cp "$META_FILE" "$TEST_ROOT/valid-meta.json"
modify_inbound_client_address vless-node <<<'' >/dev/null
assert_file_eq "$TEST_ROOT/valid-meta.json" "$META_FILE" "accepting the current address should not rewrite metadata"
assert_failure modify_inbound_client_address vless-node <<<'https://invalid.example.com:443'
assert_failure modify_inbound_client_address vless-node <<<'198.51.100.20'
assert_file_eq "$TEST_ROOT/valid-meta.json" "$META_FILE" "an invalid or ambiguous address changed metadata"
jq -S 'del(.inbounds[0].listen)' "$TEST_ROOT/original.json" >"$TEST_ROOT/original-static.json"
jq -S 'del(.inbounds[0].listen)' "$CONFIG_FILE" >"$TEST_ROOT/current-static.json"
assert_file_eq "$TEST_ROOT/original-static.json" "$TEST_ROOT/current-static.json" "switching address families changed unrelated Xray settings"

# Keep the former client SNI for imported TLS configurations without an
# explicit serverName, even when the new listener uses another IP family.
jq '.inbounds[0].streamSettings.security="tls" | .inbounds[0].streamSettings.tlsSettings={}' "$CONFIG_FILE" >"$TEST_ROOT/legacy-tls.json"
cp "$TEST_ROOT/legacy-tls.json" "$CONFIG_FILE"
modify_inbound_client_address vless-node <<<'2001:db8::20' >/dev/null
decoded=$(print_subscription vless-node | base64 --decode)
[[ $decoded == *'@[2001:db8::20]:443?'* && $decoded == *'&sni=another.example.com&'* ]]
modify_inbound_client_address vless-node <<<'192.0.2.20' >/dev/null
decoded=$(print_subscription vless-node | base64 --decode)
[[ $decoded == *'@192.0.2.20:443?'* && $decoded == *'&sni=another.example.com&'* ]]
assert_eq 443 "$(inbound_effective_port vless-node)" "the original port must remain fixed"
jq -e '.inbounds[0].streamSettings.tlsSettings=={}' "$CONFIG_FILE" >/dev/null

pass "client address edits rebind safely, preserve the port and TLS identity, and roll back on failure"
