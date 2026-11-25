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
    "listen": "::",
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
) <<<$'2\n2\n1\n0' >"$TEST_ROOT/address-menu.out"
grep -Fq '修改客户端连接地址' "$TEST_ROOT/address-menu.out"
grep -Fxq '信息 · 监听地址：::' "$TEST_ROOT/address-menu.out"
if grep -Fq '当前客户端连接地址' "$TEST_ROOT/address-menu.out"; then fail "the edit prompt repeated the client address"; fi
grep -Fxq '    1) IPv4' "$TEST_ROOT/address-menu.out"
grep -Fxq '    2) IPv6' "$TEST_ROOT/address-menu.out"
if grep -Eq '^    [0-9]+\) .*域名|双栈' "$TEST_ROOT/address-menu.out"; then fail "the address menu offered a domain or wildcard mode"; fi
grep -Fxq '    2) 2001:db8::20' "$TEST_ROOT/address-menu.out"
if grep -Fq '192.0.2.20' "$TEST_ROOT/address-menu.out"; then fail "IPv6 mode offered an IPv4 address"; fi
if grep -Fq 'eth0' "$TEST_ROOT/address-menu.out"; then fail "the address list displayed a network interface"; fi
if grep -Fq '修改地址/端口' "$TEST_ROOT/address-menu.out"; then fail "the edit menu still exposes the old address/port entry"; fi
assert_eq '2001:db8::10' "$(inbound_effective_listen vless-node)" "the address edit must change the listener to IPv6"
assert_eq '2001:db8::10' "$(jq -r '.inbounds["vless-node"].host' "$META_FILE")" "IPv6 must be stored without URI brackets"
assert_eq "${expected/@edge.example.com:/@[2001:db8::10]:}" "$(print_subscription vless-node | base64 --decode)" "IPv6 subscription did not use a bracketed address"
assert_eq "${expected/@edge.example.com:/@[2001:db8::10]:}" "$(print_links vless-node | sed -n 's/^链接: //p')" "interactive share link did not change"
jq -S 'del(.inbounds["vless-node"].host)' "$TEST_ROOT/original-meta.json" >"$TEST_ROOT/old-other.json"
jq -S 'del(.inbounds["vless-node"].host)' "$META_FILE" >"$TEST_ROOT/new-other.json"
assert_file_eq "$TEST_ROOT/old-other.json" "$TEST_ROOT/new-other.json" "the address edit changed unrelated metadata"

modify_inbound_client_address vless-node <<<$'1\n1' >/dev/null
assert_eq '192.0.2.10' "$(inbound_effective_listen vless-node)" "IPv6-to-IPv4 edit must rebind the original port"
assert_eq "${expected/@edge.example.com:/@192.0.2.10:}" "$(print_subscription | base64 --decode)" "IPv6-to-IPv4 edit did not update the combined subscription"

# Another listener can share 443 on an unoccupied address.
cp "$CONFIG_FILE" "$TEST_ROOT/single.json"
jq '.inbounds += [{tag:"existing-v6",listen:"2001:db8::20",port:443,protocol:"vless"}]' "$TEST_ROOT/single.json" >"$CONFIG_FILE"
cp "$CONFIG_FILE" "$TEST_ROOT/conflict.json"
cp "$META_FILE" "$TEST_ROOT/conflict-meta.json"
assert_failure modify_inbound_client_address vless-node <<<$'2\n2'
assert_file_eq "$TEST_ROOT/conflict.json" "$CONFIG_FILE" "a conflicting listener changed config"
assert_file_eq "$TEST_ROOT/conflict-meta.json" "$META_FILE" "a conflicting listener changed the share address"
assert_eq 2 "$(wc -l <"$TEST_ROOT/restarts" | tr -d '[:space:]')" "conflict restarted Xray"

cp "$TEST_ROOT/single.json" "$CONFIG_FILE"
touch "$TEST_ROOT/force-restart-failure"
assert_failure modify_inbound_client_address vless-node <<<$'2\n1'
assert_file_eq "$TEST_ROOT/single.json" "$CONFIG_FILE" "restart failure did not restore the original listener"
assert_file_eq "$TEST_ROOT/conflict-meta.json" "$META_FILE" "restart failure did not restore metadata"
modify_inbound_client_address vless-node <<<$'2\n1' >/dev/null
assert_eq '2001:db8::10' "$(inbound_effective_listen vless-node)" "the new IPv6 listener did not take effect after retry"
cp "$META_FILE" "$TEST_ROOT/valid-meta.json"
modify_inbound_client_address vless-node <<<$'2\n1' >/dev/null
assert_eq 5 "$(wc -l <"$TEST_ROOT/restarts" | tr -d '[:space:]')" "selecting the same address should not restart"
assert_failure modify_inbound_client_address vless-node <<<$'3\nedge.example.com'
assert_failure modify_inbound_client_address vless-node <<<'2'
assert_file_eq "$TEST_ROOT/valid-meta.json" "$META_FILE" "an invalid or incomplete selection changed metadata"
jq -S 'del(.inbounds[0].listen)' "$TEST_ROOT/original.json" >"$TEST_ROOT/original-static.json"
jq -S 'del(.inbounds[0].listen)' "$CONFIG_FILE" >"$TEST_ROOT/current-static.json"
assert_file_eq "$TEST_ROOT/original-static.json" "$TEST_ROOT/current-static.json" "switching address families changed unrelated Xray settings"

# Keep the former client SNI for a legacy TLS domain as it moves to an IP.
jq '.inbounds[0].streamSettings.security="tls" | .inbounds[0].streamSettings.tlsSettings={}' "$CONFIG_FILE" >"$TEST_ROOT/legacy-tls.json"
cp "$TEST_ROOT/legacy-tls.json" "$CONFIG_FILE"
jq '.inbounds["vless-node"].host="cert.example.com"' "$META_FILE" >"$TEST_ROOT/legacy-tls-meta.json"
cp "$TEST_ROOT/legacy-tls-meta.json" "$META_FILE"
modify_inbound_client_address vless-node <<<$'2\n1' >/dev/null
decoded=$(print_subscription vless-node | base64 --decode)
[[ $decoded == *'@[2001:db8::10]:443?'* && $decoded == *'&sni=cert.example.com&'* ]]
assert_eq 5 "$(wc -l <"$TEST_ROOT/restarts" | tr -d '[:space:]')" "changing the share address alone should not restart"
modify_inbound_client_address vless-node <<<$'1\n2' >/dev/null
decoded=$(print_subscription vless-node | base64 --decode)
[[ $decoded == *'@192.0.2.20:443?'* && $decoded == *'&sni=cert.example.com&'* ]]
assert_eq 443 "$(inbound_effective_port vless-node)" "the original port must remain fixed"
assert_eq 192.0.2.20 "$(inbound_effective_listen vless-node)" "editing must use the selected second IPv4 address"
jq -e '.inbounds[0].streamSettings.tlsSettings=={}' "$CONFIG_FILE" >/dev/null

pass "client address edits rebind safely, preserve the port and TLS identity, and roll back on failure"

# A hand-written inbound can lack both a saved host and a saved TLS name.
unset XRAYCTL_PUBLIC_HOST
jq 'del(.inbounds["vless-node"].host, .inbounds["vless-node"].shareTlsServerName)' "$META_FILE" >"$TEST_ROOT/imported-meta.json"
cp "$TEST_ROOT/imported-meta.json" "$META_FILE"
decoded=$(print_subscription vless-node | base64 --decode)
[[ $decoded == *'@192.0.2.20:443?'* && $decoded == *'&sni=192.0.2.20&'* ]]
decoded=$(XRAYCTL_PUBLIC_HOST=override.example.com print_subscription vless-node | base64 --decode)
[[ $decoded == *'@override.example.com:443?'* && $decoded == *'&sni=override.example.com&'* ]]

jq '.inbounds[0].listen="::"' "$CONFIG_FILE" >"$TEST_ROOT/imported-config.json"
cp "$TEST_ROOT/imported-config.json" "$CONFIG_FILE"
python3 - "$REPO_ROOT/xrayctl.sh" <<'PY'
import os
import pty
import subprocess
import sys

script = r'''
source "$1"
detect_local_ips() { printf '%s\t%s\teth0\n' IPv4 192.0.2.20 IPv6 2001:db8::20; }
print_links vless-node
'''
master, slave = pty.openpty()
with subprocess.Popen(['bash', '-c', script, 'share-test', sys.argv[1]], stdin=slave,
                      stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True) as process:
    os.close(slave)
    try:
        os.write(master, b'2\n1\n')
        try:
            stdout, stderr = process.communicate(timeout=10)
        except subprocess.TimeoutExpired:
            process.kill()
            raise AssertionError('sharing asked for the host more than once')
    finally:
        os.close(master)
    assert process.returncode == 0, stderr
    assert stderr.count('选择客户端连接地址类型') == 1, stderr
    links = [line for line in stdout.splitlines() if line.startswith('链接: vless://')]
    assert len(links) == 1 and '@[2001:db8::20]:443?' in links[0], stdout
    assert '&sni=2001%3Adb8%3A%3A20&' in links[0], stdout
PY
pass "imported inbounds share their concrete address or prompt once on a wildcard"

jq '.inbounds += [{tag:"socks-legacy", listen:"2001:db8::20", port:8443, protocol:"socks",
  settings:{auth:"password", users:[{user:"fixture",pass:"fixture"}], udp:true, ip:"0.0.0.0"}}]' \
  "$CONFIG_FILE" >"$TEST_ROOT/socks-config.json"
cp "$TEST_ROOT/socks-config.json" "$CONFIG_FILE"
jq '.inbounds["socks-legacy"].host="2001:db8::20"' "$META_FILE" >"$TEST_ROOT/socks-meta.json"
cp "$TEST_ROOT/socks-meta.json" "$META_FILE"
modify_inbound_client_address socks-legacy <<<$'2\n2' >/dev/null
jq -e '.inbounds[] | select(.tag=="socks-legacy") |
  .listen=="2001:db8::20" and .port==8443 and .settings.udp==true and (.settings|has("ip")|not)' "$CONFIG_FILE" >/dev/null
jq '(.inbounds[] | select(.tag=="socks-legacy") | .settings.ip)="192.0.2.50"' \
  "$CONFIG_FILE" >"$TEST_ROOT/socks-config.json"
cp "$TEST_ROOT/socks-config.json" "$CONFIG_FILE"
modify_inbound_client_address socks-legacy <<<$'1\n1' >/dev/null
jq -e '.inbounds[] | select(.tag=="socks-legacy") |
  .listen=="192.0.2.10" and .port==8443 and .settings.ip=="192.0.2.50"' "$CONFIG_FILE" >/dev/null
pass "SOCKS address edits repair an advertised wildcard and preserve explicit relay addresses"
