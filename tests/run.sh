#!/usr/bin/env bash

set -Eeuo pipefail

readonly TEST_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
readonly REPO_ROOT=$(cd "${TEST_DIR}/.." && pwd)
readonly RUNTIME_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/xrayctl-suite.XXXXXX")
cleanup_suite() { rm -rf "$RUNTIME_ROOT"; }
trap cleanup_suite EXIT

tests=(
  "tests/architecture/test_architecture.sh"
  "tests/unit/test_validators.sh"
  "tests/unit/test_notices.sh"
  "tests/unit/test_platform.sh"
  "tests/unit/test_protocol_builders.sh"
  "tests/unit/test_interactive_builders.sh"
  "tests/unit/test_input_cancellation.sh"
  "tests/unit/test_traffic.sh"
  "tests/unit/test_user_identity.sh"
  "tests/unit/test_account_user_traffic.sh"
  "tests/integration/test_state.sh"
  "tests/integration/test_data_safety.sh"
  "tests/integration/test_restore_transaction.sh"
  "tests/integration/test_maintenance_safety.sh"
  "tests/integration/test_service_failures.sh"
  "tests/integration/test_bbr_real.sh"
  "tests/integration/test_user_identity_transaction.sh"
  "tests/integration/test_certificate_transaction.sh"
  "tests/integration/test_certificate_local.sh"
  "tests/integration/test_certificate_acme_local.sh"
  "tests/integration/test_lifecycle.sh"
  "tests/integration/test_outbound_routing.sh"
  "tests/integration/test_user_outbound_routing.sh"
  "tests/integration/test_user_outbound_real_xray.sh"
  "tests/integration/test_domain_templates.sh"
  "tests/integration/test_user_templates.sh"
  "tests/integration/test_coexistence.sh"
  "tests/integration/test_share.sh"
  "tests/integration/test_interactive_menus.sh"
  "tests/integration/test_menu_navigation.sh"
  "tests/integration/test_regressions.sh"
  "tests/integration/test_runtime_access.sh"
  "tests/integration/test_real_xray.sh"
  "tests/integration/test_transport_matrix_real_xray.sh"
  "tests/integration/test_real_xray_user_traffic.sh"
  "tests/integration/test_user_quota_real_xray.sh"
  "tests/integration/test_account_user_quota_real_xray.sh"
  "tests/integration/test_systemd_user_quota.sh"
  "tests/integration/test_systemd_lifecycle_real.sh"
  "tests/integration/test_openrc_user_quota.sh"
  "tests/smoke/test_cli.sh"
  "tests/smoke/test_build.sh"
  "tests/smoke/test_installer.sh"
  "tests/smoke/test_docs.sh"
)

for test_file in "${tests[@]}"; do
  printf '\n==> %s\n' "$test_file"
  # Defaults must never refer to installed user data when run as root. Tests
  # may still choose their own explicit paths or real dedicated services.
  case_root="$RUNTIME_ROOT/${test_file//\//_}"
  mkdir -p "$case_root"
  XRAYCTL_CONFIG_DIR="$case_root/config" \
  XRAYCTL_LOG_DIR="$case_root/logs" \
  XRAYCTL_BACKUP_DIR="$case_root/backups" \
  XRAYCTL_TRAFFIC_FILE="$case_root/traffic.json" \
  XRAYCTL_LOCK_FILE="$case_root/lock" \
  XRAYCTL_CERTBOT_VENV="$case_root/certbot" \
  XRAYCTL_CERTBOT_CONFIG_DIR="$case_root/letsencrypt" \
  bash "${REPO_ROOT}/${test_file}"
done

printf '\n==> scripts/lint.sh\n'
bash "${REPO_ROOT}/scripts/lint.sh"

printf '\nall tests passed\n'
