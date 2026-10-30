#!/usr/bin/env bash
set -Eeuo pipefail
if [[ ${XRAYCTL_TEST_SYSTEMD:-0} != 1 ]]; then printf 'ok - real systemd quota test skipped (set XRAYCTL_TEST_SYSTEMD=1)\n'; exit 0; fi
[[ $(id -u) == 0 ]] || { printf 'not ok - real systemd test requires root\n' >&2; exit 1; }
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
bin=${XRAYCTL_REAL_XRAY_BIN:?set XRAYCTL_REAL_XRAY_BIN}
for cmd in jq systemctl systemd-run; do command -v "$cmd" >/dev/null || exit 1; done
TEST_ROOT=$(mktemp -d /var/lib/xrayctl-systemd-test.XXXXXXXX)
name="xrayctl-user-test-${TEST_ROOT##*.}"
unit="/run/systemd/system/${name}.service"
cleanup_test() {
  systemctl stop "$name" >/dev/null 2>&1 || true
  rm -f "$unit"
  systemctl daemon-reload >/dev/null 2>&1 || true
  rm -rf "$TEST_ROOT"
}
trap cleanup_test EXIT
mkdir -p "$TEST_ROOT"/{repo,bin,config,state,lock}
cp -R "$root/src" "$root/xrayctl.sh" "$TEST_ROOT/repo/"
cp "$bin" "$TEST_ROOT/bin/xray"
cp "$(command -v jq)" "$TEST_ROOT/bin/jq"
chmod 755 "$TEST_ROOT/bin/xray" "$TEST_ROOT/bin/jq"
unset XRAYCTL_TMP_DIR
export XRAYCTL_CONFIG_DIR="$TEST_ROOT/config"
export XRAYCTL_CONFIG_FILE="$TEST_ROOT/config/config.json" XRAYCTL_META_FILE="$TEST_ROOT/config/meta.json"
export XRAYCTL_TRAFFIC_FILE="$TEST_ROOT/state/traffic.json" XRAYCTL_LOCK_FILE="$TEST_ROOT/lock/xrayctl.lock"
export XRAYCTL_XRAY_BIN="$TEST_ROOT/bin/xray" XRAYCTL_RUNTIME_OWNER=root XRAYCTL_RUNTIME_GROUP=root XRAYCTL_SERVICE_NAME="$name"
export PATH="$TEST_ROOT/bin:$PATH"
source "$TEST_ROOT/repo/xrayctl.sh"
trap - ERR
trap cleanup_test EXIT
base=$((40000 + RANDOM % 20000)); api=$base; inbound=$((base+1))
jq --argjson port "$inbound" 'del(.api,.stats,.policy) | .inbounds[0].port=$port | .routing.rules=[]' "$root/tests/fixtures/user-traffic/server.json" > "$TEST_ROOT/input.json"
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
pid_before=$(systemctl show "$name" -p MainPID --value)
cat >"$TEST_ROOT/collect.sh" <<SCRIPT
#!/usr/bin/env bash
set -Eeuo pipefail
export PATH="$TEST_ROOT/bin:\$PATH"
unset XRAYCTL_TMP_DIR
export XRAYCTL_CONFIG_DIR="$TEST_ROOT/config"
export XRAYCTL_CONFIG_FILE="$TEST_ROOT/config/config.json" XRAYCTL_META_FILE="$TEST_ROOT/config/meta.json"
export XRAYCTL_TRAFFIC_FILE="$TEST_ROOT/state/traffic.json" XRAYCTL_LOCK_FILE="$TEST_ROOT/lock/xrayctl.lock"
export XRAYCTL_XRAY_BIN="$TEST_ROOT/bin/xray" XRAYCTL_RUNTIME_OWNER=root XRAYCTL_RUNTIME_GROUP=root XRAYCTL_SERVICE_NAME="$name"
source "$TEST_ROOT/repo/xrayctl.sh"
traffic_user_collect_serialized
traffic_user_reconcile
SCRIPT
chmod 755 "$TEST_ROOT/collect.sh"
systemd-run --quiet --wait --pipe --collect --service-type=oneshot --unit="${name}-collector" \
  --property=NoNewPrivileges=yes --property=PrivateTmp=yes --property=ProtectSystem=strict --property=ProtectHome=yes \
  --property="ReadWritePaths=$TEST_ROOT/config $TEST_ROOT/state $TEST_ROOT/lock" "$TEST_ROOT/collect.sh"
pid_after=$(systemctl show "$name" -p MainPID --value)
[[ $pid_before != "$pid_after" && $pid_after != 0 ]]
jq -e --arg id "$id" '.routing.rules[0].user==[$id] and .routing.rules[0].outboundTag=="xrayctl-user-deny"' "$CONFIG_FILE" >/dev/null
printf 'ok - systemd sandbox persists quota rule and restarts isolated real Xray service\n'
