#!/usr/bin/env bash
set -Eeuo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
export XRAYCTL_TESTING=1 XRAYCTL_CONFIG_DIR="$TMP/config"
export XRAYCTL_CONFIG_FILE="$TMP/config/config.json" XRAYCTL_META_FILE="$TMP/config/meta.json"
export XRAYCTL_TRAFFIC_FILE="$TMP/traffic.json" XRAYCTL_LOCK_FILE="$TMP/lock"
export XRAYCTL_CERT_DIR="$TMP/certs" XRAYCTL_LOG_DIR="$TMP/logs"
export XRAYCTL_RUNTIME_OWNER XRAYCTL_RUNTIME_GROUP
XRAYCTL_RUNTIME_OWNER=$(id -un)
XRAYCTL_RUNTIME_GROUP=$(id -gn)
cd "$ROOT"
# shellcheck source=../../xrayctl.sh
source ./xrayctl.sh
trap - ERR
trap 'rm -rf "$TMP"' EXIT
write_default_config
jq '.inbounds=[{tag:"first",protocol:"vless",port:443,settings:{clients:[{email:"one"},{email:"two"}]}},{tag:"second",protocol:"vless",port:8443}]' "$CONFIG_FILE" >"$TMP/config.tmp"
mv "$TMP/config.tmp" "$CONFIG_FILE"
before=$(cat "$CONFIG_FILE")

# Calls inside `if` suppress errexit for the entire call tree. Cancellation
# must still return before reading any output variable or changing files.
check_cancel() {
  XRAYCTL_INPUT_CANCELLED=0
  local value=unchanged
  if "$@" <"${CANCEL_INPUT:-/dev/null}" >"$TMP/output" 2>&1; then
    printf 'expected cancellation: %s\n' "$*" >&2; exit 1
  fi
  [[ $XRAYCTL_INPUT_CANCELLED == 1 && $value == unchanged ]]
  ! rg -q 'unbound variable|命令在第|输入已中断|操作未完成' "$TMP/output"
  [[ $(cat "$CONFIG_FILE") == "$before" ]]
}
check_cancel choose value test one two
check_cancel prompt_value value test default
check_cancel prompt_optional_value value test
check_cancel prompt_secret value test generated
check_cancel prompt_hidden_secret value test
check_cancel select_inbound value
check_cancel select_client value first
check_cancel build_inbound value host public_key
check_cancel build_stream_settings vless value public_key
check_cancel prompt_certificate_files value key
certificate_server_names() { printf '%s\n' one.example.com two.example.com; }
check_cancel prompt_certificate_server_name value unused
managed_certificate_count() { printf 2; }
meta_cert_list() { printf '%s\n' one.example.com two.example.com; }
mkdir -p "$CERT_DIR"
touch "$CERT_DIR/one.example.com.crt" "$CERT_DIR/one.example.com.key" "$CERT_DIR/two.example.com.crt" "$CERT_DIR/two.example.com.key"
check_cancel select_managed_certificate value
ensure_runtime_dependencies() { :; }
require_xray_installed() { :; }
check_cancel add_outbound

# EOF at later fields must propagate through nested builders too.
for input in $'2\n' $'2\nnew-inbound\n' $'2\nnew-inbound\n127.0.0.1\n'; do
  printf '%s' "$input" >"$TMP/input"
  CANCEL_INPUT="$TMP/input" check_cancel build_inbound value host public_key
done
for input in $'3\n' $'3\n2\n' $'3\n3\n'; do
  printf '%s' "$input" >"$TMP/input"
  CANCEL_INPUT="$TMP/input" check_cancel build_stream_settings vless value public_key
done

# The menu action wrapper must stay alive after cancellation and continue to
# report actual errors that are unrelated to EOF.
run_menu_action select_inbound value </dev/null >"$TMP/output" 2>&1
! rg -q 'unbound variable|命令在第|操作未完成' "$TMP/output"
run_menu_action false >"$TMP/output" 2>&1
rg -q '操作未完成' "$TMP/output"

# Reproduce the quota-menu selector from the report with real shared helpers.
traffic_set_enabled true
traffic_set_limits_enabled true
traffic_collect() { :; }
run_menu_action traffic_limit_set </dev/null >"$TMP/output" 2>&1
! rg -q 'unbound variable|命令在第|操作未完成' "$TMP/output"
[[ $(cat "$CONFIG_FILE") == "$before" ]]
printf 'input cancellation checks passed\n'
