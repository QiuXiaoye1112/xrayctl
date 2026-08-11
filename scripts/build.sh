#!/usr/bin/env bash

set -Eeuo pipefail

readonly SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
readonly REPO_ROOT=$(cd "${SCRIPT_DIR}/.." && pwd)
readonly OUTPUT="${REPO_ROOT}/dist/xrayctl"

modules=(
  core.sh
  platform.sh
  state.sh
  security.sh
  certificate.sh
  protocols.sh
  inbound.sh
  share.sh
  outbound.sh
  service.sh
  uninstall.sh
  menu.sh
)

source_commit=${XRAYCTL_BUILD_COMMIT:-$(git -C "$REPO_ROOT" rev-parse --short=12 HEAD 2>/dev/null || printf unknown)}
build_tmp=$(mktemp "${TMPDIR:-/tmp}/xrayctl-build.XXXXXX")
cleanup_build() { rm -f "$build_tmp"; }
trap cleanup_build EXIT

mkdir -p "$(dirname "$OUTPUT")"
for module in "${modules[@]}"; do
  [[ -f ${REPO_ROOT}/src/${module} ]] || { printf 'missing module: %s\n' "$module" >&2; exit 1; }
done

awk -v commit="$source_commit" '
  /^readonly XRAYCTL_BUILD_COMMIT=/ {
    printf "readonly XRAYCTL_BUILD_COMMIT=\"%s\"\n", commit
    next
  }
  { print }
' "${REPO_ROOT}/src/core.sh" >"$build_tmp"

for module in "${modules[@]:1}"; do
  printf '\n# --- src/%s ---\n' "$module" >>"$build_tmp"
  sed '/^#!\/usr\/bin\/env bash$/d' "${REPO_ROOT}/src/${module}" >>"$build_tmp"
done

cat >>"$build_tmp" <<'EOF'

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
  dispatch "$@"
fi
EOF

bash -n "$build_tmp"
install -m 755 "$build_tmp" "$OUTPUT"
bash -n "$OUTPUT"
printf 'built %s from source commit %s\n' "$OUTPUT" "$source_commit"
