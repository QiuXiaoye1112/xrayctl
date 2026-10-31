#!/usr/bin/env bash

set -Eeuo pipefail

readonly TEST_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
readonly REPO_ROOT=$(cd "${TEST_DIR}/../.." && pwd)
# The unprivileged service user must be able to traverse every parent. A caller's
# TMPDIR can live below /root, where chmod on TEST_ROOT alone cannot help.
readonly TEST_ROOT=$(mktemp -d /tmp/xrayctl-runtime-access.XXXXXX)
cleanup_test_root() { rm -rf "$TEST_ROOT"; }
trap cleanup_test_root EXIT
chmod 755 "$TEST_ROOT"

export XRAYCTL_CONFIG_DIR="$TEST_ROOT/config"
export XRAYCTL_LOG_DIR="$TEST_ROOT/logs"
export XRAYCTL_SYSTEMD_OVERRIDE_DIR="$TEST_ROOT/unit.d"
export XRAYCTL_RUNTIME_OWNER
XRAYCTL_RUNTIME_OWNER=$(id -un)
export XRAYCTL_RUNTIME_GROUP
XRAYCTL_RUNTIME_GROUP=$(id -gn)
if [[ $(id -u) == 0 ]]; then XRAYCTL_RUNTIME_GROUP=$(id -gn nobody); fi
export XRAYCTL_TMP_DIR="$TEST_ROOT/tmp"

# shellcheck source=../helpers/assert.sh
export XRAYCTL_TRAFFIC_FILE="$TEST_ROOT/traffic.json"
export XRAYCTL_LOCK_FILE="$TEST_ROOT/lock"
export XRAYCTL_CERTBOT_VENV="$TEST_ROOT/certbot"
export XRAYCTL_CERTBOT_CONFIG_DIR="$TEST_ROOT/letsencrypt"
source "$REPO_ROOT/tests/helpers/assert.sh"
# shellcheck source=../../xrayctl.sh
source "$REPO_ROOT/xrayctl.sh"
trap - ERR
trap cleanup_test_root EXIT

meta_resource_register() { :; }
service_exists() { return 0; }
platform_daemon_reload() { :; }
getent() { return 0; }
systemctl() {
  [[ ${1-} == show && ${2-} == "$SERVICE_NAME" && ${3-} == --property=User && ${4-} == --value ]] || return 1
  printf '%s\n' "$TEST_SERVICE_USER"
}

TEST_SERVICE_USER=$(id -un)
if [[ $(id -u) == 0 ]]; then TEST_SERVICE_USER=nobody; fi
XRAYCTL_PLATFORM=systemd
mkdir -p "$LOG_DIR"
printf 'existing access record\n' >"$LOG_DIR/access.log"
touch "$LOG_DIR/error.log"
chmod 600 "$LOG_DIR/access.log" "$LOG_DIR/error.log"
setup_runtime_access
assert_eq "$TEST_SERVICE_USER" "$(stat -c %U "$LOG_DIR/access.log")" 'log owner differs from systemd service user'
assert_eq 640 "$(stat -c %a "$LOG_DIR/access.log")" 'access log is not writable by its owner'
assert_eq 640 "$(stat -c %a "$LOG_DIR/error.log")" 'error log permissions were not repaired'
assert_eq 750 "$(stat -c %a "$LOG_DIR")" 'service cannot traverse log directory'
assert_eq 'existing access record' "$(cat "$LOG_DIR/access.log")" 'permission repair truncated log history'
if [[ $(id -u) == 0 ]]; then
  su -s /bin/sh "$TEST_SERVICE_USER" -c "test -w '$LOG_DIR/access.log' && test -w '$LOG_DIR/error.log'" \
    || fail 'service user cannot open the repaired logs'
fi
setup_runtime_access
assert_eq 'existing access record' "$(cat "$LOG_DIR/access.log")" 'repeated permission repair truncated logs'

# An unset User= means root in systemd, not the OpenRC runtime user.
if [[ $(id -u) == 0 ]]; then
  TEST_SERVICE_USER=''
  setup_runtime_access
  assert_eq root "$(stat -c %U "$LOG_DIR/access.log")" 'empty systemd User did not resolve to root'
fi

XRAYCTL_PLATFORM=openrc
RUNTIME_USER=$(id -un)
setup_runtime_access
for log in access.log error.log openrc.log openrc-error.log; do
  assert_eq "$RUNTIME_USER" "$(stat -c %U "$LOG_DIR/$log")" "OpenRC log owner changed: $log"
  assert_eq 640 "$(stat -c %a "$LOG_DIR/$log")" "OpenRC log permissions changed: $log"
done
# Refuse to follow a service-controlled symlink during privileged repairs.
printf 'outside data\n' >"$TEST_ROOT/outside"
chmod 600 "$TEST_ROOT/outside"
rm -f "$LOG_DIR/access.log"
ln -s "$TEST_ROOT/outside" "$LOG_DIR/access.log"
assert_failure setup_runtime_access
assert_eq 600 "$(stat -c %a "$TEST_ROOT/outside")" 'log repair followed a symlink outside the managed directory'
assert_eq 'outside data' "$(cat "$TEST_ROOT/outside")" 'log repair changed a symlink target'
rm -f "$LOG_DIR/access.log"
setup_runtime_access
assert_eq "$RUNTIME_OWNER" "$(stat -c %U "$LOG_DIR")" 'service can replace managed log directory entries'

# Certificate access also works before any systemd service has been installed.
if [[ $(id -u) == 0 ]]; then
  XRAYCTL_PLATFORM=systemd
  service_exists() { return 1; }
  setup_runtime_access
fi

pass 'runtime log permissions support systemd service users and OpenRC without truncation'

# Catch cores that exit immediately after systemctl restart reports success.
service_exists() { return 0; }
platform_service_restart() { :; }
platform_service_logs() { :; }
sleep() { :; }
service_checks=0
service_is_active() {
  service_checks=$((service_checks + 1))
  ((service_checks == 1))
}
assert_failure restart_service
assert_eq 2 "$service_checks" 'restart did not check for an early startup failure'
service_is_active() { return 0; }
assert_success restart_service
pass 'restart detects early process exits'
