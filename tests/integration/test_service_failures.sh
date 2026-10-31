#!/usr/bin/env bash
set -Eeuo pipefail
REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/xrayctl-service-failures.XXXXXX")
cleanup() { rm -rf "$TEST_ROOT"; }
trap cleanup EXIT
export XRAYCTL_TESTING=1 XRAYCTL_TMP_DIR="$TEST_ROOT/tmp"
export XRAYCTL_CONFIG_DIR="$TEST_ROOT/config" XRAYCTL_LOG_DIR="$TEST_ROOT/logs"
export XRAYCTL_TRAFFIC_FILE="$TEST_ROOT/traffic.json" XRAYCTL_LOCK_FILE="$TEST_ROOT/lock"
export XRAYCTL_CERTBOT_VENV="$TEST_ROOT/certbot" XRAYCTL_CERTBOT_CONFIG_DIR="$TEST_ROOT/letsencrypt"
source "$REPO_ROOT/tests/helpers/assert.sh"
source "$REPO_ROOT/xrayctl.sh"
trap - ERR
trap cleanup EXIT
# Reproduced with the real upstream installer: custom core/service settings
# still installed the default xray.service. Reject before dependencies/writes.
(
  export XRAYCTL_PLATFORM=systemd
  XRAY_BIN="$TEST_ROOT/custom-xray"
  SERVICE_NAME=custom-xray
  ensure_runtime_dependencies() { fail 'custom systemd install reached dependency writes'; }
  curl() { fail 'custom systemd install downloaded the default installer'; }
  assert_failure install_or_update_xray 26.6.27
  [[ ! -e $XRAY_BIN ]] || fail 'rejected custom install created a core'
)
ensure_system_context() { :; }
_uninstall_snapshot_metadata() { SNAPSHOT_META="$TEST_ROOT/snapshot"; touch "$SNAPSHOT_META"; }
_scan_xrayctl_residuals() { printf -v "$1" '%s' 0; }
service_exists() { return 0; }
service_is_active() { [[ ${ACTIVE:-0} == 1 ]]; }
platform_service_stop() { return 1; }
for step in _uninstall_disable_timers traffic_remove_all _uninstall_remove_managed_certs \
  _uninstall_remove_cloudflare _uninstall_remove_certbot _uninstall_xray_core \
  _uninstall_remove_systemd_overrides _uninstall_remove_runtime_group \
  _uninstall_remove_quick_command _uninstall_remove_bbr _uninstall_remove_owned_jq \
  _cleanup_legacy_resources _uninstall_remove_config _uninstall_remove_logs _uninstall_remove_backups; do
  eval "$step() { touch \"\$TEST_ROOT/deleted\"; }"
done
ACTIVE=1
if uninstall_xray <<<DELETE >"$TEST_ROOT/stop.log" 2>&1; then fail 'full uninstall hid a service stop failure'; fi
[[ ! -e $TEST_ROOT/deleted ]] || fail 'full uninstall deleted data while Xray was running'
ACTIVE=0
_uninstall_xray_core() { return 1; }
_uninstall_remove_config() { touch "$TEST_ROOT/config-deleted"; }
_uninstall_remove_quick_command() { touch "$TEST_ROOT/command-deleted"; }
_uninstall_remove_owned_jq() { touch "$TEST_ROOT/jq-deleted"; }
if uninstall_xray <<<DELETE >"$TEST_ROOT/cleanup.log" 2>&1; then fail 'full uninstall returned success after core removal failed'; fi
[[ -e $TEST_ROOT/deleted ]] || fail 'stopped-service uninstall did not attempt cleanup'
[[ ! -e $TEST_ROOT/config-deleted && ! -e $TEST_ROOT/command-deleted && ! -e $TEST_ROOT/jq-deleted ]] || fail 'failed uninstall removed assets needed for retry'
pass 'custom systemd install refuses default-path writes; uninstall preserves a running service and reports partial failures'
