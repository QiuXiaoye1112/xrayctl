#!/usr/bin/env bash
set -Eeuo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
cd "$ROOT"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

XRAYCTL_TESTING=1 \
XRAYCTL_CONFIG_DIR="$TMP/cfg" \
XRAYCTL_CONFIG_FILE="$TMP/cfg/config.json" \
XRAYCTL_META_FILE="$TMP/meta.json" \
XRAYCTL_TRAFFIC_FILE="$TMP/traffic.json" \
XRAYCTL_CERT_DIR="$TMP/cfg/certs" \
XRAYCTL_LOG_DIR="$TMP/log" \
XRAYCTL_BACKUP_DIR="$TMP/backups" \
XRAYCTL_LOCK_FILE="$TMP/lock" \
bash <<'BASH'
set -Eeuo pipefail
source ./xrayctl.sh

write_default_config
candidate=$(temp_file)
jq '.inbounds=[
  {"protocol":"vless","tag":"vless","listen":"0.0.0.0","port":17225,"settings":{"clients":[]}},
  {"protocol":"socks","tag":"socks","listen":"0.0.0.0","port":5000,"settings":{"accounts":[]}},
  {"protocol":"http","tag":"http","listen":"0.0.0.0","port":24443,"settings":{"accounts":[]}}
]' "$CONFIG_FILE" >"$candidate"
mv -f "$candidate" "$CONFIG_FILE"

# Calendar-month retention clamps missing dates at month end.
[[ $(traffic_months_ago 2026-08-24 3) == 2026-05-24 ]]
[[ $(traffic_months_ago 2024-05-31 3) == 2024-02-29 ]]
[[ $(traffic_months_ago 2025-05-31 3) == 2025-02-28 ]]
[[ $(traffic_limit_next_timestamp '2026-08-07 18:00:00' 7 '18:00:00') == '2026-09-07 18:00:00' ]]
[[ $(traffic_limit_next_timestamp '2026-01-31 18:00:00' 31 '18:00:00') == '2026-02-28 18:00:00' ]]
[[ $(traffic_limit_next_timestamp '2026-02-28 18:00:00' 31 '18:00:00') == '2026-03-31 18:00:00' ]]
[[ $(traffic_limit_first_cycle_end '2026-08-10 12:00:00' 15 '12:34:56') == '2026-08-15 12:34:56' ]]
[[ $(traffic_limit_first_cycle_end '2026-08-20 12:00:00' 15 '12:34:56') == '2026-09-15 12:34:56' ]]
[[ $(traffic_limit_first_cycle_end '2026-01-20 12:00:00' 31 '12:34:56') == '2026-01-31 12:34:56' ]]
traffic_iso_compare '2026-01-31 12:34:56' gt '2026-01-20 12:00:00'
traffic_iso_compare 2026-08-24 ge 2026-08-24
! traffic_iso_compare 2026-08-23 ge 2026-08-24
traffic_validate_date 2024-02-29
! traffic_validate_date 2025-02-29
! traffic_validate_date 2026-13-01
traffic_validate_timestamp '2026-08-07 18:00:00'
! traffic_validate_timestamp '2026-08-07 24:00:00'

XRAYCTL_TRAFFIC_TODAY=2026-08-24
traffic_validate_range 2026-05-24 2026-08-24
traffic_validate_range 2026-08-24 2026-08-24
! traffic_validate_range 2026-05-23 2026-08-24
! traffic_validate_range 2026-08-20 2026-08-19
! traffic_validate_range 2026-08-20 2026-08-25
range_start=old; range_end=old
traffic_prompt_range range_start range_end <<< $'\n\n'
[[ $range_start == 2026-05-24 && $range_end == 2026-08-24 ]]

# Existing 0.5 traffic files gain the quota switch in the disabled state.
printf '%s\n' '{"schema":1,"enabled":false,"backend":"","lastCollectedAt":"","inbounds":{}}' >"$TRAFFIC_FILE"
traffic_init_file
jq -e '.limitsEnabled==false' "$TRAFFIC_FILE" >/dev/null

# Collection adds one sample to the current daily bucket and resets rules only
# after the file was committed. Backend functions are mocked at this boundary.
traffic_set_enabled true
MOCK_COUNTERS=$'vless\t1073741824\nsocks\t2048\nhttp\t4096'
RESTORE_CALLS=0
traffic_read_counters() { printf '%s\n' "$MOCK_COUNTERS"; }
traffic_rules_restore() { RESTORE_CALLS=$((RESTORE_CALLS + 1)); }
traffic_collect
[[ $RESTORE_CALLS == 1 ]]
jq -e '
  .enabled==true and
  .limitsEnabled==false and
  .inbounds.vless.daily["2026-08-24"]==1073741824 and
  .inbounds.socks.daily["2026-08-24"]==2048 and
  .inbounds.http.daily["2026-08-24"]==4096
' "$TRAFFIC_FILE" >/dev/null
last=$(jq -r .lastCollectedAt "$TRAFFIC_FILE")
traffic_sync_inventory
[[ $(jq -r .lastCollectedAt "$TRAFFIC_FILE") == "$last" ]]

output=$(traffic_show 2026-05-24 2026-08-24)
grep -Fq '统计范围：2026-05-24 ～ 2026-08-24' <<<"$output"
grep -Fq '1.00 GB' <<<"$output"
grep -Fq '全部入站：1.00 GB' <<<"$output"
vless_line=$(grep -n '^vless[[:space:]]' <<<"$output" | cut -d: -f1)
socks_line=$(grep -n '^socks[[:space:]]' <<<"$output" | cut -d: -f1)
http_line=$(grep -n '^http[[:space:]]' <<<"$output" | cut -d: -f1)
[[ $vless_line -lt $socks_line && $socks_line -lt $http_line ]]
# jq 1.6 parses `end` as a keyword, so date range filters must not expose it
# as a jq variable even though newer jq releases accept it in some contexts.
! grep -Eq -- '--arg(json)?[[:space:]]+end([[:space:]]|$)' src/traffic.sh

# Entries older than the three-calendar-month cutoff are removed, while the
# cutoff day and current day remain queryable.
tmp=$(temp_file)
jq '.inbounds.vless.daily += {"2026-05-23":100,"2026-05-24":200}' "$TRAFFIC_FILE" >"$tmp"
install -m 600 "$tmp" "$TRAFFIC_FILE"; rm -f "$tmp"
traffic_sync_inventory
jq -e '
  (.inbounds.vless.daily["2026-05-23"] == null) and
  .inbounds.vless.daily["2026-05-24"]==200
' "$TRAFFIC_FILE" >/dev/null

# A rename preserves and merges daily history under the new inbound tag.
tmp=$(temp_file)
jq '(.inbounds[]|select(.tag=="vless")|.tag)="vless-new"' "$CONFIG_FILE" >"$tmp"
mv -f "$tmp" "$CONFIG_FILE"
traffic_sync_inventory
traffic_rename_records vless vless-new
jq -e '
  (.inbounds.vless == null) and
  .inbounds["vless-new"].daily["2026-08-24"]==1073741824 and
  .inbounds["vless-new"].daily["2026-05-24"]==200
' "$TRAFFIC_FILE" >/dev/null

# Deleted inbounds keep their retained history and are marked for display.
tmp=$(temp_file)
jq '.inbounds |= map(select(.tag!="socks"))' "$CONFIG_FILE" >"$tmp"
mv -f "$tmp" "$CONFIG_FILE"
traffic_sync_inventory
jq -e '.inbounds.socks.deleted==true and .inbounds.socks.daily["2026-08-24"]==2048' "$TRAFFIC_FILE" >/dev/null

# Clearing a selected inbound also offers retained records for inbounds that
# have already been removed from the current config.
selection_output=$(temp_file)
selected=""
traffic_select_record_tag selected <<<"3" >"$selection_output"
[[ $selected == socks ]]
grep -Fq '3) socks(已删除)' "$selection_output"
rm -f "$selection_output"
confirm() { return 0; }
traffic_clear_tag_records "$selected" >/dev/null
jq -e '.inbounds.socks.daily|length==0' "$TRAFFIC_FILE" >/dev/null

[[ $(traffic_format_bytes 0) == '0 B' ]]
[[ $(traffic_format_bytes 1024) == '1.00 KB' ]]
[[ $(traffic_format_percent 0 107374182400) == '0.00%' ]]
[[ $(traffic_format_percent 1 107374182400) == '<0.01%' ]]
[[ $(traffic_format_cycle '2026-08-24 11:10:16' '2026-09-24 11:10:16') == '2026-08-24 11:10 → 09-24 11:10' ]]
[[ $(traffic_format_cycle '2026-12-24 11:10:16' '2027-01-24 11:10:16') == '2026-12-24 11:10 → 2027-01-24 11:10' ]]

# Backups include the retained traffic file and restore it atomically with the
# rest of xrayctl state.
traffic_set_enabled false
archive="${TRAFFIC_FILE%/*}/traffic-backup.tar.gz"
require_root() { :; }
ensure_runtime_dependencies() { :; }
backup_all "$archive" >/dev/null
tmp=$(temp_file)
jq '.inbounds["vless-new"].daily["2026-08-24"]=1' "$TRAFFIC_FILE" >"$tmp"
install -m 600 "$tmp" "$TRAFFIC_FILE"; rm -f "$tmp"
confirm() { return 0; }
restart_service() { return 0; }
validate_candidate() { return 0; }
setup_certificate_access() { mkdir -p "$CERT_DIR"; }
setup_runtime_access() { :; }
restore_backup "$archive" >/dev/null
jq -e '.inbounds["vless-new"].daily["2026-08-24"]==1073741824' "$TRAFFIC_FILE" >/dev/null
BASH

# Monthly limits start at the exact creation time, retain that anchor when the
# quota changes, block only at the quota, and roll over at the next timestamp.
XRAYCTL_TESTING=1 \
XRAYCTL_TRAFFIC_BACKEND=nft \
XRAYCTL_TRAFFIC_TODAY=2026-08-07 \
XRAYCTL_TRAFFIC_NOW='2026-08-07 18:00:00' \
XRAYCTL_CONFIG_DIR="$TMP/limits/cfg" \
XRAYCTL_CONFIG_FILE="$TMP/limits/cfg/config.json" \
XRAYCTL_META_FILE="$TMP/limits/meta.json" \
XRAYCTL_TRAFFIC_FILE="$TMP/limits/traffic.json" \
XRAYCTL_CERT_DIR="$TMP/limits/cfg/certs" \
XRAYCTL_LOG_DIR="$TMP/limits/log" \
XRAYCTL_LOCK_FILE="$TMP/limits/lock" \
bash <<'BASH_LIMITS'
set -Eeuo pipefail
source ./xrayctl.sh
write_default_config
tmp=$(temp_file)
jq '.inbounds=[{"protocol":"vless","tag":"vless","listen":"0.0.0.0","port":17225,"settings":{"clients":[]}}]' "$CONFIG_FILE" >"$tmp"
mv -f "$tmp" "$CONFIG_FILE"
traffic_set_backend nft
traffic_set_enabled true
traffic_sync_inventory
! traffic_limits_are_enabled
MOCK_COUNTERS=""
traffic_read_counters() { printf '%s' "$MOCK_COUNTERS"; }
traffic_rules_restore() { :; }
traffic_limits_enable >/dev/null
traffic_limits_are_enabled
traffic_limits_disable >/dev/null
! traffic_limits_are_enabled
traffic_limits_enable >/dev/null
traffic_limit_set vless 1 7 >/dev/null
jq -e '
  .limitsEnabled==true and
  .inbounds.vless.limit.quotaBytes==1073741824 and
  .inbounds.vless.limit.usedBytes==0 and
  .inbounds.vless.limit.cycleStart=="2026-08-07 18:00:00" and
  .inbounds.vless.limit.cycleEnd=="2026-09-07 18:00:00"
' "$TRAFFIC_FILE" >/dev/null
output=$(traffic_limits_show)
grep -Fq '功能：已启用  ·  已设置：1  ·  已禁用：0' <<<"$output"
grep -Fq '流量  0 B / 1.00 GB  (0.00%)' <<<"$output"
grep -Fq '周期  2026-08-07 18:00 → 09-07 18:00' <<<"$output"

MOCK_COUNTERS=$'vless\t536870912\n'
traffic_collect
! traffic_limit_is_blocked vless
MOCK_COUNTERS=$'vless\t536870912\n'
traffic_collect
traffic_limit_is_blocked vless
output=$(traffic_limits_show)
grep -Fq '已设置：1  ·  已禁用：1' <<<"$output"
grep -Fq '100.00%' <<<"$output"
grep -Fq '已禁用' <<<"$output"
MOCK_COUNTERS=""
traffic_limits_disable >/dev/null
! traffic_limits_are_enabled
! traffic_limit_is_blocked vless
jq -e '.inbounds.vless.limit.usedBytes==1073741824' "$TRAFFIC_FILE" >/dev/null
traffic_limits_enable >/dev/null
traffic_limit_is_blocked vless
! traffic_disable 2>/dev/null
traffic_is_enabled

# Changing only the quota must not restart the billing cycle.
XRAYCTL_TRAFFIC_NOW='2026-08-20 12:34:56'
XRAYCTL_TRAFFIC_TODAY=2026-08-20
MOCK_COUNTERS=""
traffic_limit_set vless 2 7 >/dev/null
jq -e '
  .inbounds.vless.limit.quotaBytes==2147483648 and
  .inbounds.vless.limit.usedBytes==1073741824 and
  .inbounds.vless.limit.cycleStart=="2026-08-07 18:00:00" and
  .inbounds.vless.limit.cycleEnd=="2026-09-07 18:00:00"
' "$TRAFFIC_FILE" >/dev/null

XRAYCTL_TRAFFIC_NOW='2026-09-07 17:59:59'
XRAYCTL_TRAFFIC_TODAY=2026-09-07
traffic_sync_inventory
jq -e '.inbounds.vless.limit.usedBytes==1073741824' "$TRAFFIC_FILE" >/dev/null
XRAYCTL_TRAFFIC_NOW='2026-09-07 18:00:00'
traffic_sync_inventory
jq -e '
  .inbounds.vless.limit.usedBytes==0 and
  .inbounds.vless.limit.cycleStart=="2026-09-07 18:00:00" and
  .inbounds.vless.limit.cycleEnd=="2026-10-07 18:00:00"
' "$TRAFFIC_FILE" >/dev/null
BASH_LIMITS

# nft JSON snapshots are grouped by inbound tag across upload/download rules.
XRAYCTL_TESTING=1 \
XRAYCTL_CONFIG_DIR="$TMP/nft/cfg" \
XRAYCTL_CONFIG_FILE="$TMP/nft/cfg/config.json" \
XRAYCTL_META_FILE="$TMP/nft/meta.json" \
XRAYCTL_TRAFFIC_FILE="$TMP/nft/traffic.json" \
XRAYCTL_CERT_DIR="$TMP/nft/cfg/certs" \
XRAYCTL_LOG_DIR="$TMP/nft/log" \
XRAYCTL_LOCK_FILE="$TMP/nft/lock" \
bash <<'BASH_NFT'
set -Eeuo pipefail
source ./xrayctl.sh
nft() {
  [[ $1 == -j ]] || return 1
  cat <<'JSON'
{"nftables":[
  {"rule":{"comment":"xrayctl-traffic:vless","expr":[{"counter":{"packets":2,"bytes":100}}]}},
  {"rule":{"comment":"xrayctl-traffic:count:vless","expr":[{"counter":{"packets":3,"bytes":250}}]}},
  {"rule":{"comment":"xrayctl-traffic:block:vless","expr":[{"counter":{"packets":4,"bytes":999}}]}},
  {"rule":{"comment":"unrelated","expr":[{"counter":{"packets":1,"bytes":999}}]}},
  {"rule":{"comment":"xrayctl-traffic:socks","expr":[{"counter":{"packets":1,"bytes":50}}]}}
]}
JSON
}
rows=$(traffic_read_nft_counters | sort)
grep -Fxq $'socks\t50' <<<"$rows"
grep -Fxq $'vless\t350' <<<"$rows"
! traffic_clear_nft_rules 2>/dev/null
BASH_NFT

# Real nft JSON includes table and chain objects alongside rule objects. Those
# non-rule nodes must not be mistaken for foreign rules in an xrayctl-owned table.
XRAYCTL_TESTING=1 \
XRAYCTL_CONFIG_DIR="$TMP/nft-owned/cfg" \
XRAYCTL_CONFIG_FILE="$TMP/nft-owned/cfg/config.json" \
XRAYCTL_META_FILE="$TMP/nft-owned/meta.json" \
XRAYCTL_TRAFFIC_FILE="$TMP/nft-owned/traffic.json" \
XRAYCTL_CERT_DIR="$TMP/nft-owned/cfg/certs" \
XRAYCTL_LOG_DIR="$TMP/nft-owned/log" \
XRAYCTL_LOCK_FILE="$TMP/nft-owned/lock" \
CASE_DIR="$TMP/nft-owned" \
bash <<'BASH_NFT_OWNED'
set -Eeuo pipefail
source ./xrayctl.sh
mkdir -p "$CASE_DIR"
nft() {
  if [[ ${1-} == -j ]]; then
    cat <<'JSON'
{"nftables":[
  {"metainfo":{"version":"1.0.9"}},
  {"table":{"family":"inet","name":"xrayctl_traffic"}},
  {"chain":{"family":"inet","table":"xrayctl_traffic","name":"input"}},
  {"chain":{"family":"inet","table":"xrayctl_traffic","name":"output"}},
  {"rule":{"family":"inet","table":"xrayctl_traffic","chain":"input","comment":"xrayctl-traffic:count:vless","expr":[]}}
]}
JSON
    return 0
  fi
  local IFS=' '; printf '%s\n' "$*" >>"$CASE_DIR/nft-calls"
}
traffic_clear_nft_rules
grep -Fxq 'delete table inet xrayctl_traffic' "$CASE_DIR/nft-calls"
BASH_NFT_OWNED

# iptables fallback counts only accounting rules and places DROP rules before
# the counter/RETURN rules for an exhausted inbound.
XRAYCTL_TESTING=1 \
XRAYCTL_TRAFFIC_BACKEND=iptables \
XRAYCTL_TRAFFIC_TODAY=2026-08-24 \
XRAYCTL_TRAFFIC_NOW='2026-08-24 12:01:00' \
XRAYCTL_CONFIG_DIR="$TMP/iptables/cfg" \
XRAYCTL_CONFIG_FILE="$TMP/iptables/cfg/config.json" \
XRAYCTL_META_FILE="$TMP/iptables/meta.json" \
XRAYCTL_TRAFFIC_FILE="$TMP/iptables/traffic.json" \
XRAYCTL_CERT_DIR="$TMP/iptables/cfg/certs" \
XRAYCTL_LOG_DIR="$TMP/iptables/log" \
XRAYCTL_LOCK_FILE="$TMP/iptables/lock" \
CASE_DIR="$TMP/iptables" \
bash <<'BASH_IPTABLES'
set -Eeuo pipefail
source ./xrayctl.sh
trap - ERR
mkdir -p "$CASE_DIR"
command_exists() { [[ ${1-} == iptables ]]; }
write_default_config
tmp=$(temp_file)
jq '.inbounds=[{"protocol":"vless","tag":"vless","listen":"0.0.0.0","port":17225,"settings":{"clients":[]}}]' "$CONFIG_FILE" >"$tmp"
mv -f "$tmp" "$CONFIG_FILE"
traffic_init_file
tmp=$(temp_file)
jq '.enabled=true | .limitsEnabled=true | .backend="iptables" |
  .inbounds.vless={protocol:"vless",port:17225,deleted:false,daily:{},limit:{enabled:true,quotaBytes:100,
    anchorDay:24,anchorTime:"12:00:00",cycleStart:"2026-08-24 12:00:00",cycleEnd:"2026-09-24 12:00:00",usedBytes:100}}' \
  "$TRAFFIC_FILE" >"$tmp"
install -m 600 "$tmp" "$TRAFFIC_FILE"; rm -f "$tmp"

IPTABLES_MODE=read
iptables() {
  if [[ $IPTABLES_MODE == read && ${3-} == -L ]]; then
    cat <<'TABLE'
Chain mock (1 references)
 pkts bytes target prot opt in out source destination
 1 100 RETURN tcp -- * * 0.0.0.0/0 0.0.0.0/0 /* xrayctl-traffic:count:vless */
 1 999 DROP tcp -- * * 0.0.0.0/0 0.0.0.0/0 /* xrayctl-traffic:block:vless */
TABLE
    return 0
  fi
  if [[ ${3-} == -S || ${3-} == -C ]]; then return 1; fi
  local IFS=' '; printf '%s\n' "$*" >>"$CASE_DIR/iptables-calls"
}
rows=$(traffic_read_iptables_counters)
[[ $(grep -Fc $'vless\t100' <<<"$rows") == 2 ]]
! grep -Fq $'vless\t999' <<<"$rows"

IPTABLES_MODE=write
traffic_restore_iptables_rules
drop_line=$(grep -nF -- '--comment xrayctl-traffic:block:vless -j DROP' "$CASE_DIR/iptables-calls" | head -1 | cut -d: -f1)
count_line=$(grep -nF -- '--comment xrayctl-traffic:count:vless -j RETURN' "$CASE_DIR/iptables-calls" | head -1 | cut -d: -f1)
[[ -n $drop_line && -n $count_line && $drop_line -lt $count_line ]]
BASH_IPTABLES

# Rule generation covers ordinary TCP and SOCKS TCP+UDP, and the
# systemd timer is installed as an xrayctl-owned one-minute collector.
mkdir -p "$TMP/runtime/bin" "$TMP/runtime/systemd" "$TMP/runtime/cfg"
printf '#!/usr/bin/env bash\nexit 0\n' >"$TMP/runtime/bin/xrayctl"
chmod 755 "$TMP/runtime/bin/xrayctl"
XRAYCTL_TESTING=1 \
XRAYCTL_TRAFFIC_BACKEND=nft \
XRAYCTL_CONFIG_DIR="$TMP/runtime/cfg" \
XRAYCTL_CONFIG_FILE="$TMP/runtime/cfg/config.json" \
XRAYCTL_META_FILE="$TMP/runtime/meta.json" \
XRAYCTL_TRAFFIC_FILE="$TMP/runtime/traffic.json" \
XRAYCTL_CERT_DIR="$TMP/runtime/cfg/certs" \
XRAYCTL_LOG_DIR="$TMP/runtime/log" \
XRAYCTL_LOCK_FILE="$TMP/runtime/lock" \
XRAYCTL_SYSTEMD_UNIT_DIR="$TMP/runtime/systemd" \
XRAYCTL_COMMAND_PATH="$TMP/runtime/bin/xrayctl" \
XRAYCTL_SYMLINK_PATH="$TMP/runtime/bin/xrayctl-link" \
CASE_DIR="$TMP/runtime" \
bash <<'BASH_RUNTIME'
set -Eeuo pipefail
source ./xrayctl.sh
write_default_config
tmp=$(temp_file)
jq '.inbounds=[
  {"protocol":"vless","tag":"vless","listen":"0.0.0.0","port":17225,"settings":{"clients":[]}},
  {"protocol":"socks","tag":"socks","listen":"0.0.0.0","port":5000,"settings":{"accounts":[]}},
  {"protocol":"http","tag":"http","listen":"0.0.0.0","port":24443,"settings":{"accounts":[]}}
]' "$CONFIG_FILE" >"$tmp"; mv -f "$tmp" "$CONFIG_FILE"
traffic_set_backend nft
traffic_init_file
tmp=$(temp_file)
jq '.limitsEnabled=true | .inbounds.vless={protocol:"vless",port:17225,deleted:false,daily:{},limit:{enabled:true,quotaBytes:100,anchorDay:24,anchorTime:"12:00:00",cycleStart:"2026-08-24 12:00:00",cycleEnd:"2026-09-24 12:00:00",usedBytes:100}}' "$TRAFFIC_FILE" >"$tmp"
install -m 600 "$tmp" "$TRAFFIC_FILE"; rm -f "$tmp"

nft() {
  if [[ $1 == -j ]]; then printf '%s\n' '{"nftables":[]}'; return 0; fi
  local IFS=' '; printf '%s\n' "$*" >>"$CASE_DIR/nft-calls"
}
traffic_rules_restore
grep -Fq 'add rule inet xrayctl_traffic input tcp dport 17225 comment "xrayctl-traffic:block:vless" drop' "$CASE_DIR/nft-calls"
grep -Fq 'add rule inet xrayctl_traffic input tcp dport 17225 counter comment "xrayctl-traffic:count:vless"' "$CASE_DIR/nft-calls"
grep -Fq 'add rule inet xrayctl_traffic input tcp dport 5000 counter comment "xrayctl-traffic:count:socks"' "$CASE_DIR/nft-calls"
grep -Fq 'add rule inet xrayctl_traffic input udp dport 5000 counter comment "xrayctl-traffic:count:socks"' "$CASE_DIR/nft-calls"
grep -Fq 'add rule inet xrayctl_traffic input tcp dport 24443 counter comment "xrayctl-traffic:count:http"' "$CASE_DIR/nft-calls"
! grep -Fq 'xrayctl-traffic:block:socks' "$CASE_DIR/nft-calls"
! grep -Fq 'udp dport 17225' "$CASE_DIR/nft-calls"

platform_init_system() { printf systemd; }
systemctl() { local IFS=' '; printf '%s\n' "$*" >>"$CASE_DIR/systemctl-calls"; }
traffic_timer_install
grep -Fxq 'OnUnitActiveSec=1min' "$TRAFFIC_SYSTEMD_TIMER"
grep -Fxq 'NoNewPrivileges=true' "$TRAFFIC_SYSTEMD_SERVICE"
grep -Fxq 'ProtectSystem=strict' "$TRAFFIC_SYSTEMD_SERVICE"
grep -Fxq "ExecStart=$QUICK_COMMAND internal-traffic-collect" "$TRAFFIC_SYSTEMD_SERVICE"
[[ $(jq -r '.managedResources.trafficService' "$META_FILE") == "$TRAFFIC_SYSTEMD_SERVICE" ]]
[[ $(jq -r '.managedResources.trafficTimer' "$META_FILE") == "$TRAFFIC_SYSTEMD_TIMER" ]]
traffic_timer_remove
[[ ! -e $TRAFFIC_SYSTEMD_SERVICE && ! -e $TRAFFIC_SYSTEMD_TIMER ]]
BASH_RUNTIME

# Returning from either quota-menu state is a successful navigation action;
# it must not bubble the preceding boolean probe's status up to traffic_menu.
XRAYCTL_TESTING=1 bash <<'BASH_MENU_RETURN'
set -Eeuo pipefail
source ./xrayctl.sh
clear_screen() { :; }
traffic_is_enabled() { return 0; }
traffic_collect() { :; }
traffic_limits_show() { :; }
traffic_limits_are_enabled() { return 1; }
traffic_limit_menu <<<"0" >/dev/null
traffic_limits_are_enabled() { return 0; }
traffic_limit_menu <<<"0" >/dev/null
BASH_MENU_RETURN

printf 'traffic accounting unit checks passed.\n'
