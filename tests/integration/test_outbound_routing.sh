#!/usr/bin/env bash

set -Eeuo pipefail

readonly TEST_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
readonly REPO_ROOT=$(cd "${TEST_DIR}/../.." && pwd)
readonly TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/xrayctl-routing.XXXXXX")
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
cat >"$XRAYCTL_CONFIG_FILE" <<'JSON'
{
  "log": {"loglevel": "warning"},
  "inbounds": [
    {"tag": "vless-443", "protocol": "vless", "port": 443, "settings": {"clients": []}},
    {"tag": "vmess-20000", "protocol": "vmess", "port": 20000, "settings": {"clients": []}}
  ],
  "outbounds": [
    {"protocol": "freedom", "tag": "direct"},
    {"protocol": "blackhole", "tag": "blocked"},
    {"protocol": "socks", "tag": "socks-us", "settings": {"address": "192.0.2.10", "port": 1080}},
    {"protocol": "socks", "tag": "socks-jp", "settings": {"address": "192.0.2.20", "port": 1080}},
    {"protocol": "http", "tag": "http-jp", "settings": {"address": "192.0.2.30", "port": 8080}}
  ],
  "routing": {
    "domainStrategy": "IPIfNonMatch",
    "rules": [
      {"type": "field", "ip": ["geoip:private"], "outboundTag": "blocked"},
      {"type": "field", "protocol": ["bittorrent"], "outboundTag": "blocked"}
    ]
  }
}
JSON

# shellcheck source=../helpers/assert.sh
source "${REPO_ROOT}/tests/helpers/assert.sh"
# shellcheck source=../../xrayctl.sh
source "${REPO_ROOT}/xrayctl.sh"
trap - ERR
trap 'rm -rf "$TEST_ROOT"' EXIT

ensure_runtime_dependencies() { :; }
require_xray_installed() { :; }
setup_runtime_access() { :; }
service_is_active() { return 1; }
confirm() { return 0; }

assert_domain_rules_before_default() {
  local inbound=$1 default_index domain_index rule_tag
  default_index=$(jq -r --arg tag "xrayctl-outbound:${inbound}" \
    '[.routing.rules|to_entries[]|select(.value.ruleTag==$tag)|.key][0] // -1' "$CONFIG_FILE")
  ((default_index >= 0)) || fail "missing default rule for ${inbound}"
  while IFS=$'\t' read -r domain_index rule_tag; do
    [[ -n $domain_index ]] || continue
    ((domain_index < default_index)) || fail "domain rule ${rule_tag} is not before ${inbound} default rule"
  done < <(jq -r --arg inbound "$inbound" \
    '.routing.rules|to_entries[]|
     select(((.value.ruleTag // "")|startswith("xrayctl-domain:")) and
       (((.value.inboundTag // [])|index($inbound))!=null))|[.key,.value.ruleTag]|@tsv' "$CONFIG_FILE")
}

_normalize_domain_input normalized '*.OPENAI.COM' && fail 'wildcard domain was accepted'
_normalize_domain_input normalized 'https://openai.com' && fail 'URL domain was accepted'

add_domain_rule vless-443 suffix OPENAI.COM socks-us >/dev/null
assert_eq 'domain:openai.com' \
  "$(jq -r '.routing.rules[]|select(.inboundTag==["vless-443"] and .domain==["domain:openai.com"])|.domain[0]' "$CONFIG_FILE")" \
  'suffix domain was not normalized to domain: form'
suffix_rule_tag=$(jq -r '.routing.rules[]|select(.domain==["domain:openai.com"])|.ruleTag' "$CONFIG_FILE")
[[ $suffix_rule_tag == xrayctl-domain:* ]] || fail 'suffix domain ruleTag is not managed'

add_domain_rule vless-443 exact OPENAI.COM direct >/dev/null
assert_eq 'full:openai.com' \
  "$(jq -r '.routing.rules[]|select(.inboundTag==["vless-443"] and .domain==["full:openai.com"])|.domain[0]' "$CONFIG_FILE")" \
  'exact domain was not normalized to full: form'
assert_eq 2 "$(jq '[.routing.rules[]|select(((.ruleTag // "")|startswith("xrayctl-domain:")) and (.inboundTag==["vless-443"]))]|length' "$CONFIG_FILE")" \
  'suffix and exact rules for the same domain were not both retained'

assign_outbound vless-443 socks-jp >/dev/null
assert_domain_rules_before_default vless-443
assert_eq socks-jp "$(jq -r '.routing.rules[]|select(.ruleTag=="xrayctl-outbound:vless-443")|.outboundTag' "$CONFIG_FILE")" \
  'default outbound assignment failed'

add_domain_rule vless-443 suffix OPENAI.COM http-jp >/dev/null
assert_eq 1 "$(jq '[.routing.rules[]|select(.domain==["domain:openai.com"])]|length' "$CONFIG_FILE")" \
  'duplicate suffix domain rule was created'
assert_eq "$suffix_rule_tag" "$(jq -r '.routing.rules[]|select(.domain==["domain:openai.com"])|.ruleTag' "$CONFIG_FILE")" \
  'duplicate domain update changed ruleTag'
assert_eq http-jp "$(jq -r '.routing.rules[]|select(.domain==["domain:openai.com"])|.outboundTag' "$CONFIG_FILE")" \
  'duplicate domain update did not change outbound'
assert_domain_rules_before_default vless-443

assign_outbound vless-443 http-jp >/dev/null
assert_eq 2 "$(jq '[.routing.rules[]|select(((.ruleTag // "")|startswith("xrayctl-domain:")) and (.inboundTag==["vless-443"]))]|length' "$CONFIG_FILE")" \
  'changing default outbound deleted domain rules'
assert_domain_rules_before_default vless-443

detect_local_ips() {
  printf '%s\t%s\t%s\n' '203.0.113.10 (IPv4)' 203.0.113.10 eth0
  printf '%s\t%s\t%s\n' '2001:db8::1 (IPv6)' 2001:db8::1 eth0
}
local_ipv4_tag=$(_ensure_freedom_outbound 203.0.113.10)
local_ipv6_tag=$(_ensure_freedom_outbound 2001:db8::1)
add_domain_rule vless-443 suffix ipv4.example.com "$local_ipv4_tag" >/dev/null
add_domain_rule vless-443 suffix ipv6.example.com "$local_ipv6_tag" >/dev/null
assert_eq 203.0.113.10 "$(jq -r --arg tag "$local_ipv4_tag" '.outbounds[]|select(.tag==$tag)|.sendThrough' "$CONFIG_FILE")" \
  'IPv4 freedom outbound sendThrough changed'
assert_eq 2001:db8::1 "$(jq -r --arg tag "$local_ipv6_tag" '.outbounds[]|select(.tag==$tag)|.sendThrough' "$CONFIG_FILE")" \
  'IPv6 freedom outbound sendThrough changed'
assert_eq UseIP "$(jq -r --arg tag "$local_ipv6_tag" '.outbounds[]|select(.tag==$tag)|.settings.domainStrategy' "$CONFIG_FILE")" \
  'IPv6 freedom outbound domainStrategy changed'
assert_domain_rules_before_default vless-443
listing=$(list_domain_rules vless-443)
[[ $listing == *'2001:db8::1'* ]] || fail 'domain rule list exposed local tag instead of sendThrough IP'

add_domain_rule vmess-20000 suffix socks.example.com socks-us >/dev/null
add_domain_rule vmess-20000 suffix http.example.com http-jp >/dev/null
assign_outbound vmess-20000 socks-jp >/dev/null
assert_domain_rules_before_default vmess-20000
assert_eq socks-us "$(jq -r '.routing.rules[]|select(.domain==["domain:socks.example.com"])|.outboundTag' "$CONFIG_FILE")" \
  'SOCKS outbound was not accepted by domain rule'
assert_eq http-jp "$(jq -r '.routing.rules[]|select(.domain==["domain:http.example.com"])|.outboundTag' "$CONFIG_FILE")" \
  'HTTP outbound was not accepted by domain rule'

delete_domain_rule vless-443 suffix openai.com >/dev/null
assert_eq 0 "$(jq '[.routing.rules[]|select(.domain==["domain:openai.com"])]|length' "$CONFIG_FILE")" \
  'domain rule delete did not remove the selected rule'
assert_eq 1 "$(jq '[.routing.rules[]|select(.ruleTag=="xrayctl-outbound:vless-443")]|length' "$CONFIG_FILE")" \
  'domain rule delete removed the default rule'

renamed_rule_tag=$(jq -r '.routing.rules[]|select(.domain==["full:openai.com"])|.ruleTag' "$CONFIG_FILE")
rename_inbound vless-443 vless-renamed >/dev/null
assert_eq 0 "$(jq '[.routing.rules[]|select((.inboundTag // [])|index("vless-443"))]|length' "$CONFIG_FILE")" \
  'inbound rename left the old inboundTag in routing rules'
assert_eq 1 "$(jq '[.routing.rules[]|select(.inboundTag==["vless-renamed"] and .domain==["full:openai.com"])]|length' "$CONFIG_FILE")" \
  'inbound rename did not update domain rule inboundTag'
assert_eq "$renamed_rule_tag" "$(jq -r '.routing.rules[]|select(.domain==["full:openai.com"])|.ruleTag' "$CONFIG_FILE")" \
  'inbound rename changed domain ruleTag'
delete_domain_rule vless-renamed exact openai.com >/dev/null
delete_inbound vless-renamed 1 >/dev/null
assert_eq 0 "$(jq '[.routing.rules[]|select(((((.inboundTag // [])|index("vless-renamed"))!=null) or (.ruleTag=="xrayctl-outbound:vless-renamed")))]|length' "$CONFIG_FILE")" \
  'inbound delete left domain or default routing rules'

delete_outbound socks-us >/dev/null
assert_eq 0 "$(jq '[.outbounds[]|select(.tag=="socks-us")]|length' "$CONFIG_FILE")" \
  'managed SOCKS outbound was not deleted'
assert_eq 0 "$(jq '[.routing.rules[]|select(.outboundTag=="socks-us")]|length' "$CONFIG_FILE")" \
  'managed domain references survived outbound deletion'

candidate=$(temp_file)
jq '.outbounds += [{protocol:"socks",tag:"proxy-custom",settings:{address:"192.0.2.40",port:1080}}] |
  .routing.rules += [{type:"field",inboundTag:["vmess-20000"],outboundTag:"proxy-custom",ruleTag:"user-custom"}]' \
  "$CONFIG_FILE" >"$candidate"
state_apply_candidate_file "$candidate" apply_candidate >/dev/null
if (delete_outbound proxy-custom >/dev/null 2>&1); then
  fail 'outbound with custom routing reference was deleted'
fi
assert_eq 1 "$(jq '[.outbounds[]|select(.tag=="proxy-custom")]|length' "$CONFIG_FILE")" \
  'custom-referenced outbound disappeared after refused delete'
assert_eq 1 "$(jq '[.routing.rules[]|select(.ruleTag=="user-custom")]|length' "$CONFIG_FILE")" \
  'custom routing rule disappeared after refused outbound delete'

printf 'ok - Xray domain routing rules, ordering, lifecycle and outbound safety pass\n'
