#!/usr/bin/env bash
set -Eeuo pipefail
if [[ ${XRAYCTL_TEST_BBR:-0} != 1 ]]; then
  printf 'ok - real BBR writes skipped (set XRAYCTL_TEST_BBR=1 in a private network namespace)\n'; exit 0
fi
[[ $(readlink /proc/self/ns/net) != "$(readlink /proc/1/ns/net)" ]] || { printf 'refusing host BBR writes\n' >&2; exit 1; }
REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/xrayctl-bbr-real.XXXXXX")
cleanup() { rm -rf "$TEST_ROOT"; }
trap cleanup EXIT
export XRAYCTL_TESTING=1 XRAYCTL_TMP_DIR="$TEST_ROOT/tmp"
export XRAYCTL_CONFIG_DIR="$TEST_ROOT/config" XRAYCTL_LOG_DIR="$TEST_ROOT/logs"
export XRAYCTL_TRAFFIC_FILE="$TEST_ROOT/traffic.json" XRAYCTL_LOCK_FILE="$TEST_ROOT/lock"
export XRAYCTL_CERTBOT_VENV="$TEST_ROOT/certbot" XRAYCTL_CERTBOT_CONFIG_DIR="$TEST_ROOT/letsencrypt"
export XRAYCTL_BBR_CONFIG="$TEST_ROOT/bbr.conf" XRAYCTL_SBCTL_BBR_CONFIG="$TEST_ROOT/peer.conf"
source "$REPO_ROOT/tests/helpers/assert.sh"
source "$REPO_ROOT/xrayctl.sh"
trap - ERR
trap cleanup EXIT
# The host already exposes BBR. Kernel module loading is not namespaced.
modprobe() { :; }
_check_bbr_available || { printf 'BBR unavailable in this namespace\n' >&2; exit 1; }
sysctl -q -w net.ipv4.tcp_congestion_control=cubic
mkdir "$BBR_CONFIG"
printf 'keep peer persistence\n' >"$SBCTL_BBR_CONFIG"
if _enable_bbr; then fail 'BBR enable hid a persistence write failure'; fi
assert_eq cubic "$(cat /proc/sys/net/ipv4/tcp_congestion_control)" 'failed enable changed the kernel setting'
[[ -f $SBCTL_BBR_CONFIG ]] || fail 'failed enable removed peer persistence'
rmdir "$BBR_CONFIG"
# Failure after the real sysctl write must also restore the previous value.
mv() { return 1; }
if _enable_bbr; then fail 'BBR enable hid its final persistence commit failure'; fi
unset -f mv
assert_eq cubic "$(cat /proc/sys/net/ipv4/tcp_congestion_control)" 'failed persistence commit did not restore the kernel setting'
[[ -f $SBCTL_BBR_CONFIG && ! -e $BBR_CONFIG ]] || fail 'failed persistence commit changed ownership'
_enable_bbr
assert_eq bbr "$(cat /proc/sys/net/ipv4/tcp_congestion_control)" 'real BBR enable failed'
assert_eq xrayctl "$(bbr_manager)" 'BBR ownership did not follow successful enable'
grep -Fxq net.ipv4.tcp_congestion_control=bbr "$BBR_CONFIG" || fail 'BBR persistence missing'
_disable_bbr
[[ $(cat /proc/sys/net/ipv4/tcp_congestion_control) != bbr && ! -e $BBR_CONFIG ]] || fail 'real BBR disable failed'
pass 'real BBR enable/disable, persistence, and unwritable-config failure in private network namespace'
