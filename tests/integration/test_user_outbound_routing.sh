#!/usr/bin/env bash

set -Eeuo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(cd "$TEST_DIR/../.." && pwd)
TEST_ROOT=$(mktemp -d /tmp/xrayctl-user-outbound.XXXXXX)
trap 'rm -rf "$TEST_ROOT"' EXIT

export XRAYCTL_TESTING=1
export XRAYCTL_CONFIG_DIR="$TEST_ROOT/config"
export XRAYCTL_CONFIG_FILE="$XRAYCTL_CONFIG_DIR/config.json"
export XRAYCTL_META_FILE="$XRAYCTL_CONFIG_DIR/meta.json"
export XRAYCTL_CERT_DIR="$XRAYCTL_CONFIG_DIR/certs"
export XRAYCTL_LOG_DIR="$TEST_ROOT/logs"
export XRAYCTL_BACKUP_DIR="$TEST_ROOT/backups"
export XRAYCTL_XRAY_BIN="$TEST_ROOT/missing-xray"
export XRAYCTL_RUNTIME_OWNER XRAYCTL_RUNTIME_GROUP
XRAYCTL_RUNTIME_OWNER=$(id -un)
XRAYCTL_RUNTIME_GROUP=$(id -gn)

mkdir -p "$XRAYCTL_CONFIG_DIR" "$XRAYCTL_CERT_DIR"
cat >"$XRAYCTL_CONFIG_FILE" <<'JSON'
{
  "log":{"loglevel":"warning"},
  "inbounds":[
    {"tag":"in-a","protocol":"vless","port":443,"settings":{"clients":[
      {"id":"11111111-1111-4111-8111-111111111111","email":"xrayctl-user-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","xrayctlLabel":"alice","level":0},
      {"id":"22222222-2222-4222-8222-222222222222","email":"xrayctl-user-bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","xrayctlLabel":"bob","level":0},
      {"id":"33333333-3333-4333-8333-333333333333","email":"charlie","level":0}
    ]}},
    {"tag":"in-b","protocol":"vless","port":8443,"settings":{"clients":[
      {"id":"44444444-4444-4444-8444-444444444444","email":"xrayctl-user-cccccccccccccccccccccccccccccccc","xrayctlLabel":"alice","level":0}
    ]}},
    {"tag":"socks-in","protocol":"socks","port":1080,"settings":{"auth":"password","accounts":[{"user":"socks-alice","pass":"secret"}]}},
    {"tag":"noauth-in","protocol":"socks","port":1081,"settings":{"auth":"noauth"}}
  ],
  "outbounds":[
    {"tag":"direct","protocol":"freedom"},
    {"tag":"blocked","protocol":"blackhole"},
    {"tag":"proxy-us","protocol":"socks","settings":{"address":"192.0.2.1","port":1080}},
    {"tag":"proxy-jp","protocol":"http","settings":{"address":"192.0.2.2","port":8080}},
    {"tag":"proxy-extra","protocol":"socks","settings":{"address":"192.0.2.3","port":1080}}
  ],
  "routing":{"domainStrategy":"IPIfNonMatch","rules":[
    {"type":"field","ip":["geoip:private"],"outboundTag":"blocked"},
    {"type":"field","protocol":["bittorrent"],"outboundTag":"blocked"}
  ]}
}
JSON

source "$REPO_ROOT/xrayctl.sh"
mv() {
  if [[ ${1-} == -T ]]; then
    shift
    [[ ${1-} != -- ]] || shift
  fi
  command mv "$@"
}
ensure_runtime_dependencies() { :; }
require_xray_installed() { :; }
setup_runtime_access() { :; }
service_is_active() { return 1; }
confirm() { return 0; }
apply_calls=0
apply_candidate() { apply_calls=$((apply_calls + 1)); state_commit "$1"; }

assert_eq() {
  [[ $1 == "$2" ]] || { printf 'not ok - %s (expected %s, got %s)\n' "$3" "$1" "$2" >&2; exit 1; }
}
assert_before() {
  local tag_a=$1 tag_b=$2 index_a index_b
  index_a=$(jq -r --arg tag "$tag_a" '[.routing.rules|to_entries[]|select(.value.ruleTag==$tag)|.key][0] // -1' "$XRAYCTL_CONFIG_FILE")
  index_b=$(jq -r --arg tag "$tag_b" '[.routing.rules|to_entries[]|select(.value.ruleTag==$tag)|.key][0] // -1' "$XRAYCTL_CONFIG_FILE")
  ((index_a>=0 && index_b>=0 && index_a<index_b)) || { printf 'not ok - priority %s before %s\n' "$tag_a" "$tag_b" >&2; exit 1; }
}

assign_outbound in-a direct >/dev/null
assign_outbound in-b direct >/dev/null
outbound_user_default_set in-a alice proxy-us >/dev/null
outbound_user_default_set in-a bob proxy-jp >/dev/null
outbound_user_default_set in-b alice proxy-jp >/dev/null
applies_before=$apply_calls
outbound_user_default_set in-a alice proxy-us >/dev/null
assert_eq "$applies_before" "$apply_calls" 'repeating the same default caused an unnecessary config apply'

# A failed restart rolls a user-route edit back exactly, including its prior
# outbound and rule tag.
before_restart_failure=$(jq -S . "$XRAYCTL_CONFIG_FILE")
service_is_active() { return 0; }
restart_calls=0
restart_service() { restart_calls=$((restart_calls + 1)); ((restart_calls > 1)); }
if outbound_user_default_set in-a bob proxy-us >/dev/null 2>&1; then
  printf 'not ok - user default was accepted despite a failed service restart\n' >&2; exit 1
fi
service_is_active() { return 1; }
assert_eq 2 "$restart_calls" 'failed restart did not attempt recovery restart'
assert_eq "$before_restart_failure" "$(jq -S . "$XRAYCTL_CONFIG_FILE")" 'failed user-route apply did not roll back the config'

outbound_user_domain_add in-a alice suffix google.com proxy-us >/dev/null
outbound_user_domain_add in-a alice exact google.com proxy-jp >/dev/null
outbound_user_domain_add in-a alice suffix sub.google.com direct >/dev/null
outbound_user_domain_add in-a bob exact google.com proxy-jp >/dev/null
outbound_user_domain_add in-b alice exact google.com proxy-us >/dev/null
assert_eq 2 "$(jq '[.routing.rules[]|select((.ruleTag // "")|startswith("xrayctl-user-domain:"))|select(.inboundTag==["in-a"] and .domain==["full:google.com"])]|length' "$XRAYCTL_CONFIG_FILE")" 'same-domain rules were rejected for another user'
assert_eq 1 "$(jq '[.routing.rules[]|select((.ruleTag // "")|startswith("xrayctl-user-domain:"))|select(.inboundTag==["in-b"] and .domain==["full:google.com"])]|length' "$XRAYCTL_CONFIG_FILE")" 'same-domain rule was rejected in another inbound'
cli_users=$(dispatch outbound user list in-a)
[[ $cli_users == *alice* && $cli_users == *bob* ]] || { printf 'not ok - outbound user list CLI arguments were misrouted\n' >&2; exit 1; }
dispatch outbound user rule add in-a bob exact cli.example.com direct >/dev/null
cli_rules=$(dispatch outbound user rule list in-a bob)
[[ $cli_rules == *'cli.example.com'* ]] || { printf 'not ok - user rule list CLI arguments were misrouted\n' >&2; exit 1; }
dispatch outbound user rule delete in-a bob exact cli.example.com >/dev/null
dispatch outbound user rule add in-a bob exact blocked.example.com blocked >/dev/null
cli_rules=$(dispatch outbound user rule list in-a bob)
[[ $cli_rules == *'blocked.example.com'* && $cli_rules == *'→ blocked'* ]] || { printf 'not ok - CLI did not accept a blocked user-domain route\n' >&2; exit 1; }
dispatch outbound user rule delete in-a bob exact blocked.example.com >/dev/null
dispatch outbound user set in-a bob proxy-us >/dev/null
assert_eq 1 "$(jq '[.routing.rules[]|select((.ruleTag // "")|startswith("xrayctl-user-outbound:"))|select(.inboundTag==["in-a"] and .user==["xrayctl-user-bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"] and .outboundTag=="proxy-us")]|length' "$XRAYCTL_CONFIG_FILE")" 'user default set CLI arguments were misrouted'
dispatch outbound user unset in-a bob >/dev/null
assert_eq 0 "$(jq '[.routing.rules[]|select((.ruleTag // "")|startswith("xrayctl-user-outbound:"))|select(.inboundTag==["in-a"] and .user==["xrayctl-user-bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"])]|length' "$XRAYCTL_CONFIG_FILE")" 'user default unset CLI arguments were misrouted'
assert_eq 1 "$(jq '[.routing.rules[]|select((.ruleTag // "")|startswith("xrayctl-user-domain:"))|select(.inboundTag==["in-a"] and .user==["xrayctl-user-bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"] and .domain==["full:google.com"])]|length' "$XRAYCTL_CONFIG_FILE")" 'unsetting the default removed user domain rules'
dispatch outbound user set in-a bob proxy-jp >/dev/null
inbound_cli=$(dispatch outbound inbound list)
[[ $inbound_cli == *'入站出站状态'* && $inbound_cli == *'公共域名规则'* ]] || { printf 'not ok - outbound inbound list CLI did not report status\n' >&2; exit 1; }
dispatch outbound inbound unset in-b >/dev/null
assert_eq 0 "$(jq '[.routing.rules[]|select(.ruleTag=="xrayctl-outbound:in-b")]|length' "$XRAYCTL_CONFIG_FILE")" 'inbound default unset CLI arguments were misrouted'
dispatch outbound inbound set in-b direct >/dev/null
assert_eq 1 "$(jq '[.routing.rules[]|select(.ruleTag=="xrayctl-outbound:in-b" and .outboundTag=="direct")]|length' "$XRAYCTL_CONFIG_FILE")" 'inbound default set CLI arguments were misrouted'
applies_before=$apply_calls
outbound_user_domain_add in-a alice exact batch-one.example.com,batch-two.example.com direct >/dev/null
assert_eq "$((applies_before + 1))" "$apply_calls" 'batched personal rules were not applied as one candidate'
outbound_user_domain_delete in-a alice exact batch-one.example.com,batch-two.example.com >/dev/null
assert_eq 0 "$(jq '[.routing.rules[]|select((.ruleTag // "")|startswith("xrayctl-user-domain:"))|select(.inboundTag==["in-a"] and (.domain[0]|test("batch-")))]|length' "$XRAYCTL_CONFIG_FILE")" 'batched personal rule deletion left a rule behind'
add_domain_rule in-a suffix google.com direct >/dev/null
outbound_user_default_set socks-in socks-alice proxy-us >/dev/null
rename_client socks-in socks-alice socks-renamed >/dev/null
assert_eq 1 "$(jq '[.routing.rules[]|select((.ruleTag // "")|startswith("xrayctl-user-outbound:"))|select(.inboundTag==["socks-in"] and .user==["socks-renamed"])]|length' "$XRAYCTL_CONFIG_FILE")" 'SOCKS username change detached its user route'
if _outbound_user_identity identity noauth-in missing >/dev/null 2>&1; then
  printf 'not ok - unauthenticated SOCKS was allowed a user route\n' >&2; exit 1
fi

alice_a=xrayctl-user-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
bob_a=xrayctl-user-bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
alice_b=xrayctl-user-cccccccccccccccccccccccccccccccc
assert_eq 1 "$(jq --arg id "$alice_a" '[.routing.rules[]|select((.ruleTag // "")|startswith("xrayctl-user-outbound:"))|select(.inboundTag==["in-a"] and .user==[$id] and .outboundTag=="proxy-us")]|length' "$XRAYCTL_CONFIG_FILE")" 'alice default outbound is scoped'
assert_eq 1 "$(jq --arg id "$bob_a" '[.routing.rules[]|select((.ruleTag // "")|startswith("xrayctl-user-outbound:"))|select(.inboundTag==["in-a"] and .user==[$id] and .outboundTag=="proxy-jp")]|length' "$XRAYCTL_CONFIG_FILE")" 'bob has a different default'
assert_eq 1 "$(jq --arg id "$alice_b" '[.routing.rules[]|select((.ruleTag // "")|startswith("xrayctl-user-outbound:"))|select(.inboundTag==["in-b"] and .user==[$id] and .outboundTag=="proxy-jp")]|length' "$XRAYCTL_CONFIG_FILE")" 'same display name in another inbound is isolated'
assert_eq 0 "$(jq '[.routing.rules[]|select((.ruleTag // "")|startswith("xrayctl-user-outbound:"))|select(.inboundTag==["in-a"] and .user==["charlie"])]|length' "$XRAYCTL_CONFIG_FILE")" 'no inherited user default route is generated'
user_list=$(outbound_user_list in-a)
[[ $user_list == *alice* && $user_list == *bob* ]] || { printf 'not ok - user list omitted users\n' >&2; exit 1; }

# Migrating VLESS users to internal StatsService emails updates routing identity.
outbound_user_default_set in-a charlie proxy-us >/dev/null
candidate=$(temp_file)
traffic_user_prepare_identities "$XRAYCTL_CONFIG_FILE" "$candidate" 127.0.0.1:12345
state_apply_candidate_file "$candidate" apply_candidate >/dev/null
charlie_identity=$(jq -r '.inbounds[]|select(.tag=="in-a")|.settings.clients[]|select(.xrayctlLabel=="charlie")|.email' "$XRAYCTL_CONFIG_FILE")
assert_eq 1 "$(jq --arg id "$charlie_identity" '[.routing.rules[]|select((.ruleTag // "")|startswith("xrayctl-user-outbound:"))|select(.inboundTag==["in-a"] and (.user|index($id)!=null))]|length' "$XRAYCTL_CONFIG_FILE")" 'StatsService identity migration retained user route'

rule_id() {
  jq -r --arg id "$alice_a" --arg domain "$2" '[.routing.rules[]|select((.ruleTag // "")|startswith("xrayctl-user-domain:"))|select(.inboundTag==["in-a"] and .user==[$id] and .domain==[$domain])|.ruleTag][0]' "$XRAYCTL_CONFIG_FILE"
}
specific=$(rule_id alice domain:sub.google.com)
exact=$(rule_id alice full:google.com)
suffix=$(rule_id alice domain:google.com)
public=$(jq -r '[.routing.rules[]|select((.ruleTag // "")|startswith("xrayctl-domain:"))|select(.inboundTag==["in-a"] and .domain==["domain:google.com"])|.ruleTag][0]' "$XRAYCTL_CONFIG_FILE")
user_default=$(jq -r --arg id "$alice_a" '[.routing.rules[]|select((.ruleTag // "")|startswith("xrayctl-user-outbound:"))|select(.inboundTag==["in-a"] and .user==[$id])|.ruleTag][0]' "$XRAYCTL_CONFIG_FILE")
assert_before "$specific" "$exact"
assert_before "$exact" "$suffix"
assert_before "$suffix" "$public"
assert_before "$public" "$user_default"
assert_before "$user_default" xrayctl-outbound:in-a

ensure_meta
state_commit_metadata _meta_template_add shared
add_domain_template_domains shared exact google.com
apply_domain_template in-a shared proxy-jp >/dev/null
template_rule=$(jq -r '[.routing.rules[]|select((.ruleTag // "")|startswith("xrayctl-domain:"))|select(.template=="shared" and .inboundTag==["in-a"] and .domain==["full:google.com"])|.ruleTag][0]' "$XRAYCTL_CONFIG_FILE")
assert_eq 1 "$(jq --arg id "$alice_a" '[.routing.rules[]|select((.ruleTag // "")|startswith("xrayctl-user-domain:"))|select(.inboundTag==["in-a"] and .user==[$id] and .domain==["full:google.com"])]|length' "$XRAYCTL_CONFIG_FILE")" 'template did not overwrite personal rule'
assert_before "$exact" "$template_rule"

quota=$(jq -n --arg id "$alice_a" '{type:"field",ruleTag:("xrayctl-user-limit:"+$id),inboundTag:["in-a"],user:[$id],outboundTag:"blocked"}')
tmp=$(temp_file)
jq --argjson quota "$quota" '.routing.rules=[$quota]+.routing.rules' "$XRAYCTL_CONFIG_FILE" >"$tmp"
state_commit "$tmp"
outbound_user_default_set in-a alice proxy-jp >/dev/null
assert_eq "xrayctl-user-limit:$alice_a" "$(jq -r '.routing.rules[0].ruleTag' "$XRAYCTL_CONFIG_FILE")" 'quota ban remains first'

rename_client in-a alice alice-renamed >/dev/null
assert_eq "$alice_a" "$(jq --arg tag "$user_default" -r '.routing.rules[]|select(.ruleTag==$tag)|.user[0]' "$XRAYCTL_CONFIG_FILE")" 'VLESS rename preserved Xray email identity'
prompt_validated_value() { printf -v "$1" '%s' aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa; }
rotate_client_credential in-a alice-renamed >/dev/null
assert_eq "$alice_a" "$(jq --arg tag "$user_default" -r '.routing.rules[]|select(.ruleTag==$tag)|.user[0]' "$XRAYCTL_CONFIG_FILE")" 'UUID rotation preserved route identity'

rename_inbound in-a renamed-a >/dev/null
assert_eq 1 "$(jq --arg id "$alice_a" '[.routing.rules[]|select((.ruleTag // "")|startswith("xrayctl-user-outbound:"))|select(.inboundTag==["renamed-a"] and .user==[$id])]|length' "$XRAYCTL_CONFIG_FILE")" 'inbound rename kept user route'
delete_client in-b alice 1 >/dev/null
assert_eq 0 "$(jq '[.routing.rules[]|select((.ruleTag // "")|startswith("xrayctl-user-outbound:"))|select(.inboundTag==["in-b"])]|length' "$XRAYCTL_CONFIG_FILE")" 'user deletion removed that user route'
assert_eq 0 "$(jq '[.routing.rules[]|select((.ruleTag // "")|startswith("xrayctl-user-domain:"))|select(.inboundTag==["in-b"])]|length' "$XRAYCTL_CONFIG_FILE")" 'user deletion removed that user domain route'
assert_eq 1 "$(jq --arg id "$alice_a" '[.routing.rules[]|select((.ruleTag // "")|startswith("xrayctl-user-outbound:"))|select(.inboundTag==["renamed-a"] and .user==[$id])]|length' "$XRAYCTL_CONFIG_FILE")" 'deleting another user did not affect this user'

outbound_user_domain_add renamed-a alice-renamed exact remove.example.com proxy-extra >/dev/null
outbound_user_domain_add renamed-a alice-renamed exact keep.example.com direct >/dev/null
delete_outbound proxy-extra >/dev/null
assert_eq 0 "$(jq '[.routing.rules[]|select((.ruleTag // "")|startswith("xrayctl-user-domain:"))|select(.inboundTag==["renamed-a"] and .domain==["full:remove.example.com"])]|length' "$XRAYCTL_CONFIG_FILE")" 'outbound deletion removed only its managed user rule'
assert_eq 1 "$(jq '[.routing.rules[]|select((.ruleTag // "")|startswith("xrayctl-user-domain:"))|select(.inboundTag==["renamed-a"] and .domain==["full:keep.example.com"])]|length' "$XRAYCTL_CONFIG_FILE")" 'outbound deletion preserved other user rules'

outbound_user_default_unset renamed-a alice-renamed >/dev/null
assert_eq 4 "$(jq --arg id "$alice_a" '[.routing.rules[]|select((.ruleTag // "")|startswith("xrayctl-user-domain:"))|select(.inboundTag==["renamed-a"] and .user==[$id])]|length' "$XRAYCTL_CONFIG_FILE")" 'cancel default retained personal domain rules'
outbound_user_restore renamed-a alice-renamed >/dev/null
assert_eq 0 "$(jq --arg id "$alice_a" '[.routing.rules[]|select((.ruleTag // "")|startswith("xrayctl-user-domain:"))|select(.inboundTag==["renamed-a"] and .user==[$id])]|length' "$XRAYCTL_CONFIG_FILE")" 'restore removed personal rules'
delete_inbound socks-in 1 >/dev/null
assert_eq 0 "$(jq '[.routing.rules[]|select((.ruleTag // "")|startswith("xrayctl-user-outbound:"))|select(.inboundTag==["socks-in"])]|length' "$XRAYCTL_CONFIG_FILE")" 'inbound deletion removed associated user route'

custom=$(jq -n '{type:"field",inboundTag:["renamed-a"],network:["tcp"],outboundTag:"proxy-us"}')
tmp=$(temp_file)
jq --argjson custom "$custom" '.routing.rules += [$custom]' "$XRAYCTL_CONFIG_FILE" >"$tmp"
state_commit "$tmp"
before=$(jq -S . "$XRAYCTL_CONFIG_FILE")
if outbound_user_default_set renamed-a alice-renamed direct >/dev/null 2>&1; then
  printf 'not ok - user routing changed with an unknown applicable rule\n' >&2; exit 1
fi
assert_eq "$before" "$(jq -S . "$XRAYCTL_CONFIG_FILE")" 'unsafe change left custom config untouched'
if outbound_user_domain_add renamed-a alice-renamed exact unsafe.example.com direct >/dev/null 2>&1; then
  printf 'not ok - user domain routing changed with an unknown applicable rule\n' >&2; exit 1
fi
assert_eq "$before" "$(jq -S . "$XRAYCTL_CONFIG_FILE")" 'unsafe domain change left custom config untouched'

selector_options=()
selector_pick=direct
choose() {
  local destination=$1 index=1 option
  shift 2
  selector_options=("$@")
  for option in "${selector_options[@]}"; do
    if [[ $option == "$selector_pick" ]]; then printf -v "$destination" '%s' "$index"; return 0; fi
    index=$((index + 1))
  done
  return 1
}
detect_local_ips() { printf 'Loopback Test\t192.0.2.10\tlo\n'; }
selector_has() {
  local expected=$1 option
  for option in "${selector_options[@]}"; do [[ $option == "$expected" ]] && return 0; done
  return 1
}
select_outbound selected 1 1 "" || { printf 'not ok - normal outbound selection failed\n' >&2; exit 1; }
assert_eq direct "$selected" 'normal selector selected the requested outbound'
for expected in direct proxy-us proxy-jp 'Loopback'; do
  selector_has "$expected" || { printf 'not ok - normal selector omitted %s\n' "$expected" >&2; exit 1; }
done
if selector_has blocked; then
  printf 'not ok - ordinary outbound selector exposed blocked\n' >&2; exit 1
fi
selector_pick=blocked
select_outbound selected 1 0 "" 1 || { printf 'not ok - user-domain selector did not offer blocked\n' >&2; exit 1; }
assert_eq blocked "$selected" 'user-domain selector selected blocked'
selector_has direct && selector_has blocked && selector_has proxy-us && selector_has proxy-jp || {
  printf 'not ok - user-domain selector changed the existing outbound choices\n' >&2; exit 1;
}

printf 'ok - per-inbound user outbound scope, priority, inheritance, blocked rules, identity lifecycle, rollback, and safe refusal pass\n'
