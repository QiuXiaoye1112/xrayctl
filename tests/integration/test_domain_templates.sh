#!/usr/bin/env bash

set -Eeuo pipefail

readonly TEST_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
readonly REPO_ROOT=$(cd "${TEST_DIR}/../.." && pwd)
readonly TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/xrayctl-templates.XXXXXX")
trap 'rm -rf "$TEST_ROOT"' EXIT

export XRAYCTL_TESTING=1
export XRAYCTL_CONFIG_DIR="${TEST_ROOT}/config"
export XRAYCTL_CONFIG_FILE="${XRAYCTL_CONFIG_DIR}/config.json"
export XRAYCTL_META_FILE="${XRAYCTL_CONFIG_DIR}/meta.json"
export XRAYCTL_CERT_DIR="${XRAYCTL_CONFIG_DIR}/certs"
export XRAYCTL_LOG_DIR="${TEST_ROOT}/logs"
export XRAYCTL_BACKUP_DIR="${TEST_ROOT}/backups"
export XRAYCTL_XRAY_BIN="${TEST_ROOT}/missing-xray"
export XRAYCTL_RUNTIME_OWNER
XRAYCTL_RUNTIME_OWNER=$(id -un)
export XRAYCTL_RUNTIME_GROUP
XRAYCTL_RUNTIME_GROUP=$(id -gn)

mkdir -p "$XRAYCTL_CONFIG_DIR" "$XRAYCTL_CERT_DIR"
printf '%s\n' '{
  "log": {"loglevel": "warning"},
  "inbounds": [
    {"tag": "vless-one", "protocol": "vless", "port": 443, "settings": {"clients": []}},
    {"tag": "vless-two", "protocol": "vless", "port": 8443, "settings": {"clients": []}}
  ],
  "outbounds": [
    {"protocol": "freedom", "tag": "direct"},
    {"protocol": "socks", "tag": "proxy-us", "settings": {"address": "192.0.2.10", "port": 1080}}
  ],
  "routing": {"domainStrategy": "IPIfNonMatch", "rules": []}
}' >"$XRAYCTL_CONFIG_FILE"

source "${REPO_ROOT}/xrayctl.sh"

ensure_runtime_dependencies() { :; }
require_xray_installed() { :; }
setup_runtime_access() { :; }
service_is_active() { return 1; }

ensure_meta
state_commit_metadata _meta_template_add OpenAI
add_domain_template_domains OpenAI suffix openai.com
apply_domain_template vless-one OpenAI proxy-us
apply_domain_template vless-two OpenAI proxy-us

assert_count() {
  local expected=$1 actual=$2 message=$3
  [[ $actual == "$expected" ]] || { printf 'not ok - %s (expected %s, got %s)\n' "$message" "$expected" "$actual"; exit 1; }
}

assert_count 2 "$(jq '[.routing.rules[]|select(.template=="OpenAI")]|length' "$CONFIG_FILE")" 'template applied to both inbounds'
assert_count 2 "$(jq '[.domainTemplates.bindings[]|select(.template=="OpenAI")]|length' "$META_FILE")" 'template bindings persisted'
menu_rules=$(list_domain_rules vless-one --menu)
[[ $menu_rules != *'openai.com'* ]] || { printf 'not ok - menu expanded template domains\n'; exit 1; }

update_domain_template_outbound vless-one OpenAI direct
assert_count 1 "$(jq '[.routing.rules[]|select(.template=="OpenAI" and .inboundTag==["vless-one"] and .outboundTag=="direct")]|length' "$CONFIG_FILE")" 'template outbound updated for selected inbound'
assert_count 1 "$(jq '[.routing.rules[]|select(.template=="OpenAI" and .inboundTag==["vless-two"] and .outboundTag=="proxy-us")]|length' "$CONFIG_FILE")" 'template outbound unchanged for other inbound'
assert_count 1 "$(jq '[.domainTemplates.bindings[]|select(.inbound=="vless-one" and .template=="OpenAI" and .outbound=="direct")]|length' "$META_FILE")" 'binding outbound updated'

add_domain_template_domains OpenAI exact api.openai.com
assert_count 2 "$(jq '[.routing.rules[]|select(.template=="OpenAI" and .domain==["full:api.openai.com"]) ]|length' "$CONFIG_FILE")" 'template addition synchronized to both inbounds'

add_domain_rule vless-one exact direct.example.com direct >/dev/null
add_domain_template_domains OpenAI exact direct.example.com
delete_domain_template_domains OpenAI exact direct.example.com
assert_count 1 "$(jq '[.routing.rules[]|select(.inboundTag==["vless-one"] and .domain==["full:direct.example.com"])]|length' "$CONFIG_FILE")" 'direct rule was not removed by template deletion'
assert_count '["api.openai.com"]' "$(jq -c '[.domainTemplates.templates[]|select(.name=="OpenAI")|(.exact // [])[]]' "$META_FILE")" 'partial template delete kept other exact domains'
assert_count 2 "$(jq '[.routing.rules[]|select(.template=="OpenAI" and .domain==["full:api.openai.com"])]|length' "$CONFIG_FILE")" 'unrelated template rules survived partial delete'
assert_count 0 "$(jq '[.routing.rules[]|select(.inboundTag==["vless-two"] and .domain==["full:direct.example.com"])]|length' "$CONFIG_FILE")" 'deleted template domain removed from other inbound'

delete_domain_template_domains OpenAI exact api.openai.com
assert_count 0 "$(jq '[.routing.rules[]|select(.template=="OpenAI" and .domain==["full:api.openai.com"]) ]|length' "$CONFIG_FILE")" 'template deletion synchronized to both inbounds'

remove_domain_template vless-two OpenAI
assert_count 1 "$(jq '[.domainTemplates.bindings[]|select(.template=="OpenAI")]|length' "$META_FILE")" 'template was removed from one inbound'
assert_count 0 "$(jq '[.routing.rules[]|select(.template=="OpenAI" and .inboundTag==["vless-two"]) ]|length' "$CONFIG_FILE")" 'template rules were removed from one inbound'

state_commit_metadata _meta_template_add Second
add_domain_template_domains Second suffix openai.com
apply_domain_template vless-one Second proxy-us
assert_count 1 "$(jq '[.routing.rules[]|select(.inboundTag==["vless-one"] and .domain==["domain:openai.com"] and .template=="Second" and .outboundTag=="proxy-us")]|length' "$CONFIG_FILE")" 'later applied template takes over overlapping domain'
assert_count 1 "$(jq '[.routing.rules[]|select(.inboundTag==["vless-one"] and .domain==["domain:openai.com"])]|length' "$CONFIG_FILE")" 'overlapping domain keeps a single rule'
update_domain_template_outbound vless-one Second direct
assert_count 1 "$(jq '[.routing.rules[]|select(.inboundTag==["vless-one"] and .domain==["domain:openai.com"] and .template=="Second" and .outboundTag=="direct")]|length' "$CONFIG_FILE")" 'outbound update applies to overriding template'
remove_domain_template vless-one Second
assert_count 1 "$(jq '[.routing.rules[]|select(.inboundTag==["vless-one"] and .domain==["domain:openai.com"] and .template=="OpenAI" and .outboundTag=="direct")]|length' "$CONFIG_FILE")" 'overlap falls back to earlier template after removal'

state_commit_metadata _meta_template_add Partial
add_domain_template_domains Partial suffix keep.example.com,drop.example.com
delete_domain_template_domains Partial suffix drop.example.com
assert_count '["keep.example.com"]' "$(jq -c '[.domainTemplates.templates[]|select(.name=="Partial")|(.suffix // [])[]]' "$META_FILE")" 'partial template suffix delete kept the other domain'

(
  confirm() { return 0; }
  printf '1\n' | delete_domain_template_domains_menu Second suffix
)
assert_count 0 "$(jq '[.domainTemplates.templates[]|select(.name=="Second")|(.suffix // [])[]?]|length' "$META_FILE")" 'template delete menu removed the selected domain'

# rename keeps template bindings in sync
rename_inbound vless-one vless-renamed
assert_count 1 "$(jq '[.domainTemplates.bindings[]|select(.inbound=="vless-renamed" and .template=="OpenAI")]|length' "$META_FILE")" 'binding follows renamed inbound'
assert_count 0 "$(jq '[.domainTemplates.bindings[]|select(.inbound=="vless-one")]|length' "$META_FILE")" 'stale binding removed after inbound rename'
assert_count 1 "$(jq '[.routing.rules[]|select(.inboundTag==["vless-renamed"] and .template=="OpenAI" and .domain==["domain:openai.com"])]|length' "$CONFIG_FILE")" 'template rule follows renamed inbound'

# CLI delete must not remove template-owned rules
cli_delete_output=$( (delete_domain_rule vless-renamed suffix openai.com) 2>&1 || true )
[[ $cli_delete_output == *'模板管理'* ]] || { printf 'not ok - CLI delete did not protect template-owned rule\n'; exit 1; }
assert_count 1 "$(jq '[.routing.rules[]|select(.inboundTag==["vless-renamed"] and .domain==["domain:openai.com"])]|length' "$CONFIG_FILE")" 'template rule survived CLI delete attempt'

# deleting an outbound removes bindings that target it
update_domain_template_outbound vless-renamed OpenAI proxy-us
(
  confirm() { return 0; }
  delete_outbound proxy-us
)
assert_count 0 "$(jq '[.domainTemplates.bindings[]|select(.outbound=="proxy-us")]|length' "$META_FILE")" 'bindings targeting deleted outbound removed'
assert_count 0 "$(jq '[.outbounds[]|select(.tag=="proxy-us")]|length' "$CONFIG_FILE")" 'outbound was deleted'

# deleting an inbound removes its bindings
apply_domain_template vless-renamed OpenAI direct
delete_inbound vless-renamed 1
assert_count 0 "$(jq '[.domainTemplates.bindings[]|select(.inbound=="vless-renamed")]|length' "$META_FILE")" 'bindings removed with deleted inbound'
assert_count 0 "$(jq '[.routing.rules[]|select(.inboundTag==["vless-renamed"])]|length' "$CONFIG_FILE")" 'rules removed with deleted inbound'

printf '0\n' | template_library_menu >/dev/null

printf 'ok - xrayctl domain template bindings and synchronization pass\n'
