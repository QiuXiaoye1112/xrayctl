#!/usr/bin/env bash
set -Eeuo pipefail
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
bin=${XRAYCTL_REAL_XRAY_BIN:-}
if [[ -z $bin ]]; then printf 'ok - real user quota test skipped (set XRAYCTL_REAL_XRAY_BIN)\n'; exit 0; fi
for cmd in jq curl nc; do command -v "$cmd" >/dev/null || { printf 'not ok - missing %s\n' "$cmd" >&2; exit 1; }; done
TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/xrayctl-user-quota.XXXXXX")
server_pid='' client_pid='' listener_pid='' tls_pid=''
cleanup_test() {
  if [[ ${XRAYCTL_TEST_KEEP:-0} == 1 && ${XRAYCTL_TEST_FIREWALL:-0} == 1 ]]; then
    iptables-save >"$TEST_ROOT/iptables.txt" 2>/dev/null || true
    if command -v nft >/dev/null; then nft -j list ruleset >"$TEST_ROOT/nft.json" 2>/dev/null || true; fi
  fi
  for pid in "$server_pid" "$client_pid" "$listener_pid" "$tls_pid"; do [[ -z $pid ]] || kill "$pid" 2>/dev/null || true; done
  wait 2>/dev/null || true
  if [[ ${XRAYCTL_TEST_KEEP:-0} == 1 ]]; then printf 'test files: %s\n' "$TEST_ROOT" >&2; else rm -rf "$TEST_ROOT"; fi
}
trap cleanup_test EXIT
export XRAYCTL_TESTING=1 XRAYCTL_TMP_DIR="$TEST_ROOT" XRAYCTL_CONFIG_DIR="$TEST_ROOT/config"
export XRAYCTL_CONFIG_FILE="$TEST_ROOT/config/config.json" XRAYCTL_META_FILE="$TEST_ROOT/config/meta.json"
export XRAYCTL_TRAFFIC_FILE="$TEST_ROOT/traffic.json" XRAYCTL_LOCK_FILE="$TEST_ROOT/lock" XRAYCTL_XRAY_BIN="$bin"
export XRAYCTL_RUNTIME_OWNER XRAYCTL_RUNTIME_GROUP
XRAYCTL_RUNTIME_OWNER=$(id -un); XRAYCTL_RUNTIME_GROUP=$(id -gn)
mkdir -p "$XRAYCTL_CONFIG_DIR"
source "$root/xrayctl.sh"
trap - ERR
trap cleanup_test EXIT
base=$((30000 + RANDOM % 20000)); api=$base; inbound=$((base+1)); alice=$((base+2)); bob=$((base+3)); target=$((base+4)); tls_port=$((base+5)); other_in=$((base+6)); other_socks=$((base+7))
jq --argjson port "$inbound" 'del(.api,.stats,.policy) | .inbounds[0].port=$port | .routing.rules=[]' "$root/tests/fixtures/user-traffic/server.json" >"$TEST_ROOT/input.json"
if [[ ${XRAYCTL_TEST_DUPLICATE:-0} == 1 ]]; then
  jq --argjson port "$other_in" '.inbounds += [{tag:"b",listen:"127.0.0.1",port:$port,protocol:"vless",settings:{decryption:"none",clients:[{email:"alice",id:"123e4567-e89b-12d3-a456-426614174002"}]}}]' "$TEST_ROOT/input.json" >"$TEST_ROOT/duplicate.json"
  mv "$TEST_ROOT/duplicate.json" "$TEST_ROOT/input.json"
fi
if [[ ${XRAYCTL_TEST_REALITY:-0} == 1 ]]; then
  command -v openssl >/dev/null || { printf 'not ok - openssl is required for REALITY test\n' >&2; exit 1; }
  keys=$("$bin" x25519)
  private=$(awk '/^PrivateKey:/ {print $2}' <<<"$keys")
  public=$(awk '/^Password \(PublicKey\):/ {print $3}' <<<"$keys")
  [[ -n $private && -n $public ]]
  reality_name=${XRAYCTL_TEST_REALITY_NAME:-example.com}
  reality_target=${XRAYCTL_TEST_REALITY_TARGET:-127.0.0.1:$tls_port}
  if [[ -z ${XRAYCTL_TEST_REALITY_TARGET:-} ]]; then
    openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -subj "/CN=$reality_name" -addext "subjectAltName=DNS:$reality_name" -keyout "$TEST_ROOT/tls.key" -out "$TEST_ROOT/tls.crt" -days 1 > /dev/null 2>&1
    openssl s_server -accept "127.0.0.1:$tls_port" -cert "$TEST_ROOT/tls.crt" -key "$TEST_ROOT/tls.key" -cert2 "$TEST_ROOT/tls.crt" -key2 "$TEST_ROOT/tls.key" -servername "$reality_name" -alpn h2,http/1.1 -tls1_3 -www -quiet >"$TEST_ROOT/tls.log" 2>&1 & tls_pid=$!
    sleep .3
    if ! kill -0 "$tls_pid" 2>/dev/null; then cat "$TEST_ROOT/tls.log" >&2; exit 1; fi
  fi
  jq --arg private "$private" --arg target "$reality_target" --arg name "$reality_name" '
    .log.loglevel="debug" | .inbounds[0].streamSettings={network:"raw",security:"reality",realitySettings:{show:true,dest:$target,serverNames:[$name],privateKey:$private,shortIds:["0123456789abcdef"]}} |
    .inbounds[0].settings.clients[].flow="xtls-rprx-vision" |
    if (.inbounds|length)>1 then .inbounds[1].streamSettings=.inbounds[0].streamSettings | .inbounds[1].settings.clients[].flow="xtls-rprx-vision" else . end' "$TEST_ROOT/input.json" >"$TEST_ROOT/reality-input.json"
  mv "$TEST_ROOT/reality-input.json" "$TEST_ROOT/input.json"
fi
traffic_user_prepare_config "$TEST_ROOT/input.json" "$CONFIG_FILE" "127.0.0.1:$api"
jq --argjson port "$inbound" --argjson alice "$alice" --argjson bob "$bob" '.inbounds[0].port=$alice | .inbounds[1].port=$bob | .outbounds[].settings.vnext[0].port=$port' "$root/tests/fixtures/user-traffic/client.json" >"$TEST_ROOT/client.json"
if [[ ${XRAYCTL_TEST_DUPLICATE:-0} == 1 ]]; then
  jq --argjson port "$other_in" --argjson socks "$other_socks" '
    .inbounds += [{tag:"other-in",listen:"127.0.0.1",port:$socks,protocol:"socks",settings:{auth:"noauth"}}] |
    (.outbounds[0] | .tag="other" | .settings.vnext[0].port=$port | .settings.vnext[0].users[0].id="123e4567-e89b-12d3-a456-426614174002") as $other |
    .outbounds += [$other] | .routing.rules += [{type:"field",inboundTag:["other-in"],outboundTag:"other"}]' "$TEST_ROOT/client.json" >"$TEST_ROOT/duplicate-client.json"
  mv "$TEST_ROOT/duplicate-client.json" "$TEST_ROOT/client.json"
fi
if [[ ${XRAYCTL_TEST_REALITY:-0} == 1 ]]; then
  jq --arg public "$public" --arg name "$reality_name" '
    .log.loglevel="debug" | .outbounds[].streamSettings={network:"raw",security:"reality",realitySettings:{show:true,serverName:$name,fingerprint:"chrome",publicKey:$public,shortId:"0123456789abcdef",spiderX:"/"}} |
    .outbounds[].settings.vnext[0].users[].flow="xtls-rprx-vision"' "$TEST_ROOT/client.json" >"$TEST_ROOT/reality-client.json"
  mv "$TEST_ROOT/reality-client.json" "$TEST_ROOT/client.json"
fi
printf '%s\n' '{"schema":4,"inbounds":{},"certificates":{},"managedResources":{},"migrations":{}}' > "$META_FILE"
traffic_default_json | jq '.enabled=true | .limitsEnabled=true' > "$TRAFFIC_FILE"
start_test_server() {
  "$bin" run -config "$CONFIG_FILE" >"$TEST_ROOT/server.log" 2>&1 & server_pid=$!
  for _ in {1..50}; do
    if "$bin" api statsquery -s "127.0.0.1:$api" -t 1 -pattern 'user>>>' >/dev/null 2>&1; then return 0; fi
    kill -0 "$server_pid" || { cat "$TEST_ROOT/server.log" >&2; return 1; }
    sleep .1
  done
  return 1
}
start_test_server
start_test_client() { "$bin" run -config "$TEST_ROOT/client.json" >"$TEST_ROOT/client.log" 2>&1 & client_pid=$!; sleep .5; }
restart_test_client() { kill "$client_pid"; wait "$client_pid" || true; client_pid=''; start_test_client; }
start_test_client
ensure_config() { :; }
setup_runtime_access() { :; }
traffic_timer_install() { :; }
service_is_active() { [[ -n $server_pid ]] && kill -0 "$server_pid" 2>/dev/null; }
traffic_user_core_epoch() { service_is_active || return 1; printf 'test:%s' "$server_pid"; }
restart_service() { kill "$server_pid"; wait "$server_pid" || true; server_pid=''; start_test_server; }
if [[ ${XRAYCTL_TEST_FIREWALL:-0} == 1 ]]; then
  [[ $(readlink /proc/self/ns/net) != "$(readlink /proc/1/ns/net)" ]] || { printf 'not ok - firewall test requires an isolated network namespace\n' >&2; exit 1; }
  export XRAYCTL_TRAFFIC_BACKEND=${XRAYCTL_TEST_BACKEND:-iptables}
  traffic_set_backend "$XRAYCTL_TRAFFIC_BACKEND"
  traffic_rules_restore
else
  traffic_read_counters() { printf 'a\t10\n'; }
  traffic_rules_restore() { :; }
fi
confirm() { return 0; }
XRAYCTL_MANAGEMENT_LOCK_HELD=1
respond() { printf 'HTTP/1.1 200 OK\r\nContent-Length: 5\r\nConnection: close\r\n\r\nhello' | nc -l 127.0.0.1 "$target" >/dev/null & listener_pid=$!; sleep .2; }
fetch() { curl -fsS --noproxy '' --max-time "${XRAYCTL_TEST_CURL_TIMEOUT:-20}" --socks5-hostname "127.0.0.1:$1" "http://127.0.0.1:$target/"; }
fetch_blocked() { XRAYCTL_TEST_CURL_TIMEOUT=4 fetch "$1"; }
traffic_user_limit_set a alice 0.00000001 1 00:00
respond
if [[ $(fetch "$alice") != hello ]]; then printf 'not ok - Alice could not connect before exhaustion\n' >&2; exit 1; fi
wait "$listener_pid" || true; listener_pid=''
traffic_collect
id_a=$(traffic_user_id a alice)
jq -e --arg id "$id_a" '.inbounds.a.users[$id] as $user | $user.limit.usedBytes > $user.limit.quotaBytes and $user.limit.usedBytes==2*($user.uplinkBytes+$user.downlinkBytes)' "$TRAFFIC_FILE" >/dev/null
jq -e --arg id "$id_a" '.routing.rules[0].user==[$id] and .routing.rules[0].inboundTag==["a"]' "$CONFIG_FILE" >/dev/null
respond
if fetch_blocked "$alice" >/dev/null 2>&1; then printf 'not ok - exhausted user was not blocked\n' >&2; exit 1; fi
if [[ $(fetch "$bob") != hello ]]; then printf 'not ok - Bob could not connect while Alice was blocked\n' >&2; exit 1; fi
wait "$listener_pid" || true; listener_pid=''
if [[ ${XRAYCTL_TEST_DUPLICATE:-0} == 1 ]]; then
  id_other=$(traffic_user_id b alice)
  [[ $id_other != "$id_a" ]]
  respond
  if [[ $(fetch "$other_socks") != hello ]]; then printf 'not ok - same-named user in another inbound was blocked\n' >&2; exit 1; fi
  wait "$listener_pid" || true; listener_pid=''
  traffic_user_collect_serialized
  jq -e --arg first "$id_a" --arg second "$id_other" '.inbounds.a.users[$first].limit.usedBytes>0 and .inbounds.b.users[$second].uplinkBytes>0 and .inbounds.b.users[$second].downlinkBytes>0' "$TRAFFIC_FILE" >/dev/null
fi
if [[ ${XRAYCTL_TEST_FIREWALL:-0} == 1 ]]; then
  # The inbound and user limits are independent: resetting one cannot bypass
  # an exhausted limit at the other level.
  jq '.inbounds.a.limit={enabled:true,quotaBytes:1,usedBytes:1,anchorDay:1,resetDay:1,anchorTime:"00:00:00",cycleStart:"2026-01-01 00:00:00",cycleEnd:"2099-01-01 00:00:00"}' "$TRAFFIC_FILE" >"$TEST_ROOT/state"
  cp "$TEST_ROOT/state" "$TRAFFIC_FILE"
  traffic_rules_restore_serialized
  respond
  if fetch_blocked "$bob" >/dev/null 2>&1; then printf 'not ok - exhausted inbound was not blocked\n' >&2; exit 1; fi
  restart_test_client
  jq '.inbounds.a.limit.usedBytes=0' "$TRAFFIC_FILE" >"$TEST_ROOT/state"
  cp "$TEST_ROOT/state" "$TRAFFIC_FILE"
  traffic_rules_restore_serialized
  if fetch_blocked "$alice" >/dev/null 2>&1; then printf 'not ok - inbound reset bypassed the user limit\n' >&2; exit 1; fi
  restart_test_client
  if [[ $(fetch "$bob") != hello ]]; then printf 'not ok - inbound reset did not restore Bob\n' >&2; exit 1; fi
  wait "$listener_pid" || true; listener_pid=''
  jq '.inbounds.a.limit.usedBytes=1' "$TRAFFIC_FILE" >"$TEST_ROOT/state"
  cp "$TEST_ROOT/state" "$TRAFFIC_FILE"
  traffic_rules_restore_serialized
  respond
  traffic_user_reset a alice
  if fetch_blocked "$alice" >/dev/null 2>&1; then printf 'not ok - user reset bypassed the inbound limit\n' >&2; exit 1; fi
  restart_test_client
  jq '.inbounds.a.limit.usedBytes=0' "$TRAFFIC_FILE" >"$TEST_ROOT/state"
  cp "$TEST_ROOT/state" "$TRAFFIC_FILE"
  traffic_rules_restore_serialized
  if [[ $(fetch "$alice") != hello ]]; then printf 'not ok - Alice could not connect after both resets\n' >&2; exit 1; fi
  wait "$listener_pid" || true; listener_pid=''
else
traffic_user_reset a alice
respond
if [[ $(fetch "$alice") != hello ]]; then printf 'not ok - Alice could not connect after reset\n' >&2; exit 1; fi
wait "$listener_pid" || true; listener_pid=''
fi
jq -e '[.routing.rules[] | select((.ruleTag // "")|startswith("xrayctl-user-limit:"))] | length==0' "$CONFIG_FILE" >/dev/null
# The previous successful request must be charged without duplicating earlier
# samples. If the API disappears while the user is blocked, inbound
# collection still succeeds and the persisted ban remains in place.
traffic_user_limit_set a alice 0.00000001 1 00:00
jq -e --arg id "$id_a" '.inbounds.a.users[$id].limit.usedBytes>0' "$TRAFFIC_FILE" >/dev/null
jq -e --arg id "$id_a" '[.routing.rules[] | select(.ruleTag==("xrayctl-user-limit:"+$id))] | length==1' "$CONFIG_FILE" >/dev/null
before_user=$(jq -cS --arg id "$id_a" '.inbounds.a.users[$id]' "$TRAFFIC_FILE")
kill "$server_pid"; wait "$server_pid" || true; server_pid=''
traffic_collect
after_user=$(jq -cS --arg id "$id_a" '.inbounds.a.users[$id]' "$TRAFFIC_FILE")
[[ $before_user == "$after_user" ]]
jq -e --arg id "$id_a" '[.routing.rules[] | select(.ruleTag==("xrayctl-user-limit:"+$id))] | length==1' "$CONFIG_FILE" >/dev/null
start_test_server
traffic_collect
jq -e --arg id "$id_a" '[.routing.rules[] | select(.ruleTag==("xrayctl-user-limit:"+$id))] | length==1' "$CONFIG_FILE" >/dev/null
cycle_end=$(jq -r --arg id "$id_a" '.inbounds.a.users[$id].limit.cycleEnd' "$TRAFFIC_FILE")
export XRAYCTL_TRAFFIC_NOW="$cycle_end"
traffic_collect
jq -e --arg id "$id_a" '.inbounds.a.users[$id].limit.usedBytes==0 and .inbounds.a.users[$id].limit.enabled==true' "$TRAFFIC_FILE" >/dev/null
jq -e '[.routing.rules[] | select((.ruleTag // "")|startswith("xrayctl-user-limit:"))] | length==0' "$CONFIG_FILE" >/dev/null
unset XRAYCTL_TRAFFIC_NOW
traffic_user_limit_remove a alice 1
jq -e --arg id "$id_a" '.inbounds.a.users[$id].limit==null' "$TRAFFIC_FILE" >/dev/null
jq -e '[.routing.rules[] | select((.ruleTag // "")|startswith("xrayctl-user-limit:"))] | length==0' "$CONFIG_FILE" >/dev/null
traffic_user_limit_set a alice 0.00000001 1 00:00
traffic_user_limit_set a bob 0.00000001 15 12:00
id_b=$(traffic_user_id a bob)
respond
if [[ $(fetch "$alice") != hello ]]; then printf 'not ok - Alice could not use her new quota\n' >&2; exit 1; fi
wait "$listener_pid" || true; listener_pid=''
traffic_collect
jq -e --arg a "$id_a" --arg b "$id_b" '[.routing.rules[] | select(.ruleTag==("xrayctl-user-limit:"+$a))] | length==1' "$CONFIG_FILE" >/dev/null
jq -e --arg b "$id_b" '[.routing.rules[] | select(.ruleTag==("xrayctl-user-limit:"+$b))] | length==0' "$CONFIG_FILE" >/dev/null
respond
if [[ $(fetch "$bob") != hello ]]; then printf 'not ok - Bob was blocked by Alice quota\n' >&2; exit 1; fi
wait "$listener_pid" || true; listener_pid=''
traffic_collect
jq -e --arg a "$id_a" --arg b "$id_b" '[.routing.rules[] | select(.ruleTag==("xrayctl-user-limit:"+$a) or .ruleTag==("xrayctl-user-limit:"+$b))] | length==2' "$CONFIG_FILE" >/dev/null
traffic_user_reset a alice 1
jq -e --arg a "$id_a" --arg b "$id_b" '([.routing.rules[] | select(.ruleTag==("xrayctl-user-limit:"+$a))]|length)==0 and ([.routing.rules[] | select(.ruleTag==("xrayctl-user-limit:"+$b))]|length)==1' "$CONFIG_FILE" >/dev/null
printf 'ok - real user quota collection, isolation, persistence and recovery\n'
