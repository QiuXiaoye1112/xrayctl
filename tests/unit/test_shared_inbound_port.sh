#!/usr/bin/env bash
set -Eeuo pipefail
cd "$(dirname "$0")/../.."
root=$(mktemp -d)
trap 'rm -rf "$root"' EXIT
export XRAYCTL_TESTING=1 XRAYCTL_CONFIG_DIR="$root/config" XRAYCTL_TRAFFIC_FILE="$root/traffic.json"
export XRAYCTL_META_FILE="$root/meta.json" XRAYCTL_LOCK_FILE="$root/lock" XRAYCTL_TMP_DIR="$root/tmp"
export XRAYCTL_XRAY_BIN=/usr/local/bin/xray XRAYCTL_TRAFFIC_NOW='2026-11-18 12:00:00'
export XRAYCTL_TRAFFIC_BACKEND=nft
source ./tests/helpers/assert.sh
source ./xrayctl.sh
trap - ERR
trap 'rm -rf "$root"' EXIT

mkdir -p "$CONFIG_DIR"
cat >"$CONFIG_FILE" <<'JSON'
{"inbounds":[
  {"tag":"v4","listen":"192.0.2.10","port":443,"protocol":"vless","settings":{"clients":[]}},
  {"tag":"v6","listen":"2001:db8::10","port":443,"protocol":"vless","settings":{"clients":[]}}
],"outbounds":[]}
JSON
assert_failure port_in_config 443 v6 2001:db8::10 tcp
assert_failure port_in_config 443 v4 192.0.2.10 tcp
if ! port_in_config 443 '' 2001:0db8:0:0:0:0:0:10 tcp; then fail "IPv6 alias missed a duplicate"; fi
if ! port_in_config 443 '' :: tcp; then fail "wildcard must conflict with existing TCP sockets"; fi
assert_failure port_in_config 443 '' 192.0.2.10 udp

# Exercise the real interactive validator against a live socket on the other IP.
original_prompt_value=$(declare -f prompt_value)
prompt_value() { printf -v "$1" '%s' 443; }
ss() { printf '%s\n' "$live_sockets"; }
live_sockets='tcp LISTEN 0 100 192.0.2.10:443 0.0.0.0:* users:(("xray",pid=10,fd=8))'
assert_failure port_in_use_os 443 2001:db8::10 tcp
selected_port=""
prompt_port selected_port 443 v6 2001:db8::10 tcp
assert_eq 443 "$selected_port" "same-port edit should accept an address on the other family"
eval "$original_prompt_value"
if ! port_in_use_os 443 192.0.2.10 tcp; then fail "existing TCP socket was missed"; fi
service_is_active() { return 0; }
assert_failure port_in_use_os 443 192.0.2.10 tcp v4
live_sockets='tcp LISTEN 0 100 *:443 *:* users:(("xray",pid=10,fd=8)) v6only:0'
if ! port_in_use_os 443 2001:db8::10 tcp; then fail "dual-stack socket was missed"; fi

# Distinguish address families and packet directions on both rule backends.
nft() {
  if [[ $1 == -j ]]; then cat "$root/counters.json"; return; fi
  local IFS=' '; printf '%s\n' "$*" >>"$root/nft.log"
}
iptables() {
  if [[ ${3-} == -S || ${3-} == -C ]]; then return 1; fi
  local IFS=' '; printf '%s\n' "$*" >>"$root/iptables.log"
}
ip6tables() {
  if [[ ${3-} == -S || ${3-} == -C ]]; then return 1; fi
  local IFS=' '; printf '%s\n' "$*" >>"$root/ip6tables.log"
}
printf '%s\n' '{"nftables":[]}' >"$root/counters.json"
traffic_restore_iptables_rules
grep -Fq -- '-d 192.0.2.10 -p tcp --dport 443 -m comment --comment xrayctl-traffic:count:v4' "$root/iptables.log"
grep -Fq -- '-s 192.0.2.10 -p tcp --sport 443 -m comment --comment xrayctl-traffic:count:v4' "$root/iptables.log"
grep -Fq -- '-d 2001:0db8:0000:0000:0000:0000:0000:0010 -p tcp --dport 443 -m comment --comment xrayctl-traffic:count:v6' "$root/ip6tables.log"
grep -Fq -- '-s 2001:0db8:0000:0000:0000:0000:0000:0010 -p tcp --sport 443 -m comment --comment xrayctl-traffic:count:v6' "$root/ip6tables.log"
if grep -Fq 'count:v6' "$root/iptables.log" || grep -Fq 'count:v4' "$root/ip6tables.log"; then
  fail "an iptables counter was added to the wrong address family"
fi

sample() {
  jq -n --argjson v4 "$1" --argjson v6 "$2" '
    {nftables:[{"rule":{"chain":"input","comment":"xrayctl-traffic:count:v4","expr":[{counter:{bytes:$v4}}]}},
               {"rule":{"chain":"input","comment":"xrayctl-traffic:count:v6","expr":[{counter:{bytes:$v6}}]}}]}'
}

# Import the final deltas from the old counters, then start the new rules
# without carrying their predecessors' baselines into the next sample.
epoch=$(cat /proc/sys/kernel/random/boot_id 2>/dev/null || printf unknown)
traffic_init_file
jq -n --arg epoch "$epoch" '
  {schema:1,accountingMultiplier:2,backend:"nft",enabled:true,period:{day:1,time:"00:00:00"},
   periodsSeeded:true,rulesEpoch:$epoch,kernelCounterEpoch:$epoch,
   rulesInventory:{v4:{protocol:"vless",port:443,disabled:false},v6:{protocol:"vless",port:12321,disabled:false}},
   kernelCounters:{"input:v4":100,"input:v6":60},
   inbounds:{v4:{daily:{"2026-11-18":200},cycles:{"2026-11-01 00:00:00":200}},
             v6:{daily:{"2026-11-18":120},cycles:{"2026-11-01 00:00:00":120},users:{kept:{limit:{enabled:true}}}}},
   totals:{daily:{"2026-11-18":320},cycles:{"2026-11-01 00:00:00":320}}}' >"$TRAFFIC_FILE"
traffic_user_has_clients() { return 1; }
traffic_user_collect_locked() { :; }
traffic_user_reconcile() { :; }

sample 150 70 >"$root/counters.json"
traffic_collect
grep -Fq 'input ip daddr 192.0.2.10 tcp dport 443 counter comment "xrayctl-traffic:count:v4"' "$root/nft.log"
grep -Fq 'output ip saddr 192.0.2.10 tcp sport 443 counter comment "xrayctl-traffic:count:v4"' "$root/nft.log"
grep -Fq 'input ip6 daddr 2001:0db8:0000:0000:0000:0000:0000:0010 tcp dport 443 counter comment "xrayctl-traffic:count:v6"' "$root/nft.log"
grep -Fq 'output ip6 saddr 2001:0db8:0000:0000:0000:0000:0000:0010 tcp sport 443 counter comment "xrayctl-traffic:count:v6"' "$root/nft.log"
jq -e '.rulesInventory.v6.port==443 and .rulesInventory.v6.listen=="2001:db8::10" and .kernelCounters=={}' "$TRAFFIC_FILE" >/dev/null

sample 25 0 >"$root/counters.json"
traffic_collect
jq -e '.inbounds.v4.daily["2026-11-18"]==350 and .inbounds.v6.daily["2026-11-18"]==140' "$TRAFFIC_FILE" >/dev/null
sample 25 15 >"$root/counters.json"
traffic_collect
traffic_collect
jq -e '.inbounds.v4.daily["2026-11-18"]==350 and .inbounds.v6.daily["2026-11-18"]==170 and
       .inbounds.v4.cycles["2026-11-01 00:00:00"]==350 and .inbounds.v6.cycles["2026-11-01 00:00:00"]==170 and
       .totals.cycles["2026-11-01 00:00:00"]==520 and .inbounds.v6.users.kept.limit.enabled' "$TRAFFIC_FILE" >/dev/null

pass "shared-port listeners, address-specific rules, and legacy counter migration"

# The listener edit must snapshot the old counters before any rule reset,
# install the new IP match before restart, and roll back on firewall failure.
ensure_system_context() { :; }
setup_runtime_access() { :; }
RUNTIME_OWNER=$(id -un)
RUNTIME_GROUP=$(id -gn)
XRAY_BIN="$root/missing/xray"
detect_local_ips() { printf '%s\t%s\teth0\n' IPv4 192.0.2.11 IPv4 192.0.2.12 IPv6 2001:db8::10; }
live_sockets=""
jq -n '{schema:4,inbounds:{v4:{host:"192.0.2.10"}},
  migrations:{legacyCertScanV1:true,legacyCertbotSymlinkV1:true}}' >"$META_FILE"
nft() {
  if [[ $1 == -j ]]; then cat "$root/counters.json"; return; fi
  if [[ $1 == add && $2 == table ]]; then
    sample 0 0 >"$root/counters.json"
    if [[ -e $root/fail-firewall ]]; then
      rm -f "$root/fail-firewall"
      return 1
    fi
  fi
  local IFS=' '; printf '%s\n' "$*" >>"$root/nft.log"
}
restart_service() {
  [[ ${TRAFFIC_LOCK_HELD:-0} == 1 ]] || fail "listener restarted outside the traffic lock"
  jq -e --slurpfile config "$CONFIG_FILE" '
    .rulesInventory.v4.listen == ($config[0].inbounds[] | select(.tag=="v4") | .listen)
  ' "$TRAFFIC_FILE" >/dev/null || fail "listener restarted before preparing its firewall rule"
  printf '%s\n' restart >>"$root/restart-log"
}

sample 35 15 >"$root/counters.json"
modify_inbound_client_address v4 <<<$'1\n1' >/dev/null
jq -e '.rulesInventory.v4.listen=="192.0.2.11" and .kernelCounters=={} and
  .inbounds.v4.cycles["2026-11-01 00:00:00"]==370 and .totals.cycles["2026-11-01 00:00:00"]==540' "$TRAFFIC_FILE" >/dev/null
assert_eq 443 "$(inbound_effective_port v4)" "switching the listener changed the port"
assert_eq 192.0.2.11 "$(public_host_for_tag v4)" "switching the listener lost the share address"
cp "$CONFIG_FILE" "$root/before-failure.json"
cp "$META_FILE" "$root/before-failure-meta.json"

sample 5 0 >"$root/counters.json"
touch "$root/fail-firewall"
assert_failure modify_inbound_client_address v4 <<<$'1\n2'
assert_file_eq "$root/before-failure.json" "$CONFIG_FILE" "firewall failure changed listener config"
assert_file_eq "$root/before-failure-meta.json" "$META_FILE" "firewall failure changed share metadata"
assert_eq restart "$(cat "$root/restart-log")" "firewall failure must stop before restarting Xray"
jq -e '.rulesInventory.v4.listen=="192.0.2.11" and .inbounds.v4.cycles["2026-11-01 00:00:00"]==380 and
  .totals.cycles["2026-11-01 00:00:00"]==550 and .inbounds.v6.users.kept.limit.enabled' "$TRAFFIC_FILE" >/dev/null
pass "listener edits protect the counter transition and roll back when firewall rules cannot be installed"
