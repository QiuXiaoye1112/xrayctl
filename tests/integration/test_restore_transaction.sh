#!/usr/bin/env bash
set -Eeuo pipefail
REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/xrayctl-restore-transaction.XXXXXX")
cleanup() { rm -rf "$TEST_ROOT"; }
trap cleanup EXIT
export XRAYCTL_TESTING=1 XRAYCTL_TMP_DIR="$TEST_ROOT/tmp"
export XRAYCTL_CONFIG_DIR="$TEST_ROOT/config" XRAYCTL_CERT_DIR="$TEST_ROOT/config/certs"
export XRAYCTL_CONFIG_FILE="$TEST_ROOT/config/config.json" XRAYCTL_META_FILE="$TEST_ROOT/config/meta.json"
export XRAYCTL_TRAFFIC_FILE="$TEST_ROOT/traffic.json" XRAYCTL_LOCK_FILE="$TEST_ROOT/lock"
export XRAYCTL_LOG_DIR="$TEST_ROOT/logs" XRAYCTL_BACKUP_DIR="$TEST_ROOT/backups"
export XRAYCTL_CERTBOT_VENV="$TEST_ROOT/certbot" XRAYCTL_CERTBOT_CONFIG_DIR="$TEST_ROOT/letsencrypt"
export XRAYCTL_XRAY_BIN="${XRAYCTL_REAL_XRAY_BIN:-$TEST_ROOT/missing-xray}"
export XRAYCTL_RUNTIME_OWNER XRAYCTL_RUNTIME_GROUP
XRAYCTL_RUNTIME_OWNER=$(id -un); XRAYCTL_RUNTIME_GROUP=$(id -gn)
source "$REPO_ROOT/tests/helpers/assert.sh"
source "$REPO_ROOT/xrayctl.sh"
trap - ERR
trap cleanup EXIT
ensure_runtime_dependencies() { :; }
setup_runtime_access() { :; }
traffic_is_enabled() { return 1; }
traffic_runtime_ensure() { :; }
restart_service() { :; }
confirm() { return 0; }
mkdir -p "$CERT_DIR"
openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj /CN=restore.test \
  -keyout "$CERT_DIR/restore.key" -out "$CERT_DIR/restore.crt" >/dev/null 2>&1
jq -n --arg cert "$CERT_DIR/restore.crt" --arg key "$CERT_DIR/restore.key" '{
  log:{loglevel:"warning"},inbounds:[{tag:"tls-node",listen:"127.0.0.1",port:16000,protocol:"vless",
    settings:{decryption:"none",clients:[{id:"11111111-1111-4111-8111-111111111111",email:"alice"}]},
    streamSettings:{network:"raw",security:"tls",tlsSettings:{certificates:[{certificateFile:$cert,keyFile:$key}]}}}],
  outbounds:[{tag:"direct",protocol:"freedom"}],routing:{rules:[]}
}' >"$CONFIG_FILE"
init_meta
archive="$TEST_ROOT/backup.tar.gz"
backup_all "$archive" >/dev/null
cp "$CERT_DIR/restore.crt" "$TEST_ROOT/original.crt"
cp "$CERT_DIR/restore.key" "$TEST_ROOT/original.key"
rm -rf "$CERT_DIR"
restore_backup "$archive" >/dev/null
cmp -s "$CERT_DIR/restore.crt" "$TEST_ROOT/original.crt" || fail 'disaster recovery lost certificate contents'
cmp -s "$CERT_DIR/restore.key" "$TEST_ROOT/original.key" || fail 'disaster recovery lost private key contents'
validate_restore_config "$CONFIG_FILE"

jq '.log.loglevel="debug"' "$CONFIG_FILE" >"$TEST_ROOT/changed.json"
mv "$TEST_ROOT/changed.json" "$CONFIG_FILE"
cp "$CONFIG_FILE" "$TEST_ROOT/before-config"
cp "$META_FILE" "$TEST_ROOT/before-meta"
(
  cp() {
    local src=${*: -2:1} dest=${*: -1}
    if [[ $dest == "$CONFIG_FILE" && $src == *'/xrayctl-restore.'* && $src != *'/.current.'* ]]; then
      printf '{partial' >"$dest"
      return 1
    fi
    command cp "$@"
  }
  if (restore_backup "$archive") >"$TEST_ROOT/partial-write.log" 2>&1; then fail 'partial restore installation reported success'; fi
)
cmp -s "$CONFIG_FILE" "$TEST_ROOT/before-config" || fail 'restore did not roll back a partial file copy'
cmp -s "$META_FILE" "$TEST_ROOT/before-meta" || fail 'restore rollback lost metadata'
cmp -s "$CERT_DIR/restore.key" "$TEST_ROOT/original.key" || fail 'restore rollback lost the key'
(
  cp() {
    [[ ${*: -1} != *'/.current.'*'/config.json' ]] || return 1
    command cp "$@"
  }
  if (restore_backup "$archive") >"$TEST_ROOT/snapshot-failure.log" 2>&1; then fail 'restore ignored snapshot failure'; fi
)
cmp -s "$CONFIG_FILE" "$TEST_ROOT/before-config" || fail 'snapshot failure changed current configuration'
pass 'TLS disaster recovery validates archived certificates and rolls back partial writes and snapshot failures'
