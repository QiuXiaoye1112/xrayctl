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
    {"tag": "vmess-20000", "protocol": "vmess", "port": 20000, "settings": {"clients": []}},
    {"tag": "priority-in", "protocol": "vless", "port": 30001, "settings": {"clients": []}},
    {"tag": "reverse-in", "protocol": "vless", "port": 30002, "settings": {"clients": []}},
    {"tag": "specificity-in", "protocol": "vless", "port": 30003, "settings": {"clients": []}}
  ],
  "outbounds": [
    {"protocol": "freedom", "tag": "direct"},
    {"protocol": "blackhole", "tag": "blocked"},
    {"protocol": "socks", "tag": "socks-us", "settings": {"address": "192.0.2.10", "port": 1080, "user": "Ethan", "pass": "secret", "level": 0}},
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

append_custom_rule() {
  local inbound=$1 rule_tag=$2 before_default=${3:-0} custom tmp
  custom=$(jq -n --arg inbound "$inbound" --arg ruleTag "$rule_tag" \
    '{type:"field",inboundTag:[$inbound],network:["tcp"],outboundTag:"socks-jp",ruleTag:$ruleTag}')
  tmp=$(temp_file)
  if ((before_default)); then
    jq --arg inbound "$inbound" --argjson custom "$custom" '
      .routing.rules=[.routing.rules[] as $rule |
        if $rule.ruleTag==("xrayctl-outbound:"+$inbound) then $custom,$rule else $rule end]' \
      "$CONFIG_FILE" >"$tmp"
  else
    jq --argjson custom "$custom" '.routing.rules += [$custom]' "$CONFIG_FILE" >"$tmp"
  fi
  state_apply_candidate_file "$tmp" apply_candidate >/dev/null
}

specificity_order() {
  local inbound=$1
  jq -c --arg inbound "$inbound" '
    [.routing.rules[] |
      select(((.inboundTag // []) == [$inbound]) or
        .ruleTag=="custom-X" or .ruleTag=="custom-Y") |
      .ruleTag]' "$CONFIG_FILE"
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

before_duplicate_add=$(sha256sum "$CONFIG_FILE" | awk '{print $1}')
add_domain_rule vless-443 suffix OPENAI.COM http-jp >/dev/null
after_duplicate_add=$(sha256sum "$CONFIG_FILE" | awk '{print $1}')
assert_eq "$before_duplicate_add" "$after_duplicate_add" \
  'duplicate domain add changed the configuration'
assert_eq 1 "$(jq '[.routing.rules[]|select(.domain==["domain:openai.com"])]|length' "$CONFIG_FILE")" \
  'duplicate suffix domain rule was created'
assert_eq "$suffix_rule_tag" "$(jq -r '.routing.rules[]|select(.domain==["domain:openai.com"])|.ruleTag' "$CONFIG_FILE")" \
  'duplicate domain warning changed ruleTag'
assert_eq socks-us "$(jq -r '.routing.rules[]|select(.domain==["domain:openai.com"])|.outboundTag' "$CONFIG_FILE")" \
  'duplicate domain warning changed outbound'
assert_domain_rules_before_default vless-443

add_domain_rule vless-443 suffix 'batch-one.example.com, batch-two.example.com' socks-us >/dev/null
assert_eq 1 "$(jq '[.routing.rules[]|select(.domain==["domain:batch-one.example.com"])]|length' "$CONFIG_FILE")" \
  'first comma-separated domain was not added'
assert_eq 1 "$(jq '[.routing.rules[]|select(.domain==["domain:batch-two.example.com"])]|length' "$CONFIG_FILE")" \
  'second comma-separated domain was not added'
assert_eq socks-us "$(jq -r '.routing.rules[]|select(.domain==["domain:batch-two.example.com"])|.outboundTag' "$CONFIG_FILE")" \
  'comma-separated domain outbound was not applied'

assign_outbound vless-443 http-jp >/dev/null
assert_eq 4 "$(jq '[.routing.rules[]|select(((.ruleTag // "")|startswith("xrayctl-domain:")) and (.inboundTag==["vless-443"]))]|length' "$CONFIG_FILE")" \
  'changing default outbound deleted domain rules'
assert_domain_rules_before_default vless-443

# Specificity is scoped to each inbound and only new rules are inserted.
add_domain_rule priority-in suffix example.com socks-jp >/dev/null
add_domain_rule priority-in exact example.com direct >/dev/null
priority_order=$(jq -c --arg inbound priority-in '
  [.routing.rules[]|select(.inboundTag==[$inbound])|.domain[0]]' "$CONFIG_FILE")
assert_eq '["full:example.com","domain:example.com"]' "$priority_order" \
  'exact rule was not inserted before an existing suffix rule'
add_domain_rule priority-in suffix api.example.com socks-jp >/dev/null
priority_order=$(jq -c --arg inbound priority-in '
  [.routing.rules[]|select(.inboundTag==[$inbound])|.domain[0]]' "$CONFIG_FILE")
assert_eq '["full:example.com","domain:api.example.com","domain:example.com"]' "$priority_order" \
  'more specific suffix was not inserted before broader suffix'

add_domain_rule reverse-in suffix api.example.com socks-jp >/dev/null
add_domain_rule reverse-in suffix example.com socks-jp >/dev/null
reverse_order=$(jq -c --arg inbound reverse-in '
  [.routing.rules[]|select(.inboundTag==[$inbound])|.domain[0]]' "$CONFIG_FILE")
assert_eq '["domain:api.example.com","domain:example.com"]' "$reverse_order" \
  'reverse suffix insertion did not produce specificity order'
delete_domain_rule reverse-in <<< '1,2' >/dev/null
assert_eq 0 "$(jq '[.routing.rules[]|select(.inboundTag==["reverse-in"] and ((.ruleTag // "")|startswith("xrayctl-domain:")))]|length' "$CONFIG_FILE")" \
  'batch domain deletion did not remove all selected rules'
add_domain_rule reverse-in suffix zeta-delete.test direct >/dev/null
add_domain_rule reverse-in suffix alpha-delete.test socks-jp >/dev/null
delete_domain_rule reverse-in <<< '1' >/dev/null
assert_eq 0 "$(jq '[.routing.rules[]|select(.inboundTag==["reverse-in"] and .domain==["domain:zeta-delete.test"])]|length' "$CONFIG_FILE")" \
  'delete list did not use the same grouped order as the rule display'
assert_eq 1 "$(jq '[.routing.rules[]|select(.inboundTag==["reverse-in"] and .domain==["domain:alpha-delete.test"])]|length' "$CONFIG_FILE")" \
  'delete list removed a rule other than the displayed first rule'
add_domain_rule priority-in suffix foo.bar.example.com socks-jp >/dev/null
priority_order=$(jq -c --arg inbound priority-in '
  [.routing.rules[]|select(.inboundTag==[$inbound])|.domain[0]]' "$CONFIG_FILE")
assert_eq '["full:example.com","domain:foo.bar.example.com","domain:api.example.com","domain:example.com"]' "$priority_order" \
  'specificity analysis was affected by another inbound'

add_domain_rule specificity-in exact example.com direct >/dev/null
specificity_exact_tag=$(jq -r '.routing.rules[]|select(.inboundTag==["specificity-in"] and .domain==["full:example.com"])|.ruleTag' "$CONFIG_FILE")
append_custom_rule specificity-in custom-X
assign_outbound specificity-in socks-jp >/dev/null
add_domain_rule specificity-in suffix example.com socks-jp >/dev/null
append_custom_rule specificity-in custom-Y 1
specificity_order_before=$(specificity_order specificity-in)
specificity_broad_tag=$(jq -r '.routing.rules[]|select(.inboundTag==["specificity-in"] and .domain==["domain:example.com"])|.ruleTag' "$CONFIG_FILE")
expected_specificity_order=$(jq -cn --arg exact "$specificity_exact_tag" --arg broad "$specificity_broad_tag" \
  '[$exact,"custom-X",$broad,"custom-Y","xrayctl-outbound:specificity-in"]')
assert_eq "$expected_specificity_order" \
  "$specificity_order_before" 'managed and custom rules were not interleaved as expected'

add_domain_rule specificity-in suffix api.example.com socks-jp >/dev/null
specificity_order_after_insert=$(specificity_order specificity-in)
specificity_specific_tag=$(jq -r '.routing.rules[]|select(.inboundTag==["specificity-in"] and .domain==["domain:api.example.com"])|.ruleTag' "$CONFIG_FILE")
expected_specificity_order=$(jq -cn --arg exact "$specificity_exact_tag" --arg specific "$specificity_specific_tag" \
  --arg broad "$specificity_broad_tag" \
  '[$exact,"custom-X",$specific,$broad,"custom-Y","xrayctl-outbound:specificity-in"]')
assert_eq "$expected_specificity_order" \
  "$specificity_order_after_insert" 'new specific suffix disturbed custom rule order'

order_before_exact_update=$specificity_order_after_insert
before_exact_update=$(sha256sum "$CONFIG_FILE" | awk '{print $1}')
add_domain_rule specificity-in exact example.com socks-us >/dev/null
after_exact_update=$(sha256sum "$CONFIG_FILE" | awk '{print $1}')
assert_eq "$before_exact_update" "$after_exact_update" \
  'duplicate exact add changed the configuration'
assert_eq "$order_before_exact_update" "$(specificity_order specificity-in)" \
  'duplicate exact add moved custom or managed rules'
assert_eq "$specificity_exact_tag" "$(jq -r '[.routing.rules[]|select(.inboundTag==["specificity-in"] and .domain==["full:example.com"])|.ruleTag][0]' "$CONFIG_FILE")" \
  'duplicate exact warning changed ruleTag'
assert_eq direct "$(jq -r '.routing.rules[]|select(.inboundTag==["specificity-in"] and .domain==["full:example.com"])|.outboundTag' "$CONFIG_FILE")" \
  'duplicate exact warning changed outbound'
before_broad_update=$(sha256sum "$CONFIG_FILE" | awk '{print $1}')
add_domain_rule specificity-in suffix example.com http-jp >/dev/null
after_broad_update=$(sha256sum "$CONFIG_FILE" | awk '{print $1}')
assert_eq "$before_broad_update" "$after_broad_update" \
  'duplicate suffix add changed the configuration'
assert_eq "$order_before_exact_update" "$(specificity_order specificity-in)" \
  'duplicate suffix add moved custom or managed rules'
assert_eq "$specificity_broad_tag" "$(jq -r '.routing.rules[]|select(.inboundTag==["specificity-in"] and .domain==["domain:example.com"])|.ruleTag' "$CONFIG_FILE")" \
  'duplicate suffix warning changed ruleTag'
assert_eq socks-jp "$(jq -r '.routing.rules[]|select(.inboundTag==["specificity-in"] and .domain==["domain:example.com"])|.outboundTag' "$CONFIG_FILE")" \
  'duplicate suffix warning changed outbound'
assign_outbound specificity-in http-jp >/dev/null
assert_eq "$order_before_exact_update" "$(specificity_order specificity-in)" \
  'updating default moved custom or managed rules'

duplicate=$(jq -c --arg tag "$specificity_exact_tag" '[.routing.rules[]|select(.ruleTag==$tag)][0]' "$CONFIG_FILE")
candidate=$(temp_file)
jq --argjson duplicate "$duplicate" '.routing.rules += [$duplicate]' "$CONFIG_FILE" >"$candidate"
state_apply_candidate_file "$candidate" apply_candidate >/dev/null
order_before_duplicate_warning=$(specificity_order specificity-in)
before_duplicate_warning=$(sha256sum "$CONFIG_FILE" | awk '{print $1}')
add_domain_rule specificity-in exact example.com direct >/dev/null
after_duplicate_warning=$(sha256sum "$CONFIG_FILE" | awk '{print $1}')
assert_eq "$before_duplicate_warning" "$after_duplicate_warning" \
  'historical duplicate warning changed the configuration'
assert_eq 2 "$(jq '[.routing.rules[]|select(.inboundTag==["specificity-in"] and .domain==["full:example.com"])]|length' "$CONFIG_FILE")" \
  'historical duplicate was unexpectedly removed'
assert_eq "$specificity_exact_tag" "$(jq -r '[.routing.rules[]|select(.inboundTag==["specificity-in"] and .domain==["full:example.com"])|.ruleTag][0]' "$CONFIG_FILE")" \
  'historical duplicate warning changed the first ruleTag'
assert_eq "$order_before_duplicate_warning" "$(specificity_order specificity-in)" \
  'historical duplicate warning changed the first rule position'

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
assert_eq UseIP "$(jq -r --arg tag "$local_ipv4_tag" '.outbounds[]|select(.tag==$tag)|.settings.domainStrategy' "$CONFIG_FILE")" \
  'IPv4 freedom outbound domainStrategy changed'
assert_eq 2001:db8::1 "$(jq -r --arg tag "$local_ipv6_tag" '.outbounds[]|select(.tag==$tag)|.sendThrough' "$CONFIG_FILE")" \
  'IPv6 freedom outbound sendThrough changed'
assert_eq UseIP "$(jq -r --arg tag "$local_ipv6_tag" '.outbounds[]|select(.tag==$tag)|.settings.domainStrategy' "$CONFIG_FILE")" \
  'IPv6 freedom outbound domainStrategy changed'
assert_domain_rules_before_default vless-443
listing=$(list_domain_rules vless-443)
[[ $listing == *'2001:...:1'* ]] || fail 'domain rule list did not compact the IPv6 sendThrough address'
[[ $listing == *'入站：vless-443'* ]] || fail 'domain rule list was not grouped by inbound'
[[ $listing == *'子域名 →'* ]] || fail 'domain rule list did not group repeated match and outbound values'
[[ $listing != *'序号  | 匹配   | 域名'* ]] || fail 'domain rule list still repeated table columns'
menu_listing=$(list_domain_rules vless-443 --menu)
[[ $menu_listing != *'入站：vless-443'* ]] || fail 'domain menu repeated the selected inbound label'
[[ $menu_listing == *'子域名 →'* ]] || fail 'domain menu lost grouped rule display'

(
  select_inbound() { return 1; }
  choose() { printf -v "$1" '%s' 1; }
  prompt_value() { printf -v "$1" '%s' menu-scoped.test; }
  select_outbound() { printf -v "$1" '%s' direct; }
  add_domain_rule vless-443 "" "" "" --prompt
)
assert_eq 1 "$(jq '[.routing.rules[]|select(.inboundTag==["vless-443"] and .domain==["domain:menu-scoped.test"] and .outboundTag=="direct")]|length' "$CONFIG_FILE")" \
  'menu-scoped add prompted for another inbound or used the wrong inbound'

add_domain_rule vless-443 suffix zeta-sort.test socks-us >/dev/null
add_domain_rule vless-443 suffix alpha-sort.test socks-us >/dev/null
add_domain_rule vless-443 suffix middle-sort.test socks-us >/dev/null
route_order_before=$(jq -c '
  [.routing.rules[] |
    select(.inboundTag==["vless-443"] and
      (.domain[0] | IN("domain:zeta-sort.test", "domain:alpha-sort.test", "domain:middle-sort.test"))) |
    .domain[0]]
' "$CONFIG_FILE")
before_listing=$(sha256sum "$CONFIG_FILE" | awk '{print $1}')
listing=$(list_domain_rules vless-443)
after_listing=$(sha256sum "$CONFIG_FILE" | awk '{print $1}')
assert_eq "$before_listing" "$after_listing" 'listing domain rules changed the configuration'
route_order_after=$(jq -c '
  [.routing.rules[] |
    select(.inboundTag==["vless-443"] and
      (.domain[0] | IN("domain:zeta-sort.test", "domain:alpha-sort.test", "domain:middle-sort.test"))) |
    .domain[0]]
' "$CONFIG_FILE")
assert_eq "$route_order_before" "$route_order_after" 'listing domain rules changed route order'
alpha_line=$(grep -nF 'alpha-sort.test' <<<"$listing" | cut -d: -f1)
middle_line=$(grep -nF 'middle-sort.test' <<<"$listing" | cut -d: -f1)
zeta_line=$(grep -nF 'zeta-sort.test' <<<"$listing" | cut -d: -f1)
((alpha_line < middle_line && middle_line < zeta_line)) || fail 'domain rule list is not sorted A-Z'

assert_eq '[2001:...:1746]:5000' "$(_outbound_endpoint_display 2001:db8:1700::1746 5000)" \
  'IPv6 proxy endpoint was not compacted'
assert_eq '192.0.2.10:1080' "$(_outbound_endpoint_display 192.0.2.10 1080)" \
  'IPv4 proxy endpoint display changed'
overview=$(list_outbound_overview)
[[ $overview == *'socks-us'* ]] || fail 'manual proxy disappeared from outbound overview'
[[ $overview != *'secret'* ]] || fail 'outbound overview exposed the proxy password'
details=$(show_outbound_details socks-us)
[[ $details == *'"address": "192.0.2.10"'* ]] || fail 'outbound details omitted the proxy address'
[[ $details == *'"user": "Ethan"'* ]] || fail 'outbound details omitted the proxy username'
[[ $details == *'"pass": "secret"'* ]] || fail 'outbound details omitted the proxy password'

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
