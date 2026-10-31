#!/usr/bin/env bash
set -Eeuo pipefail
REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/xrayctl-maintenance.XXXXXX")
cleanup() { rm -rf "$TEST_ROOT"; }
trap cleanup EXIT
export XRAYCTL_TESTING=1 XRAYCTL_TMP_DIR="$TEST_ROOT/tmp"
export XRAYCTL_CONFIG_DIR="$TEST_ROOT/config" XRAYCTL_META_FILE="$TEST_ROOT/config/meta.json"
export XRAYCTL_XRAY_BIN="$TEST_ROOT/bin/xray" XRAYCTL_SHARE_DIR="$TEST_ROOT/share"
export XRAYCTL_SERVICE_NAME=xrayctl-maintenance-test XRAYCTL_SYSTEMD_UNIT_DIR="$TEST_ROOT/units"
export XRAYCTL_OPENRC_SERVICE="$TEST_ROOT/init/xrayctl-maintenance-test"
export XRAYCTL_BBR_CONFIG="$TEST_ROOT/xrayctl-bbr.conf" XRAYCTL_SBCTL_BBR_CONFIG="$TEST_ROOT/sbctl-bbr.conf"
export XRAYCTL_TRAFFIC_FILE="$TEST_ROOT/traffic.json"
export XRAYCTL_LOCK_FILE="$TEST_ROOT/lock"
export XRAYCTL_CERTBOT_VENV="$TEST_ROOT/certbot"
export XRAYCTL_CERTBOT_CONFIG_DIR="$TEST_ROOT/letsencrypt"
source "$REPO_ROOT/tests/helpers/assert.sh"
source "$REPO_ROOT/xrayctl.sh"
trap - ERR
trap cleanup EXIT
mkdir -p "$TEST_ROOT/bin" "$XRAY_SHARE_DIR" "$SYSTEMD_UNIT_DIR" "$TEST_ROOT/init"
printf 'keep unrelated\n' >"$TEST_ROOT/unrelated"
platform_service_stop() { :; }
platform_service_disable() { :; }
platform_daemon_reload() { :; }
service_is_active() { return 1; }
systemctl() { fail 'custom service removal attempted to control another systemd unit'; }
curl() { fail 'custom resource removal attempted to run the default remote installer'; }
XRAYCTL_PLATFORM=systemd
touch "$XRAY_BIN" "$XRAY_SHARE_DIR/geoip.dat" "$SYSTEMD_UNIT_DIR/$SYSTEMD_UNIT"
_uninstall_xray_core
[[ ! -e $XRAY_BIN && ! -e $XRAY_SHARE_DIR && ! -e $SYSTEMD_UNIT_DIR/$SYSTEMD_UNIT ]] || fail 'custom systemd resources survived removal'
[[ -f $TEST_ROOT/unrelated ]] || fail 'custom uninstall removed unrelated data'

XRAYCTL_PLATFORM=openrc
mkdir -p "$XRAY_SHARE_DIR"
touch "$XRAY_BIN" "$OPENRC_SERVICE" "$XRAY_SHARE_DIR/geosite.dat"
_uninstall_xray_core
[[ ! -e $XRAY_BIN && ! -e $OPENRC_SERVICE && ! -e $XRAY_SHARE_DIR ]] || fail 'OpenRC fallback ignored configured resource paths'

touch "$XRAY_BIN"
service_is_active() { return 0; }
assert_failure _uninstall_xray_core_fallback
[[ -f $XRAY_BIN ]] || fail 'uninstall removed a core whose service could not be stopped'
service_is_active() { return 1; }

init_meta
assert_failure traffic_backend_test_guard nft
(
  nft() { :; }
  assert_success traffic_backend_test_guard nft
)
touch "$BBR_CONFIG" "$SBCTL_BBR_CONFIG" "$TEST_ROOT/third-party-sysctl.conf"
assert_eq both "$(bbr_manager)" 'BBR manager did not report shared persistence'
bbr_remove_known_persistence
[[ ! -e $BBR_CONFIG && ! -e $SBCTL_BBR_CONFIG && -f $TEST_ROOT/third-party-sysctl.conf ]] || fail 'BBR cleanup changed unrelated persistence'
touch "$BBR_CONFIG"
meta_resource_register bbrConfig "$BBR_CONFIG"
_uninstall_snapshot_metadata
(
  _disable_bbr() { return 1; }
  assert_failure _uninstall_remove_bbr
  [[ -f $BBR_CONFIG ]] || fail 'failed BBR disable erased its persistence'
  assert_eq "$BBR_CONFIG" "$(jq -r '.managedResources.bbrConfig' "$META_FILE")" 'failed BBR disable erased its ownership record'
)

# Verify official-installer failure propagation without executing network code
# or touching default service paths. The downloaded script is this local stub.
XRAYCTL_PLATFORM=systemd
XRAY_BIN=/usr/local/bin/xray; SERVICE_NAME=xray
SYSTEMD_UNIT_DIR=/etc/systemd/system; XRAY_SHARE_DIR=/usr/local/share/xray
curl() { printf '#!/usr/bin/env bash\nexit 7\n' >"${@: -1}"; }
_uninstall_xray_core_fallback() { fail 'unexpected fallback after official uninstall failure'; }
if _uninstall_xray_core; then fail 'official installer failure was hidden'; fi
pass 'custom systemd/OpenRC removal paths, stop-failure refusal, installer errors, and BBR persistence ownership'
