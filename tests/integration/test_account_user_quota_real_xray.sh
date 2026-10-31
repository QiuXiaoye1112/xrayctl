#!/usr/bin/env bash
set -Eeuo pipefail
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
bin=${XRAYCTL_REAL_XRAY_BIN:-}
if [[ -z $bin ]]; then printf 'ok - real authenticated account quota test skipped (set XRAYCTL_REAL_XRAY_BIN)\n'; exit 0; fi
for cmd in jq curl python3; do command -v "$cmd" >/dev/null || { printf 'not ok - missing %s\n' "$cmd" >&2; exit 1; }; done
source "$root/tests/helpers/http.sh"
test_root=$(mktemp -d "${TMPDIR:-/tmp}/xrayctl-account-quota.XXXXXX")
server_pid=''
listener_pid=''
cleanup_account_test() {
  [[ -z $server_pid ]] || kill "$server_pid" 2>/dev/null || true
  [[ -z $listener_pid ]] || kill "$listener_pid" 2>/dev/null || true
  wait 2>/dev/null || true
  if [[ ${XRAYCTL_TEST_KEEP:-0} == 1 ]]; then printf 'test files: %s\n' "$test_root" >&2; else rm -rf "$test_root"; fi
}
trap cleanup_account_test EXIT
base=$((30000 + RANDOM % 20000)); api=$base; socks=$((base+1)); http=$((base+2))
export XRAYCTL_TESTING=1 XRAYCTL_TMP_DIR="$test_root" XRAYCTL_CONFIG_DIR="$test_root/config"
export XRAYCTL_CONFIG_FILE="$test_root/config/config.json" XRAYCTL_META_FILE="$test_root/config/meta.json"
export XRAYCTL_TRAFFIC_FILE="$test_root/traffic.json" XRAYCTL_LOCK_FILE="$test_root/lock" XRAYCTL_XRAY_BIN="$bin"
export XRAYCTL_RUNTIME_OWNER XRAYCTL_RUNTIME_GROUP XRAYCTL_PUBLIC_HOST=127.0.0.1
XRAYCTL_RUNTIME_OWNER=$(id -un); XRAYCTL_RUNTIME_GROUP=$(id -gn)
mkdir -p "$XRAYCTL_CONFIG_DIR"
source "$root/xrayctl.sh"
trap - ERR
trap cleanup_account_test EXIT
# Validate the exact SOCKS/HTTP builder shape, including the duplicate
# compatibility `users` fields, against the pinned core before exercising it.
jq -n --slurpfile socks "$root/tests/fixtures/protocols/socks.json" --slurpfile http "$root/tests/fixtures/protocols/http.json" --argjson socksport "$((base+10))" --argjson httpport "$((base+11))" '
  {log:{loglevel:"warning"},inbounds:[$socks[0],$http[0]],outbounds:[{tag:"direct",protocol:"freedom"}],routing:{rules:[]}} |
  .inbounds[0].listen="127.0.0.1" | .inbounds[0].port=$socksport |
  .inbounds[1].listen="127.0.0.1" | .inbounds[1].port=$httpport
' >"$test_root/builder-check.json"
"$bin" run -test -config "$test_root/builder-check.json" >"$test_root/builder-check.log" 2>&1 || { cat "$test_root/builder-check.log" >&2; exit 1; }
jq -n --argjson socks "$socks" --argjson http "$http" '{
  log:{loglevel:"warning"},
  inbounds:[
    {tag:"socks-in",listen:"127.0.0.1",port:$socks,protocol:"socks",settings:{auth:"password",accounts:[{user:"socks-one",pass:"socks-pass"},{user:"socks-two",pass:"second-pass"}] }},
    {tag:"http-in",listen:"127.0.0.1",port:$http,protocol:"http",settings:{accounts:[{user:"http-one",pass:"http-pass"}]}}
  ],outbounds:[{tag:"direct",protocol:"freedom"}],routing:{rules:[]}
}' >"$test_root/input.json"
traffic_user_prepare_config "$test_root/input.json" "$CONFIG_FILE" "127.0.0.1:$api"
printf '%s\n' '{"schema":4,"inbounds":{},"certificates":{},"managedResources":{},"migrations":{}}' >"$META_FILE"
traffic_default_json | jq '.enabled=true' >"$TRAFFIC_FILE"

start_account_test_xray() {
  "$bin" run -config "$CONFIG_FILE" >"$test_root/xray.log" 2>&1 & server_pid=$!
  for _ in {1..80}; do
    if "$bin" api statsquery -s "127.0.0.1:$api" -t 1 -pattern 'user>>>' >/dev/null 2>&1; then return 0; fi
    kill -0 "$server_pid" || { cat "$test_root/xray.log" >&2; return 1; }
    sleep .1
  done
  return 1
}
restart_account_test_xray() {
  [[ -z $server_pid ]] || { kill "$server_pid"; wait "$server_pid" || true; }
  server_pid=''
  start_account_test_xray
}
service_is_active() { [[ -n $server_pid ]] && kill -0 "$server_pid" 2>/dev/null; }
restart_service() { restart_account_test_xray; }
setup_runtime_access() { :; }
ensure_config() { :; }
require_xray_installed() { :; }
traffic_runtime_ensure() { :; }
traffic_timer_install() { :; }
traffic_user_core_epoch() { service_is_active || return 1; printf 'test:%s' "$server_pid"; }
XRAYCTL_MANAGEMENT_LOCK_HELD=1
start_account_test_xray

test_http_server_start "$test_root/http-port"
listener_pid=$TEST_HTTP_SERVER_PID
target=$TEST_HTTP_SERVER_PORT
request_socks() {
  curl -fsS --noproxy '' --max-time 5 --proxy-user "$1" --socks5-hostname "127.0.0.1:$socks" "http://127.0.0.1:$target/"
}
request_http() {
  curl -fsS --noproxy '' --max-time 5 --proxy "http://127.0.0.1:$http" --proxy-user "$1" "http://127.0.0.1:$target/"
}
fetch_blocked_socks() { curl -fsS --noproxy '' --max-time 3 --proxy-user socks-one:socks-pass --socks5-hostname "127.0.0.1:$socks" "http://127.0.0.1:$target/"; }
fetch_blocked_http() { curl -fsS --noproxy '' --max-time 3 --proxy "http://127.0.0.1:$http" --proxy-user http-one:http-pass "http://127.0.0.1:$target/"; }

# Exercise both credentials first and prove StatsService reports independent
# username counters. They are not VLESS email fields in the inbound JSON.
[[ $(request_socks socks-one:socks-pass) == hello ]]
[[ $(request_socks socks-two:second-pass) == hello ]]
[[ $(request_http http-one:http-pass) == hello ]]
stats=$(traffic_user_read_samples "127.0.0.1:$api")
jq -e '."socks-one".uplink>0 and ."socks-one".downlink>0 and ."socks-two".uplink>0 and ."http-one".uplink>0' <<<"$stats" >/dev/null

traffic_user_limit_set socks-in socks-two 100 15 12:00
traffic_user_limit_set socks-in socks-one 0.00000001 1 00:00
[[ $(request_socks socks-one:socks-pass) == hello ]]

traffic_user_collect_serialized
traffic_user_reconcile
id_socks=$(traffic_user_id socks-in socks-one)
jq -e --arg id "$id_socks" '.inbounds["socks-in"].users[$id].limit.usedBytes>.inbounds["socks-in"].users[$id].limit.quotaBytes' "$TRAFFIC_FILE" >/dev/null
jq -e --arg id "$id_socks" '[.routing.rules[]|select(.ruleTag==("xrayctl-user-limit:"+$id) and .inboundTag==["socks-in"] and .user==[$id])]|length==1' "$CONFIG_FILE" >/dev/null
blocked_response=$(fetch_blocked_socks 2>/dev/null || true)
if [[ $blocked_response == hello ]]; then printf 'not ok - exhausted SOCKS user was not blocked\n' >&2; exit 1; fi
[[ $(request_socks socks-two:second-pass) == hello ]]
[[ $(request_http http-one:http-pass) == hello ]]

traffic_user_limit_set http-in http-one 0.00000001 1 00:00
[[ $(request_http http-one:http-pass) == hello ]]

traffic_user_collect_serialized
traffic_user_reconcile
id_http=$(traffic_user_id http-in http-one)
jq -e --arg id "$id_http" '[.routing.rules[]|select(.ruleTag==("xrayctl-user-limit:"+$id) and .inboundTag==["http-in"] and .user==[$id])]|length==1' "$CONFIG_FILE" >/dev/null
blocked_response=$(fetch_blocked_http 2>/dev/null || true)
if [[ $blocked_response == hello ]]; then printf 'not ok - exhausted HTTP user was not blocked\n' >&2; exit 1; fi
[[ $(request_socks socks-two:second-pass) == hello ]]
jq -e --arg socks_id "$id_socks" --arg http_id "$id_http" '([.routing.rules[]|select(.ruleTag==("xrayctl-user-limit:"+$socks_id))]|length)==1 and ([.routing.rules[]|select(.ruleTag==("xrayctl-user-limit:"+$http_id))]|length)==1' "$CONFIG_FILE" >/dev/null
printf 'ok - real Xray authenticated SOCKS/HTTP stats, independent quotas and isolated bans\n'
