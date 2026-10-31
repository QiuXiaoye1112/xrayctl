#!/usr/bin/env bash
set -Eeuo pipefail
if [[ -z ${XRAYCTL_PEBBLE_BIN:-} || -z ${XRAYCTL_CERTBOT_TEST_BIN:-} ]]; then
  printf 'ok - local ACME test skipped (set XRAYCTL_PEBBLE_BIN and XRAYCTL_CERTBOT_TEST_BIN)\n'; exit 0
fi
REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
TEST_ROOT=$(mktemp -d /tmp/xrayctl-acme-local.XXXXXX)
pebble_pid="" core_pid=""
cleanup() {
  for pid in "$core_pid" "$pebble_pid"; do
    [[ -z $pid ]] || { kill "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true; }
  done
  rm -rf "$TEST_ROOT"
}
trap cleanup EXIT
export XRAYCTL_TESTING=1 XRAYCTL_TMP_DIR="$TEST_ROOT/tmp"
export XRAYCTL_CONFIG_DIR="$TEST_ROOT/config" XRAYCTL_META_FILE="$TEST_ROOT/config/meta.json"
export XRAYCTL_CERT_DIR="$TEST_ROOT/certs" XRAYCTL_LOG_DIR="$TEST_ROOT/logs"
export XRAYCTL_TRAFFIC_FILE="$TEST_ROOT/traffic.json" XRAYCTL_LOCK_FILE="$TEST_ROOT/lock"
export XRAYCTL_CERTBOT_VENV="$TEST_ROOT/certbot-venv" XRAYCTL_BACKUP_DIR="$TEST_ROOT/backups"
export XRAYCTL_CERTBOT_CONFIG_DIR="$TEST_ROOT/letsencrypt"
export XRAYCTL_CERTBOT_WORK_DIR="$TEST_ROOT/work" XRAYCTL_CERTBOT_LOGS_DIR="$TEST_ROOT/acme-logs"
export XRAYCTL_CERTBOT_SHARED_LOCK="$TEST_ROOT/certbot.lock"
export XRAYCTL_RUNTIME_OWNER XRAYCTL_RUNTIME_USER XRAYCTL_RUNTIME_GROUP
XRAYCTL_RUNTIME_OWNER=$(id -un); XRAYCTL_RUNTIME_USER=$(id -un); XRAYCTL_RUNTIME_GROUP=$(id -gn)
export XRAYCTL_XRAY_BIN="${XRAYCTL_REAL_XRAY_BIN:-/usr/local/bin/xray}"
source "$REPO_ROOT/tests/helpers/assert.sh"
source "$REPO_ROOT/xrayctl.sh"
trap - ERR
trap cleanup EXIT
# Disable Certbot's unattended renewal sleep in this synchronous local test.
CERTBOT_BIN="$TEST_ROOT/certbot"
cat >"$CERTBOT_BIN" <<'SH'
#!/bin/sh
exec "$XRAYCTL_CERTBOT_TEST_BIN" --no-random-sleep-on-renew "$@"
SH
chmod 755 "$CERTBOT_BIN"
# Real files/permissions; no native init service or host unit is touched.
platform_init_system() { printf openrc; }
service_is_active() { [[ -n $core_pid ]] && kill -0 "$core_pid" 2>/dev/null; }
restart_service() {
  if [[ -n $core_pid ]]; then kill "$core_pid"; wait "$core_pid" 2>/dev/null || true; fi
  "$XRAY_BIN" run -config "$CONFIG_FILE" >"$TEST_ROOT/xray.log" 2>&1 &
  core_pid=$!
  for _ in {1..50}; do
    if openssl s_client -connect "127.0.0.1:$tls_port" </dev/null >"$TEST_ROOT/handshake" 2>/dev/null; then return 0; fi
    sleep .1
  done
  cat "$TEST_ROOT/xray.log" >&2; return 1
}
mkdir -p "$CONFIG_DIR" "$CERT_DIR" "$CERTBOT_CONFIG_DIR"
init_meta
IFS=' ' read -r acme_port http_port tls_port < <(python3 - <<'PY'
import socket
sockets=[socket.socket() for _ in range(3)]
for sock in sockets: sock.bind(('127.0.0.1',0))
print(*(sock.getsockname()[1] for sock in sockets))
PY
)
openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj /CN=localhost \
  -addext 'subjectAltName=DNS:localhost,IP:127.0.0.1' \
  -keyout "$TEST_ROOT/ca.key" -out "$TEST_ROOT/ca.crt" >/dev/null 2>&1
jq -n --arg cert "$TEST_ROOT/ca.crt" --arg key "$TEST_ROOT/ca.key" --arg addr "127.0.0.1:$acme_port" --argjson http "$http_port" \
  '{pebble:{listenAddress:$addr,certificate:$cert,privateKey:$key,httpPort:$http,tlsPort:5001,ocspResponderURL:"",externalAccountBindingRequired:false,profiles:{default:{validityPeriod:3600},shortlived:{validityPeriod:3600}}}}' >"$TEST_ROOT/pebble.json"
PEBBLE_VA_NOSLEEP=1 PEBBLE_WFE_NONCEREJECT=0 PEBBLE_AUTHZREUSE=0 \
  "$XRAYCTL_PEBBLE_BIN" -config "$TEST_ROOT/pebble.json" >"$TEST_ROOT/pebble.log" 2>&1 &
pebble_pid=$!
for _ in {1..50}; do
  if curl --silent --fail --cacert "$TEST_ROOT/ca.crt" "https://localhost:$acme_port/dir" >"$TEST_ROOT/directory.json"; then break; fi
  sleep .1
done
jq -e '.newAccount and .newOrder' "$TEST_ROOT/directory.json" >/dev/null || { cat "$TEST_ROOT/pebble.log" >&2; exit 1; }
export REQUESTS_CA_BUNDLE="$TEST_ROOT/ca.crt"
# IP SAN avoids DNS dependencies; HTTP-01 is actually checked by Pebble.
certbot_issue_cmd local-ip certonly --standalone --non-interactive --agree-tos \
  --server "https://localhost:$acme_port/dir" --http-01-port "$http_port" \
  --cert-name local-ip -m local@example.test --ip-address 127.0.0.1 --preferred-profile shortlived
sync_managed_certificate local-ip local-ip
register_certificate_metadata local-ip 127.0.0.1 local-ip letsencrypt http-standalone true
jq -n --argjson port "$tls_port" --arg cert "$CERT_DIR/local-ip.crt" --arg key "$CERT_DIR/local-ip.key" \
  '{log:{loglevel:"warning"},inbounds:[{tag:"tls",listen:"127.0.0.1",port:$port,protocol:"http",settings:{},streamSettings:{network:"raw",security:"tls",tlsSettings:{certificates:[{certificateFile:$cert,keyFile:$key}]}}}],outbounds:[{protocol:"freedom",tag:"direct"}]}' >"$CONFIG_FILE"
validate_candidate "$CONFIG_FILE"
restart_service
before=$(openssl x509 -in "$CERT_DIR/local-ip.crt" -noout -serial)
# A fresh certificate must first be recognized as unchanged.
result=""
renew_one_certificate local-ip result
assert_eq unchanged "$result" 'fresh certificate was unexpectedly renewed'
# Set the real lineage renewal window to include this one-hour certificate.
# Certbot otherwise waits until the last fraction of its lifetime, even for
# short-lived certificates.
renewal="$CERTBOT_CONFIG_DIR/renewal/local-ip.conf"
{ printf 'renew_before_expiry = 2 hours\n'; cat "$renewal"; } >"$TEST_ROOT/renewal.conf"
mv "$TEST_ROOT/renewal.conf" "$renewal"
renew_one_certificate local-ip result
assert_eq renewed "$result" 'local ACME renewal did not issue a new certificate'
after=$(openssl x509 -in "$CERT_DIR/local-ip.crt" -noout -serial)
[[ $before != "$after" ]] || fail 'renewal did not change the certificate serial'
served=$(openssl s_client -connect "127.0.0.1:$tls_port" </dev/null 2>/dev/null | openssl x509 -noout -serial)
assert_eq "$after" "$served" 'real Xray did not load the renewed certificate'
[[ ! -e $CERTBOT_SHARED_LOCK ]] || fail 'ACME operation leaked the shared lock'
pass 'real local HTTP-01 ACME IP issuance, renewal, managed sync, and real Xray certificate reload'
