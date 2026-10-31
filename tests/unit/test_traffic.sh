#!/usr/bin/env bash
set -Eeuo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
cd "$ROOT"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

XRAYCTL_TESTING=1 \
XRAYCTL_XRAY_BIN="$TMP/missing-xray" \
XRAYCTL_TRAFFIC_NOW='2026-08-24 12:00:00' \
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
traffic_init_file
jq -e '.enabled==true' "$TRAFFIC_FILE" >/dev/null

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
traffic_validate_range 2026-08-01 2026-08-24
traffic_validate_range 2026-08-24 2026-08-24
! traffic_validate_range 2026-07-31 2026-08-24
! traffic_validate_range 2026-08-20 2026-08-19
! traffic_validate_range 2026-08-20 2026-08-25
range_start=old; range_end=old
traffic_prompt_range range_start range_end <<< $'\n\n'
[[ $range_start == 2026-08-01 && $range_end == 2026-08-24 ]]

# Legacy traffic files retain aggregate statistics while inbound quota fields
# are discarded; per-user quota state lives in each inbound's users object.
printf '%s\n' '{"schema":1,"enabled":false,"backend":"","lastCollectedAt":"","inbounds":{}}' >"$TRAFFIC_FILE"
traffic_init_file
jq -e '.enabled==true and (has("limitsEnabled")|not)' "$TRAFFIC_FILE" >/dev/null

# Existing client-side totals are converted once, including quota usage.
tmp=$(temp_file)
jq '.periodsSeeded=true | .inbounds.vless={protocol:"vless",port:17225,daily:{"2026-08-24":100},cycles:{"2026-08-01 00:00:00":100},limit:{quotaBytes:1000,usedBytes:30},users:{"email-id":{label:"alice",limit:{enabled:true,quotaBytes:1000,usedBytes:30}}}}' "$TRAFFIC_FILE" >"$tmp"
install -m 600 "$tmp" "$TRAFFIC_FILE"; rm -f "$tmp"
traffic_sync_inventory
traffic_sync_inventory
jq -e '.accountingMultiplier==2 and .inbounds.vless.daily["2026-08-24"]==200 and .inbounds.vless.cycles["2026-08-01 00:00:00"]==200 and .inbounds.vless.limit==null and .inbounds.vless.users["email-id"].limit.usedBytes==30 and (has("limitsEnabled")|not)' "$TRAFFIC_FILE" >/dev/null
tmp=$(temp_file); traffic_default_json >"$tmp"
install -m 600 "$tmp" "$TRAFFIC_FILE"; rm -f "$tmp"

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
  (has("limitsEnabled")|not) and
  .accountingMultiplier==2 and
  .inbounds.vless.daily["2026-08-24"]==2147483648 and
  .inbounds.socks.daily["2026-08-24"]==4096 and
  .inbounds.http.daily["2026-08-24"]==8192
' "$TRAFFIC_FILE" >/dev/null

# A failed rule rebuild must not commit counters that will be read again on
# the next retry.
before_retry=$(jq -S . "$TRAFFIC_FILE")
traffic_rules_restore() { return 1; }
traffic_collect || true
traffic_collect || true
[[ $before_retry == "$(jq -S . "$TRAFFIC_FILE")" ]] || {
  printf 'failed rule rebuild double-counted traffic\n' >&2
  exit 1
}
traffic_rules_restore() { RESTORE_CALLS=$((RESTORE_CALLS + 1)); }
last=$(jq -r .lastCollectedAt "$TRAFFIC_FILE")
traffic_sync_inventory
[[ $(jq -r .lastCollectedAt "$TRAFFIC_FILE") == "$last" ]]

output=$(traffic_show 2026-08-01 2026-08-24)
! grep -Fq '统计口径' <<<"$output"
grep -Fq '统计范围：2026-08-01 ～ 2026-08-24' <<<"$output"
grep -Fq '2.00 GB' <<<"$output"
grep -Fq '全部入站：2.00 GB' <<<"$output"
vless_line=$(grep -n '^vless[[:space:]]' <<<"$output" | cut -d: -f1)
socks_line=$(grep -n '^socks[[:space:]]' <<<"$output" | cut -d: -f1)
http_line=$(grep -n '^http[[:space:]]' <<<"$output" | cut -d: -f1)
[[ $vless_line -lt $socks_line && $socks_line -lt $http_line ]]
# jq 1.6 parses `end` as a keyword, so date range filters must not expose it
# as a jq variable even though newer jq releases accept it in some contexts.
! grep -Eq -- '--arg(json)?[[:space:]]+end([[:space:]]|$)' src/traffic.sh

# Entries before the current period are removed, while its first date remains.
tmp=$(temp_file)
jq '.inbounds.vless.daily += {"2026-07-31":100,"2026-08-01":200}' "$TRAFFIC_FILE" >"$tmp"
install -m 600 "$tmp" "$TRAFFIC_FILE"; rm -f "$tmp"
traffic_sync_inventory
jq -e '
  (.inbounds.vless.daily["2026-07-31"] == null) and
  .inbounds.vless.daily["2026-08-01"]==200
' "$TRAFFIC_FILE" >/dev/null

# A rename preserves and merges daily history under the new inbound tag.
tmp=$(temp_file)
jq '(.inbounds[]|select(.tag=="vless")|.tag)="vless-new"' "$CONFIG_FILE" >"$tmp"
mv -f "$tmp" "$CONFIG_FILE"
traffic_sync_inventory
traffic_rename_records vless vless-new
jq -e '
  (.inbounds.vless == null) and
  .inbounds["vless-new"].daily["2026-08-24"]==2147483648 and
  .inbounds["vless-new"].daily["2026-08-01"]==200
' "$TRAFFIC_FILE" >/dev/null

# Deleted inbounds keep their retained history and are marked for display.
tmp=$(temp_file)
jq '.inbounds |= map(select(.tag!="socks"))' "$CONFIG_FILE" >"$tmp"
mv -f "$tmp" "$CONFIG_FILE"
traffic_sync_inventory
jq -e '.inbounds.socks.deleted==true and .inbounds.socks.daily["2026-08-24"]==4096' "$TRAFFIC_FILE" >/dev/null

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
jq -e '.inbounds.socks==null' "$TRAFFIC_FILE" >/dev/null

[[ $(traffic_format_bytes 0) == '0 B' ]]
[[ $(traffic_format_bytes 1024) == '1.00 KB' ]]

# Backups include the retained traffic file and restore it atomically with the
# rest of xrayctl state.
if traffic_set_enabled false >/dev/null 2>&1; then
  printf 'traffic stats were unexpectedly disabled\n' >&2
  exit 1
fi
jq -e '.enabled==true' "$TRAFFIC_FILE" >/dev/null
traffic_disable >/dev/null
jq -e '.enabled==true' "$TRAFFIC_FILE" >/dev/null
traffic_collect() { :; }
traffic_ensure_backend() { :; }
traffic_sync_inventory() { :; }
traffic_rules_restore_serialized() { :; }
traffic_timer_install() { :; }
traffic_runtime_stop() { :; }
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
jq -e '.inbounds["vless-new"].daily["2026-08-24"]==2147483648' "$TRAFFIC_FILE" >/dev/null

# Runtime setup automatically migrates stopped installations and installs the
# existing collector backend/timer without a separate user toggle.
printf '%s\n' '{"schema":1,"enabled":false,"backend":"","lastCollectedAt":"","period":{"day":1,"time":"00:00:00"},"periodsSeeded":false,"inbounds":{}}' >"$TRAFFIC_FILE"
traffic_ensure_backend() { :; }
traffic_sync_inventory() { :; }
traffic_rules_restore_serialized() { :; }
traffic_timer_install() { : >"${TRAFFIC_FILE}.timer-installed"; }
traffic_collect() { : >"${TRAFFIC_FILE}.collected"; }
traffic_runtime_ensure
jq -e '.enabled==true' "$TRAFFIC_FILE" >/dev/null
[[ -f ${TRAFFIC_FILE}.timer-installed && ! -e ${TRAFFIC_FILE}.collected ]]
BASH


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
jq '.enabled=true | .backend="iptables" |
  .inbounds.vless={protocol:"vless",port:17225,deleted:false,daily:{}}' \
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
count_line=$(grep -nF -- '--comment xrayctl-traffic:count:vless -j RETURN' "$CASE_DIR/iptables-calls" | head -1 | cut -d: -f1)
[[ -n $count_line ]]
! grep -Fq -- 'xrayctl-traffic:block:' "$CASE_DIR/iptables-calls"
! grep -Fq -- ' -j DROP' "$CASE_DIR/iptables-calls"
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
jq '.inbounds.vless={protocol:"vless",port:17225,deleted:false,daily:{}}' "$TRAFFIC_FILE" >"$tmp"
install -m 600 "$tmp" "$TRAFFIC_FILE"; rm -f "$tmp"

nft() {
  if [[ $1 == -j ]]; then printf '%s\n' '{"nftables":[]}'; return 0; fi
  local IFS=' '; printf '%s\n' "$*" >>"$CASE_DIR/nft-calls"
}
traffic_rules_restore
grep -Fq 'add rule inet xrayctl_traffic input tcp dport 17225 counter comment "xrayctl-traffic:count:vless"' "$CASE_DIR/nft-calls"
grep -Fq 'add rule inet xrayctl_traffic input tcp dport 5000 counter comment "xrayctl-traffic:count:socks"' "$CASE_DIR/nft-calls"
grep -Fq 'add rule inet xrayctl_traffic input udp dport 5000 counter comment "xrayctl-traffic:count:socks"' "$CASE_DIR/nft-calls"
grep -Fq 'add rule inet xrayctl_traffic input tcp dport 24443 counter comment "xrayctl-traffic:count:http"' "$CASE_DIR/nft-calls"
! grep -Fq 'xrayctl-traffic:block:' "$CASE_DIR/nft-calls"
! grep -Fq ' drop ' "$CASE_DIR/nft-calls"
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

# Returning from the user-quota menu is a successful navigation action.
XRAYCTL_TESTING=1 bash <<'BASH_MENU_RETURN'
set -Eeuo pipefail
source ./xrayctl.sh
clear_screen() { :; }
traffic_is_enabled() { return 0; }
traffic_collect() { :; }
traffic_users_show() { :; }
traffic_user_menu() { :; }
traffic_limit_menu <<<"0" >/dev/null
BASH_MENU_RETURN

# A shared display period starts at the configured wall-clock time. Existing
# daily data is seeded approximately, while new samples follow the exact
# collection-side boundary; quota anchors are independent.
XRAYCTL_TESTING=1 \
XRAYCTL_TRAFFIC_TODAY=2026-08-24 \
XRAYCTL_TRAFFIC_NOW='2026-08-24 12:00:00' \
XRAYCTL_CONFIG_DIR="$TMP/period/cfg" \
XRAYCTL_CONFIG_FILE="$TMP/period/cfg/config.json" \
XRAYCTL_META_FILE="$TMP/period/meta.json" \
XRAYCTL_TRAFFIC_FILE="$TMP/period/traffic.json" \
XRAYCTL_CERT_DIR="$TMP/period/cfg/certs" \
XRAYCTL_LOG_DIR="$TMP/period/log" \
XRAYCTL_LOCK_FILE="$TMP/period/lock" \
bash <<'BASH_PERIOD'
set -Eeuo pipefail
source ./xrayctl.sh
write_default_config
tmp=$(temp_file)
jq '.inbounds=[{"protocol":"vless","tag":"vless","listen":"0.0.0.0","port":17225,"settings":{"clients":[]}}]' "$CONFIG_FILE" >"$tmp"
mv -f "$tmp" "$CONFIG_FILE"
traffic_init_file
tmp=$(temp_file)
jq '.inbounds.vless={protocol:"vless",port:17225,deleted:false,daily:{"2026-08-21":100,"2026-08-22":200,"2026-08-24":300}}' "$TRAFFIC_FILE" >"$tmp"
install -m 600 "$tmp" "$TRAFFIC_FILE"; rm -f "$tmp"
original_traffic_collect=$(declare -f traffic_collect)
traffic_collect() { :; }
traffic_period_set 22 18:30 >/dev/null
! traffic_period_set 22 18:30:15 2>/dev/null
[[ $(traffic_period_start '2026-08-22 18:29:59') == '2026-07-22 18:30:00' ]]
[[ $(traffic_period_start '2026-08-22 18:30:00') == '2026-08-22 18:30:00' ]]
[[ $(traffic_period_bounds '2026-08-24 12:00:00') == $'2026-08-22 18:30:00\t2026-09-22 18:30:00' ]]
jq -e '.inbounds.vless.cycles["2026-08-22 18:30:00"]==500 and .inbounds.vless.limit==null' "$TRAFFIC_FILE" >/dev/null
output=$(traffic_show)
grep -Fq '统计范围：2026-08-22 18:30:00 ～ 2026-09-22 18:30:00' <<<"$output"
grep -Fq '全部入站：500 B' <<<"$output"
eval "$original_traffic_collect"
MOCK_COUNTERS=$'vless\t50'
traffic_read_counters() { printf '%s\n' "$MOCK_COUNTERS"; }
traffic_rules_restore() { :; }
traffic_set_enabled true
XRAYCTL_TRAFFIC_NOW='2026-09-22 18:29:59'
XRAYCTL_TRAFFIC_TODAY=2026-09-22
traffic_collect
XRAYCTL_TRAFFIC_NOW='2026-09-22 18:30:00'
traffic_collect
jq -e '.inbounds.vless.cycles["2026-08-22 18:30:00"]==null and .inbounds.vless.cycles["2026-09-22 18:30:00"]==100 and .inbounds.vless.daily["2026-09-22"]==100 and (.inbounds.vless.daily|length)==1 and .inbounds.vless.limit==null' "$TRAFFIC_FILE" >/dev/null
[[ $(traffic_period_start '2026-02-28 23:59:59') == '2026-02-22 18:30:00' ]]
traffic_period_set 31 00:00 >/dev/null
[[ $(traffic_period_bounds '2026-02-28 23:59:59') == $'2026-02-28 00:00:00\t2026-03-31 00:00:00' ]]
[[ $(traffic_period_bounds '2028-02-29 12:00:00') == $'2028-02-29 00:00:00\t2028-03-31 00:00:00' ]]
[[ $(traffic_period_bounds '2026-04-30 12:00:00') == $'2026-04-30 00:00:00\t2026-05-31 00:00:00' ]]
BASH_PERIOD

# The aggregate survives single-inbound resets, including stopped legacy
# installations, then resets only with all records or the monthly boundary.
XRAYCTL_TESTING=1 \
XRAYCTL_TRAFFIC_NOW='2026-08-24 12:00:00' \
XRAYCTL_TRAFFIC_TODAY=2026-08-24 \
XRAYCTL_CONFIG_DIR="$TMP/aggregate/cfg" \
XRAYCTL_CONFIG_FILE="$TMP/aggregate/cfg/config.json" \
XRAYCTL_META_FILE="$TMP/aggregate/meta.json" \
XRAYCTL_TRAFFIC_FILE="$TMP/aggregate/traffic.json" \
XRAYCTL_CERT_DIR="$TMP/aggregate/cfg/certs" \
XRAYCTL_LOG_DIR="$TMP/aggregate/log" \
XRAYCTL_LOCK_FILE="$TMP/aggregate/lock" \
bash <<'BASH_AGGREGATE'
set -Eeuo pipefail
source ./xrayctl.sh
write_default_config
tmp=$(temp_file)
jq '.inbounds=[{protocol:"vless",tag:"a",port:17225,settings:{clients:[]}},
               {protocol:"vless",tag:"b",port:17226,settings:{clients:[]}}]' "$CONFIG_FILE" >"$tmp"
mv -f "$tmp" "$CONFIG_FILE"
traffic_init_file
tmp=$(temp_file)
jq 'del(.accountingMultiplier) | .periodsSeeded=true |
  .inbounds={a:{daily:{"2026-08-24":100},cycles:{"2026-08-01 00:00:00":100}},
             b:{daily:{"2026-08-24":200},cycles:{"2026-08-01 00:00:00":200}}}' "$TRAFFIC_FILE" >"$tmp"
mv -f "$tmp" "$TRAFFIC_FILE"
confirm() { return 0; }
# Clearing also migrates the aggregate before updating a single inbound.
traffic_clear_tag_records a >/dev/null
traffic_sync_inventory
jq -e '.totals.daily["2026-08-24"]==600 and .totals.cycles["2026-08-01 00:00:00"]==600 and
       .inbounds.a.daily=={} and .inbounds.b.daily["2026-08-24"]==400' "$TRAFFIC_FILE" >/dev/null
output=$(traffic_show)
grep -Fq '全部入站：600 B' <<<"$output"
[[ $(traffic_range_total 2026-08-01 2026-08-24) == 600 ]]
traffic_read_counters() { printf '%s' "$MOCK_COUNTERS"; }
traffic_rules_restore() { :; }
traffic_set_enabled true
MOCK_COUNTERS=$'a\t50\nb\t25'
traffic_collect
jq -e '.totals.cycles["2026-08-01 00:00:00"]==750 and .inbounds.a.daily["2026-08-24"]==100' "$TRAFFIC_FILE" >/dev/null
MOCK_COUNTERS=""
traffic_clear_tag_records b >/dev/null
traffic_clear_tag_records a >/dev/null
output=$(traffic_show 2026-08-01 2026-08-24)
grep -Fq '全部入站：750 B' <<<"$output"
# Rebucket using independent daily history, even though every row is empty.
traffic_period_set 22 18:30 >/dev/null
output=$(traffic_show)
grep -Fq '全部入站：750 B' <<<"$output"
jq -e '.totals.cycles["2026-08-22 18:30:00"]==750' "$TRAFFIC_FILE" >/dev/null
# A successful aggregate migration is never seeded again on later updates.
traffic_sync_inventory
[[ $(traffic_range_total 2026-08-22 2026-08-24) == 750 ]]
# Failed rule replacement must roll the independent aggregate back too.
MOCK_COUNTERS=$'a\t50'
before=$(jq -S . "$TRAFFIC_FILE")
traffic_rules_restore() { return 1; }
if traffic_collect >/dev/null 2>&1; then exit 1; fi
[[ $(jq -S . "$TRAFFIC_FILE") == "$before" ]]
traffic_rules_restore() { :; }
traffic_collect
MOCK_COUNTERS=""
traffic_clear_all_records <<<RESET >/dev/null
jq -e '.totals=={daily:{},cycles:{}} and ([.inbounds[]?.cycles | length] | add)==0' "$TRAFFIC_FILE" >/dev/null
output=$(traffic_show)
grep -Fq '全部入站：0 B' <<<"$output"
MOCK_COUNTERS=$'a\t50'
traffic_collect
XRAYCTL_TRAFFIC_NOW='2026-09-22 18:30:00'
XRAYCTL_TRAFFIC_TODAY=2026-09-22
traffic_collect
jq -e '.totals.cycles=={"2026-09-22 18:30:00":100} and .totals.daily=={"2026-09-22":100}' "$TRAFFIC_FILE" >/dev/null
BASH_AGGREGATE

# Clearing a deleted inbound removes its entire retained record. Legacy
# inbound quotas are discarded during schema migration; user limits remain.
XRAYCTL_TESTING=1 \
XRAYCTL_TRAFFIC_NOW='2026-08-24 12:00:00' \
XRAYCTL_CONFIG_DIR="$TMP/clear-deleted/cfg" \
XRAYCTL_CONFIG_FILE="$TMP/clear-deleted/cfg/config.json" \
XRAYCTL_META_FILE="$TMP/clear-deleted/meta.json" \
XRAYCTL_TRAFFIC_FILE="$TMP/clear-deleted/traffic.json" \
XRAYCTL_CERT_DIR="$TMP/clear-deleted/cfg/certs" \
XRAYCTL_LOG_DIR="$TMP/clear-deleted/log" \
XRAYCTL_LOCK_FILE="$TMP/clear-deleted/lock" \
bash <<'BASH_CLEAR_DELETED'
set -Eeuo pipefail
source ./xrayctl.sh
write_default_config
tmp=$(temp_file)
jq '.inbounds=[{protocol:"socks",tag:"socks",port:26399,settings:{accounts:[]}}]' "$CONFIG_FILE" >"$tmp"
mv -f "$tmp" "$CONFIG_FILE"
confirm() { return 0; }
traffic_read_counters() { :; }
traffic_rules_restore() { :; }
for collecting in false true; do
    traffic_default_json >"$TRAFFIC_FILE"
    tmp=$(temp_file)
    jq --argjson collecting "$collecting" '
      .enabled=$collecting | .accountingMultiplier=2 | .periodsSeeded=true |
      del(.totals) |
      .inbounds={
        removed:{protocol:"vless",port:15078,deleted:true,
          daily:{"2026-08-24":100},cycles:{"2026-08-01 00:00:00":100},
          limit:{enabled:true,quotaBytes:1000,usedBytes:100}},
        empty:{protocol:"vless",port:15079,deleted:true,daily:{},cycles:{},
          limit:{enabled:true,quotaBytes:1000,usedBytes:0}},
        socks:{protocol:"socks",port:26399,deleted:false,
          daily:{"2026-08-24":200},cycles:{"2026-08-01 00:00:00":200},
          limit:{enabled:true,quotaBytes:1000,usedBytes:200,resetDay:24,
            anchorDay:24,anchorTime:"12:00:00",cycleStart:"2026-08-24 12:00:00",
            cycleEnd:"2026-09-24 12:00:00"}}
      }
    ' "$TRAFFIC_FILE" >"$tmp"
    mv -f "$tmp" "$TRAFFIC_FILE"
    traffic_sync_inventory
    live_before=$(jq -S .inbounds.socks "$TRAFFIC_FILE")
    totals_before=$(jq -S .totals "$TRAFFIC_FILE")
    traffic_clear_tag_records removed >/dev/null
    traffic_sync_inventory
    jq -e '.inbounds.removed==null and .totals.cycles["2026-08-01 00:00:00"]==300' "$TRAFFIC_FILE" >/dev/null
    [[ $(jq -S .inbounds.socks "$TRAFFIC_FILE") == "$live_before" ]]
    [[ $(jq -S .totals "$TRAFFIC_FILE") == "$totals_before" ]]
    jq -e '.inbounds.empty==null' "$TRAFFIC_FILE" >/dev/null
    output=$(traffic_show)
    ! grep -Fq removed <<<"$output"
    ! grep -Fq 'empty(已删除)' <<<"$output"
    traffic_clear_tag_records socks >/dev/null
    traffic_sync_inventory
    jq -e '.inbounds.socks.deleted==false and .inbounds.socks.daily=={} and
      .inbounds.socks.cycles=={} and .inbounds.socks.limit==null' "$TRAFFIC_FILE" >/dev/null
    [[ $(jq -S .totals "$TRAFFIC_FILE") == "$totals_before" ]]
done
BASH_CLEAR_DELETED

printf 'traffic accounting unit checks passed.\n'
