#!/usr/bin/env bash
REPO_ROOT=$(cd "$(dirname "$0")/../.." && pwd)
set -Eeuo pipefail
case_dir=$(mktemp -d /tmp/xrayctl-rotate-check.XXXXXXXX)
trap 'rm -rf "$case_dir"' EXIT
source "$REPO_ROOT/xrayctl.sh"
trap - ERR
trap 'rm -rf "$case_dir"' EXIT
CONFIG_FILE="$case_dir/config.json"
cat > "$CONFIG_FILE" <<'JSON'
{"inbounds":[{"tag":"vless-test","protocol":"vless","settings":{"clients":[{"id":"11111111-1111-4111-8111-111111111111","email":"xrayctl-user-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","xrayctlLabel":"Alice","level":0},{"id":"22222222-2222-4222-8222-222222222222","email":"xrayctl-user-bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","xrayctlLabel":"Bob","level":0}]}},{"tag":"socks-test","protocol":"socks","settings":{"auth":"password","accounts":[{"user":"SocksUser","pass":"old-socks"}]}},{"tag":"http-test","protocol":"http","settings":{"accounts":[{"user":"HttpUser","pass":"old-http"}]}}],"outbounds":[{"tag":"direct","protocol":"freedom"}],"routing":{"rules":[]},"api":{"tag":"xrayctl-user-stats","listen":"127.0.0.1:12346","services":["StatsService"]},"xrayctlUserStats":{"enabled":true}}
JSON
ensure_runtime_dependencies() { :; }
ensure_config() { :; }
inbound_require_supported_configuration() { :; }
temp_file() { mktemp "$case_dir/candidate.XXXXXXXX"; }
apply_candidate() { cp "$1" "$CONFIG_FILE"; }
# Each failure must be nonzero and leave all credentials byte-for-byte intact.
expect_failure_unchanged() {
  local before exit_code
  before=$(sha256sum "$CONFIG_FILE")
  if (dispatch "$@" </dev/null) >"$case_dir/failure.out" 2>&1; then
    printf 'unexpected success: %s\n' "$*" >&2; return 1
  else
    exit_code=$?
  fi
  [[ $exit_code -ne 0 && $(sha256sum "$CONFIG_FILE") == "$before" ]]
  [[ -s $case_dir/failure.out ]]
}
expect_failure_unchanged client rotate vless-test Alice
expect_failure_unchanged client rotate vless-test --yes
expect_failure_unchanged client rotate missing Alice --yes
expect_failure_unchanged client rotate vless-test MissingUser --yes
expect_failure_unchanged client rotate vless-test Alice --force
expect_failure_unchanged client rotate vless-test Alice --yes extra
before_bob=$(jq -c '.inbounds[0].settings.clients[1]' "$CONFIG_FILE")
dispatch client rotate vless-test Alice --yes </dev/null >"$case_dir/vless.out"
jq -e '.inbounds[0].settings.clients[0] | .id!="11111111-1111-4111-8111-111111111111" and (.id|test("^[0-9a-fA-F-]{36}$")) and .email=="xrayctl-user-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" and .xrayctlLabel=="Alice"' "$CONFIG_FILE" >/dev/null
[[ $(jq -c '.inbounds[0].settings.clients[1]' "$CONFIG_FILE") == "$before_bob" ]]
dispatch client rotate socks-test SocksUser --yes </dev/null >"$case_dir/socks.out"
jq -e '.inbounds[1].settings | .accounts[0].pass!="old-socks" and (.accounts[0].pass|length)>0 and .accounts==.users' "$CONFIG_FILE" >/dev/null
dispatch client reset http-test HttpUser --yes </dev/null >"$case_dir/http.out"
jq -e '.inbounds[2].settings | .accounts[0].pass!="old-http" and (.accounts[0].pass|length)>0 and .accounts==.users' "$CONFIG_FILE" >/dev/null
# UUID/password generator failures must not result in a success or partial commit.
generate_uuid() { return 1; }
expect_failure_unchanged client rotate vless-test Alice --yes
random_password() { printf ''; }
expect_failure_unchanged client rotate socks-test SocksUser --yes
printf 'isolated VLESS/SOCKS5/HTTP rotations, identity preservation, argument validation and no-change failures passed\n'
