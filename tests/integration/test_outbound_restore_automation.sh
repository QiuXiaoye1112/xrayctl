#!/usr/bin/env bash
REPO_ROOT=$(cd "$(dirname "$0")/../.." && pwd)
set -Eeuo pipefail
case_dir=$(mktemp -d /tmp/xrayctl-restore-check.XXXXXXXX)
trap 'rm -rf "$case_dir"' EXIT
source "$REPO_ROOT/xrayctl.sh"
trap - ERR
trap 'rm -rf "$case_dir"' EXIT
CONFIG_FILE="$case_dir/config.json"
META_FILE="$case_dir/meta.json"
cat > "$CONFIG_FILE" <<'JSON'
{"inbounds":[{"tag":"test-in","protocol":"vless","settings":{"clients":[{"email":"alice-id","xrayctlLabel":"Alice"},{"email":"bob-id","xrayctlLabel":"Bob"}]}},{"tag":"socks-test","protocol":"socks","settings":{"auth":"password","accounts":[{"user":"213","pass":"fixture"}]}}],"outbounds":[{"tag":"direct","protocol":"freedom"},{"tag":"blocked","protocol":"blackhole"}],"routing":{"rules":[{"type":"field","ruleTag":"xrayctl-user-limit:alice-id","inboundTag":["test-in"],"user":["alice-id"],"outboundTag":"blocked"},{"type":"field","ruleTag":"xrayctl-user-domain:alice","inboundTag":["test-in"],"user":["alice-id"],"domain":["full:personal.example.com"],"outboundTag":"direct"},{"type":"field","ruleTag":"xrayctl-user-domain:bob","inboundTag":["test-in"],"user":["bob-id"],"domain":["domain:bob.example.com"],"outboundTag":"direct"},{"type":"field","ruleTag":"xrayctl-domain:public","inboundTag":["test-in"],"domain":["domain:public.example.com"],"outboundTag":"direct"},{"type":"field","ruleTag":"xrayctl-user-outbound:alice","inboundTag":["test-in"],"user":["alice-id"],"outboundTag":"direct"},{"type":"field","ruleTag":"xrayctl-outbound:test-in","inboundTag":["test-in"],"outboundTag":"direct"}]}}
JSON
cp "$CONFIG_FILE" "$case_dir/base.json"
printf '%s\n' '{"domainTemplates":{"templates":[],"bindings":[],"userBindings":[]}}' > "$META_FILE"
ensure_runtime_dependencies() { :; }
ensure_config() { :; }
ensure_meta() { :; }
temp_file() { mktemp "$case_dir/candidate.XXXXXXXX"; }
state_commit() {
  local config_candidate=$1 metadata_builder=${2-}
  if [[ -n $metadata_builder ]]; then
    "$metadata_builder" "$META_FILE" "$case_dir/new-meta.json" "${@:3}"
    mv "$case_dir/new-meta.json" "$META_FILE"
  fi
  cp "$config_candidate" "$CONFIG_FILE"
  touch "$case_dir/committed"
}
apply_candidate() { state_commit "$1"; }
before=$(jq -Sc . "$CONFIG_FILE")
dispatch outbound user rule delete test-in Alice suffix not-exist.com > "$case_dir/no-change.out"
grep -q '域名规则没有变化' "$case_dir/no-change.out"
if grep -q '域名规则已更新\|已删除' "$case_dir/no-change.out"; then
  printf 'no-op deletion reported a modification\n' >&2; exit 1
fi
[[ $(jq -Sc . "$CONFIG_FILE") == "$before" && ! -e "$case_dir/committed" ]]
dispatch outbound user rule delete socks-test 213 suffix not-exist.com > "$case_dir/no-change-socks.out"
grep -q '域名规则没有变化' "$case_dir/no-change-socks.out"
[[ ! -e "$case_dir/committed" ]]
dispatch outbound user rule delete test-in Alice exact personal.example.com > "$case_dir/deleted.out"
grep -q '已删除' "$case_dir/deleted.out"
jq -e '[.routing.rules[]|select(.domain==["full:personal.example.com"])]|length==0' "$CONFIG_FILE" >/dev/null
cp "$case_dir/base.json" "$CONFIG_FILE"
printf '%s\n' '{"domainTemplates":{"templates":[],"bindings":[{"inbound":"test-in","template":"public-template","outbound":"direct"}],"userBindings":[{"inbound":"test-in","user":"alice-id","template":"alice-template","outbound":"direct"},{"inbound":"test-in","user":"bob-id","template":"bob-template","outbound":"direct"}]}}' > "$META_FILE"
expect_failure_unchanged() {
  local before_config before_meta
  before_config=$(sha256sum "$CONFIG_FILE"); before_meta=$(sha256sum "$META_FILE")
  if (dispatch "$@" </dev/null) > "$case_dir/failure.out" 2>&1; then
    printf 'unexpected success: %s\n' "$*" >&2; return 1
  fi
  [[ $(sha256sum "$CONFIG_FILE") == "$before_config" && $(sha256sum "$META_FILE") == "$before_meta" ]]
  [[ -s "$case_dir/failure.out" ]]
}
expect_failure_unchanged outbound user restore test-in Alice
expect_failure_unchanged outbound user restore test-in Missing --yes
expect_failure_unchanged outbound user restore missing Alice --yes
expect_failure_unchanged outbound user restore test-in Alice --force
expect_failure_unchanged outbound user restore test-in Alice --yes extra
expected_config=$(jq -Sc '.routing.rules |= map(select((.inboundTag==["test-in"] and .user==["alice-id"] and (((.ruleTag // "")|startswith("xrayctl-user-domain:")) or ((.ruleTag // "")|startswith("xrayctl-user-outbound:"))))|not))' "$CONFIG_FILE")
expected_meta=$(jq -Sc '.domainTemplates.userBindings |= map(select(.inbound!="test-in" or .user!="alice-id"))' "$META_FILE")
dispatch outbound user restore test-in Alice --yes </dev/null > "$case_dir/restored.out"
grep -q '已恢复继承入站路由' "$case_dir/restored.out"
[[ $(jq -Sc . "$CONFIG_FILE") == "$expected_config" && $(jq -Sc . "$META_FILE") == "$expected_meta" ]]
# The alias uses the same flag handling and retains all inherited/public/quota rules.
dispatch outbound user inherit test-in Alice --yes </dev/null > "$case_dir/inherit.out"
[[ $(jq -Sc . "$CONFIG_FILE") == "$expected_config" ]]
clear_screen() { :; }
domain_rule_detail_menu() { menu_action=public; }
inbound_user_outbound_menu() { menu_action=user; }
menu_action=''
inbound_outbound_detail_menu test-in <<< $'2\n0\n' > "$case_dir/menu.out"
[[ $menu_action == public ]]
grep -q '2) 公共域名分流' "$case_dir/menu.out"
grep -q '3) 用户出站管理' "$case_dir/menu.out"
menu_action=''
inbound_outbound_detail_menu test-in <<< $'3\n0\n' >/dev/null
[[ $menu_action == user ]]
printf 'isolated menu ordering, no-change deletion and restore --yes checks passed\n'
