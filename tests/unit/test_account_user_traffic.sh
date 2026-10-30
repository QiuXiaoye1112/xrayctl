#!/usr/bin/env bash
set -Eeuo pipefail
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
export XRAYCTL_TMP_DIR="$tmp" XRAYCTL_TESTING=1
export XRAYCTL_TRAFFIC_FILE="$tmp/traffic.json" XRAYCTL_CONFIG_FILE="$tmp/config.json" XRAYCTL_LOCK_FILE="$tmp/lock"
source "$root/xrayctl.sh"
trap - ERR

jq -n '{
  log:{loglevel:"warning"},
  inbounds:[
    {tag:"socks",protocol:"socks",settings:{auth:"password",accounts:[{user:"socks-one",pass:"socks-pass"}],users:[{user:"socks-one",pass:"socks-pass"}] }},
    {tag:"http",protocol:"http",settings:{accounts:[{user:"http-one",pass:"http-pass"}],users:[{user:"http-one",pass:"http-pass"}]}}
  ],
  outbounds:[{tag:"direct",protocol:"freedom"}],routing:{rules:[]}
}' >"$tmp/input.json"
traffic_user_prepare_config "$tmp/input.json" "$tmp/prepared.json" '127.0.0.1:32401'
jq -e '
  .api.listen=="127.0.0.1:32401" and
  (.api.services|index("StatsService")!=null) and
  .policy.levels["0"].statsUserUplink and .policy.levels["0"].statsUserDownlink and
  ([.inbounds[] | select(.protocol=="socks" or .protocol=="http")]|length)==2
' "$tmp/prepared.json" >/dev/null
cp "$tmp/prepared.json" "$CONFIG_FILE"
traffic_user_has_clients
printf '%s\n' '{"inbounds":[{"tag":"legacy-anon","protocol":"socks","settings":{"auth":"noauth"}}]}' >"$tmp/no-auth-only.json"
if CONFIG_FILE="$tmp/no-auth-only.json" traffic_user_has_clients; then exit 1; fi
chosen=''
prompt_client_label chosen socks '新用户名' '' '' socks <<< $'http-one\nunique-name\n' >"$tmp/duplicate-prompt.log" 2>&1
[[ $chosen == unique-name ]]
grep -Fq '警告 · 此用户名已存在' "$tmp/duplicate-prompt.log"

inventory=$(traffic_user_inventory_json "$CONFIG_FILE")
jq -e 'length==2 and .[0].id=="socks-one" and .[0].tag=="socks" and .[1].id=="http-one" and .[1].tag=="http" and (all(.[];.ambiguous|not))' <<<"$inventory" >/dev/null
traffic_default_json | jq '.enabled=true | .inbounds.socks.users["socks-one"]={label:"socks-one",limit:{enabled:true,quotaBytes:60,usedBytes:0}} | .inbounds.http.users["http-one"]={label:"http-one",limit:{enabled:true,quotaBytes:1000,usedBytes:0}}' >"$TRAFFIC_FILE"
export XRAYCTL_TRAFFIC_NOW='2026-10-30 12:00:00'
samples='{"socks-one":{"uplink":10,"downlink":20},"http-one":{"uplink":5,"downlink":8}}'
traffic_user_update_samples "$samples" epoch1
jq -e '
  .inbounds.socks.users["socks-one"].uplinkBytes==10 and
  .inbounds.socks.users["socks-one"].downlinkBytes==20 and
  .inbounds.socks.users["socks-one"].limit.usedBytes==60 and
  .inbounds.http.users["http-one"].uplinkBytes==5 and
  .inbounds.http.users["http-one"].downlinkBytes==8 and
  .inbounds.http.users["http-one"].limit.usedBytes==26
' "$TRAFFIC_FILE" >/dev/null

# A duplicated auth username is one global Xray counter. Freeze both affected
# identities and their quota rules rather than assigning the aggregate twice.
jq '(.inbounds[]|select(.tag=="http")|.settings.accounts[0].user)="socks-one" | (.inbounds[]|select(.tag=="http")|.settings.users[0].user)="socks-one"' "$CONFIG_FILE" >"$tmp/duplicate.json"
cp "$tmp/duplicate.json" "$CONFIG_FILE"
traffic_user_core_epoch() { printf 'epoch1'; }
traffic_user_read_samples() { printf '%s' '{"socks-one":{"uplink":200,"downlink":300}}'; }
traffic_user_collect_locked
jq -e '
  .inbounds.socks.users["socks-one"].uplinkBytes==10 and
  .inbounds.socks.users["socks-one"].downlinkBytes==20 and
  .inbounds.socks.users["socks-one"].samplingBlocked==true and
  (.inbounds.http.users["socks-one"].uplinkBytes // 0)==0 and
  .inbounds.http.users["socks-one"].samplingBlocked==true
' "$TRAFFIC_FILE" >/dev/null
jq --arg now '2026-10-30 12:00:00' '.inbounds.http.users["socks-one"]={label:"socks-one",limit:{enabled:true,quotaBytes:1,usedBytes:1}}' "$TRAFFIC_FILE" >"$tmp/duplicate-state.json"
cp "$tmp/duplicate-state.json" "$TRAFFIC_FILE"
inventory=$(traffic_user_inventory_json "$CONFIG_FILE")
jq -e 'all(.[];.ambiguous)' <<<"$inventory" >/dev/null

traffic_user_managed_config() { return 0; }
traffic_user_recover_identities() { cp "$1" "$2"; }
traffic_user_collect_locked() { :; }
state_commit() { cp "$1" "$CONFIG_FILE"; }
traffic_user_reconcile_locked
jq -e '[.routing.rules[]? | select((.ruleTag // "")|startswith("xrayctl-user-limit:"))] | length==0' "$CONFIG_FILE" >/dev/null

# Once renamed to a globally unique username, the next sample establishes a
# baseline; only the following delta is charged to the original account.
jq '(.inbounds[]|select(.tag=="http")|.settings.accounts[0].user)="http-new" | (.inbounds[]|select(.tag=="http")|.settings.users[0].user)="http-new"' "$CONFIG_FILE" >"$tmp/unique.json"
cp "$tmp/unique.json" "$CONFIG_FILE"
samples='{"socks-one":{"uplink":250,"downlink":400},"http-new":{"uplink":10,"downlink":20}}'
traffic_user_update_samples "$samples" epoch1
traffic_user_update_samples '{"socks-one":{"uplink":260,"downlink":410},"http-new":{"uplink":12,"downlink":22}}' epoch1
jq -e '
  .inbounds.socks.users["socks-one"].uplinkBytes==20 and
  .inbounds.socks.users["socks-one"].downlinkBytes==30 and
  .inbounds.http.users["http-new"].uplinkBytes==12 and
  .inbounds.http.users["http-new"].downlinkBytes==22 and
  .inbounds.http.users["socks-one"]==null
' "$TRAFFIC_FILE" >/dev/null

# Quota routing is isolated by inbound tag and account username. Ambiguous
# names produce no user-ban rule; once unique, only the exhausted account bans.
jq '.inbounds.socks.users["socks-one"].limit.usedBytes=60 | .inbounds.socks.users["socks-one"].limit.quotaBytes=60' "$TRAFFIC_FILE" >"$tmp/over.json"
cp "$tmp/over.json" "$TRAFFIC_FILE"
traffic_user_reconcile_locked
jq -e '[.routing.rules[]|select(.ruleTag=="xrayctl-user-limit:socks-one" and .inboundTag==["socks"] and .user==["socks-one"])]|length==1' "$CONFIG_FILE" >/dev/null
jq -e '[.routing.rules[]|select(.ruleTag=="xrayctl-user-limit:http-new")]|length==0' "$CONFIG_FILE" >/dev/null

# Exercise account rename through its config transaction shim and verify both
# the accumulated state and its managed rule follow the new StatsService ID.
ensure_runtime_dependencies() { :; }
require_xray_installed() { :; }
ensure_config() { :; }
inbound_require_supported_configuration() { :; }
state_apply_candidate_file() { cp "$1" "$CONFIG_FILE"; rm -f "$1"; }
rename_client socks socks-one socks-renamed
jq -e '
  .inbounds[]|select(.tag=="socks")|.settings.accounts[0].user=="socks-renamed"
' "$CONFIG_FILE" >/dev/null
jq -e '
  .inbounds.socks.users["socks-renamed"].uplinkBytes==20 and
  .inbounds.socks.users["socks-renamed"].limit.usedBytes==60 and
  .inbounds.socks.users["socks-one"]==null
' "$TRAFFIC_FILE" >/dev/null
jq -e '[.routing.rules[]|select(.ruleTag=="xrayctl-user-limit:socks-renamed" and .user==["socks-renamed"])]|length==1' "$CONFIG_FILE" >/dev/null

delete_client socks socks-renamed 1
jq -e '.inbounds.socks.users["socks-renamed"]==null' "$TRAFFIC_FILE" >/dev/null
jq -e '[.routing.rules[]|select((.ruleTag // "")=="xrayctl-user-limit:socks-renamed")]|length==0' "$CONFIG_FILE" >/dev/null

printf 'ok - authenticated SOCKS/HTTP identities, isolated counters, ambiguity and account lifecycle\n'
