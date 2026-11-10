#!/usr/bin/env bash
set -Eeuo pipefail
if [[ ${XRAYCTL_TEST_SYSTEMD:-0} != 1 ]]; then printf 'ok - systemd timer test skipped\n'; exit 0; fi
cd "$(dirname "$0")/../.."
root=$(mktemp -d /tmp/xrayctl-timer-test.XXXXXXXX)
name="xrayctl-timer-test-${root##*.}"
cleanup_test() {
  systemctl stop "$name.timer" "$name.service" >/dev/null 2>&1 || true
  systemctl reset-failed "$name.service" >/dev/null 2>&1 || true
  rm -f "/run/systemd/system/$name.timer" "/run/systemd/system/$name.service"
  systemctl daemon-reload
  rm -rf "$root"
}
trap cleanup_test EXIT
export XRAYCTL_TESTING=1 XRAYCTL_SYSTEMD_UNIT_DIR="$root" XRAYCTL_COMMAND_PATH=/bin/true
source ./xrayctl.sh
trap cleanup_test EXIT
platform_init_system() { printf systemd; }
systemctl() { local IFS=' '; printf '%s\n' "$*" >>"$root/calls"; }
meta_resource_register() { :; }
traffic_timer_install
grep -Fxq 'restart xrayctl-traffic-collect.timer' "$root/calls"
unset -f systemctl
# Exercise generated settings using independent units and shorter intervals.
sed -e 's/OnActiveSec=1min/OnActiveSec=1s/' -e 's/OnUnitInactiveSec=1min/OnUnitInactiveSec=1s/' -e 's/RandomizedDelaySec=5s/RandomizedDelaySec=0/' "$TRAFFIC_SYSTEMD_TIMER" >"/run/systemd/system/$name.timer"
printf '[Service]\nType=oneshot\nExecStart=/bin/true\n' >"/run/systemd/system/$name.service"
systemctl daemon-reload
systemctl start "$name.timer"
sleep 4
first=$(systemctl show "$name.timer" -p LastTriggerUSec --value)
[[ -n $first ]]
systemctl stop "$name.timer"
sleep 3
systemctl start "$name.timer"
sleep 4
second=$(systemctl show "$name.timer" -p LastTriggerUSec --value)
[[ -n $second && $first != "$second" ]]
[[ $(systemctl show "$name.timer" -p SubState --value) != elapsed ]]
systemctl stop "$name.timer"
printf '[Service]\nType=oneshot\nExecStart=/bin/false\n' >"/run/systemd/system/$name.service"
systemctl daemon-reload
systemctl start "$name.timer"
sleep 4
failed_first=$(systemctl show "$name.timer" -p LastTriggerUSec --value)
sleep 3
failed_second=$(systemctl show "$name.timer" -p LastTriggerUSec --value)
[[ -n $failed_first && $failed_first != "$failed_second" ]]
printf 'ok - generated timer re-arms after stop/start and continues triggering\n'
