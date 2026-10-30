#!/usr/bin/env bash
set -Eeuo pipefail
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/xrayctl-user-transaction.XXXXXX")
trap 'rm -rf "$TEST_ROOT"' EXIT
export XRAYCTL_TESTING=1 XRAYCTL_TMP_DIR="$TEST_ROOT" XRAYCTL_CONFIG_DIR="$TEST_ROOT/config"
export XRAYCTL_CONFIG_FILE="$TEST_ROOT/config/config.json" XRAYCTL_META_FILE="$TEST_ROOT/config/meta.json"
export XRAYCTL_TRAFFIC_FILE="$TEST_ROOT/traffic.json" XRAYCTL_LOCK_FILE="$TEST_ROOT/lock"
export XRAYCTL_RUNTIME_OWNER XRAYCTL_RUNTIME_GROUP
XRAYCTL_RUNTIME_OWNER=$(id -un); XRAYCTL_RUNTIME_GROUP=$(id -gn)
mkdir -p "$XRAYCTL_CONFIG_DIR"
source "$root/xrayctl.sh"
trap - ERR
trap 'rm -rf "$TEST_ROOT"' EXIT
ensure_config() { :; }
setup_runtime_access() { :; }
service_is_active() { return 1; }
jq 'del(.api,.stats,.policy) | .routing.rules=[]' "$root/tests/fixtures/user-traffic/server.json" > "$TEST_ROOT/input.json"
traffic_user_prepare_config "$TEST_ROOT/input.json" "$CONFIG_FILE" '127.0.0.1:32401'
printf '%s\n' '{"schema":4,"inbounds":{"a":{"host":"example.com"}},"certificates":{},"managedResources":{},"migrations":{}}' > "$META_FILE"
id=$(jq -r '.inbounds[0].settings.clients[0].email' "$CONFIG_FILE")
traffic_default_json | jq --arg id "$id" '.enabled=true | .inbounds.a={daily:{"2026-01-01":5},users:{($id):{label:"alice",uplinkBytes:42,limit:{enabled:true,quotaBytes:100,usedBytes:17}}}}' > "$TRAFFIC_FILE"
jq '(.inbounds[]|select(.tag=="a")|.tag)="renamed"' "$CONFIG_FILE" > "$TEST_ROOT/candidate.json"
state_commit_inbound_rename "$TEST_ROOT/candidate.json" a renamed
jq -e --arg id "$id" '.inbounds.a==null and .inbounds.renamed.users[$id].uplinkBytes==42 and .inbounds.renamed.users[$id].limit.usedBytes==17' "$TRAFFIC_FILE" >/dev/null
jq -e '.inbounds.renamed.host=="example.com" and .inbounds.a==null' "$META_FILE" >/dev/null
jq '(.inbounds[]|select(.tag=="renamed")|.tag)="rollback"' "$CONFIG_FILE" > "$TEST_ROOT/candidate.json"
traffic_rename_records_locked() { return 1; }
if state_commit_inbound_rename "$TEST_ROOT/candidate.json" renamed rollback; then printf 'not ok - failed traffic migration committed rename\n' >&2; exit 1; fi
jq -e '.inbounds[0].tag=="renamed"' "$CONFIG_FILE" >/dev/null
jq -e --arg id "$id" '.inbounds.renamed.users[$id].uplinkBytes==42 and .inbounds.rollback==null' "$TRAFFIC_FILE" >/dev/null
jq -e '.inbounds.renamed.host=="example.com" and .inbounds.rollback==null' "$META_FILE" >/dev/null
printf 'ok - inbound rename migrates user state under lock and rolls back on failure\n'
