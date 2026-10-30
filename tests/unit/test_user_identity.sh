#!/usr/bin/env bash
set -Eeuo pipefail
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
export XRAYCTL_TMP_DIR="$tmp"
export XRAYCTL_TESTING=1
export XRAYCTL_TRAFFIC_FILE="$tmp/traffic.json"
export XRAYCTL_CONFIG_FILE="$tmp/config.json"
export XRAYCTL_LOCK_FILE="$tmp/lock"
source "$root/xrayctl.sh"
trap - ERR
jq -n '{inbounds:[{tag:"a",protocol:"vless",settings:{clients:[{email:"alice",id:"123e4567-e89b-12d3-a456-426614174000"}]}},{tag:"b",protocol:"vless",settings:{clients:[{email:"alice",id:"123e4567-e89b-12d3-a456-426614174001"}]}}],outbounds:[{protocol:"freedom",tag:"direct"}],routing:{rules:[{type:"field",user:["alice"],outboundTag:"direct"}]}}' >"$tmp/input"
traffic_user_prepare_identities "$tmp/input" "$tmp/output"
jq -e '
  .inbounds[0].settings.clients[0] as $a | .inbounds[1].settings.clients[0] as $b |
  $a.email != $b.email and $a.xrayctlLabel=="alice" and $b.xrayctlLabel=="alice" and
  $a.id=="123e4567-e89b-12d3-a456-426614174000" and
  $b.id=="123e4567-e89b-12d3-a456-426614174001" and
  (.routing.rules[0].user | index($a.email)!=null and index($b.email)!=null and index("alice")!=null)
' "$tmp/output" >/dev/null
traffic_user_prepare_identities "$tmp/output" "$tmp/again"
jq -S . "$tmp/output" >"$tmp/first.sorted"
jq -S . "$tmp/again" >"$tmp/second.sorted"
cmp -s "$tmp/first.sorted" "$tmp/second.sorted"
jq '.routing.rules[0].user=["regexp:^ali"]' "$tmp/input" >"$tmp/regexp"
traffic_user_prepare_identities "$tmp/regexp" "$tmp/regexp-output"
jq -e '.inbounds[0].settings.clients[0].email as $a | .inbounds[1].settings.clients[0].email as $b | .routing.rules[0].user | index($a)!=null and index($b)!=null and index("regexp:^ali")!=null' "$tmp/regexp-output" >/dev/null
jq '.routing.rules[0].user=["regexp:^xrayctl-user-"]' "$tmp/input" >"$tmp/regexp-conflict"
if traffic_user_prepare_identities "$tmp/regexp-conflict" "$tmp/regexp-output"; then exit 1; fi
traffic_user_prepare_config "$tmp/input" "$tmp/config" '127.0.0.1:32401'
jq -e '.api.listen=="127.0.0.1:32401" and (.api.services | index("StatsService")!=null) and .policy.levels["0"].statsUserUplink and .policy.levels["0"].statsUserDownlink' "$tmp/config" >/dev/null
if traffic_user_prepare_config "$tmp/input" "$tmp/config" '0.0.0.0:32401'; then exit 1; fi
jq '.api={tag:"external",services:["StatsService"]}' "$tmp/input" >"$tmp/external"
if traffic_user_prepare_config "$tmp/external" "$tmp/config" '127.0.0.1:32401'; then exit 1; fi
jq '.api={tag:"external",listen:"127.0.0.1:32401",services:["HandlerService"]}' "$tmp/input" >"$tmp/external"
traffic_user_prepare_config "$tmp/external" "$tmp/config" '127.0.0.1:32401'
jq -e '.api.tag=="external" and (.api.services|index("HandlerService")!=null and index("StatsService")!=null)' "$tmp/config" >/dev/null
jq '.routing.rules += [{type:"field",outboundTag:"external",inboundTag:["a"]}]' "$tmp/external" >"$tmp/exposed"
if traffic_user_prepare_config "$tmp/exposed" "$tmp/config" '127.0.0.1:32401'; then exit 1; fi
cp "$tmp/output" "$CONFIG_FILE"
(
  ensure_config() { :; }
  tag=''; label=''
  traffic_user_select tag label <<< $'1\n1\n' >/dev/null
  [[ $tag == a && $label == alice ]]
)
cat > "$TRAFFIC_FILE" <<'JSON'
{"schema":1,"accountingMultiplier":2,"enabled":true,"limitsEnabled":true,"backend":"iptables","inbounds":{"a":{"protocol":"vless","port":443,"daily":{"2026-02-01":123},"limit":{"enabled":true,"quotaBytes":1000,"usedBytes":345,"anchorDay":15,"anchorTime":"12:00:00","cycleStart":"2026-02-15 12:00:00","cycleEnd":"2026-03-15 12:00:00"},"users":{"legacy-user":{"label":"alice","limit":{"enabled":true,"quotaBytes":500,"usedBytes":20}}}}}}
JSON
traffic_init_file
jq -e '.inbounds.a.daily["2026-02-01"]==123 and .inbounds.a.limit==null and .inbounds.a.users["legacy-user"].limit.usedBytes==20 and (has("limitsEnabled")|not)' "$TRAFFIC_FILE" >/dev/null
traffic_default_json > "$TRAFFIC_FILE"
(
  platform_init_system() { printf 'systemd\n'; }
  traffic_user_require_manager() { :; }
  ensure_config() { :; }
  require_xray_installed() { :; }
  traffic_runtime_ensure() { :; }
  traffic_user_collect_serialized() { :; }
  traffic_timer_install() { : > "$tmp/timer-upgraded"; }
  apply_candidate() { cp "$1" "$CONFIG_FILE"; }
  TRAFFIC_SYSTEMD_SERVICE="$tmp/old-timer.service"
  printf 'ReadWritePaths=/var/lib/xrayctl /run/lock\n' > "$TRAFFIC_SYSTEMD_SERVICE"
  traffic_user_enable
  [[ -f $tmp/timer-upgraded ]]
)
cp "$tmp/output" "$CONFIG_FILE"
# A failed replacement must retain the complete previous JSON document.
cp "$TRAFFIC_FILE" "$tmp/before-failed-write"
printf '%s\n' '{"inbounds":{"new":{}}}' > "$tmp/replacement"
(
  mv() { return 1; }
  if traffic_write_file "$tmp/replacement"; then exit 1; fi
)
cmp -s "$TRAFFIC_FILE" "$tmp/before-failed-write"
id_a=$(jq -r '.inbounds[0].settings.clients[0].email' "$CONFIG_FILE")
id_b=$(jq -r '.inbounds[1].settings.clients[0].email' "$CONFIG_FILE")
samples=$(jq -nc --arg a "$id_a" --arg b "$id_b" '{($a):{uplink:10,downlink:20},($b):{uplink:5,downlink:7}}')
traffic_user_update_samples "$samples" epoch1
traffic_user_update_samples "$samples" epoch1
jq -e --arg a "$id_a" --arg b "$id_b" '.inbounds.a.users[$a].uplinkBytes==10 and .inbounds.a.users[$a].downlinkBytes==20 and .inbounds.b.users[$b].uplinkBytes==5 and .inbounds.b.users[$b].downlinkBytes==7' "$TRAFFIC_FILE" >/dev/null
cp "$CONFIG_FILE" "$tmp/before-manual-delete-config"
cp "$TRAFFIC_FILE" "$tmp/before-manual-delete-state"
jq '.inbounds[1].settings.clients=[]' "$CONFIG_FILE" >"$tmp/deleted-config"
cp "$tmp/deleted-config" "$CONFIG_FILE"
traffic_user_update_samples '{}' epoch1
jq -e --arg b "$id_b" '.inbounds.b.users[$b]==null' "$TRAFFIC_FILE" >/dev/null
cp "$tmp/before-manual-delete-config" "$CONFIG_FILE"
cp "$tmp/before-manual-delete-state" "$TRAFFIC_FILE"
jq '(.inbounds[]|select(.tag=="a")|.tag)="manual-rename"' "$CONFIG_FILE" >"$tmp/renamed-config"
cp "$tmp/renamed-config" "$CONFIG_FILE"
traffic_user_update_samples "$samples" epoch1
jq -e --arg a "$id_a" '.inbounds["manual-rename"].users[$a].uplinkBytes==10 and .inbounds["manual-rename"].users[$a].downlinkBytes==20 and .inbounds.a.users[$a]==null' "$TRAFFIC_FILE" >/dev/null
cp "$tmp/before-manual-delete-config" "$CONFIG_FILE"
cp "$tmp/before-manual-delete-state" "$TRAFFIC_FILE"
cp "$TRAFFIC_FILE" "$tmp/before-estimate"
jq --arg a "$id_a" '.inbounds.a.users[$a].limit={enabled:true,usedBytes:0}' "$TRAFFIC_FILE" >"$tmp/state"
cp "$tmp/state" "$TRAFFIC_FILE"
samples=$(jq -nc --arg a "$id_a" '{($a):{uplink:12,downlink:23}}')
traffic_user_update_samples "$samples" epoch1
jq -e --arg a "$id_a" '.inbounds.a.users[$a].uplinkBytes==12 and .inbounds.a.users[$a].downlinkBytes==23 and .inbounds.a.users[$a].limit.usedBytes==10' "$TRAFFIC_FILE" >/dev/null
cp "$tmp/before-estimate" "$TRAFFIC_FILE"
samples=$(jq -nc --arg a "$id_a" '{($a):{uplink:4,downlink:6}}')
traffic_user_update_samples "$samples" epoch2
jq -e --arg a "$id_a" --arg b "$id_b" '.inbounds.a.users[$a].uplinkBytes==14 and .inbounds.a.users[$a].downlinkBytes==26 and .inbounds.b.users[$b].uplinkBytes==5 and .inbounds.b.users[$b].downlinkBytes==7' "$TRAFFIC_FILE" >/dev/null
export XRAYCTL_TRAFFIC_NOW='2026-02-28 12:00:00'
jq --arg a "$id_a" --arg b "$id_b" '
  .inbounds.a.users[$a].limit={enabled:true,quotaBytes:100,usedBytes:80,anchorDay:31,anchorTime:"12:00:00",cycleStart:"2026-01-31 12:00:00",cycleEnd:"2026-02-28 12:00:00"} |
  .inbounds.b.users[$b].limit={enabled:true,quotaBytes:100,usedBytes:70,anchorDay:15,anchorTime:"12:00:00",cycleStart:"2026-02-15 12:00:00",cycleEnd:"2026-03-15 12:00:00"}' "$TRAFFIC_FILE" >"$tmp/state"
cp "$tmp/state" "$TRAFFIC_FILE"
traffic_user_update_samples '{}' epoch2
jq -e --arg a "$id_a" --arg b "$id_b" '.inbounds.a.users[$a].limit.usedBytes==0 and .inbounds.a.users[$a].limit.cycleEnd=="2026-03-31 12:00:00" and .inbounds.b.users[$b].limit.usedBytes==70' "$TRAFFIC_FILE" >/dev/null
traffic_user_prepare_config "$tmp/input" "$CONFIG_FILE" '127.0.0.1:32401'
id_a=$(jq -r '.inbounds[0].settings.clients[0].email' "$CONFIG_FILE")
id_b=$(jq -r '.inbounds[1].settings.clients[0].email' "$CONFIG_FILE")
jq --arg a "$id_a" '.enabled=true | .inbounds.a.users[$a]={label:"alice",cycles:{"2026-02-01 00:00:00":10},limit:{enabled:true,quotaBytes:10,usedBytes:10,anchorDay:15,anchorTime:"00:00:00",cycleStart:"2026-01-15 00:00:00",cycleEnd:"2026-02-15 00:00:00"}}' "$TRAFFIC_FILE" >"$tmp/state"
cp "$tmp/state" "$TRAFFIC_FILE"
user_display=$(traffic_users_show)
[[ $user_display == *'流量限制'* ]]
[[ $user_display == *'alice'* && $user_display == *'10 B / 10 B'* && $user_display == *'超额'* ]]
[[ $user_display != *'剩余'* && $user_display != *'入站：'* && $user_display != *'流量统计：'* && $user_display != *'用户统计：'* && $user_display != *'仍有入站总额度生效'* ]]
(
  ensure_config() { :; }
  select_inbound() { printf -v "$1" '%s' a; }
  traffic_user_managed_config() { return 0; }
  clear_screen() { :; }
  pause() { :; }
  run_menu_action() { printf '%s\t%s\t%s\n' "$1" "${2-}" "${3-}" >>"$tmp/menu-actions"; }
  printf '1\n0\n' >"$tmp/menu-input"
  traffic_user_menu <"$tmp/menu-input" >"$tmp/user-menu"
  grep -Fq '1) 设置/修改额度' "$tmp/user-menu"
  grep -Fq '2) 重置用户流量' "$tmp/user-menu"
  grep -Fq '3) 取消用户额度' "$tmp/user-menu"
  grep -Fq '流量：10 B / 10 B' "$tmp/user-menu"
  grep -Fq '重置：每月 15 日 00:00' "$tmp/user-menu"
  grep -Fq '周期：1月15日 00:00 ～ 2月15日 00:00' "$tmp/user-menu"
  grep -Fq '状态：超额' "$tmp/user-menu"
  grep -Fq $'traffic_user_limit_set\ta\talice' "$tmp/menu-actions"
  jq '.inbounds[0].settings.clients += [{email:"second-id",xrayctlLabel:"bob"}]' "$CONFIG_FILE" >"$tmp/menu-config"
  check_multi_user_menu() {
    : >"$tmp/menu-actions"
    printf '1\n2\n0\n' >"$tmp/menu-input"
    CONFIG_FILE="$tmp/menu-config" traffic_user_menu <"$tmp/menu-input" >"$tmp/user-menu"
  grep -Fxq '用户：alice' "$tmp/user-menu"
  grep -Fxq '用户：bob' "$tmp/user-menu"
  grep -Fq '1) alice' "$tmp/user-menu"
  grep -Fq '2) bob' "$tmp/user-menu"
  grep -Fq '重置周期：无' "$tmp/user-menu"
  grep -Fq $'traffic_user_limit_set\ta\tbob' "$tmp/menu-actions"
  : >"$tmp/menu-actions"
  printf '2\n' >"$tmp/menu-input"
  CONFIG_FILE="$tmp/menu-config" traffic_user_menu <"$tmp/menu-input" >"$tmp/user-menu"
  [[ $(grep -Fc '用户：alice' "$tmp/user-menu") == 1 ]]
    [[ ! -s $tmp/menu-actions ]]
  }
  check_multi_user_menu
)
cp "$TRAFFIC_FILE" "$tmp/before-unlimited-display"
jq --arg a "$id_a" 'del(.inbounds.a.users[$a].limit)' "$TRAFFIC_FILE" >"$tmp/unlimited-display"
cp "$tmp/unlimited-display" "$TRAFFIC_FILE"
unlimited_display=$(traffic_users_show)
[[ $unlimited_display == *'10 B / ∞'* ]]
cp "$tmp/before-unlimited-display" "$TRAFFIC_FILE"
jq '.inbounds += [{tag:"c",protocol:"socks",settings:{accounts:[]}}]' "$CONFIG_FILE" >"$tmp/with-socks"
cp "$tmp/with-socks" "$CONFIG_FILE"
user_display=$(traffic_users_show)
[[ $user_display == *'c'* && $user_display == *'此入站暂不支持按用户统计'* && $user_display != *'socks'* ]]
state_commit() { cp "$1" "$CONFIG_FILE"; }
jq '.routing.rules += [{type:"field",user:["regexp:^new"],outboundTag:"direct"}] | .inbounds[0].settings.clients += [{email:"new-user",id:"123e4567-e89b-12d3-a456-426614174003"}]' "$CONFIG_FILE" >"$tmp/new-candidate"
state_apply_candidate_file "$tmp/new-candidate" apply_candidate
new_id=$(jq -r '.inbounds[0].settings.clients[1].email' "$CONFIG_FILE")
jq -e --arg id "$new_id" '.inbounds[0].settings.clients[1].xrayctlLabel=="new-user" and (.routing.rules[-1].user|index($id)!=null)' "$CONFIG_FILE" >/dev/null
traffic_user_reconcile_locked
jq -e --arg a "$id_a" --arg b "$id_b" '.routing.rules[0].ruleTag==("xrayctl-user-limit:"+$a) and .routing.rules[0].inboundTag==["a"] and .routing.rules[0].user==[$a] and ([.routing.rules[] | select(.user==[$b])]|length)==0 and .routing.rules[1].user!=null' "$CONFIG_FILE" >/dev/null
cp "$TRAFFIC_FILE" "$tmp/before-limit-edit"
(
  ensure_runtime_dependencies() { :; }
  ensure_config() { :; }
  traffic_user_enable() { :; }
  traffic_user_collect_serialized() { :; }
  traffic_user_reconcile() { :; }
  confirm() { return 0; }
  traffic_user_limit_set a alice 100 15 18:30
  jq -e --arg id "$id_a" '(has("limitsEnabled")|not) and .inbounds.a.users[$id].limit.usedBytes==10 and .inbounds.a.users[$id].limit.anchorDay==15 and .inbounds.a.users[$id].limit.anchorTime=="18:30:00"' "$TRAFFIC_FILE" >/dev/null
  traffic_user_limit_remove a alice
  jq -e --arg id "$id_a" '.inbounds.a.users[$id].limit==null and .inbounds.a.users[$id].label=="alice"' "$TRAFFIC_FILE" >/dev/null
)
cp "$tmp/before-limit-edit" "$TRAFFIC_FILE"
jq --arg a "$id_a" '.inbounds.a.users[$a].limit.usedBytes=0' "$TRAFFIC_FILE" >"$tmp/state"
cp "$tmp/state" "$TRAFFIC_FILE"
traffic_user_reconcile_locked
jq -e '[.routing.rules[] | select((.ruleTag // "")|startswith("xrayctl-user-limit:"))] | length==0' "$CONFIG_FILE" >/dev/null
ensure_runtime_dependencies() { :; }
ensure_config() { :; }
require_xray_installed() { :; }
confirm() { return 0; }
prompt_validated_value() { printf -v "$1" '%s' '123e4567-e89b-12d3-a456-426614174099'; }
rename_client a alice charlie
jq -e --arg id "$id_a" '.inbounds[0].settings.clients[0].email==$id and .inbounds[0].settings.clients[0].xrayctlLabel=="charlie"' "$CONFIG_FILE" >/dev/null
traffic_user_update_samples '{}' epoch2
jq -e --arg id "$id_a" '.inbounds.a.users[$id].label=="charlie" and .inbounds.a.users[$id].limit.enabled==true' "$TRAFFIC_FILE" >/dev/null
jq '.inbounds[0].settings.clients[0].email="manually-edited"' "$CONFIG_FILE" >"$tmp/edited"
traffic_user_recover_identities "$tmp/edited" "$tmp/recovered"
jq -e --arg id "$id_a" '.inbounds[0].settings.clients[0].email==$id' "$tmp/recovered" >/dev/null
rotate_client_credential a charlie
jq -e --arg id "$id_a" '.inbounds[0].settings.clients[0].email==$id and .inbounds[0].settings.clients[0].id=="123e4567-e89b-12d3-a456-426614174099"' "$CONFIG_FILE" >/dev/null
jq --arg a "$id_a" '.inbounds.a.users[$a].limit.usedBytes=10' "$TRAFFIC_FILE" >"$tmp/state"
cp "$tmp/state" "$TRAFFIC_FILE"
traffic_user_reconcile_locked
(
  before=$(jq -cS --arg id "$id_a" '.inbounds.a.users[$id]' "$TRAFFIC_FILE")
  traffic_user_core_epoch() { printf '%s' epoch2; }
  traffic_user_read_samples() { return 1; }
  traffic_read_counters() { printf 'a\t100\n'; }
  traffic_rules_restore() { :; }
  traffic_user_reconcile() { :; }
  traffic_collect
  after=$(jq -cS --arg id "$id_a" '.inbounds.a.users[$id]' "$TRAFFIC_FILE")
  [[ $before == "$after" ]]
  jq -e '.inbounds.a.daily["2026-02-28"]==200' "$TRAFFIC_FILE" >/dev/null
)
delete_client a charlie 1
jq -e --arg id "$id_a" '.inbounds.a.users[$id]==null' "$TRAFFIC_FILE" >/dev/null
jq -e --arg id "$id_a" '[.routing.rules[] | select(.ruleTag==("xrayctl-user-limit:"+$id))] | length==0' "$CONFIG_FILE" >/dev/null
if [[ -n ${XRAYCTL_REAL_XRAY_BIN:-} ]]; then
  # Add fields required by the actual core to the accounting candidate.
  jq '.inbounds |= map(.listen="127.0.0.1" | .port=(if .tag=="a" then 32402 else 32403 end) | .settings.decryption="none")' "$tmp/input" >"$tmp/real-input"
  traffic_user_prepare_config "$tmp/real-input" "$tmp/real-config.json" '127.0.0.1:32401'
  if ! "$XRAYCTL_REAL_XRAY_BIN" run -test -format json -config "$tmp/real-config.json" >"$tmp/xray-config-test.log" 2>&1; then
    cat "$tmp/xray-config-test.log" >&2
    exit 1
  fi
fi
printf 'ok - VLESS user identities preserve labels, UUIDs and routing\n'
