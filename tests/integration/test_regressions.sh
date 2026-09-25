#!/usr/bin/env bash

set -Eeuo pipefail

readonly TEST_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
readonly REPO_ROOT=$(cd "${TEST_DIR}/../.." && pwd)
readonly TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/xrayctl-regressions.XXXXXX")
trap 'rm -rf "$TEST_ROOT"' EXIT

export XRAYCTL_CONFIG_DIR="$TEST_ROOT/config"
export XRAYCTL_CONFIG_FILE="$XRAYCTL_CONFIG_DIR/config.json"
export XRAYCTL_META_FILE="$XRAYCTL_CONFIG_DIR/meta.json"
export XRAYCTL_CERT_DIR="$XRAYCTL_CONFIG_DIR/certs"
export XRAYCTL_LOG_DIR="$TEST_ROOT/logs"
export XRAYCTL_BACKUP_DIR="$TEST_ROOT/backups"
export XRAYCTL_TRAFFIC_FILE="$TEST_ROOT/traffic.json"
export XRAYCTL_LOCK_FILE="$TEST_ROOT/lock"
export XRAYCTL_XRAY_BIN="$TEST_ROOT/missing-xray"
export XRAYCTL_RUNTIME_OWNER
XRAYCTL_RUNTIME_OWNER=$(id -un)
export XRAYCTL_RUNTIME_GROUP
XRAYCTL_RUNTIME_GROUP=$(id -gn)

mkdir -p "$XRAYCTL_CONFIG_DIR/certs"

cat >"$XRAYCTL_CONFIG_FILE" <<'JSON'
{
  "log": {"loglevel": "warning"},
  "inbounds": [],
  "outbounds": [{"protocol": "freedom", "tag": "direct"}],
  "routing": {"rules": []}
}
JSON
cat >"$XRAYCTL_META_FILE" <<'JSON'
{"schema":4,"inbounds":{},"certificates":{},"managedResources":{},"migrations":{"legacyCertScanV1":true,"legacyCertbotSymlinkV1":true}}
JSON

# shellcheck source=../helpers/assert.sh
source "${REPO_ROOT}/tests/helpers/assert.sh"
# shellcheck source=../../xrayctl.sh
source "${REPO_ROOT}/xrayctl.sh"
trap - ERR

# New builders emit the field understood by released Xray, while readers still
# accept the old field.
stream='{"network":"websocket","security":"none","wsSettings":{"path":"/x"}}'
built=""
protocol_build_vless built node 127.0.0.1 12345 alice "$stream"
assert_eq websocket "$(jq -r '.streamSettings.network' <<<"$built")" "builder did not emit network"
legacy_stream='{"method":"websocket","security":"none","wsSettings":{"path":"/x"}}'
assert_eq 'websocket' "$(jq -r '.method // .network' <<<"$legacy_stream")" "legacy transport fixture changed"

# Old protocols remain deletable after an upgrade.
ensure_runtime_dependencies() { :; }
setup_runtime_access() { :; }
service_is_active() { return 1; }
jq '.inbounds=[{"tag":"legacy","protocol":"vmess","port":12345,"settings":{"clients":[]}}]' \
  "$CONFIG_FILE" >"$CONFIG_FILE.new"
mv "$CONFIG_FILE.new" "$CONFIG_FILE"
delete_inbound legacy 1 >/dev/null
assert_eq 0 "$(jq '.inbounds|length' "$CONFIG_FILE")" "legacy inbound could not be deleted"

# Explicitly removing the last HTTP credential remains available for a public
# listener; the generic delete confirmation is the only interactive guard.
jq '.inbounds=[{"tag":"public-http","listen":"0.0.0.0","port":12346,"protocol":"http","settings":{"accounts":[{"user":"alice","pass":"secret"}]}}]' \
  "$CONFIG_FILE" >"$CONFIG_FILE.new"
mv "$CONFIG_FILE.new" "$CONFIG_FILE"
delete_client public-http alice 1 >/dev/null
assert_eq 0 "$(jq '.inbounds[0].settings.accounts|length' "$CONFIG_FILE")" "public HTTP credential deletion was blocked"

# A malformed metadata member is rejected before any current state is changed.
printf '%s\n' 'current certificate' >"$XRAYCTL_CERT_DIR/current.crt"
jq '.log.loglevel="warning" | .inbounds=[]' "$CONFIG_FILE" >"$CONFIG_FILE.new"
mv "$CONFIG_FILE.new" "$CONFIG_FILE"
archive="$TEST_ROOT/bad-metadata.tar.gz"
archive_root="$TEST_ROOT/archive-root"
config_member="$archive_root/${CONFIG_FILE#/}"
meta_member="$archive_root/${META_FILE#/}"
mkdir -p "$(dirname "$config_member")" "$(dirname "$meta_member")"
printf '%s\n' '{"log":{"loglevel":"debug"},"inbounds":[],"outbounds":[{"protocol":"freedom","tag":"direct"}],"routing":{"rules":[]}}' >"$config_member"
printf '%s' '{"schema":' >"$meta_member"
tar -czf "$archive" -C "$archive_root" "${CONFIG_FILE#/}" "${META_FILE#/}"
set +e
(restore_backup "$archive") >/dev/null 2>&1
restore_status=$?
set -e
((restore_status != 0)) || fail "malformed metadata restore unexpectedly succeeded"
assert_eq warning "$(jq -r '.log.loglevel' "$CONFIG_FILE")" "restore changed config before metadata validation"
[[ -f "$XRAYCTL_CERT_DIR/current.crt" ]] || fail "restore removed certificates before metadata validation"

# Share export must preserve a literal backslash in a proxy password.
jq '.inbounds=[{"tag":"proxy","listen":"127.0.0.1","port":12345,"protocol":"http","settings":{"accounts":[{"user":"alice","pass":"hello\\world"}]}}]' \
  "$CONFIG_FILE" >"$CONFIG_FILE.new"
mv "$CONFIG_FILE.new" "$CONFIG_FILE"
jq '.inbounds.proxy={"host":"127.0.0.1"}' "$META_FILE" >"$META_FILE.new"
mv "$META_FILE.new" "$META_FILE"
link_output=$(print_links proxy)
grep -Fq 'hello%5Cworld' <<<"$link_output" || fail "share export did not URI-encode the original password"
! grep -Fq 'hello%5C%5Cworld' <<<"$link_output" || fail "share export doubled a backslash"

# Upgrading from a layout that kept a regular xrayctl copy at the symlink path
# must back that copy up and take over, while foreign files stay protected.
quick_dir="$TEST_ROOT/quick-command"
quick_real="$quick_dir/xrayctl"
quick_link="$quick_dir/bin/xrayctl"
mkdir -p "$(dirname "$quick_link")"
printf '%s\n' '# xrayctl - Xray Linux terminal manager' 'current release' >"$quick_real"
printf '%s\n' '# xrayctl - Xray Linux terminal manager' 'previous release' >"$quick_link"
chmod 755 "$quick_real" "$quick_link"
QUICK_COMMAND="$quick_real"
QUICK_SYMLINK="$quick_link"
install_quick_command >/dev/null
[[ -L $quick_link ]] || fail "legacy quick command file was not replaced by a symlink"
assert_eq "$quick_real" "$(readlink "$quick_link")" "quick command symlink does not point at the installed script"
backup_files=("$quick_dir"/bin/xrayctl.bak-*)
[[ -e ${backup_files[0]} ]] || fail "legacy quick command file was not backed up"
assert_eq 'previous release' "$(sed -n 2p "${backup_files[0]}")" "quick command backup lost the previous release"

foreign_link="$quick_dir/bin/foreign"
printf '#!/bin/sh\necho foreign\n' >"$foreign_link"
chmod 755 "$foreign_link"
QUICK_SYMLINK="$foreign_link"
set +e
(install_quick_command) >/dev/null 2>&1
foreign_status=$?
set -e
((foreign_status != 0)) || fail "foreign quick command path was overwritten"
assert_eq '#!/bin/sh' "$(sed -n 1p "$foreign_link")" "foreign quick command file changed"

pass "transport compatibility, legacy deletion, restore validation, share escaping, and quick command upgrade regressions pass"
