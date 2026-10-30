#!/usr/bin/env bash
set -Eeuo pipefail
if [[ ${XRAYCTL_TEST_OPENRC:-0} != 1 ]]; then printf 'ok - real OpenRC quota test skipped (set XRAYCTL_TEST_OPENRC=1)\n'; exit 0; fi
[[ $(id -u) == 0 && -f /etc/alpine-release ]] || { printf 'not ok - real OpenRC test requires Alpine root\n' >&2; exit 1; }
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
bin=${XRAYCTL_REAL_XRAY_BIN:?set XRAYCTL_REAL_XRAY_BIN}
for cmd in jq rc-service rc-update; do command -v "$cmd" >/dev/null || exit 1; done
TEST_ROOT=$(mktemp -d /tmp/xrayctl-openrc-test.XXXXXXXX)
name="xrayctl-user-test-${TEST_ROOT##*.}"
unit="/etc/init.d/$name"
cleanup_test() {
  rc-service "$name" stop >/dev/null 2>&1 || true
  rm -f "$unit" "/run/$name.pid"
  rm -rf "$TEST_ROOT"
}
trap cleanup_test EXIT
mkdir -p "$TEST_ROOT"/{config,state,lock}
export XRAYCTL_TMP_DIR="$TEST_ROOT/state" XRAYCTL_CONFIG_DIR="$TEST_ROOT/config"
export XRAYCTL_CONFIG_FILE="$TEST_ROOT/config/config.json" XRAYCTL_META_FILE="$TEST_ROOT/config/meta.json"
export XRAYCTL_TRAFFIC_FILE="$TEST_ROOT/state/traffic.json" XRAYCTL_LOCK_FILE="$TEST_ROOT/lock/xrayctl.lock"
export XRAYCTL_XRAY_BIN="$bin" XRAYCTL_RUNTIME_OWNER=root XRAYCTL_RUNTIME_GROUP=root XRAYCTL_SERVICE_NAME="$name"
export XRAYCTL_PLATFORM=openrc
source "$root/xrayctl.sh"
trap - ERR
trap cleanup_test EXIT
base=$((40000 + RANDOM % 20000)); api=$base; inbound=$((base+1))
jq --argjson port "$inbound" 'del(.api,.stats,.policy) | .inbounds[0].port=$port | .routing.rules=[]' "$root/tests/fixtures/user-traffic/server.json" > "$TEST_ROOT/input.json"
traffic_user_prepare_config "$TEST_ROOT/input.json" "$CONFIG_FILE" "127.0.0.1:$api"
printf '%s\n' '{"schema":4,"inbounds":{},"certificates":{},"managedResources":{},"migrations":{}}' > "$META_FILE"
id=$(jq -r '.inbounds[0].settings.clients[0].email' "$CONFIG_FILE")
traffic_default_json | jq --arg id "$id" '.enabled=true | .inbounds.a={daily:{},users:{($id):{label:"alice",limit:{enabled:true,quotaBytes:1,usedBytes:1,anchorDay:1,anchorTime:"00:00:00",cycleStart:"2026-01-01 00:00:00",cycleEnd:"2099-01-01 00:00:00"}}}}' > "$TRAFFIC_FILE"
cat >"$unit" <<UNIT
#!/sbin/openrc-run
command="$bin"
command_args="run -config $CONFIG_FILE"
command_background=true
pidfile="/run/$name.pid"
output_log="$TEST_ROOT/server.log"
error_log="$TEST_ROOT/error.log"
UNIT
chmod 755 "$unit"
rc-service "$name" start
pid_before=$(cat "/run/$name.pid")
for _ in {1..50}; do
  if "$bin" api statsquery -s "127.0.0.1:$api" -t 1 -pattern 'user>>>' >/dev/null 2>&1; then break; fi
  sleep .1
done
traffic_user_collect_serialized
traffic_user_reconcile
pid_after=$(cat "/run/$name.pid")
[[ $pid_before != "$pid_after" ]]
jq -e --arg id "$id" '.routing.rules[0].user==[$id] and .routing.rules[0].outboundTag=="xrayctl-user-deny"' "$CONFIG_FILE" >/dev/null
printf 'ok - OpenRC persists quota rule and restarts isolated real Xray service\n'
