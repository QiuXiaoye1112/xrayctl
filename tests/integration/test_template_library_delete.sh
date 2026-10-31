#!/usr/bin/env bash
set -Eeuo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(cd "$TEST_DIR/../.." && pwd)
TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/xrayctl-template-delete.XXXXXX")
trap 'rm -rf "$TEST_ROOT"' EXIT
export XRAYCTL_TESTING=1 XRAYCTL_CONFIG_DIR="$TEST_ROOT/config"
export XRAYCTL_CONFIG_FILE="$XRAYCTL_CONFIG_DIR/config.json" XRAYCTL_META_FILE="$XRAYCTL_CONFIG_DIR/meta.json"
export XRAYCTL_CERT_DIR="$TEST_ROOT/certs" XRAYCTL_LOG_DIR="$TEST_ROOT/logs" XRAYCTL_BACKUP_DIR="$TEST_ROOT/backups"
export XRAYCTL_TRAFFIC_FILE="$TEST_ROOT/traffic.json" XRAYCTL_XRAY_BIN="${XRAYCTL_REAL_XRAY_BIN:-$TEST_ROOT/missing-xray}"
if [[ -n ${XRAYCTL_REAL_XRAY_BIN:-} ]]; then export XRAYCTL_SHARE_DIR="$(dirname "$XRAYCTL_REAL_XRAY_BIN")"; fi
export XRAYCTL_RUNTIME_OWNER XRAYCTL_RUNTIME_GROUP
XRAYCTL_RUNTIME_OWNER=$(id -un); XRAYCTL_RUNTIME_GROUP=$(id -gn)
mkdir -p "$XRAYCTL_CONFIG_DIR" "$XRAYCTL_CERT_DIR"
cat >"$XRAYCTL_CONFIG_FILE" <<'JSON'
{"log":{"loglevel":"warning"},"inbounds":[{"tag":"in-a","protocol":"vless","port":443,"settings":{"decryption":"none","clients":[{"id":"11111111-1111-4111-8111-111111111111","email":"alice"},{"id":"22222222-2222-4222-8222-222222222222","email":"bob"}]}}],"outbounds":[{"tag":"direct","protocol":"freedom"},{"tag":"blocked","protocol":"blackhole"},{"tag":"proxy","protocol":"socks","settings":{"address":"192.0.2.1","port":1080}}],"routing":{"domainStrategy":"IPIfNonMatch","rules":[{"type":"field","ip":["geoip:private"],"outboundTag":"blocked"}]}}
JSON
source "$REPO_ROOT/tests/helpers/assert.sh"
source "$REPO_ROOT/xrayctl.sh"
trap - ERR
trap 'rm -rf "$TEST_ROOT"' EXIT
ensure_runtime_dependencies() { :; }
require_xray_installed() { :; }
setup_runtime_access() { :; }
service_is_active() { return 1; }
confirm() { return 0; }
ensure_meta
for template in Alpha Beta Gamma; do state_commit_metadata _meta_template_add "$template"; done
add_domain_template_domains Alpha suffix shared.example.com,alpha-only.example.com >/dev/null
add_domain_template_domains Beta suffix shared.example.com,beta-only.example.com >/dev/null
add_domain_template_domains Gamma suffix gamma.example.com >/dev/null
assign_outbound in-a direct >/dev/null
apply_domain_template in-a Alpha direct >/dev/null
apply_domain_template in-a Beta proxy >/dev/null
outbound_user_default_set in-a alice proxy >/dev/null
user_template_apply in-a alice Alpha direct >/dev/null
user_template_apply in-a alice Beta proxy >/dev/null
user_template_apply in-a bob Gamma direct >/dev/null
add_domain_rule in-a exact manual.public.example direct >/dev/null
outbound_user_domain_add in-a alice exact manual.personal.example direct >/dev/null
assert_eq 1 "$(jq '[.routing.rules[]|select(.template=="Beta" and .domain==["domain:shared.example.com"] and .user==["alice"] and .outboundTag=="proxy")]|length' "$CONFIG_FILE")" 'overlapping user template was not active before deletion'
assert_eq 1 "$(jq '[.routing.rules[]|select(.template=="Beta" and .domain==["domain:shared.example.com"] and (.user // [])==[] and .outboundTag=="proxy")]|length' "$CONFIG_FILE")" 'overlapping inbound template was not active before deletion'

before_config=$(jq -Sc . "$CONFIG_FILE"); before_meta=$(jq -Sc . "$META_FILE")
confirm() { return 1; }
delete_domain_template Beta >/dev/null
assert_eq "$before_config" "$(jq -Sc . "$CONFIG_FILE")" 'cancel changed config'
assert_eq "$before_meta" "$(jq -Sc . "$META_FILE")" 'cancel changed metadata'
confirm() { return 0; }
service_is_active() { return 0; }
restart_calls=0
restart_service() { restart_calls=$((restart_calls+1)); ((restart_calls > 1)); }
if delete_domain_template Beta >/dev/null 2>&1; then fail 'failed restart accepted template deletion'; fi
service_is_active() { return 1; }
assert_eq 2 "$restart_calls" 'failed restart did not attempt recovery'
assert_eq "$before_config" "$(jq -Sc . "$CONFIG_FILE")" 'failed deletion changed config'
assert_eq "$before_meta" "$(jq -Sc . "$META_FILE")" 'failed deletion changed metadata'

delete_domain_template Beta >/dev/null
assert_eq 0 "$(jq '[.domainTemplates.templates[]?|select(.name=="Beta")]|length' "$META_FILE")" 'deleted template remains in library'
assert_eq 0 "$(jq '[.domainTemplates.bindings[]?,.domainTemplates.userBindings[]?|select(.template=="Beta")]|length' "$META_FILE")" 'deleted template bindings remain'
assert_eq 0 "$(jq '[.routing.rules[]?|select(.template=="Beta" or .domain==["domain:beta-only.example.com"]) ]|length' "$CONFIG_FILE")" 'deleted template rules remain'
assert_eq 1 "$(jq '[.routing.rules[]|select(.template=="Alpha" and .domain==["domain:shared.example.com"] and (.user // [])==[] and .outboundTag=="direct")]|length' "$CONFIG_FILE")" 'inbound overlap did not fall back to Alpha'
assert_eq 1 "$(jq '[.routing.rules[]|select(.template=="Alpha" and .domain==["domain:shared.example.com"] and .user==["alice"] and .outboundTag=="direct")]|length' "$CONFIG_FILE")" 'user overlap did not fall back to Alpha'
assert_eq 1 "$(jq '[.routing.rules[]|select(.domain==["full:manual.public.example"]) ]|length' "$CONFIG_FILE")" 'unrelated public rule removed'
assert_eq 1 "$(jq '[.routing.rules[]|select(.domain==["full:manual.personal.example"]) ]|length' "$CONFIG_FILE")" 'unrelated personal rule removed'
assert_eq 1 "$(jq '[.routing.rules[]|select(.template=="Gamma" and .user==["bob"]) ]|length' "$CONFIG_FILE")" 'another user template was removed'
assert_eq 1 "$(jq '[.routing.rules[]|select(.ruleTag=="xrayctl-outbound:in-a")]|length' "$CONFIG_FILE")" 'inbound default removed'
assert_eq 1 "$(jq '[.routing.rules[]|select((.ruleTag // "")|startswith("xrayctl-user-outbound:"))|select(.user==["alice"]) ]|length' "$CONFIG_FILE")" 'user default removed'
# Deleting the final binding must also remove its last generated inbound rule.
delete_domain_template Alpha >/dev/null
assert_eq 0 "$(jq '[.routing.rules[]?|select(.template=="Alpha")]|length' "$CONFIG_FILE")" 'last template rules remain after deletion'
# An orphaned generated rule is removed even if its old binding is already missing.
state_commit_metadata _meta_template_add Orphan
tmp=$(temp_file)
jq '.routing.rules += [{type:"field",ruleTag:"xrayctl-domain:orphan",template:"Orphan",inboundTag:["in-a"],domain:["domain:orphan.example.com"],outboundTag:"direct"}]' "$CONFIG_FILE" >"$tmp"
state_apply_candidate_file "$tmp" apply_candidate >/dev/null
delete_domain_template Orphan >/dev/null
assert_eq 0 "$(jq '[.routing.rules[]?|select(.template=="Orphan")]|length' "$CONFIG_FILE")" 'orphan template rule remains after deletion'
# Malformed ownership must be rejected without changing either file.
state_commit_metadata _meta_template_add Ambiguous
tmp=$(temp_file)
jq '.routing.rules += [{type:"field",ruleTag:"xrayctl-domain:ambiguous",template:"Ambiguous",inboundTag:["in-a","other"],domain:["domain:ambiguous.example.com"],outboundTag:"direct"}]' "$CONFIG_FILE" >"$tmp"
state_apply_candidate_file "$tmp" apply_candidate >/dev/null
before_config=$(jq -Sc . "$CONFIG_FILE"); before_meta=$(jq -Sc . "$META_FILE")
if delete_domain_template Ambiguous >/dev/null 2>&1; then fail 'ambiguous template ownership was accepted'; fi
assert_eq "$before_config" "$(jq -Sc . "$CONFIG_FILE")" 'ambiguous deletion changed config'
assert_eq "$before_meta" "$(jq -Sc . "$META_FILE")" 'ambiguous deletion changed metadata'
tmp=$(temp_file)
jq '.routing.rules |= map(select(.ruleTag!="xrayctl-domain:ambiguous"))' "$CONFIG_FILE" >"$tmp"
state_apply_candidate_file "$tmp" apply_candidate >/dev/null
# Unused template deletion must not require changing unrelated custom routes.
tmp=$(temp_file)
jq '.routing.rules += [{type:"field",inboundTag:["in-a"],network:["tcp"],outboundTag:"direct"}]' "$CONFIG_FILE" >"$tmp"
state_apply_candidate_file "$tmp" apply_candidate >/dev/null
before_config=$(jq -Sc . "$CONFIG_FILE")
state_commit_metadata _meta_template_add Unused
delete_domain_template Unused >/dev/null
assert_eq "$before_config" "$(jq -Sc . "$CONFIG_FILE")" 'unused template deletion changed unrelated routing'
printf 'ok - template deletion preserves overlaps, unrelated routes, cancellation and rollback\n'
