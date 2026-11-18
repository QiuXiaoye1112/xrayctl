#!/usr/bin/env bash
set -Eeuo pipefail
cd "$(dirname "$0")/../.."
root=$(mktemp -d)
trap 'rm -rf "$root"' EXIT
export XRAYCTL_TESTING=1 XRAYCTL_CONFIG_DIR="$root/config" XRAYCTL_TRAFFIC_FILE="$root/traffic.json"
export XRAYCTL_CERT_DIR="$root/certs" XRAYCTL_LOG_DIR="$root/log" XRAYCTL_BACKUP_DIR="$root/backups"
export XRAYCTL_LOCK_FILE="$root/lock" XRAYCTL_META_FILE="$root/meta.json" XRAYCTL_TMP_DIR="$root/tmp"
export XRAYCTL_XRAY_BIN="$root/missing-xray" XRAYCTL_TRAFFIC_NOW="2026-11-18 12:00:00"
source ./xrayctl.sh
trap 'rm -rf "$root"' EXIT
write_default_config
traffic_init_file
traffic_set_backend iptables
epoch=$(cat /proc/sys/kernel/random/boot_id 2>/dev/null || printf unknown)
tmp=$(temp_file)
jq --arg epoch "$epoch" '.rulesInventory={} | .rulesEpoch=$epoch | .totals.daily["2026-11-17"]=12345' "$TRAFFIC_FILE" >"$tmp"
traffic_write_file "$tmp"
rm -f "$tmp"
traffic_user_collect_locked() { :; }
traffic_user_reconcile() { :; }
# Exercise the real inventory/restore decisions with simulated kernel rules.
traffic_backend() { printf iptables; }
traffic_clear_iptables_rules() { rm -f "$root/rules-created"; }
traffic_restore_iptables_rules() {
  if jq -e '.inbounds | length > 0' "$CONFIG_FILE" >/dev/null; then
    printf 'create\n' >>"$root/rule-installs"
    : >"$root/rules-created"
  fi
}
traffic_read_counters() {
  [[ -f $root/rules-created && ${fail_read:-0} == 0 ]] || return 1
  printf 'iptables:in:first\t100\n'
}
# No inbounds means no chains; an empty sample should still succeed.
traffic_collect
traffic_rules_restore_serialized
[[ ! -e $root/rules-created ]]
jq -e '.rulesInventory=={} and .lastCollectedAt!=""' "$TRAFFIC_FILE" >/dev/null
# Adding the first inbound creates rules before the first read. If that read
# fails, the new inventory must survive so retries don't reset live counters.
tmp=$(temp_file)
jq '.inbounds=[{tag:"first",protocol:"vless",port:443,settings:{clients:[],decryption:"none"}}]' "$CONFIG_FILE" >"$tmp"
mv -f "$tmp" "$CONFIG_FILE"
cp "$CONFIG_FILE" "$root/with-inbound.json"
fail_read=1
if traffic_collect; then printf 'failed sample unexpectedly succeeded\n' >&2; exit 1; fi
[[ -f $root/rules-created ]]
jq -e '.rulesInventory.first.port==443' "$TRAFFIC_FILE" >/dev/null
# A retry samples the existing rules instead of rebuilding them.
fail_read=0
traffic_collect
jq -e '.rulesInventory.first.port==443 and .kernelCounters["iptables:in:first"]==100 and .inbounds.first!=null and .totals.daily["2026-11-17"]==12345' "$TRAFFIC_FILE" >/dev/null
[[ $(wc -l <"$root/rule-installs") -eq 1 ]]

# Deleting the final inbound samples the old rules before removing them.
write_default_config
traffic_collect
jq -e '.rulesInventory == {} and .inbounds.first.deleted' "$TRAFFIC_FILE" >/dev/null
[[ ! -e $root/rules-created ]]
traffic_collect

# A previous boot may have left only the empty rule inventory, with no
# successful sample yet. Creating an inbound still establishes rules.
jq '.rulesEpoch="previous-boot" | del(.kernelCounterEpoch)' "$TRAFFIC_FILE" >"$root/old-state.json"
traffic_write_file "$root/old-state.json"
cp "$root/with-inbound.json" "$CONFIG_FILE"
traffic_collect
[[ $(wc -l <"$root/rule-installs") -eq 2 ]]
jq -e --arg epoch "$epoch" '.rulesInventory.first.port==443 and .rulesEpoch==$epoch and .inbounds.first.deleted==false and .totals.daily["2026-11-18"]==400' "$TRAFFIC_FILE" >/dev/null
printf 'ok - empty install, last inbound removal, and first inbound after reboot collect safely\n'
