#!/usr/bin/env bash

set -Eeuo pipefail

readonly TEST_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
readonly REPO_ROOT=$(cd "${TEST_DIR}/../.." && pwd)
readonly TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/xrayctl-installer.XXXXXX")

cleanup_test_root() {
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
PATH="$TEST_ROOT/bin:$PATH" bash "$REPO_ROOT/install.sh" 26.3.27 >/dev/null
assert_eq 'install 26.3.27' "$(<"$XRAYCTL_TEST_INVOCATION")" 'bootstrap did not invoke the installed distribution'
grep -q '^# xrayctl - Xray Linux terminal manager' "$XRAYCTL_COMMAND_PATH" \
  || fail 'bootstrap did not install the verified distribution'

before=$(openssl dgst -sha256 "$XRAYCTL_COMMAND_PATH" | awk '{print $NF}')
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
grep -Fq "[ ! -L \"\$TARGET\" ]" "$REPO_ROOT/alpine/install.sh" \
  || fail 'Alpine bootstrap does not reject a symlink target'

pass 'bootstrap validates downloads and refuses unsafe target replacement'
