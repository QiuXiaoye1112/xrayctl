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
  assert_eq "$expected_method" "$(jq -r .method <<<"$stream")" "$protocol transport choice routed incorrectly"
  case $expected_security in
    reality) assert_eq public-key "$public_key" "REALITY public key was not returned";;
    tls) assert_eq example.com "$(jq -r .tlsSettings.serverName <<<"$stream")" "TLS certificate selection was not applied";;
  esac
}

for transport in '1 raw' '2 xhttp' '3 grpc'; do method=${transport#* }; index=${transport%% *}; assert_stream_choice vless 1 "$index" reality "$method"; done
for security in '2 tls' '3 none'; do
  security_index=${security%% *}; security_name=${security#* }
  for transport in '1 raw' '2 xhttp' '3 websocket' '4 grpc'; do assert_stream_choice vless "$security_index" "${transport%% *}" "$security_name" "${transport#* }"; done
done
for transport in '1 raw' '2 xhttp' '3 websocket' '4 grpc'; do assert_stream_choice trojan 1 "${transport%% *}" tls "${transport#* }"; done
for security in '2 reality' '3 none'; do
  for transport in '1 raw' '2 xhttp' '3 grpc'; do assert_stream_choice trojan "${security%% *}" "${transport%% *}" "${security#* }" "${transport#* }"; done
done
for security in '1 tls' '2 none'; do
  for transport in '1 raw' '2 xhttp' '3 websocket' '4 grpc'; do assert_stream_choice vmess "${security%% *}" "${transport%% *}" "${security#* }" "${transport#* }"; done
done

build_stream_settings() { printf -v "$2" '%s' '{"method":"raw","security":"none","rawSettings":{"acceptProxyProtocol":false,"header":{"type":"none"}}}'; printf -v "$3" '%s' ''; }
prompt_tag() { printf -v "$1" '%s' test-node; }
prompt_value() { printf -v "$1" '%s' 127.0.0.1; }
prompt_port() { printf -v "$1" '%s' 39081; }
prompt_public_host() { printf -v "$1" '%s' 203.0.113.10; }
prompt_client_label() { printf -v "$1" '%s' user; }
prompt_optional_value() { printf -v "$1" '%s' user; }
prompt_secret() { printf -v "$1" '%s' password; }
for protocol_choice in 1 2 3 4 5; do
  set_choices "$protocol_choice"
  inbound="" host="" public_key=""
  build_inbound inbound host public_key
  expected=(unused vless vmess trojan socks http)
  assert_eq "${expected[$protocol_choice]}" "$(jq -r .protocol <<<"$inbound")" "protocol menu choice routed incorrectly"
done

pass "all protocol, security, and transport interactive builder choices are covered"
