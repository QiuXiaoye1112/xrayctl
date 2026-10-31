#!/usr/bin/env bash
set -Eeuo pipefail
REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/xrayctl-user-templates.XXXXXX")
cleanup() { rm -rf "$TEST_ROOT"; }
trap cleanup EXIT
export XRAYCTL_TESTING=1 XRAYCTL_TMP_DIR="$TEST_ROOT/tmp"
export XRAYCTL_CONFIG_DIR="$TEST_ROOT/config" XRAYCTL_LOG_DIR="$TEST_ROOT/logs"
export XRAYCTL_CONFIG_FILE="$TEST_ROOT/config/config.json" XRAYCTL_META_FILE="$TEST_ROOT/config/meta.json"
export XRAYCTL_TRAFFIC_FILE="$TEST_ROOT/traffic.json" XRAYCTL_LOCK_FILE="$TEST_ROOT/lock"
export XRAYCTL_XRAY_BIN="${XRAYCTL_REAL_XRAY_BIN:-$TEST_ROOT/missing-xray}"
export XRAYCTL_RUNTIME_OWNER XRAYCTL_RUNTIME_GROUP
XRAYCTL_RUNTIME_OWNER=$(id -un); XRAYCTL_RUNTIME_GROUP=$(id -gn)
source "$REPO_ROOT/tests/helpers/assert.sh"
source "$REPO_ROOT/xrayctl.sh"
trap - ERR
trap cleanup EXIT
ensure_runtime_dependencies() { :; }
setup_runtime_access() { :; }
service_is_active() { return 1; }
confirm() { return 0; }
mkdir -p "$CONFIG_DIR"
cat >"$CONFIG_FILE" <<'JSON'
{"log":{"loglevel":"warning"},"inbounds":[{"tag":"node","listen":"127.0.0.1","port":12345,"protocol":"vless","settings":{"decryption":"none","clients":[{"id":"11111111-1111-4111-8111-111111111111","email":"alice"},{"id":"22222222-2222-4222-8222-222222222222","email":"bob"}]}}],"outbounds":[{"tag":"direct","protocol":"freedom"},{"tag":"first","protocol":"http","settings":{"address":"192.0.2.1","port":8080}},{"tag":"second","protocol":"http","settings":{"address":"192.0.2.2","port":8080}}],"routing":{"rules":[]}}
JSON
ensure_meta
for name in Shared Personal; do
  state_commit_metadata _meta_template_add "$name"
  add_domain_template_domains "$name" suffix example.com >/dev/null
done
apply_domain_template node Shared first >/dev/null
apply_domain_template node Personal second >/dev/null
user_template_apply node alice Shared second >/dev/null
user_template_apply node bob Shared first >/dev/null
add_domain_template_domains Shared exact api.example.com >/dev/null
jq -e '
  ([.routing.rules[]|select(.template=="Shared" and .domain==["full:api.example.com"])]|length)==3 and
  ([.routing.rules[]|select(.user==["alice"])]|length)==2 and
  ([.routing.rules[]|select(.user==["bob"])]|length)==2
' "$CONFIG_FILE" >/dev/null || fail 'template edit did not synchronize public and user bindings'
outbound_user_domain_add node alice exact api.example.com direct >/dev/null
jq -e '[.routing.rules[]|select(.user==["alice"] and .domain==["full:api.example.com"])] | length==1 and .[0].outboundTag=="direct" and .[0].template==null' "$CONFIG_FILE" >/dev/null || fail 'direct user rule did not override its template'
user_template_remove node bob Shared >/dev/null
jq -e '[.routing.rules[]|select(.user==["bob"])]|length==0' "$CONFIG_FILE" >/dev/null || fail 'template removal affected the wrong user'
delete_outbound second >/dev/null
jq -e '
  ([.domainTemplates.bindings[]?,.domainTemplates.userBindings[]?|select(.outbound=="second")]|length)==0
' "$META_FILE" >/dev/null || fail 'outbound deletion retained template references'
jq -e '
  ([.routing.rules[]|select(.domain==["domain:example.com"] and .user==null)] | length==1 and .[0].outboundTag=="first") and
  ([.routing.rules[]|select(.user==["alice"] and .domain==["full:api.example.com"])] | length==1 and .[0].outboundTag=="direct")
' "$CONFIG_FILE" >/dev/null || fail 'outbound deletion did not restore template fallback or preserve direct user rules'
rename_inbound node renamed >/dev/null
jq -e 'all(.domainTemplates.bindings[]?; .inbound=="renamed")' "$META_FILE" >/dev/null
pass 'public and per-user templates synchronize, preserve overrides, and recover fallback on outbound deletion'
