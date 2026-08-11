#!/usr/bin/env bash

set -Eeuo pipefail

readonly TEST_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
readonly REPO_ROOT=$(cd "${TEST_DIR}/../.." && pwd)

# shellcheck source=../helpers/assert.sh
source "${REPO_ROOT}/tests/helpers/assert.sh"

definition_stream() {
  awk '
    /^[A-Za-z_][A-Za-z0-9_]*[[:space:]]*\(\)[[:space:]]*\{/ {
      name=$0
      sub(/[[:space:]]*\(.*/, "", name)
      print name "\t" FILENAME ":" FNR
    }
  ' "$@"
}

if [[ -d ${REPO_ROOT}/src ]]; then
  production_files=()
  while IFS= read -r file; do
    production_files+=("$file")
  done < <(find "${REPO_ROOT}/src" -maxdepth 1 -type f -name '*.sh' | sort)
  ((${#production_files[@]} > 0)) || fail "src exists but contains no modules"
  expected_modules=$'certificate.sh\ncore.sh\ninbound.sh\nmenu.sh\noutbound.sh\nplatform.sh\nprotocols.sh\nsecurity.sh\nservice.sh\nshare.sh\nstate.sh\nuninstall.sh'
  actual_modules=$(printf '%s\n' "${production_files[@]##*/}")
  assert_eq "$expected_modules" "$actual_modules" "production domain module set changed"
  duplicates=$(definition_stream "${production_files[@]}" | sort | awk -F '\t' '
    seen[$1] { print $1 "\n  " first[$1] "\n  " $2 }
    !seen[$1] { first[$1]=$2 }
    { seen[$1]=1 }
  ')
  [[ -z $duplicates ]] || fail "duplicate production functions found:\n${duplicates}"

  if rg -n '^[[:space:]]*(source|\.)[[:space:]]+' "${REPO_ROOT}/src"; then
    fail "src modules must not source one another"
  fi
  if rg -n '(apply_candidate|state_commit_inbound_[a-z_]+)[[:space:]]+"\$tmp"' \
      "${REPO_ROOT}/src/inbound.sh" "${REPO_ROOT}/src/outbound.sh" "${REPO_ROOT}/src/certificate.sh"; then
    fail "business modules must preserve candidate failures through temporary-file cleanup"
  fi
  if find "${REPO_ROOT}/src" -maxdepth 1 -type f \
      \( -name '*_guard.sh' -o -name '*_fix.sh' -o -name '*_compat.sh' -o -name '*_legacy.sh' \) \
      | grep -q .; then
    fail "patch-chain module names are forbidden"
  fi
else
  for script in "${REPO_ROOT}/xrayctl.sh" "${REPO_ROOT}/alpine/xrayctl.sh"; do
    duplicates=$(definition_stream "$script" | cut -f1 | sort | uniq -d)
    [[ -z $duplicates ]] || fail "duplicate functions in ${script}: ${duplicates}"
  done
fi

for protocol in vless vmess trojan socks http; do
  rg -q "^protocol_build_${protocol}\\(\\)" "${REPO_ROOT}/src/protocols.sh" \
    || fail "missing protocol builder: ${protocol}"
done

rg -q 'dist/xrayctl' "${REPO_ROOT}/install.sh" || fail "root installer does not install dist/xrayctl"
rg -q 'dist/xrayctl' "${REPO_ROOT}/alpine/install.sh" || fail "Alpine installer does not install dist/xrayctl"
[[ ! -e ${REPO_ROOT}/alpine/xrayctl.sh ]] || fail "parallel Alpine business script still exists"

pass "production functions are unique and modules do not self-source"
