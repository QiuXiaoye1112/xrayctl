#!/usr/bin/env bash

set -Eeuo pipefail

readonly TEST_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
readonly REPO_ROOT=$(cd "${TEST_DIR}/../.." && pwd)
readonly TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/xrayctl-coexistence.XXXXXX")
trap 'rm -rf "$TEST_ROOT"' EXIT

export XRAYCTL_CONFIG_DIR="${TEST_ROOT}/xray"
export XRAYCTL_CONFIG_FILE="${XRAYCTL_CONFIG_DIR}/config.json"
export XRAYCTL_META_FILE="${XRAYCTL_CONFIG_DIR}/meta.json"
export XRAYCTL_BBR_CONFIG="${TEST_ROOT}/99-xrayctl-bbr.conf"
export XRAYCTL_SBCTL_BBR_CONFIG="${TEST_ROOT}/99-sbctl-bbr.conf"
export XRAYCTL_CERTBOT_VENV="${TEST_ROOT}/certbot-venv"
export XRAYCTL_CERTBOT_SHARED_LOCK="${TEST_ROOT}/certbot.lock"
export XRAYCTL_CERTBOT_SHARED_LOCK_WAIT=0

mkdir -p "$XRAYCTL_CONFIG_DIR"
cat >"$XRAYCTL_CONFIG_FILE" <<'JSON'
{"inbounds":[{"tag":"existing","port":10000,"protocol":"socks"}],"outbounds":[],"routing":{"rules":[]}}
JSON

# shellcheck source=../helpers/assert.sh
source "${REPO_ROOT}/tests/helpers/assert.sh"
# shellcheck source=../../xrayctl.sh
source "${REPO_ROOT}/xrayctl.sh"
trap - ERR
trap 'rm -rf "$TEST_ROOT"' EXIT

random_file="$TEST_ROOT/random-values"
printf '%s\n' 0000 0001 4e20 >"$random_file"
random_hex() {
  local value
  IFS= read -r value <"$random_file"
  tail -n +2 "$random_file" >"$random_file.next"
  mv "$random_file.next" "$random_file"
  printf '%s' "$value"
}
port_in_use_os() { [[ $1 == 10001 ]]; }
automatic_port=""
suggest_available_port automatic_port
assert_eq 50001 "$automatic_port" "automatic port did not skip own/listening ports"
((automatic_port < 30000 || automatic_port > 50000)) || fail 'automatic port entered the default HY2 hopping range'

prompt_values=(10000 10001 10002)
prompt_index=0
prompt_value() {
  printf -v "$1" '%s' "${prompt_values[$prompt_index]}"
  ((prompt_index+=1)) || true
}
selected=""
prompt_port selected 10000
assert_eq 10002 "$selected" "prompt did not reject own/listening ports"

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

printf 'ok - xrayctl checks active ports and coordinates BBR and Certbot operations\n'
