#!/usr/bin/env bash
REPO_ROOT=$(cd "$(dirname "$0")/../.." && pwd)
set -Eeuo pipefail
case_dir=$(mktemp -d /tmp/xrayctl-bbr-logs-check.XXXXXXXX)
trap 'rm -rf "$case_dir"' EXIT
source "$REPO_ROOT/xrayctl.sh"
trap - ERR
trap 'rm -rf "$case_dir"' EXIT
LOG_DIR="$case_dir/logs"
mkdir "$LOG_DIR"
# Test the non-BBR branch with an injected read-only kernel status fixture.
ensure_system_context() { :; }
_check_bbr_available() { return 0; }
bbr_manager() { printf test-manager; }
_enable_bbr() { touch "$case_dir/enabled"; }
_disable_bbr() { touch "$case_dir/disabled"; }
bbr_definition=$(declare -f manage_bbr)
bbr_definition=${bbr_definition//\/proc\/sys\/net\/ipv4\/tcp_congestion_control/$case_dir/current}
eval "$bbr_definition"
printf cubic > "$case_dir/current"
manage_bbr </dev/null > "$case_dir/cubic.out"
[[ ! -e "$case_dir/enabled" && ! -e "$case_dir/disabled" ]]
grep -q '非交互模式下跳过 BBR 配置' "$case_dir/cubic.out"
printf bbr > "$case_dir/current"
manage_bbr </dev/null > "$case_dir/bbr.out"
[[ ! -e "$case_dir/enabled" && ! -e "$case_dir/disabled" ]]
# Verify requested line limits, both platforms, a missing error file and journal failures.
printf 'error-1\nerror-2\nerror-3\n' > "$LOG_DIR/error.log"
platform_init_system() { printf systemd; }
journalctl() { printf 'journal-marker\n'; }
platform_service_logs 2 > "$case_dir/systemd.out"
grep -q journal-marker "$case_dir/systemd.out"
grep -q error-2 "$case_dir/systemd.out"
grep -q error-3 "$case_dir/systemd.out"
if grep -q error-1 "$case_dir/systemd.out"; then
  printf 'log output exceeded the requested line count\n' >&2; exit 1
fi
journalctl() { return 7; }
if platform_service_logs 2 > "$case_dir/failed-journal.out"; then
  printf 'journal failure was swallowed\n' >&2; exit 1
else
  log_rc=$?
fi
[[ $log_rc == 7 ]]
grep -q error-3 "$case_dir/failed-journal.out"
platform_init_system() { printf openrc; }
printf 'openrc-error-marker\n' > "$LOG_DIR/openrc-error.log"
printf 'openrc-output-marker\n' > "$LOG_DIR/openrc.log"
platform_service_logs 2 > "$case_dir/openrc.out"
grep -q openrc-error-marker "$case_dir/openrc.out"
grep -q openrc-output-marker "$case_dir/openrc.out"
grep -q error-3 "$case_dir/openrc.out"
rm "$LOG_DIR/error.log"
platform_init_system() { printf systemd; }
journalctl() { :; }
platform_service_logs 2 > "$case_dir/no-error-file.out"
grep -q '尚未生成 Xray 错误日志' "$case_dir/no-error-file.out"
printf 'isolated noninteractive BBR and systemd/OpenRC log checks passed\n'
