#!/usr/bin/env bash
set -Eeuo pipefail
if [[ ${XRAYCTL_TEST_SYSTEMD:-0} != 1 ]]; then printf 'ok - real systemd quota test skipped (set XRAYCTL_TEST_SYSTEMD=1)\n'; exit 0; fi
[[ $(id -u) == 0 ]] || { printf 'not ok - real systemd test requires root\n' >&2; exit 1; }
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
bin=${XRAYCTL_REAL_XRAY_BIN:?set XRAYCTL_REAL_XRAY_BIN}
for cmd in jq curl nc ss systemctl systemd-run; do command -v "$cmd" >/dev/null || exit 1; done
TEST_ROOT=$(mktemp -d /var/lib/xrayctl-systemd-test.XXXXXXXX)
name="xrayctl-user-test-${TEST_ROOT##*.}"
unit="/run/systemd/system/${name}.service"
client_pid=""; listener_pid=""
source "$root/tests/helpers/netcat.sh"
cleanup_test() {
  local status=$?
  if ((status != 0)); then
    cat "$TEST_ROOT/client.log" "${log_dir:-$TEST_ROOT/logs}/error.log" 2>/dev/null || true
    cat "${collector_unit:-/dev/null}" 2>/dev/null || true
    systemctl show "${name}-collector" -p ProtectSystem -p ReadWritePaths || true
    journalctl -u "$name" -u "${name}-collector" -n 25 --no-pager || true
  fi
  for pid in "$client_pid" "$listener_pid"; do [[ -z $pid ]] || kill "$pid" 2>/dev/null || true; done
  wait 2>/dev/null || true
  systemctl stop "$name" "${name}-collector" >/dev/null 2>&1 || true
  systemctl reset-failed "${name}-collector" >/dev/null 2>&1 || true
  rm -f "$unit" "/run/systemd/system/${name}-collector.service"
  systemctl daemon-reload >/dev/null 2>&1 || true
  rm -rf "$TEST_ROOT"
}
trap cleanup_test EXIT
mkdir -p "$TEST_ROOT"/{repo,bin,config,state,lock,counter-lock,logs,units}
log_dir="$TEST_ROOT/logs"
if [[ ${XRAYCTL_TEST_CUSTOM_LOGS:-0} == 1 ]]; then log_dir="$TEST_ROOT/custom logs%literal"; fi
mkdir -p "$log_dir"
if [[ ${XRAYCTL_TEST_CUSTOM_LOGS:-0} == 1 ]]; then rmdir "$TEST_ROOT/logs"; fi
cp -R "$root/src" "$root/xrayctl.sh" "$TEST_ROOT/repo/"
cp "$bin" "$TEST_ROOT/bin/xray"
cp "$(command -v jq)" "$TEST_ROOT/bin/jq"
chmod 755 "$TEST_ROOT/bin/xray" "$TEST_ROOT/bin/jq"
unset XRAYCTL_TMP_DIR
export XRAYCTL_LOG_DIR="$TEST_ROOT/logs"
export XRAYCTL_CONFIG_DIR="$TEST_ROOT/config"
export XRAYCTL_CONFIG_FILE="$TEST_ROOT/config/config.json" XRAYCTL_META_FILE="$TEST_ROOT/config/meta.json"
export XRAYCTL_TRAFFIC_LOCK="$TEST_ROOT/counter-lock/traffic"
export XRAYCTL_TRAFFIC_FILE="$TEST_ROOT/state/traffic.json" XRAYCTL_LOCK_FILE="$TEST_ROOT/lock/xrayctl.lock"
export XRAYCTL_XRAY_BIN="$TEST_ROOT/bin/xray" XRAYCTL_RUNTIME_OWNER=root XRAYCTL_RUNTIME_GROUP=root XRAYCTL_SERVICE_NAME="$name"
export PATH="$TEST_ROOT/bin:$PATH"
source "$TEST_ROOT/repo/xrayctl.sh"
trap - ERR
trap cleanup_test EXIT
base=$((40000 + RANDOM % 20000)); api=$base; inbound=$((base+1))
jq --arg logs "$log_dir" --argjson port "$inbound" 'del(.api,.stats,.policy) | .log={access:($logs+"/access.log"),error:($logs+"/error.log"),loglevel:"debug"} | .inbounds[0].port=$port | .routing.rules=[]' "$root/tests/fixtures/user-traffic/server.json" > "$TEST_ROOT/input.json"
traffic_user_prepare_config "$TEST_ROOT/input.json" "$CONFIG_FILE" "127.0.0.1:$api"
printf '%s\n' '{"schema":4,"inbounds":{},"certificates":{},"managedResources":{},"migrations":{}}' > "$META_FILE"
id=$(jq -r '.inbounds[0].settings.clients[0].email' "$CONFIG_FILE")
traffic_default_json | jq --arg id "$id" '.enabled=true | .inbounds.a={daily:{},users:{($id):{label:"alice",limit:{enabled:true,quotaBytes:1,usedBytes:1,anchorDay:1,anchorTime:"00:00:00",cycleStart:"2026-01-01 00:00:00",cycleEnd:"2099-01-01 00:00:00"}}}}' > "$TRAFFIC_FILE"
cat >"$unit" <<UNIT
[Unit]
Description=Temporary xrayctl user quota integration test
[Service]
Type=simple
ExecStart=$TEST_ROOT/bin/xray run -config $TEST_ROOT/config/config.json
UNIT
systemctl daemon-reload
systemctl start "$name"
wait_server() {
  local attempt
  for attempt in {1..50}; do
    if "$TEST_ROOT/bin/xray" api statsquery -s "127.0.0.1:$api" -t 1 -pattern 'user>>>' >/dev/null 2>&1; then return 0; fi
    sleep .1
  done
  return 1
}
wait_server
pid_before=$(systemctl show "$name" -p MainPID --value)
alice=$((base+2)); bob=$((base+3)); target=$((base+4))
jq --argjson port "$inbound" --argjson alice "$alice" --argjson bob "$bob" '.inbounds[0].port=$alice | .inbounds[1].port=$bob | .outbounds[].settings.vnext[0].port=$port' "$root/tests/fixtures/user-traffic/client.json" >"$TEST_ROOT/client.json"
"$TEST_ROOT/bin/xray" run -config "$TEST_ROOT/client.json" >"$TEST_ROOT/client.log" 2>&1 & client_pid=$!
ready=0
for attempt in {1..50}; do
  if ss -lntH "sport = :$alice" | grep -q .; then ready=1; break; fi
  kill -0 "$client_pid" || { cat "$TEST_ROOT/client.log"; exit 1; }
  sleep .1
done
[[ $ready == 1 ]]
probe() {
  local port=$1 expected=$2 output status=0
  wait_server
  printf 'HTTP/1.1 200 OK\r\nContent-Length: 5\r\nConnection: close\r\n\r\nhello' | test_nc_listen_loopback "$target" >/dev/null & listener_pid=$!
  sleep .2
  output=$(curl -fsS --noproxy '' --max-time 3 --socks5-hostname "127.0.0.1:$port" "http://127.0.0.1:$target/" 2>/dev/null) || status=$?
  kill "$listener_pid" 2>/dev/null || true; wait "$listener_pid" 2>/dev/null || true; listener_pid=""
  if [[ $expected == allow ]]; then [[ $status == 0 && $output == hello ]]; else [[ $status != 0 ]]; fi
}
probe "$alice" allow

cat >"$TEST_ROOT/collect.sh" <<SCRIPT
#!/usr/bin/env bash
set -Eeuo pipefail
export PATH="$TEST_ROOT/bin:\$PATH"
unset XRAYCTL_TMP_DIR
export XRAYCTL_LOG_DIR="$TEST_ROOT/logs"
export XRAYCTL_CONFIG_DIR="$TEST_ROOT/config"
export XRAYCTL_CONFIG_FILE="$TEST_ROOT/config/config.json" XRAYCTL_META_FILE="$TEST_ROOT/config/meta.json"
export XRAYCTL_TRAFFIC_LOCK="$TEST_ROOT/counter-lock/traffic"
export XRAYCTL_TRAFFIC_FILE="$TEST_ROOT/state/traffic.json" XRAYCTL_LOCK_FILE="$TEST_ROOT/lock/xrayctl.lock"
export XRAYCTL_XRAY_BIN="$TEST_ROOT/bin/xray" XRAYCTL_RUNTIME_OWNER=root XRAYCTL_RUNTIME_GROUP=root XRAYCTL_SERVICE_NAME="$name"
source "$TEST_ROOT/repo/xrayctl.sh"
traffic_user_collect_serialized
traffic_user_reconcile
SCRIPT
chmod 755 "$TEST_ROOT/collect.sh"
# Generate the actual collector unit instead of duplicating its sandbox here.
TRAFFIC_SYSTEMD_SERVICE="$TEST_ROOT/units/collector.service"
TRAFFIC_SYSTEMD_TIMER="$TEST_ROOT/units/collector.timer"
QUICK_COMMAND="$TEST_ROOT/collect.sh"
systemctl() { :; }
traffic_timer_install
unset -f systemctl
# Keep the global xtables lock untouched by this isolated test.
sed -i "s|/run/xtables.lock|$TEST_ROOT/xtables.lock|g" "$TRAFFIC_SYSTEMD_SERVICE"
collector_unit="/run/systemd/system/${name}-collector.service"
# Negative control: the former allowlist must fail with file logging enabled.
unit_log_dir=${log_dir//%/%%}
sed "s| \"$unit_log_dir\"||g" "$TRAFFIC_SYSTEMD_SERVICE" >"$collector_unit"
systemctl daemon-reload
if systemctl start "${name}-collector"; then
  printf 'not ok - missing log allowlist unexpectedly succeeded\n' >&2; exit 1
fi
journalctl -u "${name}-collector" --no-pager | grep -qi 'read-only file system'
jq -e '[.routing.rules[]? | select(.outboundTag=="xrayctl-user-deny")] | length==0' "$CONFIG_FILE" >/dev/null
[[ $(systemctl show "$name" -p MainPID --value) == "$pid_before" ]]
# The generated fixed unit must apply the exhausted user's ban.
cp "$TRAFFIC_SYSTEMD_SERVICE" "$collector_unit"
systemctl daemon-reload
systemctl reset-failed "${name}-collector"
systemctl start "${name}-collector"
pid_after=$(systemctl show "$name" -p MainPID --value)
[[ $pid_before != "$pid_after" && $pid_after != 0 ]]
jq -e --arg id "$id" '.routing.rules[0].user==[$id] and .routing.rules[0].outboundTag=="xrayctl-user-deny"' "$CONFIG_FILE" >/dev/null
probe "$alice" block
probe "$bob" allow
# Advancing the accounting clock to the cycle end must lift that same ban.
printf '\nEnvironment="XRAYCTL_TRAFFIC_NOW=2099-01-01 00:00:00"\n' >>"$collector_unit"
systemctl daemon-reload
systemctl start "${name}-collector"
jq -e --arg id "$id" '.inbounds.a.users[$id].limit.usedBytes==0 and .inbounds.a.users[$id].limit.enabled==true' "$TRAFFIC_FILE" >/dev/null
jq -e '[.routing.rules[]? | select(.outboundTag=="xrayctl-user-deny")] | length==0' "$CONFIG_FILE" >/dev/null
[[ $(systemctl show "$name" -p MainPID --value) != "$pid_after" ]]
probe "$alice" allow
# A managed configuration edit that moves logs must refresh the allowlist.
log_dir="$TEST_ROOT/moved logs%literal"
mkdir -p "$log_dir"
jq --arg logs "$log_dir" '.log.access=($logs+"/access.log") | .log.error=($logs+"/error.log")' "$CONFIG_FILE" >"$TEST_ROOT/moved.json"
mv "$TEST_ROOT/moved.json" "$CONFIG_FILE"
systemctl() { :; }
traffic_systemd_refresh_write_paths
unset -f systemctl
sed "s|/run/xtables.lock|$TEST_ROOT/xtables.lock|g" "$TRAFFIC_SYSTEMD_SERVICE" >"$collector_unit"
printf '\nEnvironment="XRAYCTL_TRAFFIC_NOW=2099-01-01 00:00:00"\n' >>"$collector_unit"
systemctl daemon-reload
systemctl start "${name}-collector"
probe "$alice" block
probe "$bob" allow
[[ -f $log_dir/access.log && -f $log_dir/error.log ]]
# The legacy frontend takes a file lock even when the kernel rules are private.
if command -v iptables-legacy >/dev/null; then
  systemctl stop "${name}-collector"
  rm -f "$TEST_ROOT/xtables.lock"
  cat >>"$collector_unit" <<UNIT_LOCK

PrivateNetwork=yes
Environment="XTABLES_LOCKFILE=$TEST_ROOT/xtables.lock"
ExecStart=
ExecStart=/bin/sh -c 'iptables-legacy -N XRAYCTL_SANDBOX_PROBE && iptables-legacy -L XRAYCTL_SANDBOX_PROBE -nvx'
UNIT_LOCK
  cp "$collector_unit" "$TEST_ROOT/legacy-good.service"
  cp "$TEST_ROOT/legacy-good.service" "$collector_unit"
  printf '\nExecStartPre=\n' >>"$collector_unit"
  rm -f "$TEST_ROOT/xtables.lock"
  systemctl daemon-reload
  if systemctl start "${name}-collector"; then
    printf 'not ok - legacy firewall lock unexpectedly created without preparation\n' >&2; exit 1
  fi
  journalctl -u "${name}-collector" --no-pager | grep -q "can't open lock file.*Read-only file system"
  cp "$TEST_ROOT/legacy-good.service" "$collector_unit"
  rm -f "$TEST_ROOT/xtables.lock"
  systemctl daemon-reload
  systemctl reset-failed "${name}-collector"
  systemctl start "${name}-collector"
  [[ -f $TEST_ROOT/xtables.lock ]]
fi
printf 'ok - generated strict sandbox rejects missing log access and applies ban/expiry reset with real file logs\n'
