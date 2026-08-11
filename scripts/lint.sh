#!/usr/bin/env bash

set -Eeuo pipefail

readonly SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
readonly REPO_ROOT=$(cd "${SCRIPT_DIR}/.." && pwd)

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
  shellcheck -x "${bash_files[@]}"
elif [[ ${REQUIRE_SHELLCHECK:-0} == 1 ]]; then
  printf 'shellcheck is required but not installed\n' >&2
  exit 1
else
  printf 'warning: shellcheck is not installed; syntax checks completed\n' >&2
fi

printf 'syntax/lint checks passed (%d shell files)\n' "${#bash_files[@]}"
