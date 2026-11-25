#!/usr/bin/env bash

set -Eeuo pipefail

readonly TEST_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
readonly REPO_ROOT=$(cd "${TEST_DIR}/../.." && pwd)
readonly TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/xrayctl-ui-layout.XXXXXX")
trap 'rm -rf "$TEST_ROOT"' EXIT

export XRAYCTL_CONFIG_DIR="${TEST_ROOT}/xray"
export XRAYCTL_CONFIG_FILE="${XRAYCTL_CONFIG_DIR}/config.json"
export XRAYCTL_META_FILE="${XRAYCTL_CONFIG_DIR}/meta.json"
export XRAYCTL_TRAFFIC_FILE="${TEST_ROOT}/traffic.json"
export XRAYCTL_CERT_DIR="${TEST_ROOT}/certs"
export XRAYCTL_TMP_DIR="${TEST_ROOT}/tmp"
export COLUMNS=72

mkdir -p "$XRAYCTL_CONFIG_DIR" "$XRAYCTL_CERT_DIR"

# shellcheck source=../helpers/assert.sh
source "${REPO_ROOT}/tests/helpers/assert.sh"
# shellcheck source=../../xrayctl.sh
source "${REPO_ROOT}/xrayctl.sh"
trap - ERR
trap 'rm -rf "$TEST_ROOT"' EXIT

# 1. display_width accurately strips ANSI CSI escapes and treats box-drawing symbols as width 1.
w=0
display_width w $'\033[1;36m● 正常\033[0m'
assert_eq 6 "$w" 'ANSI color escape should not inflate display_width'

display_width w '┌─ 测试 ─┐'
assert_eq 10 "$w" 'box-drawing characters should have width 1'

# Shared presentation stays compact; content headings cannot repeat navigation.
banner=$(ui_banner "xrayctl" "v1.4.0")
[[ $banner == *'xrayctl  v1.4.0'* && $banner != *'╭'* ]] || fail 'banner is not compact'
card=$(ui_card_open "连接参数 · edge"; ui_card_kv "地址" "203.0.113.10:443"; ui_card_close)
[[ $card == *'连接参数 · edge'* && $card == *'203.0.113.10:443'* && $card != *'┌'* && $card != *'│'* ]] \
  || fail 'compact detail block lost content or retained borders'
wizard=$(ui_wizard_step 1 3 "选择入站协议" "请选择协议")
[[ $wizard == *'[1/3] 选择入站协议'* && $wizard == *'请选择协议'* && $wizard != *'┌'* ]] \
  || fail 'compact wizard lost its step or hint'
page=$(XRAYCTL_UI_CRUMB="首页 › 出站管理"; ui_page "出站管理"; heading "入站与出站规则"; heading "代理出站")
assert_eq 1 "$(grep -c '首页 › 出站管理' <<<"$page")" 'navigation must appear only once per page'
assert_eq 1 "$(grep -c '─' <<<"$page")" 'content headings must not draw full-width rules'

# 2. Categorized main_menu renders overview, grouped menu headings, and exit footer.
cat >"$XRAYCTL_CONFIG_FILE" <<'JSON'
{
  "inbounds":[
    {
      "tag":"edge",
      "listen":"0.0.0.0",
      "port":443,
      "protocol":"vless",
      "settings":{"clients":[{"email":"alice","id":"11111111-1111-4111-8111-111111111111","flow":"xtls-rprx-vision"}],"decryption":"none"},
      "streamSettings":{"network":"raw","security":"reality","realitySettings":{"serverNames":["www.microsoft.com"],"privateKey":"priv","shortIds":["abcd1234"],"dest":"www.microsoft.com:443"}}
    }
  ],
  "outbounds":[{"tag":"direct","protocol":"freedom"}],
  "routing":{"rules":[]}
}
JSON
cat >"$XRAYCTL_META_FILE" <<'JSON'
{
  "schema":4,
  "inbounds":{"edge":{"host":"203.0.113.10","realityPublicKey":"PUBKEY_TEST","fingerprint":"chrome"}},
  "certificates":{},
  "managedResources":{},
  "migrations":{"legacyCertScanV1":true}
}
JSON

clear_screen() { :; }
service_is_running() { return 0; }
service_is_enabled() { return 0; }
xray_installed() { return 0; }
bbr_status_line() { printf '已开启'; }

main_out=$(printf '0\n' | main_menu)
[[ $main_out == *'代理与路由'* ]] || fail 'main_menu omitted 代理与路由 group'
[[ $main_out == *'安全与证书'* ]] || fail 'main_menu omitted 安全与证书 group'
[[ $main_out == *'流量与配额'* ]] || fail 'main_menu omitted 流量与配额 group'
[[ $main_out == *'系统与运维'* ]] || fail 'main_menu omitted 系统与运维 group'
[[ $main_out == *'入站概览'* && $main_out == *'edge'* && $main_out == *'0) 退出'* ]] \
  || fail 'main_menu omitted inbound overview or exit option'
summary=$(show_node_summary edge)
grep -Eq '^[[:space:]]*监听端口[[:space:]]+443[[:space:]]*$' <<<"$summary" || fail 'the node summary must show only the port in the listener row'
grep -Eq '^[[:space:]]*连接地址[[:space:]]+203\.0\.113\.10[[:space:]]*$' <<<"$summary" || fail 'the node summary lost the separate client address'

# 3. Delivery links output renders structured parameter card while keeping subscription URIs intact.
_reality_public_key_for_tag() { printf 'PUBKEY_TEST'; }
links_out=$(print_links edge)
[[ $links_out == *'连接参数 · edge'* ]] || fail 'print_links omitted connection parameters card'
[[ $links_out == *'协议与传输'* && $links_out == *'203.0.113.10:443'* ]] \
  || fail 'print_links omitted protocol/address details in card'
[[ $links_out == *$'\n链接: vless://11111111-1111-4111-8111-111111111111@203.0.113.10:443?'* ]] \
  || fail 'print_links did not keep column-0 URI line'

sub_b64=$(print_subscription)
sub_decoded=$(printf '%s' "$sub_b64" | base64 -d)
[[ $sub_decoded == 'vless://11111111-1111-4111-8111-111111111111@203.0.113.10:443?'* ]] \
  || fail 'print_subscription failed to decode URI alongside delivery card'

# 4. Step progress emits to stderr when enabled and suppresses output when disabled.
step_err=$(XRAYCTL_UI_PROGRESS=1 bash -c '
  source "'"${REPO_ROOT}"'/xrayctl.sh"
  ui_step 1 3 "校验配置"
  ui_step_done ok
' 2>&1)
[[ $step_err == *'[1/3] 校验配置 ... ✓'* ]] || fail "unexpected step progress output: $step_err"

step_off=$(XRAYCTL_UI_PROGRESS=0 bash -c '
  source "'"${REPO_ROOT}"'/xrayctl.sh"
  ui_step 1 3 "校验配置"
  ui_step_done ok
' 2>&1)
[[ -z $step_off ]] || fail "progress output was not suppressed when disabled: $step_off"

printf 'ok - refactored UI cards, categorized menus, delivery links, and progress steps work cleanly\n'
