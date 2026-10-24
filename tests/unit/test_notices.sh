#!/usr/bin/env bash

set -Eeuo pipefail

readonly REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
readonly TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/xrayctl-notices.XXXXXX")
trap 'rm -rf "$TEST_ROOT"' EXIT
export NO_COLOR=1
export XRAYCTL_CONFIG_DIR="$TEST_ROOT/config"
export XRAYCTL_XRAY_BIN="$TEST_ROOT/missing-xray"
mkdir -p "$XRAYCTL_CONFIG_DIR"

# shellcheck source=../helpers/assert.sh
source "$REPO_ROOT/tests/helpers/assert.sh"
# shellcheck source=../../xrayctl.sh
source "$REPO_ROOT/xrayctl.sh"
trap - ERR
trap 'rm -rf "$TEST_ROOT"' EXIT

# Notices must preserve literal user data and their existing output channels.
info '完成 100%' 'literal\path %s' >"$TEST_ROOT/out" 2>"$TEST_ROOT/err"
[[ ! -s $TEST_ROOT/err ]] || fail 'informational output moved to stderr'
grep -Fxq '  literal\path %s' "$TEST_ROOT/out" || fail 'notice altered a literal path or format token'
warn '引用信息' $'first\path\nsecond 100%' >"$TEST_ROOT/out" 2>"$TEST_ROOT/err"
[[ ! -s $TEST_ROOT/out ]] || fail 'warning details leaked into machine-readable stdout'
grep -Fxq '  first\path' "$TEST_ROOT/err" || fail 'first detail line was lost'
grep -Fxq '  second 100%' "$TEST_ROOT/err" || fail 'multiline detail was not retained'
error $'校验失败\nline one' 'line two' >"$TEST_ROOT/out" 2>"$TEST_ROOT/err"
[[ ! -s $TEST_ROOT/out ]] || fail 'diagnostics leaked into stdout'
grep -Fxq '  line one' "$TEST_ROOT/err" || fail 'multiline summary lost its diagnostic'
grep -Fxq '  line two' "$TEST_ROOT/err" || fail 'extra diagnostic was lost'
if LC_ALL=C grep -q $'\033' "$TEST_ROOT/err"; then fail 'NO_COLOR emitted terminal escapes'; fi

cat >"$CONFIG_FILE" <<'JSON'
{"inbounds":[],"outbounds":[{"tag":"proxy","protocol":"socks"}],"routing":{"rules":[
  {"ruleTag":"xrayctl-outbound:one","inboundTag":["one"],"outboundTag":"proxy"},
  {"ruleTag":"xrayctl-domain:two","inboundTag":["two"],"outboundTag":"proxy"}
]}}
JSON
cat >"$META_FILE" <<'JSON'
{"schema":4,"inbounds":{},"certificates":{},"managedResources":{},
 "migrations":{"legacyCertScanV1":true,"legacyCertbotSymlinkV1":true},
 "domainTemplates":{"templates":[],"bindings":[{"inbound":"one","template":"example","outbound":"proxy"}]}}
JSON
before_config=$(cat "$CONFIG_FILE")
before_meta=$(cat "$META_FILE")
ensure_runtime_dependencies() { :; }
confirm() { printf 'CONFIRM\n' >&2; return 1; }
delete_outbound proxy >"$TEST_ROOT/out" 2>"$TEST_ROOT/err"
[[ ! -s $TEST_ROOT/out ]] || fail 'outbound reference details used a different stream from their warning'
assert_eq 1 "$(grep -c '^警告 ·' "$TEST_ROOT/err")" 'one operation produced several separate warning headers'
if grep -Eq '默认出站：|删除后，' "$TEST_ROOT/err"; then fail 'outbound warning restored removed detail lines'; fi
assert_eq CONFIRM "$(tail -1 "$TEST_ROOT/err")" 'confirmation overtook reference details'
assert_eq "$before_config" "$(cat "$CONFIG_FILE")" 'declined confirmation changed config'
assert_eq "$before_meta" "$(cat "$META_FILE")" 'declined confirmation changed metadata'

pass 'notices preserve channels, literal diagnostics, reference ordering and cancellation safety'
