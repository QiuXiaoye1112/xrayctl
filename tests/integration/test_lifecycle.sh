#!/usr/bin/env bash

set -Eeuo pipefail

readonly TEST_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
readonly REPO_ROOT=$(cd "${TEST_DIR}/../.." && pwd)
readonly TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/xrayctl-lifecycle.XXXXXX")

cleanup_test_root() {
  [[ -n ${TEST_ROOT:-} && $TEST_ROOT == "${TMPDIR:-/tmp}"/xrayctl-lifecycle.* ]] || return 1
  rm -rf "$TEST_ROOT"
}
trap cleanup_test_root EXIT

export XRAYCTL_CONFIG_DIR="${TEST_ROOT}/config"
export XRAYCTL_CONFIG_FILE="${XRAYCTL_CONFIG_DIR}/config.json"
export XRAYCTL_META_FILE="${XRAYCTL_CONFIG_DIR}/meta.json"
export XRAYCTL_CERT_DIR="${XRAYCTL_CONFIG_DIR}/certs"
export XRAYCTL_LOG_DIR="${TEST_ROOT}/logs"
export XRAYCTL_BACKUP_DIR="${TEST_ROOT}/backups"
export XRAYCTL_XRAY_BIN="${TEST_ROOT}/missing-xray"
export XRAYCTL_RUNTIME_OWNER
XRAYCTL_RUNTIME_OWNER=$(id -un)
export XRAYCTL_RUNTIME_GROUP
XRAYCTL_RUNTIME_GROUP=$(id -gn)

mkdir -p "$XRAYCTL_CONFIG_DIR" "$XRAYCTL_CERT_DIR"
cat >"$XRAYCTL_CONFIG_FILE" <<'JSON'
{
  "log": {"loglevel": "warning"},
  "inbounds": [],
  "outbounds": [
    {"protocol": "freedom", "tag": "direct"},
    {"protocol": "blackhole", "tag": "blocked"}
  ],
  "routing": {"domainStrategy": "IPIfNonMatch", "rules": []}
}
JSON

# shellcheck source=../helpers/assert.sh
source "${REPO_ROOT}/tests/helpers/assert.sh"
# shellcheck source=../../xrayctl.sh
source "${REPO_ROOT}/xrayctl.sh"
trap - ERR
trap cleanup_test_root EXIT

ensure_runtime_dependencies() { :; }
require_xray_installed() { :; }
setup_runtime_access() { :; }
service_is_active() { return 1; }
show_inbound() { :; }
print_links() { :; }
confirm() { return 0; }

build_inbound() {
  printf -v "$1" '%s' "$(jq -c . "${REPO_ROOT}/tests/fixtures/protocols/vless.json")"
  printf -v "$2" '%s' edge.example.com
  printf -v "$3" '%s' ''
}

add_inbound >/dev/null
assert_eq 1 "$(jq '.inbounds|length' "$CONFIG_FILE")" "inbound add did not update config"
assert_eq edge.example.com "$(jq -r '.inbounds["vless-node"].host' "$META_FILE")" "inbound add did not update metadata"

prompt_client_label() { printf -v "$1" '%s' bob; }
generate_uuid() { printf '%s\n' 223e4567-e89b-12d3-a456-426614174000; }
add_client vless-node >/dev/null
assert_eq 2 "$(jq '.inbounds[0].settings.clients|length' "$CONFIG_FILE")" "client add failed"

rename_client vless-node bob robert >/dev/null
assert_eq 1 "$(jq '[.inbounds[0].settings.clients[]|select(.email=="robert")]|length' "$CONFIG_FILE")" "client rename failed"

prompt_validated_value() { printf -v "$1" '%s' 323e4567-e89b-12d3-a456-426614174000; }
rotate_client_credential vless-node robert >/dev/null
assert_eq 323e4567-e89b-12d3-a456-426614174000 \
  "$(jq -r '.inbounds[0].settings.clients[]|select(.email=="robert")|.id' "$CONFIG_FILE")" \
  "client credential rotation failed"

prompt_value() { printf -v "$1" '%s' 127.0.0.1; }
prompt_port() { printf -v "$1" '%s' 8443; }
prompt_public_host() { printf -v "$1" '%s' modified.example.com; }
modify_inbound_basic vless-node >/dev/null
assert_eq 8443 "$(jq -r '.inbounds[0].port' "$CONFIG_FILE")" "inbound port modification failed"
assert_eq modified.example.com "$(jq -r '.inbounds["vless-node"].host' "$META_FILE")" "inbound host metadata modification failed"

candidate=$(temp_file)
jq '.outbounds += [{tag:"proxy-out",protocol:"socks",settings:{address:"127.0.0.1",port:1080}}]' \
  "$CONFIG_FILE" >"$candidate"
apply_candidate "$candidate" >/dev/null
assign_outbound vless-node proxy-out >/dev/null
assert_eq proxy-out "$(jq -r '.routing.rules[]|select(.ruleTag=="xrayctl-outbound:vless-node")|.outboundTag' "$CONFIG_FILE")" \
  "outbound assignment failed"

before_failed_assignment=$(jq -S . "$CONFIG_FILE")
service_is_active() { return 0; }
restart_service() { return 1; }
assert_failure assign_outbound vless-node direct
assert_eq "$before_failed_assignment" "$(jq -S . "$CONFIG_FILE")" \
  "failed outbound assignment did not preserve the previous config"
service_is_active() { return 1; }

preserved_config=$(temp_file)
cp "$CONFIG_FILE" "$preserved_config"
printf '%s\n' '{"inbounds":[],"outbounds":[]}' >"$CONFIG_FILE"
_service_restore_or_initialize_config "$preserved_config"
assert_eq "$before_failed_assignment" "$(jq -S . "$CONFIG_FILE")" \
  "reinstall did not restore the config preserved before core installation"

delete_client vless-node robert 1 >/dev/null
assert_eq 1 "$(jq '.inbounds[0].settings.clients|length' "$CONFIG_FILE")" "client delete failed"

delete_inbound vless-node 1 >/dev/null
assert_eq 0 "$(jq '.inbounds|length' "$CONFIG_FILE")" "inbound delete failed"
assert_eq null "$(jq -r '.inbounds["vless-node"]' "$META_FILE")" "inbound metadata delete failed"
assert_eq 0 "$(jq '[.routing.rules[]?|select(.ruleTag=="xrayctl-outbound:vless-node")]|length' "$CONFIG_FILE")" \
  "inbound delete left routing state"

ensure_backup_dir
assert_eq xrayctl-backup-directory-v1 "$(cat "$BACKUP_OWNERSHIP_MARKER")" \
  "backup ownership marker was not created"
SNAPSHOT_META=$(temp_file)
printf '%s\n' '{"certificates":{},"managedResources":{}}' >"$SNAPSHOT_META"
_uninstall_remove_backups
[[ ! -e $BACKUP_DIR ]] || fail "owned backup directory survived erase without metadata"

mkdir -p "$BACKUP_DIR"
printf '%s\n' foreign >"${BACKUP_DIR}/foreign.txt"
assert_failure _uninstall_remove_backups
[[ -f ${BACKUP_DIR}/foreign.txt ]] || fail "unowned backup directory was removed"

rm -f "$candidate" "$SNAPSHOT_META"
pass "inbound, client, metadata, and outbound lifecycle remains consistent"
