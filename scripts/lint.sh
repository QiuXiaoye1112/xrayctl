#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
readonly SCRIPT_DIR
REPO_ROOT=$(cd "${SCRIPT_DIR}/.." && pwd)
readonly REPO_ROOT

bash_files=()
while IFS= read -r file; do
  bash_files+=("$file")
done < <(
  find "$REPO_ROOT" \
    -path "$REPO_ROOT/.git" -prune -o \
    -type f -name '*.sh' -print | sort
)

for file in "${bash_files[@]}"; do
  bash -n "$file"
done

if [[ -f ${REPO_ROOT}/dist/xrayctl ]]; then
  bash -n "${REPO_ROOT}/dist/xrayctl"
fi

if command -v shellcheck >/dev/null 2>&1; then
  shellcheck -x \
    "${REPO_ROOT}/dist/xrayctl" \
    "${REPO_ROOT}/xrayctl.sh" \
    "${REPO_ROOT}/install.sh" \
    "${REPO_ROOT}/alpine/install.sh" \
    "${REPO_ROOT}/scripts/build.sh" \
    "${REPO_ROOT}/scripts/lint.sh"
  test_files=()
  while IFS= read -r file; do test_files+=("$file"); done < <(find "${REPO_ROOT}/tests" -type f -name '*.sh' | sort)
  shellcheck -x -e SC1091,SC2034,SC2155,SC2329 "${test_files[@]}"
elif [[ ${REQUIRE_SHELLCHECK:-0} == 1 ]]; then
  printf 'shellcheck is required but not installed\n' >&2
  exit 1
else
  printf 'warning: shellcheck is not installed; syntax checks completed\n' >&2
fi

printf 'syntax/lint checks passed (%d shell files)\n' "${#bash_files[@]}"
