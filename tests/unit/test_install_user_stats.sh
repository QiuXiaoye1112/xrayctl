#!/usr/bin/env bash
set -Eeuo pipefail
cd "$(dirname "$0")/../.."
root=$(mktemp -d)
trap 'rm -rf "$root"' EXIT
export XRAYCTL_TESTING=1 XRAYCTL_CONFIG_DIR="$root/config" XRAYCTL_TMP_DIR="$root/tmp"
export XRAYCTL_META_FILE="$root/meta.json" XRAYCTL_TRAFFIC_FILE="$root/traffic.json" XRAYCTL_LOCK_FILE="$root/lock"
export XRAYCTL_LOG_DIR="$root/log" XRAYCTL_XRAY_BIN="${XRAYCTL_REAL_XRAY_BIN:-$root/missing-xray}"
export XRAYCTL_RUNTIME_OWNER XRAYCTL_RUNTIME_GROUP
XRAYCTL_RUNTIME_OWNER=$(id -un); XRAYCTL_RUNTIME_GROUP=$(id -gn)
source ./xrayctl.sh
trap 'rm -rf "$root"' EXIT
write_default_config
mkdir -p "$XRAYCTL_LOG_DIR"
traffic_user_choose_address() { printf '127.0.0.1:49123'; }
if [[ -z ${XRAYCTL_REAL_XRAY_BIN:-} ]]; then validate_candidate() { return 0; }; fi
restart_service() { printf 'unexpected restart\n' >&2; return 1; }
_service_prepare_user_stats
jq -e '.inbounds==[] and .xrayctlUserStats.enabled==true and .api.listen=="127.0.0.1:49123" and (.api.services|index("StatsService"))!=null' "$CONFIG_FILE" >/dev/null
before=$(cat "$CONFIG_FILE")
_service_prepare_user_stats
[[ $(cat "$CONFIG_FILE") == "$before" ]]
# An incompatible pre-existing API must never be changed by installation.
jq '.api={tag:"external",listen:"0.0.0.0:12345",services:["HandlerService"]} | del(.xrayctlUserStats)' "$CONFIG_FILE" >"$root/conflict.json"
cp "$root/conflict.json" "$CONFIG_FILE"
before=$(cat "$CONFIG_FILE")
_service_prepare_user_stats 2>/dev/null
[[ $(cat "$CONFIG_FILE") == "$before" ]]
printf 'ok - install prepares user stats without extra restart or altering conflicting APIs\n'
