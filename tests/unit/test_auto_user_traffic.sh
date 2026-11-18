#!/usr/bin/env bash
set -Eeuo pipefail
cd "$(dirname "$0")/../.."
root=$(mktemp -d)
trap 'rm -rf "$root"' EXIT
export XRAYCTL_TESTING=1 XRAYCTL_CONFIG_DIR="$root/config" XRAYCTL_META_FILE="$root/meta.json"
export XRAYCTL_TRAFFIC_FILE="$root/traffic.json" XRAYCTL_LOCK_FILE="$root/lock" XRAYCTL_TMP_DIR="$root/tmp"
export XRAYCTL_XRAY_BIN="$root/missing-xray" XRAYCTL_LOG_DIR="$root/log"
source ./xrayctl.sh
trap 'rm -rf "$root"' EXIT
write_default_config
traffic_user_choose_address() { printf '127.0.0.1:49123'; }
candidate=$(temp_file)
jq '.inbounds=[{tag:"first",protocol:"vless",port:443,settings:{clients:[{id:"123e4567-e89b-12d3-a456-426614174000",email:"alice"}],decryption:"none"}}]' "$CONFIG_FILE" >"$candidate"
capture_candidate() { cp "$1" "$root/result.json"; }
state_apply_candidate_file "$candidate" capture_candidate
jq -e '.xrayctlUserStats.enabled==true and .api.listen=="127.0.0.1:49123" and .inbounds[0].settings.clients[0].xrayctlLabel=="alice" and (.inbounds[0].settings.clients[0].email|startswith("xrayctl-user-"))' "$root/result.json" >/dev/null
# An existing conflicting API must not be overwritten or block adding a node.
candidate=$(temp_file)
jq '.api={tag:"external",listen:"0.0.0.0:12345",services:["HandlerService"]} | .inbounds=[{tag:"first",protocol:"vless",port:443,settings:{clients:[{id:"123e4567-e89b-12d3-a456-426614174000",email:"alice"}],decryption:"none"}}]' "$CONFIG_FILE" >"$candidate"
state_apply_candidate_file "$candidate" capture_candidate
jq -e '.api.listen=="0.0.0.0:12345" and .xrayctlUserStats==null and .inbounds[0].settings.clients[0].email=="alice"' "$root/result.json" >/dev/null
# The collector must attempt legacy setup before locking and continue inbound
# collection after setup fails. No users or a recursion guard must skip setup.
traffic_is_enabled() { return 0; }
traffic_require_root() { :; }
traffic_user_managed_config() { return 1; }
traffic_user_has_clients() { [[ ${has_clients:-1} == 1 ]]; }
traffic_user_enable() { : >"$root/setup-attempted"; return 1; }
traffic_lock_acquire() { : >"$root/collector-continued"; return 1; }
traffic_collect >/dev/null 2>&1 || true
[[ -f $root/setup-attempted && -f $root/collector-continued ]]
rm -f "$root/setup-attempted" "$root/collector-continued"
has_clients=0
traffic_collect >/dev/null 2>&1 || true
[[ ! -f $root/setup-attempted && -f $root/collector-continued ]]
rm -f "$root/collector-continued"
has_clients=1
XRAYCTL_USER_STATS_INITIALIZING=1 traffic_collect >/dev/null 2>&1 || true
[[ ! -f $root/setup-attempted && -f $root/collector-continued ]]
# A legacy installation initializes once through the real enable function.
# Its runtime check invokes the collector recursively, which must not recurse
# into initialization a second time or count the same sample twice.
(
  eval "$(sed -n '/^traffic_user_enable() {/,/^}/p' src/traffic.sh)"
  eval "$(sed -n '/^traffic_user_has_clients() {/,/^}/p' src/traffic.sh)"
  eval "$(sed -n '/^traffic_user_managed_config() {/,/^}/p' src/traffic.sh)"
  eval "$(sed -n '/^traffic_lock_acquire() {/,/^}/p' src/traffic.sh)"
  eval "$(sed -n '/^traffic_require_root() {/,/^}/p' src/traffic.sh)"
  cp "$root/result.json" "$root/conflict.json"
  jq 'del(.api,.stats,.policy,.xrayctlUserStats)' "$root/result.json" >"$CONFIG_FILE"
  traffic_default_json >"$TRAFFIC_FILE"
  XRAYCTL_MANAGEMENT_LOCK_HELD=1
  platform_init_system() { printf systemd; }
  TRAFFIC_SYSTEMD_SERVICE="$root/collector.service"
  printf '%s\n' "$CONFIG_DIR" >"$TRAFFIC_SYSTEMD_SERVICE"
  ensure_config() { :; }
  require_xray_installed() { :; }
  traffic_runtime_ensure() { traffic_collect; }
  traffic_read_counters() { printf 'first\t100\n'; }
  traffic_user_collect_locked() { :; }
  traffic_user_collect_serialized() { :; }
  traffic_user_reconcile() { :; }
  traffic_rules_restore() { :; }
  state_commit() { cp "$1" "$CONFIG_FILE"; printf 'restart\n' >>"$root/restarts"; }
  traffic_collect
  jq -e '.xrayctlUserStats.enabled==true' "$CONFIG_FILE" >/dev/null
  [[ $(wc -l <"$root/restarts") -eq 1 ]]
  traffic_collect
  [[ $(wc -l <"$root/restarts") -eq 1 ]]
)
printf 'ok - user stats initialize automatically without blocking inbound collection\n' 
