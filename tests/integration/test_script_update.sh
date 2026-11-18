#!/usr/bin/env bash
set -Eeuo pipefail
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
case_dir=$(mktemp -d "${TMPDIR:-/tmp}/xrayctl-script-update.XXXXXXXX")
trap 'rm -rf "$case_dir"' EXIT
export XRAYCTL_TESTING=1 XRAYCTL_CONFIG_DIR="$case_dir/config" XRAYCTL_META_FILE="$case_dir/meta.json"
export XRAYCTL_TRAFFIC_FILE="$case_dir/traffic.json" XRAYCTL_LOCK_FILE="$case_dir/lock"
export XRAYCTL_TMP_DIR="$case_dir/tmp" XRAYCTL_OPENRC_INIT_DIR="$case_dir/openrc"
source "$root/xrayctl.sh"
trap 'rm -rf "$case_dir"' EXIT
mkdir -p "$case_dir/openrc"
events="$case_dir/events"
ensure_runtime_dependencies() { printf 'dependencies\n' >>"$events"; }
install_quick_command() { printf 'command\n' >>"$events"; }
traffic_is_enabled() { return 0; }
platform_init_system() { printf '%s' "$init"; }
traffic_systemd_refresh_write_paths() { printf 'systemd-refresh\n' >>"$events"; }
platform_openrc_service() { printf 'openrc:%s:%s\n' "$1" "$2" >>"$events"; }
restart_service() { printf 'unexpected-core-restart\n' >>"$events"; return 1; }
install_xray_core_openrc() { printf 'unexpected-core-install\n' >>"$events"; return 1; }
init=systemd
update_script_resources >/dev/null
[[ $(cat "$events") == $'dependencies\ncommand\nsystemd-refresh' ]]
: >"$events"
init=openrc
printf '#!/bin/sh\n' >"$TRAFFIC_OPENRC_SERVICE"
jq -n --arg unit "$TRAFFIC_OPENRC_SERVICE" '{managedResources:{trafficService:$unit}}' >"$META_FILE"
update_script_resources >/dev/null
[[ $(cat "$events") == $'dependencies\ncommand\nopenrc:xrayctl-traffic-collect:restart' ]]
: >"$events"
jq -n '{managedResources:{}}' >"$META_FILE"
update_script_resources >/dev/null
[[ $(cat "$events") == $'dependencies\ncommand' ]]
printf 'ok - script update refreshes owned collectors without reinstalling or restarting Xray\n'
