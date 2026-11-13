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

bw=0 ctw=0 cbw=0 wtw=0
banner_first=$(ui_banner "xrayctl" "v1.4.0" | sed -n '2p')
card_top=$(ui_card_open "连接参数 · edge" | sed -n '2p')
card_bot=$(ui_card_close)
wiz_top=$(ui_wizard_step 1 3 "选择入站协议" | sed -n '2p')
display_width bw "$banner_first"
display_width ctw "$card_top"
display_width cbw "$card_bot"
display_width wtw "$wiz_top"
(( bw >= 64 && bw <= 78 )) || fail "ui_banner width out of bounds: $bw"
assert_eq "$bw" "$ctw" 'ui_card_open width mismatch'
assert_eq "$bw" "$cbw" 'ui_card_close width mismatch'
assert_eq "$bw" "$wtw" 'ui_wizard_step width mismatch'

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
[[ $main_out == *'▸ 代理与路由'* ]] || fail 'main_menu omitted 代理与路由 group'
[[ $main_out == *'▸ 安全与证书'* ]] || fail 'main_menu omitted 安全与证书 group'
[[ $main_out == *'▸ 流量与配额'* ]] || fail 'main_menu omitted 流量与配额 group'
[[ $main_out == *'▸ 系统与运维'* ]] || fail 'main_menu omitted 系统与运维 group'
[[ $main_out == *'▸ 入站概览'* && $main_out == *'edge'* && $main_out == *'0) 退出'* ]] \
  || fail 'main_menu omitted inbound overview or exit option'

# 3. Delivery links output renders structured parameter card while keeping subscription URIs intact.
_reality_public_key_for_tag() { printf 'PUBKEY_TEST'; }
links_out=$(print_links edge)
[[ $links_out == *'┌─ 连接参数 · edge'* ]] || fail 'print_links omitted connection parameters card'
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
