#!/usr/bin/env bash

set -Eeuo pipefail

readonly TEST_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
readonly REPO_ROOT=$(cd "${TEST_DIR}/../.." && pwd)
readonly TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/xrayctl-menus.XXXXXX")
readonly EVENT_LOG="${TEST_ROOT}/events"

cleanup_test_root() {
  [[ -n ${TEST_ROOT:-} && $TEST_ROOT == "${TMPDIR:-/tmp}"/xrayctl-menus.* ]] || return 1
  rm -rf "$TEST_ROOT"
}
trap cleanup_test_root EXIT

export XRAYCTL_CONFIG_DIR="${TEST_ROOT}/config"
export XRAYCTL_CONFIG_FILE="${XRAYCTL_CONFIG_DIR}/config.json"
export XRAYCTL_META_FILE="${XRAYCTL_CONFIG_DIR}/meta.json"
export XRAYCTL_CERT_DIR="${XRAYCTL_CONFIG_DIR}/certs"
export XRAYCTL_LOG_DIR="${TEST_ROOT}/logs"
export XRAYCTL_TRAFFIC_FILE="${TEST_ROOT}/traffic.json"
export XRAYCTL_LOCK_FILE="${TEST_ROOT}/xrayctl.lock"
export XRAYCTL_TESTING=1
export XRAYCTL_CLOUDFLARE_INI="${TEST_ROOT}/cloudflare.ini"
export XRAYCTL_XRAY_BIN="${TEST_ROOT}/missing-xray"
export XRAYCTL_RUNTIME_OWNER
XRAYCTL_RUNTIME_OWNER=$(id -un)
export XRAYCTL_RUNTIME_GROUP
XRAYCTL_RUNTIME_GROUP=$(id -gn)
mkdir -p "$XRAYCTL_CONFIG_DIR" "$XRAYCTL_CERT_DIR"

# shellcheck source=../helpers/assert.sh
source "${REPO_ROOT}/tests/helpers/assert.sh"
# shellcheck source=../../xrayctl.sh
source "${REPO_ROOT}/xrayctl.sh"
trap - ERR
trap cleanup_test_root EXIT

INPUTS=()
INPUT_INDEX=0
set_inputs() { INPUTS=("$@"); INPUT_INDEX=0; }
read() {
  local target=${!#} value arg prompt=0
  for arg in "$@"; do [[ $arg == -p ]] && prompt=1; done
  if ((prompt == 0)); then builtin read -r "$@"; return; fi
  ((INPUT_INDEX < ${#INPUTS[@]})) || return 1
  value=${INPUTS[$INPUT_INDEX]}
  INPUT_INDEX=$((INPUT_INDEX + 1))
  printf -v "$target" '%s' "$value"
}

record() {
  local event=${1-} arg
  shift || true
  for arg in "$@"; do event+=" ${arg}"; done
  printf '%s\n' "$event" >>"$EVENT_LOG"
}
run_menu_action() { record "$@"; }
pause() { :; }
clear_screen() { :; }
heading() { :; }
warn() { :; }
info() { :; }

assert_recorded() {
  local expected=$1
  grep -Fxq "$expected" "$EVENT_LOG" || fail "interactive route was not called: $expected"
}

exercise_menu_route() {
  local menu=$1 choice=$2 expected=$3
  shift 3
  : >"$EVENT_LOG"
  set_inputs "$choice" 0 0
  "$menu" "$@" >/dev/null
  assert_recorded "$expected"
}

list_outbound_overview() { :; }
list_domain_rules() { :; }
list_clients() { :; }
list_inbounds() { :; }
inbound_exists() { return 0; }
certificate_count() { printf 0; }
service_state_summary() { printf active; }
startup_state_summary() { printf enabled; }
xray_version_summary() { printf test; }
bbr_state_summary() { printf enabled; }
show_main_summary() { :; }
show_main_inbounds() { :; }

inbound_outbound_menu() { record inbound_outbound_menu; }
template_library_menu() { record template_library_menu; }
for spec in '1 inbound_outbound_menu' '2 template_library_menu' '3 add_outbound' '4 show_outbound_details' '5 delete_outbound'; do
  choice=${spec%% *}; action=${spec#* }; exercise_menu_route outbound_menu "$choice" "$action"
done
for spec in '1 add_client node' '2 rename_client node' '3 rotate_client_credential node' '4 delete_client node'; do
  choice=${spec%% *}; action=${spec#* }; exercise_menu_route client_menu_for_tag "$choice" "$action" node
done
for spec in '1 add_inbound' '3 print_all_share_links' '4 delete_inbound'; do
  choice=${spec%% *}; action=${spec#* }; exercise_menu_route inbound_menu "$choice" "$action"
done
select_inbound() { printf -v "$1" '%s' node; }
manage_inbound_menu() { record "manage_inbound_menu $1"; }
exercise_menu_route inbound_menu 2 'manage_inbound_menu node'
# Restore the real nested inbound menu after testing the parent dispatch.
# shellcheck source=../../src/menu.sh
source "${REPO_ROOT}/src/menu.sh"

jq -n '{inbounds:[{tag:"node",protocol:"vless",settings:{clients:[{email:"alice",id:"11111111-1111-4111-8111-111111111111"}]}}],outbounds:[{tag:"direct",protocol:"freedom"}],routing:{rules:[]}}' >"$CONFIG_FILE"
set_inputs 0
menu_output=$(inbound_outbound_menu)
[[ $menu_output == *'默认出站：direct'* ]] || fail 'outbound menu did not show the default outbound'
[[ $menu_output != *'入站默认出站：'* ]] || fail 'outbound menu retained the old default label'
inbound_summary=${menu_output%%用户：*}
[[ $inbound_summary == *'分流规则：0 条'* && $inbound_summary == *$'模板：\n  无'* ]] || fail 'empty inbound routing summary was missing'
check_inbound_routing_summary() {
  local CONFIG_FILE="$TEST_ROOT/summary-config.json" META_FILE="$TEST_ROOT/summary-meta.json"
  local menu_output inbound_summary
  cp "$XRAYCTL_CONFIG_FILE" "$CONFIG_FILE"
  ensure_meta
  jq '.routing.rules=[
    {ruleTag:"xrayctl-domain:direct",inboundTag:["node"],domain:["domain:public.test"]},
    {ruleTag:"xrayctl-domain:template",inboundTag:["node"],domain:["domain:template.test"],template:"public-openai"},
    {ruleTag:"xrayctl-domain:other",inboundTag:["other"],domain:["domain:other.test"]},
    {ruleTag:"xrayctl-user-domain:alice",inboundTag:["node"],user:["alice"],domain:["domain:personal.test"]},
    {ruleTag:"xrayctl-user-outbound:alice",inboundTag:["node"],user:["alice"],outboundTag:"direct"},
    {ruleTag:"xrayctl-outbound:node",inboundTag:["node"],outboundTag:"direct"}
  ]' "$CONFIG_FILE" >"$TEST_ROOT/summary.tmp"
  mv "$TEST_ROOT/summary.tmp" "$CONFIG_FILE"
  jq '.domainTemplates.bindings=[
    {inbound:"node",template:"public-openai",outbound:"direct"},
    {inbound:"node",template:"public-other",outbound:"direct"},
    {inbound:"other",template:"other-only",outbound:"direct"}
  ] | .domainTemplates.userBindings=[{inbound:"node",user:"alice",template:"user-only",outbound:"direct"}]' \
    "$META_FILE" >"$TEST_ROOT/summary-meta.tmp"
  mv "$TEST_ROOT/summary-meta.tmp" "$META_FILE"
  set_inputs 0
  menu_output=$(inbound_outbound_detail_menu node)
  inbound_summary=${menu_output%%用户：*}
  [[ $inbound_summary == *'分流规则：2 条'* && $inbound_summary == *$'模板：\n  public-openai → direct\n  public-other → direct'* ]] || fail 'inbound routing summary included the wrong scope'
  [[ $inbound_summary != *'user-only'* && $inbound_summary != *'other-only'* ]] || fail 'inbound summary included another scope template'
  [[ $menu_output == *'分流规则：1 条'* && $menu_output == *$'  模板：\n    user-only → direct'* ]] || fail 'user routing summary was changed'
}
check_inbound_routing_summary
check_template_library_menu() {
  local META_FILE="$TEST_ROOT/template-library-meta.json" output
  ensure_meta
  jq '.domainTemplates.templates=[{name:"openai",exact:[],suffix:["openai.com"]},{name:"claude",exact:[],suffix:[]}]' \
    "$META_FILE" >"$TEST_ROOT/template-library-meta.tmp"
  mv "$TEST_ROOT/template-library-meta.tmp" "$META_FILE"
  set_inputs 0
  output=$(template_library_menu)
  [[ $output == *openai* && $output == *claude* ]] || fail 'template library omitted template names'
  [[ $output != *'1) openai'* && $output != *'2) claude'* ]] || fail 'template list displayed action numbers'
  [[ $output == *'1) 新建模板'* && $output == *'2) 管理模板'* && $output == *'3) 删除模板'* && $output == *'0) 返回'* ]] || fail 'template actions have the wrong order'
  : >"$EVENT_LOG"; set_inputs 1 0; template_library_menu >/dev/null
  assert_recorded 'create_domain_template'
  template_manage_menu() { record template_manage_menu "$1"; }
  : >"$EVENT_LOG"; set_inputs 2 1 0; template_library_menu >/dev/null
  assert_recorded 'template_manage_menu openai'
  : >"$EVENT_LOG"; set_inputs 3 2 0; template_library_menu >/dev/null
  assert_recorded 'delete_domain_template claude'
}
check_template_library_menu
: >"$EVENT_LOG"; set_inputs 1 0; inbound_outbound_menu >/dev/null
assert_recorded 'assign_outbound node '
: >"$EVENT_LOG"; set_inputs 3 1 0 0; inbound_outbound_menu >/dev/null
assert_recorded 'outbound_user_default_set node alice '
select_outbound() {
  local destination=$1 include_blocked=${5:-0}
  if ((include_blocked)); then printf -v "$destination" '%s' blocked; else printf -v "$destination" '%s' direct; fi
}
: >"$EVENT_LOG"; set_inputs 3 3 1 example.com 0 0; inbound_outbound_menu >/dev/null
assert_recorded 'outbound_user_domain_add node alice suffix example.com blocked '
: >"$EVENT_LOG"; set_inputs 2 2 0 0; inbound_outbound_menu >/dev/null
assert_recorded 'add_domain_rule node    --prompt'
: >"$EVENT_LOG"; set_inputs 2 3 0 0; inbound_outbound_menu >/dev/null
assert_recorded 'delete_domain_rule node   --direct-only'

# An empty inbound list should report its state and still allow returning.
jq -n '{inbounds:[],outbounds:[{tag:"direct",protocol:"freedom"}],routing:{rules:[]}}' >"$CONFIG_FILE"
info() { record info "$@"; }
: >"$EVENT_LOG"
set_inputs 0
inbound_outbound_menu >/dev/null
assert_recorded 'info 还没有可管理的入站。'
info() { :; }

for spec in '1 issue_certificate' '2 import_certificate' '3 list_certificates' '4 delete_managed_certificate' '6 renew_managed_certificates'; do
  choice=${spec%% *}; action=${spec#* }; exercise_menu_route certificate_menu "$choice" "$action"
done
cloudflare_credentials_menu() { record cloudflare_credentials_menu; }
exercise_menu_route certificate_menu 5 cloudflare_credentials_menu

for spec in '1 toggle_service_running' '2 service_action restart' '3 toggle_service_startup' '4 show_logs 100' '6 manage_bbr'; do
  choice=${spec%% *}; action=${spec#* }; exercise_menu_route service_menu "$choice" "$action"
done
traffic_limit_menu() { record traffic_limit_menu; }
for spec in '1 inbound_menu' '2 outbound_menu' '3 certificate_menu' '4 traffic_limit_menu' '5 traffic_menu' '6 service_menu'; do
  choice=${spec%% *}; action=${spec#* }
  eval "$action() { record $action; }"
  exercise_menu_route main_menu "$choice" "$action"
done
# Uninstall now has one cleanup path and takes no legacy purge-level argument.
exercise_menu_route main_menu 7 'uninstall_xray'

traffic_is_enabled() { return 0; }
traffic_collect() { record traffic_collect; }
traffic_users_show() { record "traffic_users_show ${1-}"; }
traffic_user_ensure_configured() { record traffic_user_ensure_configured; }
traffic_user_menu() { record traffic_user_menu; }
# Restore the real menu functions after main-menu routing stubs.
# shellcheck source=../../src/menu.sh
source "${REPO_ROOT}/src/menu.sh"
traffic_user_menu() { record traffic_user_menu; }
exercise_menu_route traffic_limit_menu 2 traffic_user_menu
: >"$EVENT_LOG"; set_inputs 0; traffic_limit_menu >"$TEST_ROOT/traffic-limit-menu.txt"
ensure_line=$(grep -n '^traffic_user_ensure_configured$' "$EVENT_LOG" | cut -d: -f1)
show_line=$(grep -n '^traffic_users_show' "$EVENT_LOG" | cut -d: -f1)
[[ -n $ensure_line && -n $show_line && $ensure_line -lt $show_line ]] || fail 'user StatsService was not ensured before the first traffic limit display'
if rg -q '入站额度' "$TEST_ROOT/traffic-limit-menu.txt"; then fail 'user flow limit menu still exposes inbound quota controls'; fi
if rg -q '开启流量限制|关闭流量限制|3\)' "$TEST_ROOT/traffic-limit-menu.txt"; then fail 'user flow limit menu still exposes a global toggle'; fi

traffic_show() { :; }
traffic_clear_tag_records() { record traffic_clear_tag_records; }
traffic_clear_all_records() { record traffic_clear_all_records; }
traffic_period_set() { record traffic_period_set; }
for spec in '1 traffic_collect' '2 traffic_clear_tag_records' '3 traffic_clear_all_records' '4 traffic_period_set'; do
  choice=${spec%% *}; action=${spec#* }; exercise_menu_route traffic_menu "$choice" "$action"
done
: >"$EVENT_LOG"; set_inputs 0; traffic_menu >"$TEST_ROOT/traffic-menu.txt"
if rg -q '开启流量统计|停止流量统计|4\) (开启|停止)' "$TEST_ROOT/traffic-menu.txt"; then fail 'traffic information menu still exposes a manual traffic toggle'; fi
if ! rg -q '4\) 设置月度统计起点' "$TEST_ROOT/traffic-menu.txt"; then fail 'traffic period option was not renumbered after removing the toggle'; fi

prompt_renamed_inbound_tag() { printf -v "$1" '%s' "$2"; }
for spec in '1 rename_inbound node node' '2 modify_inbound_basic node' '3 modify_inbound_transport node'; do
  choice=${spec%% *}; action=${spec#* }; exercise_menu_route modify_inbound_menu "$choice" "$action" node vless
done
for spec in '1 rename_inbound node node' '2 modify_inbound_basic node'; do
  choice=${spec%% *}; action=${spec#* }; exercise_menu_route modify_inbound_menu "$choice" "$action" node socks
done

write_inbound() {
  local protocol=$1 security=${2:-none} authenticated=${3:-0}
  jq -n --arg protocol "$protocol" --arg security "$security" --argjson authenticated "$authenticated" '{
    inbounds:[{tag:"node",protocol:$protocol,streamSettings:{security:$security,tlsSettings:{certificates:[{}]}},settings:{auth:(if $authenticated==1 then "password" else "noauth" end),accounts:(if $authenticated==1 then [{user:"u",pass:"p"}] else [] end)}}],
    outbounds:[],routing:{rules:[]}
  }' >"$CONFIG_FILE"
}
show_node_summary() { :; }
show_inbound() { record "show_inbound $1"; }
print_links() { record "print_links $1"; }
client_menu_for_tag() { record "client_menu_for_tag $1"; }
modify_inbound_menu() { record "modify_inbound_menu $1 $2"; }
manage_inbound_certificate_menu() { record "manage_inbound_certificate_menu $1"; }

write_inbound vless none
for spec in '1 print_links node' '2 client_menu_for_tag node' '3 modify_inbound_menu node vless' '4 show_inbound node'; do
  choice=${spec%% *}; action=${spec#* }; exercise_menu_route manage_inbound_menu "$choice" "$action" node
done
write_inbound vless tls
for spec in '1 print_links node' '2 client_menu_for_tag node' '3 modify_inbound_menu node vless' '4 manage_inbound_certificate_menu node' '5 show_inbound node'; do
  choice=${spec%% *}; action=${spec#* }; exercise_menu_route manage_inbound_menu "$choice" "$action" node
done
for protocol in http socks; do
  write_inbound "$protocol" none 1
  for spec in "1 print_links node" "2 client_menu_for_tag node" "3 modify_inbound_menu node $protocol" '4 show_inbound node'; do
    choice=${spec%% *}; action=${spec#* }; exercise_menu_route manage_inbound_menu "$choice" "$action" node
  done
  write_inbound "$protocol" none 0
  for spec in "1 print_links node" "2 modify_inbound_menu node $protocol" '3 show_inbound node'; do
    choice=${spec%% *}; action=${spec#* }; exercise_menu_route manage_inbound_menu "$choice" "$action" node
  done
done
# Restore and exercise the two nested certificate menus.
# shellcheck source=../../src/certificate.sh
source "${REPO_ROOT}/src/certificate.sh"
cf_credentials_summary() { :; }
load_cloudflare_credentials() { [[ -f $CLOUDFLARE_INI ]]; }
save_cloudflare_credentials() { record save_cloudflare_credentials; }
: >"$EVENT_LOG"; set_inputs 1 0; cloudflare_credentials_menu >/dev/null
assert_recorded save_cloudflare_credentials

printf '%s\n' 'dns_cloudflare_email = test@example.com' 'dns_cloudflare_api_key = test' >"$CLOUDFLARE_INI"
: >"$EVENT_LOG"; set_inputs 1 0; cloudflare_credentials_menu >/dev/null
assert_recorded save_cloudflare_credentials
cloudflare_dependent_certificates() { :; }
confirm() { return 0; }
meta_resource_remove() { record "meta_resource_remove $1"; }
: >"$EVENT_LOG"; set_inputs 2 0; cloudflare_credentials_menu >/dev/null
assert_recorded 'meta_resource_remove cloudflareCredentials'
[[ ! -e $CLOUDFLARE_INI ]] || fail "Cloudflare delete menu did not remove credentials"

write_inbound vless tls
select_managed_certificate() { printf -v "$1" '%s' managed; }
prompt_certificate_server_name() { printf -v "$1" '%s' example.com; }
prompt_certificate_files() { printf -v "$1" '%s' /tmp/test.crt; printf -v "$2" '%s' /tmp/test.key; }
: >"$EVENT_LOG"; set_inputs 1 0; manage_inbound_certificate_menu node >/dev/null
assert_recorded "update_tls_inbound_certificate node ${XRAYCTL_CERT_DIR}/managed.crt ${XRAYCTL_CERT_DIR}/managed.key example.com"
: >"$EVENT_LOG"; set_inputs 2 0; manage_inbound_certificate_menu node >/dev/null
assert_recorded 'update_tls_inbound_certificate node /tmp/test.crt /tmp/test.key example.com'

pass "all interactive menu choices route to the intended business action"
