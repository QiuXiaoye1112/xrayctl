#!/usr/bin/env bash
REPO_ROOT=$(cd "$(dirname "$0")/../.." && pwd)
set -Eeuo pipefail
case_dir=$(mktemp -d /tmp/xrayctl-ip-check.XXXXXXXX)
trap 'rm -rf "$case_dir"' EXIT
source "$REPO_ROOT/xrayctl.sh"
trap - ERR
trap 'rm -rf "$case_dir"' EXIT
CONFIG_FILE="$case_dir/config.json"
cat > "$CONFIG_FILE" <<'JSON'
{"inbounds":[{"tag":"test-in","protocol":"vless","settings":{"clients":[{"email":"alice-test","xrayctlLabel":"Alice"}]}}],"outbounds":[{"tag":"direct","protocol":"freedom"},{"tag":"local-216-40-86-195","protocol":"freedom","sendThrough":"216.40.86.195"},{"tag":"local-2001-db8--1","protocol":"freedom","sendThrough":"2001:db8::1"}],"routing":{"rules":[]}}
JSON
ensure_config() { :; }
ensure_runtime_dependencies() { :; }
inbound_require_supported_configuration() { :; }
temp_file() { mktemp "$case_dir/candidate.XXXXXXXX"; }
state_apply_candidate_file() { cp "$1" "$CONFIG_FILE"; rm -f "$1"; }
assign_outbound test-in 216.40.86.195 >/dev/null
jq -e '.routing.rules[]|select(.ruleTag=="xrayctl-outbound:test-in")|.outboundTag=="local-216-40-86-195"' "$CONFIG_FILE" >/dev/null
outbound_user_default_set test-in Alice 2001:DB8::1 >/dev/null
jq -e '.routing.rules[]|select(.user==["alice-test"])|.outboundTag=="local-2001-db8--1"' "$CONFIG_FILE" >/dev/null
[[ $(_outbound_display_name local-2001-db8--1) == 2001:db8::1 ]]
assign_outbound test-in direct >/dev/null
jq -e '.routing.rules[]|select(.ruleTag=="xrayctl-outbound:test-in")|.outboundTag=="direct"' "$CONFIG_FILE" >/dev/null
resolved=unchanged
if _resolve_outbound_reference resolved 198.51.100.99; then exit 1; fi
[[ $resolved == unchanged ]]
printf 'isolated IPv4, IPv6, original-tag and unknown-IP checks passed\n'
