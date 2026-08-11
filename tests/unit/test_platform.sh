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
