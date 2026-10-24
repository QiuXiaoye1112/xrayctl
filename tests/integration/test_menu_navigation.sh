#!/usr/bin/env bash

set -Eeuo pipefail

readonly REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
readonly TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/xrayctl-navigation.XXXXXX")
readonly EVENTS="$TEST_ROOT/events"
trap 'rm -rf "$TEST_ROOT"' EXIT
export XRAYCTL_CONFIG_DIR="$TEST_ROOT/config"
export XRAYCTL_CERT_DIR="$TEST_ROOT/config/certs"
export XRAYCTL_TRAFFIC_FILE="$TEST_ROOT/traffic.json"
export XRAYCTL_XRAY_BIN="$TEST_ROOT/missing-xray"
export XRAYCTL_TMP_DIR="$TEST_ROOT/tmp"
export XRAYCTL_RUNTIME_OWNER
XRAYCTL_RUNTIME_OWNER=$(id -un)
export XRAYCTL_RUNTIME_GROUP
XRAYCTL_RUNTIME_GROUP=$(id -gn)
mkdir -p "$XRAYCTL_CONFIG_DIR" "$XRAYCTL_CERT_DIR"

# shellcheck source=../helpers/assert.sh
source "$REPO_ROOT/tests/helpers/assert.sh"
# shellcheck source=../../xrayctl.sh
source "$REPO_ROOT/xrayctl.sh"
trap - ERR
trap 'rm -rf "$TEST_ROOT"' EXIT

# Keep the real menu loops, prompts, action subshell, rename transaction and
# metadata persistence. Only service/OS work and screen clearing are stubbed.
ensure_runtime_dependencies() { :; }
require_xray_installed() { :; }
setup_runtime_access() { :; }
service_is_active() { return 1; }
clear_screen() { :; }
pause() { :; }
heading() { printf 'heading|%s\n' "$1" >>"$EVENTS"; }
show_node_summary() { :; }
show_inbound() {
  inbound_exists "$1" || fail "detail menu retained a stale tag: $1"
  printf 'show|%s\n' "$1" >>"$EVENTS"
}
modify_inbound_basic() { printf 'basic|%s\n' "$1" >>"$EVENTS"; }
modify_inbound_transport() { printf 'transport|%s\n' "$1" >>"$EVENTS"; }

reset_case() {
  local protocol=$1 security=$2 auth=$3
  jq -n --arg protocol "$protocol" --arg security "$security" --arg auth "$auth" '{
    log:{loglevel:"warning"},
    inbounds:[{tag:"original",listen:"127.0.0.1",port:12345,protocol:$protocol,
      streamSettings:{network:"raw",security:$security},
      settings:{auth:$auth,accounts:(if $auth=="password" then [{user:"alice",pass:"test"}] else [] end)}}],
    outbounds:[{tag:"direct",protocol:"freedom"}],routing:{rules:[]}
  }' >"$CONFIG_FILE"
  printf '%s\n' '{"schema":4,"inbounds":{"original":{"host":"example.com"}},"certificates":{},"managedResources":{},"migrations":{"legacyCertScanV1":true,"legacyCertbotSymlinkV1":true}}' >"$META_FILE"
  : >"$EVENTS"
}

check_rename_navigation() {
  local protocol=$1 security=$2 auth=$3 edit_choice=$4 json_choice=$5 inputs expected
  reset_case "$protocol" "$security" "$auth"
  inputs=$(printf '2\n%s\n1\nrenamed\n2\n' "$edit_choice")
  expected=$'heading|入站管理\nheading|入站 · original\nheading|修改入站信息 · original\nheading|修改入站信息 · renamed\nbasic|renamed\nheading|修改入站信息 · renamed'
  if [[ $protocol == vless ]]; then
    inputs+=$'\n3'
    expected+=$'\ntransport|renamed\nheading|修改入站信息 · renamed'
  fi
  inputs+=$(printf '\n0\n%s\n0\n0' "$json_choice")
  inbound_menu <<<"$inputs" >/dev/null
  expected+=$'\nheading|入站 · renamed\nshow|renamed\nheading|入站 · renamed\nheading|入站管理'
  assert_eq "$expected" "$(cat "$EVENTS")" "rename lost menu context: $protocol/$security/$auth"
  assert_eq renamed "$(jq -r '.inbounds[0].tag' "$CONFIG_FILE")" 'rename did not persist'
  assert_eq example.com "$(jq -r '.inbounds.renamed.host' "$META_FILE")" 'rename lost metadata'
}

check_rename_navigation vless none noauth 3 4
check_rename_navigation vless reality noauth 3 4
check_rename_navigation vless tls noauth 3 5
for protocol in socks http; do
  check_rename_navigation "$protocol" none password 3 4
  check_rename_navigation "$protocol" none noauth 2 3
done

# A second rename must update both menus again, without revisiting the list.
reset_case vless reality noauth
inbound_menu <<<'2
3
1
intermediate
1
final
0
4
0
0' >/dev/null
grep -Fxq 'show|final' "$EVENTS" || fail 'repeated rename lost the selected inbound'
assert_eq 2 "$(grep -Fxc 'heading|入站管理' "$EVENTS")" 'repeated rename jumped to the inbound list'

# No-op and failed transactions retain the original selection and stay nested.
for new_tag in original rejected; do
  (
    reset_case vless reality noauth
    if [[ $new_tag == rejected ]]; then state_commit_inbound_rename() { return 1; }; fi
    inbound_menu <<EOF >"$TEST_ROOT/action-output"
2
3
1
$new_tag
0
4
0
0
EOF
    grep -Fxq 'show|original' "$EVENTS" || fail 'failed/no-op rename lost the original inbound'
    assert_eq 2 "$(grep -Fxc 'heading|修改入站信息 · original' "$EVENTS")" 'failed/no-op rename left the edit menu'
    assert_eq original "$(jq -r '.inbounds[0].tag' "$CONFIG_FILE")" 'failed rename changed config'
  )
done

(
  reset_case vless reality noauth
  prompt_renamed_inbound_tag() { return 1; }
  inbound_menu <<<'2
3
1
0
4
0
0' >/dev/null
  grep -Fxq 'show|original' "$EVENTS" || fail 'cancelled rename lost the original inbound'
  assert_eq 2 "$(grep -Fxc 'heading|修改入站信息 · original' "$EVENTS")" 'cancelled rename left the edit menu'
)

pass 'rename preserves nested menu context across protocols, repeated renames, cancellation and failures'
