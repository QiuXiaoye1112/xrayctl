#!/usr/bin/env bash

set -Eeuo pipefail

readonly TEST_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
readonly REPO_ROOT=$(cd "${TEST_DIR}/.." && pwd)

tests=(
  "tests/architecture/test_architecture.sh"
  "tests/unit/test_validators.sh"
  "tests/unit/test_platform.sh"
  "tests/unit/test_protocol_builders.sh"
  "tests/integration/test_state.sh"
  "tests/integration/test_lifecycle.sh"
  "tests/smoke/test_cli.sh"
  "tests/smoke/test_build.sh"
)

for test_file in "${tests[@]}"; do
  printf '\n==> %s\n' "$test_file"
  bash "${REPO_ROOT}/${test_file}"
done

printf '\n==> scripts/lint.sh\n'
bash "${REPO_ROOT}/scripts/lint.sh"

printf '\nall tests passed\n'
