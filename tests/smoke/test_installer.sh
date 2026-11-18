#!/usr/bin/env bash

set -Eeuo pipefail

readonly TEST_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
readonly REPO_ROOT=$(cd "${TEST_DIR}/../.." && pwd)
readonly TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/xrayctl-installer.XXXXXX")

cleanup_test_root() {
  if [[ -n ${fake_core_pid:-} ]]; then kill "$fake_core_pid" 2>/dev/null || true; wait "$fake_core_pid" 2>/dev/null || true; fi
  [[ -n ${TEST_ROOT:-} && $TEST_ROOT == "${TMPDIR:-/tmp}"/xrayctl-installer.* ]] || return 1
  rm -rf "$TEST_ROOT"
}
trap cleanup_test_root EXIT

# shellcheck source=../helpers/assert.sh
source "${REPO_ROOT}/tests/helpers/assert.sh"

mkdir -p "$TEST_ROOT/bin" "$TEST_ROOT/payloads"
cat >"$TEST_ROOT/bin/uname" <<'SH'
#!/usr/bin/env sh
printf 'Linux\n'
SH
cat >"$TEST_ROOT/bin/id" <<'SH'
#!/usr/bin/env sh
[ "${1:-}" = -u ] && printf '0\n'
SH
cat >"$TEST_ROOT/bin/curl" <<'SH'
#!/usr/bin/env bash
set -Eeuo pipefail
output=""
for argument in "$@"; do
  case $argument in
    https://api.github.com/*)
      printf '{"ref":"refs/heads/main","object":{"sha":"%s"}}\n' "${XRAYCTL_TEST_REF_SHA:-0123456789abcdef0123456789abcdef01234567}"
      exit 0
      ;;
    https://*) printf '%s\n' "$argument" >"$XRAYCTL_TEST_CURL_URL" ;;
  esac
done
while (($#)); do
  if [[ $1 == -o ]]; then output=$2; shift 2; else shift; fi
done
[[ -n $output ]]
cp "$XRAYCTL_TEST_DOWNLOAD" "$output"
SH
chmod +x "$TEST_ROOT/bin/uname" "$TEST_ROOT/bin/id" "$TEST_ROOT/bin/curl"

cat >"$TEST_ROOT/payloads/good" <<'SH'
#!/usr/bin/env bash
# xrayctl - Xray Linux terminal manager
printf '%s\n' "$*" >"$XRAYCTL_TEST_INVOCATION"
SH
cat >"$TEST_ROOT/payloads/bad" <<'SH'
#!/usr/bin/env bash
printf 'not xrayctl\n'
SH

export XRAYCTL_COMMAND_PATH="$TEST_ROOT/target/xrayctl"
export XRAYCTL_TEST_INVOCATION="$TEST_ROOT/invocation"
export XRAYCTL_TEST_DOWNLOAD="$TEST_ROOT/payloads/good"
export XRAYCTL_TEST_CURL_URL="$TEST_ROOT/curl-url"
PATH="$TEST_ROOT/bin:$PATH" bash "$REPO_ROOT/install.sh" 26.3.27 >/dev/null
assert_eq 'install 26.3.27' "$(<"$XRAYCTL_TEST_INVOCATION")" 'bootstrap did not invoke the installed distribution'
grep -Eq '^https://raw\.githubusercontent\.com/QiuXiaoye1112/xrayctl/0123456789abcdef0123456789abcdef01234567/dist/xrayctl\?xrayctl_cache=[0-9]+$' "$XRAYCTL_TEST_CURL_URL" \
  || fail 'bootstrap did not pin the distribution to the resolved main commit'
grep -q '^# xrayctl - Xray Linux terminal manager' "$XRAYCTL_COMMAND_PATH" \
  || fail 'bootstrap did not install the verified distribution'

# Existing installations update only the manager unless a core version is requested.
export XRAYCTL_XRAY_BIN="$TEST_ROOT/xray-core"
export XRAYCTL_CONFIG_FILE="$TEST_ROOT/config.json"
printf '#!/bin/sh\nexit 0\n' >"$XRAYCTL_XRAY_BIN"
chmod +x "$XRAYCTL_XRAY_BIN"
printf '{}\n' >"$XRAYCTL_CONFIG_FILE"
PATH="$TEST_ROOT/bin:$PATH" bash "$REPO_ROOT/install.sh" >/dev/null
assert_eq 'internal-script-update' "$(<"$XRAYCTL_TEST_INVOCATION")" 'existing install should only update the manager'
PATH="$TEST_ROOT/bin:$PATH" bash "$REPO_ROOT/install.sh" 26.3.27 >/dev/null
assert_eq 'install 26.3.27' "$(<"$XRAYCTL_TEST_INVOCATION")" 'explicit version should install the core'

# Alpine uses the same distinction between manager update and core install.
export XRAYCTL_TEST_REAL_GREP
XRAYCTL_TEST_REAL_GREP=$(command -v grep)
cat >"$TEST_ROOT/bin/grep" <<'SH'
#!/bin/sh
if [ "$#" -eq 3 ] && [ "$1" = -q ] && [ "$2" = '^ID=alpine$' ] && [ "$3" = /etc/os-release ]; then exit 0; fi
exec "$XRAYCTL_TEST_REAL_GREP" "$@"
SH
cat >"$TEST_ROOT/bin/apk" <<'SH'
#!/bin/sh
exit 0
SH
cat >"$TEST_ROOT/bin/update-ca-certificates" <<'SH'
#!/bin/sh
exit 0
SH
chmod +x "$TEST_ROOT/bin/grep" "$TEST_ROOT/bin/apk" "$TEST_ROOT/bin/update-ca-certificates"
if [[ -r /etc/os-release ]]; then
  PATH="$TEST_ROOT/bin:$PATH" sh "$REPO_ROOT/alpine/install.sh" >/dev/null
  assert_eq 'internal-script-update' "$(<"$XRAYCTL_TEST_INVOCATION")" 'Alpine existing install should only update the manager'
  PATH="$TEST_ROOT/bin:$PATH" sh "$REPO_ROOT/alpine/install.sh" 26.3.27 >/dev/null
  assert_eq 'install 26.3.27' "$(<"$XRAYCTL_TEST_INVOCATION")" 'Alpine explicit version should install the core'
fi

# Exercise the real distribution through the update entry point while a core
# process is running; all paths and credentials are confined to the fixture.
printf '#!/bin/sh\nexec sleep 180\n' >"$XRAYCTL_XRAY_BIN"
chmod +x "$XRAYCTL_XRAY_BIN"
"$XRAYCTL_XRAY_BIN" &
fake_core_pid=$!
export XRAYCTL_TEST_DOWNLOAD="$REPO_ROOT/dist/xrayctl" XRAYCTL_TESTING=1 XRAYCTL_PLATFORM=systemd
export XRAYCTL_CONFIG_DIR="$TEST_ROOT/config" XRAYCTL_META_FILE="$TEST_ROOT/meta.json"
export XRAYCTL_TRAFFIC_FILE="$TEST_ROOT/traffic.json" XRAYCTL_LOCK_FILE="$TEST_ROOT/lock"
export XRAYCTL_TMP_DIR="$TEST_ROOT/runtime" XRAYCTL_SYMLINK_PATH="$TEST_ROOT/bin-link/xrayctl"
mkdir -p "$XRAYCTL_CONFIG_DIR"
printf '%s\n' '{"schema":4,"inbounds":{},"certificates":{},"managedResources":{},"migrations":{"legacyCertScanV1":true,"legacyCertbotSymlinkV1":true}}' >"$XRAYCTL_META_FILE"
PATH="$TEST_ROOT/bin:$PATH" bash "$REPO_ROOT/install.sh" >/dev/null
kill -0 "$fake_core_pid" 2>/dev/null || fail 'manager update stopped the running core process'
[[ -L $XRAYCTL_SYMLINK_PATH ]] || fail 'manager update did not refresh the quick-command link'
export XRAYCTL_TEST_DOWNLOAD="$TEST_ROOT/payloads/good"
PATH="$TEST_ROOT/bin:$PATH" bash "$REPO_ROOT/install.sh" >/dev/null

before=$(openssl dgst -sha256 "$XRAYCTL_COMMAND_PATH" | awk '{print $NF}')
export XRAYCTL_TEST_REF_SHA=invalid
assert_failure env PATH="$TEST_ROOT/bin:$PATH" bash "$REPO_ROOT/install.sh"
unset XRAYCTL_TEST_REF_SHA
assert_eq "$before" "$(openssl dgst -sha256 "$XRAYCTL_COMMAND_PATH" | awk '{print $NF}')" 'invalid main ref overwrote xrayctl'
export XRAYCTL_TEST_DOWNLOAD="$TEST_ROOT/payloads/bad"
assert_failure env PATH="$TEST_ROOT/bin:$PATH" bash "$REPO_ROOT/install.sh"
after=$(openssl dgst -sha256 "$XRAYCTL_COMMAND_PATH" | awk '{print $NF}')
assert_eq "$before" "$after" 'invalid download overwrote the installed xrayctl'

foreign="$TEST_ROOT/foreign"
printf '#!/bin/sh\n' >"$foreign"
export XRAYCTL_COMMAND_PATH="$foreign"
export XRAYCTL_TEST_DOWNLOAD="$TEST_ROOT/payloads/good"
assert_failure env PATH="$TEST_ROOT/bin:$PATH" bash "$REPO_ROOT/install.sh"
assert_eq '#!/bin/sh' "$(<"$foreign")" 'bootstrap overwrote a foreign target'

grep -Fq "bash -n \"\${temp_dir}/xrayctl\"" "$REPO_ROOT/alpine/install.sh" \
  || fail 'Alpine bootstrap does not syntax-check its download'
grep -Fq 'xrayctl_cache=' "$REPO_ROOT/alpine/install.sh" \
  || fail 'Alpine bootstrap does not bypass the stale main-branch download cache'
grep -Fq "[ ! -L \"\$TARGET\" ]" "$REPO_ROOT/alpine/install.sh" \
  || fail 'Alpine bootstrap does not reject a symlink target'

pass 'bootstrap validates downloads and refuses unsafe target replacement'
