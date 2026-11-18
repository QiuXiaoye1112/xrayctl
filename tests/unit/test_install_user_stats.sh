#!/usr/bin/env bash
set -Eeuo pipefail
cd "$(dirname "$0")/../.."
root=$(mktemp -d)
trap 'rm -rf "$root"' EXIT
export XRAYCTL_TESTING=1 XRAYCTL_CONFIG_DIR="$root/config" XRAYCTL_TMP_DIR="$root/tmp"
export XRAYCTL_META_FILE="$root/meta.json" XRAYCTL_TRAFFIC_FILE="$root/traffic.json" XRAYCTL_LOCK_FILE="$root/lock"
export XRAYCTL_LOG_DIR="$root/log" XRAYCTL_XRAY_BIN="${XRAYCTL_REAL_XRAY_BIN:-$root/missing-xray}"
if [[ -n ${XRAYCTL_REAL_XRAY_BIN:-} && -f $(dirname "$XRAYCTL_REAL_XRAY_BIN")/geoip.dat ]]; then
  export XRAYCTL_SHARE_DIR
  XRAYCTL_SHARE_DIR=$(dirname "$XRAYCTL_REAL_XRAY_BIN")
fi
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
# A first install must create its runtime group before the prepared config is
# installed with that group. Simulate the group being absent until setup.
(
  rm -f "$CONFIG_FILE" "$META_FILE"
  RUNTIME_GROUP="xrayctl-missing-test-group-$$"
  XRAY_BIN="$root/fake-xray"
  printf '#!/bin/sh\nprintf "Xray fixture\\n"\n' >"$XRAY_BIN"
  chmod +x "$XRAY_BIN"
  ensure_runtime_dependencies() { :; }
  _service_snapshot_existing_config() { printf -v "$1" '%s' ''; }
  _service_restore_or_initialize_config() { write_default_config; }
  platform_init_system() { printf openrc; }
  install_xray_core_openrc() { :; }
  setup_runtime_access() { RUNTIME_GROUP=$(id -gn); }
  write_openrc_service() { :; }
  install_quick_command() { :; }
  platform_service_enable() { :; }
  restart_service() { :; }
  traffic_runtime_ensure() { :; }
  install_or_update_xray >/dev/null
  jq -e '.xrayctlUserStats.enabled==true and .api.listen=="127.0.0.1:49123"' "$CONFIG_FILE" >/dev/null
  # A retry may already have a configuration from the interrupted install.
  # Exercise the real snapshot and restore paths with the group absent again.
  eval "$(sed -n '/^_service_snapshot_existing_config() {/,/^}/p' src/service.sh)"
  eval "$(sed -n '/^_service_restore_or_initialize_config() {/,/^}/p' src/service.sh)"
  RUNTIME_GROUP="xrayctl-missing-test-group-$$"
  install_or_update_xray >/dev/null
  jq -e '.xrayctlUserStats.enabled==true and .api.listen=="127.0.0.1:49123"' "$CONFIG_FILE" >/dev/null
)
(
  rm -f "$CONFIG_FILE" "$META_FILE" "$root/user-created"
  RUNTIME_USER="xrayctl-missing-test-user-$$"
  RUNTIME_GROUP=$(id -gn)
  XRAY_BIN="$root/fake-xray"
  printf '#!/bin/sh\nprintf "Xray fixture\\n"\n' >"$XRAY_BIN"
  chmod +x "$XRAY_BIN"
  ensure_runtime_dependencies() { :; }
  _service_snapshot_existing_config() { printf -v "$1" '%s' ''; }
  _service_restore_or_initialize_config() { write_default_config; }
  platform_init_system() { printf systemd; }
  curl() {
    local out=""
    while (($# > 0)); do
      if [[ $1 == -o ]]; then out=$2; shift 2; continue; fi
      shift
    done
    [[ -z $out ]] || printf '#!/usr/bin/env bash\n[[ -f "%s" ]] || exit 1\n: >"%s"\n' "$CONFIG_FILE" "$root/user-created" >"$out"
  }
  id() {
    if [[ ${1-} == "$RUNTIME_USER" ]]; then
      [[ -f $root/user-created ]]
      return
    fi
    command id "$@"
  }
  setup_runtime_access() { :; }
  install_quick_command() { :; }
  platform_service_enable() { :; }
  restart_service() { :; }
  traffic_runtime_ensure() { :; }
  install_or_update_xray >/dev/null
  jq -e --arg user "$RUNTIME_USER" '.managedResources.runtimeUserOwned==$user' "$META_FILE" >/dev/null

  rm -f "$CONFIG_FILE" "$META_FILE"
  : >"$root/user-created"
  install_or_update_xray >/dev/null
  jq -e '.managedResources.runtimeUserOwned==null' "$META_FILE" >/dev/null

  filtered=$(printf 'Downloading verification file\nwarning: Failed to enable and start the Xray service\ninfo: Xray 26.6.27 is installed.\n' | _service_install_output)
  [[ $filtered != *'Failed to enable and start'* && $filtered == *'核心安装完成'* ]]
)
printf 'ok - install prepares user stats without extra restart or altering conflicting APIs\n'
