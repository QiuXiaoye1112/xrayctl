#!/usr/bin/env bash

set -Eeuo pipefail

readonly TEST_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
readonly REPO_ROOT=$(cd "${TEST_DIR}/../.." && pwd)
readonly TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/xrayctl-platform.XXXXXX")

cleanup_test_root() {
  [[ -n ${TEST_ROOT:-} && $TEST_ROOT == "${TMPDIR:-/tmp}"/xrayctl-platform.* ]] || return 1
  rm -rf "$TEST_ROOT"
}
trap cleanup_test_root EXIT

# shellcheck source=../helpers/assert.sh
source "${REPO_ROOT}/tests/helpers/assert.sh"
# shellcheck source=../../xrayctl.sh
source "${REPO_ROOT}/xrayctl.sh"
trap - ERR
trap cleanup_test_root EXIT

PLATFORM_CALL=""
systemctl() {
  PLATFORM_CALL="systemctl ${1-} ${2-} ${3-}"
  case ${1-} in
    list-unit-files) printf '%s enabled\n' "$SYSTEMD_UNIT" ;;
    is-active|is-enabled) return 0 ;;
  esac
}
journalctl() { PLATFORM_CALL="journalctl ${1-} ${2-} ${3-}"; }
rc-service() { PLATFORM_CALL="rc-service ${1-} ${2-}"; }
rc-update() {
  PLATFORM_CALL="rc-update ${1-} ${2-} ${3-}"
  [[ ${1-} != show ]] || printf '  %s | default\n' "$SERVICE_NAME"
}

XRAYCTL_PLATFORM=systemd
assert_eq systemd "$(platform_init_system)" "systemd override was not selected"
assert_success platform_service_exists
platform_service_start
assert_eq "systemctl start ${SERVICE_NAME} " "$PLATFORM_CALL" "systemd start routing changed"
platform_service_enable
assert_eq "systemctl enable ${SERVICE_NAME} " "$PLATFORM_CALL" "systemd enable routing changed"

XRAYCTL_PLATFORM=openrc
OPENRC_SERVICE="${TEST_ROOT}/xray.init"
printf '%s\n' '#!/bin/sh' >"$OPENRC_SERVICE"
chmod 755 "$OPENRC_SERVICE"
assert_eq openrc "$(platform_init_system)" "OpenRC override was not selected"
assert_success platform_service_exists
platform_service_start
assert_eq "rc-service ${SERVICE_NAME} start" "$PLATFORM_CALL" "OpenRC start routing changed"
platform_service_enable
assert_eq "rc-update add ${SERVICE_NAME} default" "$PLATFORM_CALL" "OpenRC enable routing changed"

pass "platform service API routes systemd and OpenRC operations"

original_command_exists=$(declare -f command_exists)
command_exists() { [[ $1 == ifconfig ]]; }
ifconfig() {
  printf '%s\n' \
    'eth0      Link encap:Ethernet  HWaddr 02:42:AC:11:00:02' \
    '          inet addr:192.0.2.10  Bcast:192.0.2.255  Mask:255.255.255.0' \
    '          inet6 addr: 2001:db8::10/64 Scope:Global' \
    'docker0   Link encap:Ethernet  HWaddr 02:42:00:00:00:00' \
    '          inet addr:172.17.0.1  Bcast:172.17.255.255  Mask:255.255.0.0' \
    'lo        Link encap:Local Loopback' \
    '          inet addr:127.0.0.1  Mask:255.0.0.0' \
    'ens3: flags=4163<UP,BROADCAST,RUNNING,MULTICAST>  mtu 1500' \
    '        inet 198.51.100.20  netmask 255.255.255.0  broadcast 198.51.100.255' \
    '        inet6 2001:db8::20%ens3  prefixlen 64  scopeid 0x0<global>' \
    '        inet6 fe80::20%ens3  prefixlen 64  scopeid 0x20<link>'
}
local_rows=$(detect_local_ips)
[[ $local_rows == *$'192.0.2.10 (IPv4)\t192.0.2.10\teth0'* ]] || fail "BusyBox IPv4 was not detected"
[[ $local_rows == *$'2001:db8::10 (IPv6)\t2001:db8::10\teth0'* ]] || fail "BusyBox IPv6 was not detected"
[[ $local_rows == *$'198.51.100.20 (IPv4)\t198.51.100.20\tens3'* ]] || fail "net-tools IPv4 was not detected"
[[ $local_rows == *$'2001:db8::20 (IPv6)\t2001:db8::20\tens3'* ]] || fail "scoped IPv6 was not normalized"
[[ $local_rows != *172.17.0.1* && $local_rows != *127.0.0.1* && $local_rows != *fe80::* ]] \
  || fail "virtual, loopback, or link-local address was not filtered"
eval "$original_command_exists"
grep -Fq 'iproute2' "${REPO_ROOT}/alpine/install.sh" || fail "Alpine bootstrap does not install iproute2"

pass "local IP detection supports BusyBox and net-tools ifconfig"
