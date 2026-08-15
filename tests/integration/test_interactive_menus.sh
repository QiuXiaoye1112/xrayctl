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
  local target=${!#} value
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
  set_inputs "$choice" 0
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

domain_rule_menu() { record domain_rule_menu; }
for spec in '1 assign_outbound' '2 domain_rule_menu' '3 add_outbound' '4 show_outbound_details' '5 delete_outbound'; do
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

for spec in '1 add_domain_rule' '2 delete_domain_rule'; do
  choice=${spec%% *}; action=${spec#* }; exercise_menu_route domain_rule_menu "$choice" "$action"
done

for spec in '1 issue_certificate' '2 import_certificate' '3 list_certificates' '4 delete_managed_certificate' '6 renew_managed_certificates'; do
  choice=${spec%% *}; action=${spec#* }; exercise_menu_route certificate_menu "$choice" "$action"
done
cloudflare_credentials_menu() { record cloudflare_credentials_menu; }
exercise_menu_route certificate_menu 5 cloudflare_credentials_menu

for spec in '1 toggle_service_running' '2 service_action restart' '3 toggle_service_startup' '4 show_logs 100' '5 install_or_update_xray install'; do
  choice=${spec%% *}; action=${spec#* }; exercise_menu_route service_menu "$choice" "$action"
done
for spec in '1 manage_bbr' '2 system_diagnostics' '3 repair_quick_command'; do
  choice=${spec%% *}; action=${spec#* }; exercise_menu_route system_menu "$choice" "$action"
done
for spec in '1 uninstall_xray 0' '2 uninstall_xray 1' '3 uninstall_xray 2'; do
  choice=${spec%% *}; action=${spec#* }; exercise_menu_route uninstall_menu "$choice" "$action"
done

for spec in '1 inbound_menu' '2 outbound_menu' '3 certificate_menu' '4 service_menu' '5 system_menu' '6 uninstall_menu'; do
  choice=${spec%% *}; action=${spec#* }
  eval "$action() { record $action; }"
  exercise_menu_route main_menu "$choice" "$action"
done

for spec in '1 rename_inbound node' '2 modify_inbound_basic node' '3 modify_inbound_transport node'; do
  choice=${spec%% *}; action=${spec#* }; exercise_menu_route modify_inbound_menu "$choice" "$action" node vless
done
for spec in '1 rename_inbound node' '2 modify_inbound_basic node'; do
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
write_inbound shadowsocks none
exercise_menu_route manage_inbound_menu 1 'show_inbound node' node

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
