#!/usr/bin/env bash

set -Eeuo pipefail

readonly TEST_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
readonly REPO_ROOT=$(cd "${TEST_DIR}/../.." && pwd)

# shellcheck source=../helpers/assert.sh
source "${REPO_ROOT}/tests/helpers/assert.sh"
# shellcheck source=../../xrayctl.sh
source "${REPO_ROOT}/xrayctl.sh"
trap - ERR

CHOICES=()
CHOICE_INDEX=0
set_choices() { CHOICES=("$@"); CHOICE_INDEX=0; }
choose() {
  ((CHOICE_INDEX < ${#CHOICES[@]})) || fail "interactive builder requested an unexpected choice"
  printf -v "$1" '%s' "${CHOICES[$CHOICE_INDEX]}"
  CHOICE_INDEX=$((CHOICE_INDEX + 1))
}
prompt_value() {
  if [[ $2 == *serviceName* ]]; then printf -v "$1" '%s' test-service; else printf -v "$1" '%s' /test-path; fi
}
prompt_validated_value() {
  if [[ $2 == *目标* ]]; then printf -v "$1" '%s' www.microsoft.com:443; else printf -v "$1" '%s' www.microsoft.com; fi
}
prompt_tls_certificate() { printf -v "$1" '%s' /test.crt; printf -v "$2" '%s' /test.key; printf -v "$3" '%s' example.com; }
generate_reality_keys() { printf -v "$1" '%s' private-key; printf -v "$2" '%s' public-key; }
random_hex() { printf '%s' 0011223344556677; }

assert_stream_choice() {
  local protocol=$1 security_choice=$2 transport_choice=$3 expected_security=$4 expected_method=$5 stream="" public_key=""
  set_choices "$security_choice" "$transport_choice"
  build_stream_settings "$protocol" stream public_key
  assert_eq "$expected_security" "$(jq -r .security <<<"$stream")" "$protocol security choice routed incorrectly"
  assert_eq "$expected_method" "$(jq -r '.network // .method' <<<"$stream")" "$protocol transport choice routed incorrectly"
  case $expected_security in
    reality) assert_eq public-key "$public_key" "REALITY public key was not returned";;
    tls) assert_eq example.com "$(jq -r .tlsSettings.serverName <<<"$stream")" "TLS certificate selection was not applied";;
  esac
}

for transport in '1 raw' '2 xhttp'; do method=${transport#* }; index=${transport%% *}; assert_stream_choice vless 1 "$index" reality "$method"; done
for security in '2 tls' '3 none'; do
  security_index=${security%% *}; security_name=${security#* }
  for transport in '1 raw' '2 xhttp' '3 websocket'; do assert_stream_choice vless "$security_index" "${transport%% *}" "$security_name" "${transport#* }"; done
done

stream_fixture='{"method":"raw","security":"none","rawSettings":{"acceptProxyProtocol":false,"header":{"type":"none"}}}'
build_stream_settings() { printf -v "$2" '%s' "$stream_fixture"; printf -v "$3" '%s' ''; }
prompt_tag() { printf -v "$1" '%s' test-node; }
prompt_value() {
  [[ $2 != "监听地址" ]] || fail "new inbound must infer its listener"
  printf -v "$1" '%s' "${3-}"
}
prompt_port() { printf -v "$1" '%s' 39081; }
connection_host=203.0.113.10
prompt_public_host() {
  if [[ -n ${tls_sni:-} ]]; then assert_eq "$tls_sni" "${3-}" "TLS SNI should be offered as a connection address"; fi
  printf -v "$1" '%s' "$connection_host"
}
detect_local_ips() {
  printf '%s\t%s\teth0\n' IPv4 203.0.113.10 IPv6 2001:db8::10
}
prompt_client_label() { printf -v "$1" '%s' user; }
prompt_optional_value() { printf -v "$1" '%s' user; }
prompt_secret() { printf -v "$1" '%s' password; }
for protocol_choice in 1 2 3 4; do
  if [[ $protocol_choice == 2 ]]; then
    set_choices "$protocol_choice" 1
  else
    set_choices "$protocol_choice"
  fi
  inbound="" host="" public_key="" obfs_meta=""
  build_inbound inbound host public_key obfs_meta
  assert_eq 203.0.113.10 "$(jq -r .listen <<<"$inbound")" "selecting a local IPv4 must bind that address"
  expected=(unused vless shadowsocks socks http)
  assert_eq "${expected[$protocol_choice]}" "$(jq -r .protocol <<<"$inbound")" "protocol menu choice routed incorrectly"
done

for expected_bind in '2001:DB8::10 2001:db8::10' 'edge.example.com ::'; do
  IFS=' ' read -r connection_host expected_address <<<"$expected_bind"
  set_choices 1
  build_inbound inbound host public_key obfs_meta
  assert_eq "$expected_address" "$(jq -r .listen <<<"$inbound")" "automatic IPv6 or domain listener"
  assert_eq "$connection_host" "$host" "share address must remain independent of the listener"
done

(
  tls_sni=certificate.example.com
  stream_fixture='{"network":"raw","security":"tls","tlsSettings":{"serverName":"certificate.example.com"}}'
  connection_host=2001:db8::10
  set_choices 1
  build_inbound inbound host public_key obfs_meta
  jq -e --arg sni "$tls_sni" '.listen=="2001:db8::10" and .streamSettings.tlsSettings.serverName==$sni' <<<"$inbound" >/dev/null
  assert_eq "$connection_host" "$host" "choosing a TLS connection address must not replace SNI"
)
assert_eq 203.0.113.10 "$(inbound_auto_listen 198.51.100.9)" "non-local share address should use a local bind address"

set_choices 2 2
inbound="" host="" public_key="" obfs_meta=""
build_inbound inbound host public_key obfs_meta
assert_eq "127.0.0.1" "$(jq -r .listen <<<"$inbound")" "obfs SS2022 inbound must bind localhost"
assert_eq "tcp,udp" "$(jq -r .settings.network <<<"$inbound")" "obfs SS2022 inbound must support TCP and UDP"
assert_eq true "$(jq -r .dualStack <<<"$obfs_meta")" "obfs should preserve the dual-stack choice"
assert_eq "www.microsoft.com" "$(jq -r .host <<<"$obfs_meta")" "obfs metadata must preserve obfs-host"

pass "all protocol, security, and transport interactive builder choices are covered"
