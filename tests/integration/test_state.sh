#!/usr/bin/env bash

set -Eeuo pipefail

readonly TEST_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
readonly REPO_ROOT=$(cd "${TEST_DIR}/../.." && pwd)
readonly TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/xrayctl-state.XXXXXX")

cleanup_test_root() {
  [[ -n ${TEST_ROOT:-} && $TEST_ROOT == "${TMPDIR:-/tmp}"/xrayctl-state.* ]] || return 1
  rm -rf "$TEST_ROOT"
}
trap cleanup_test_root EXIT

export XRAYCTL_CONFIG_DIR="${TEST_ROOT}/config"
export XRAYCTL_CONFIG_FILE="${XRAYCTL_CONFIG_DIR}/config.json"
export XRAYCTL_META_FILE="${XRAYCTL_CONFIG_DIR}/meta.json"
export XRAYCTL_CERT_DIR="${XRAYCTL_CONFIG_DIR}/certs"
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
printf '%s\n' 'legacy certificate' >"${XRAYCTL_CERT_DIR}/legacy.crt"
printf '%s\n' 'legacy key' >"${XRAYCTL_CERT_DIR}/legacy.key"

# shellcheck source=../helpers/assert.sh
source "${REPO_ROOT}/tests/helpers/assert.sh"
# shellcheck source=../../xrayctl.sh
source "${REPO_ROOT}/xrayctl.sh"
trap - ERR
trap cleanup_test_root EXIT

setup_runtime_access() { :; }
service_is_active() { return 1; }

set +e
ensure_config
ensure_status=$?
set -e
assert_eq 0 "$ensure_status" "ensure_config failed while migrating legacy metadata"
baseline=$(jq -S . "$CONFIG_FILE")

candidate=$(temp_file)
jq '.log.loglevel="info"' "$CONFIG_FILE" >"$candidate"
apply_candidate "$candidate" >/dev/null
assert_eq info "$(jq -r '.log.loglevel' "$CONFIG_FILE")" "valid candidate was not committed"

before_invalid=$(jq -S . "$CONFIG_FILE")
printf '%s\n' '{"inbounds":"invalid","outbounds":[]}' >"$candidate"
assert_failure apply_candidate "$candidate"
assert_eq "$before_invalid" "$(jq -S . "$CONFIG_FILE")" "invalid candidate changed production config"

ensure_meta
first_meta=$(jq -S . "$META_FILE")
ensure_meta
second_meta=$(jq -S . "$META_FILE")
assert_eq "$first_meta" "$second_meta" "metadata migration is not idempotent"
assert_eq legacy "$(jq -r '.certificates.legacy.source' "$META_FILE")" "legacy certificate migration did not run"

[[ $baseline != "$(jq -S . "$CONFIG_FILE")" ]] || fail "state success-path assertion was ineffective"
rm -f "$candidate"
pass "candidate validation and metadata migration preserve state invariants"
