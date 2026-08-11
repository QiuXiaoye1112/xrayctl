#!/usr/bin/env bash

set -Eeuo pipefail

readonly TEST_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
readonly REPO_ROOT=$(cd "${TEST_DIR}/../.." && pwd)
readonly TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/xrayctl-coexistence.XXXXXX")
trap 'rm -rf "$TEST_ROOT"' EXIT

export XRAYCTL_CONFIG_DIR="${TEST_ROOT}/xray"
export XRAYCTL_CONFIG_FILE="${XRAYCTL_CONFIG_DIR}/config.json"
export XRAYCTL_META_FILE="${XRAYCTL_CONFIG_DIR}/meta.json"
export XRAYCTL_SBCTL_CONFIG_FILE="${TEST_ROOT}/sing-box/config.json"
export XRAYCTL_SBCTL_META_FILE="${TEST_ROOT}/sbctl-meta.json"
export XRAYCTL_BBR_CONFIG="${TEST_ROOT}/99-xrayctl-bbr.conf"
export XRAYCTL_SBCTL_BBR_CONFIG="${TEST_ROOT}/99-sbctl-bbr.conf"
export XRAYCTL_CERTBOT_VENV="${TEST_ROOT}/certbot-venv"
export XRAYCTL_CERTBOT_SHARED_LOCK="${TEST_ROOT}/certbot.lock"
export XRAYCTL_CERTBOT_SHARED_LOCK_WAIT=0

mkdir -p "$XRAYCTL_CONFIG_DIR" "$(dirname "$XRAYCTL_SBCTL_CONFIG_FILE")"
cat >"$XRAYCTL_CONFIG_FILE" <<'JSON'
{"inbounds":[],"outbounds":[],"routing":{"rules":[]}}
JSON
cat >"$XRAYCTL_SBCTL_CONFIG_FILE" <<'JSON'
{"inbounds":[{"type":"socks","tag":"peer","listen_port":25001}]}
JSON
cat >"$XRAYCTL_SBCTL_META_FILE" <<'JSON'
{"inbounds":{"hy2":{"hysteria2PortHopping":{"enabled":true,"range":"30000-40000"}}}}
JSON

# shellcheck source=../helpers/assert.sh
source "${REPO_ROOT}/tests/helpers/assert.sh"
# shellcheck source=../../xrayctl.sh
source "${REPO_ROOT}/xrayctl.sh"
trap - ERR
trap 'rm -rf "$TEST_ROOT"' EXIT

assert_eq 'sbctl/sing-box 入站正在使用该端口' "$(sbctl_port_conflict_reason 25001)" "sing-box port conflict was not detected"
assert_eq '该端口位于 sbctl Hysteria2 UDP 跳跃范围 30000-40000 内' "$(sbctl_port_conflict_reason 35000)" "HY2 hopping conflict was not detected"
if sbctl_port_conflict_reason 25002 >/dev/null; then fail 'free port was reported as a peer conflict'; fi

random_file="$TEST_ROOT/random-values"
printf '%s\n' 3a99 61a8 3a9a >"$random_file"
random_hex() {
  local value
  IFS= read -r value <"$random_file"
  tail -n +2 "$random_file" >"$random_file.next"
  mv "$random_file.next" "$random_file"
  printf '%s' "$value"
}
port_in_use_os() { return 1; }
automatic_port=""
suggest_available_port automatic_port
assert_eq 25002 "$automatic_port" "automatic port did not skip sing-box and HY2 conflicts"

prompt_values=(25001 35000 25002)
prompt_index=0
prompt_value() {
  printf -v "$1" '%s' "${prompt_values[$prompt_index]}"
  ((prompt_index+=1)) || true
}
selected=""
prompt_port selected 25001
assert_eq 25002 "$selected" "prompt did not skip peer-owned ports"

touch "$SBCTL_BBR_CONFIG"
assert_eq sbctl "$(bbr_manager)" "sbctl BBR ownership was not detected"
touch "$BBR_CONFIG"
assert_eq both "$(bbr_manager)" "duplicate BBR ownership was not detected"
external_bbr="$TEST_ROOT/third-party-bbr.conf"
touch "$external_bbr"
bbr_remove_known_persistence
[[ ! -e $BBR_CONFIG && ! -e $SBCTL_BBR_CONFIG ]] || fail 'known BBR persistence was not removed'
[[ -e $external_bbr ]] || fail 'unrelated BBR persistence was removed'
if declare -f _disable_bbr | grep -Fq '拒绝关闭'; then fail 'global BBR disable is still ownership-gated'; fi

mkdir -p "$CERTBOT_VENV/bin"
cat >"$CERTBOT_BIN" <<'SH'
#!/usr/bin/env bash
[[ ${CERTBOT_STUB_FAIL:-0} != 1 ]]
SH
chmod +x "$CERTBOT_BIN"
certbot_cmd certonly --cert-name example >/dev/null
[[ ! -e $CERTBOT_SHARED_LOCK ]] || fail 'xrayctl left the shared Certbot lock behind'

mkdir "$CERTBOT_SHARED_LOCK"
printf '%s\n' "$$" >"$CERTBOT_SHARED_LOCK/pid"
printf 'sbctl\n' >"$CERTBOT_SHARED_LOCK/tool"
if certbot_cmd certonly --cert-name busy >/dev/null 2>&1; then fail 'xrayctl ignored a live sbctl Certbot lock'; fi
rm -f "$CERTBOT_SHARED_LOCK/pid" "$CERTBOT_SHARED_LOCK/tool"
rmdir "$CERTBOT_SHARED_LOCK"

mkdir "$CERTBOT_SHARED_LOCK"
printf '99999999\n' >"$CERTBOT_SHARED_LOCK/pid"
printf 'sbctl\n' >"$CERTBOT_SHARED_LOCK/tool"
certbot_cmd certonly --cert-name stale >/dev/null
[[ ! -e $CERTBOT_SHARED_LOCK ]] || fail 'xrayctl did not clean a stale shared Certbot lock'

if CERTBOT_STUB_FAIL=1 certbot_cmd certonly --cert-name failed >/dev/null 2>&1; then fail 'Certbot failure was not propagated'; fi
[[ ! -e $CERTBOT_SHARED_LOCK ]] || fail 'xrayctl did not release the lock after Certbot failure'

printf 'ok - xrayctl protects sbctl ports, HY2 ranges, BBR, and Certbot operations\n'
