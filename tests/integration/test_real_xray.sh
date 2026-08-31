#!/usr/bin/env bash

set -Eeuo pipefail

readonly TEST_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
readonly REPO_ROOT=$(cd "${TEST_DIR}/../.." && pwd)
readonly REAL_XRAY_BIN=${XRAYCTL_REAL_XRAY_BIN:-}

if [[ -z $REAL_XRAY_BIN ]]; then
  printf 'ok - real Xray validation skipped (set XRAYCTL_REAL_XRAY_BIN to enable)\n'
  exit 0
fi
[[ -x $REAL_XRAY_BIN ]] || { printf 'not ok - real Xray binary is not executable: %s\n' "$REAL_XRAY_BIN" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { printf 'not ok - jq is required\n' >&2; exit 1; }

readonly TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/xrayctl-real-core.XXXXXX")
cleanup_test_root() {
  [[ -n ${TEST_ROOT:-} && $TEST_ROOT == "${TMPDIR:-/tmp}"/xrayctl-real-core.* ]] || return 1
  rm -rf "$TEST_ROOT"
}
trap cleanup_test_root EXIT

"$REAL_XRAY_BIN" version | sed -n '1p'

validate_config() {
  local label=$1 config=$2 output
  if ! output=$("$REAL_XRAY_BIN" run -test -format json -config "$config" 2>&1); then
    printf 'not ok - real Xray rejected %s\n%s\n' "$label" "$output" >&2
    return 1
  fi
}

default_config="$TEST_ROOT/default.json"
jq -n '{
  log:{loglevel:"warning"},
  inbounds:[],
  outbounds:[{protocol:"freedom",tag:"direct"},{protocol:"blackhole",tag:"blocked"}],
  routing:{domainStrategy:"IPIfNonMatch",rules:[]}
}' >"$default_config"
validate_config 'default configuration' "$default_config"

for fixture in "$REPO_ROOT"/tests/fixtures/protocols/*.json; do
  name=$(basename "$fixture" .json)
  config="$TEST_ROOT/${name}.json"
  jq -n --slurpfile inbound "$fixture" '{
    log:{loglevel:"warning"},
    inbounds:$inbound,
    outbounds:[{protocol:"freedom",tag:"direct"}],
    routing:{domainStrategy:"IPIfNonMatch",rules:[]}
  }' >"$config"
  validate_config "${name} protocol fixture" "$config"
done

printf 'ok - default config and all protocol fixtures pass the real Xray core\n'
