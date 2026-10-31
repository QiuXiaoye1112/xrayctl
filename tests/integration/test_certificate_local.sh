#!/usr/bin/env bash
set -Eeuo pipefail
REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/xrayctl-cert-local.XXXXXX")
cleanup() { rm -rf "$TEST_ROOT"; }
trap cleanup EXIT
export XRAYCTL_TESTING=1 XRAYCTL_TMP_DIR="$TEST_ROOT/tmp"
export XRAYCTL_CONFIG_DIR="$TEST_ROOT/config" XRAYCTL_CERT_DIR="$TEST_ROOT/certs"
export XRAYCTL_CONFIG_FILE="$TEST_ROOT/config/config.json" XRAYCTL_META_FILE="$TEST_ROOT/config/meta.json"
export XRAYCTL_LOG_DIR="$TEST_ROOT/logs" XRAYCTL_LOCK_FILE="$TEST_ROOT/lock"
export XRAYCTL_RUNTIME_OWNER XRAYCTL_RUNTIME_GROUP
XRAYCTL_RUNTIME_OWNER=$(id -un); XRAYCTL_RUNTIME_GROUP=$(id -gn)
export XRAYCTL_TRAFFIC_FILE="$TEST_ROOT/traffic.json"
export XRAYCTL_CERTBOT_VENV="$TEST_ROOT/certbot"
export XRAYCTL_CERTBOT_CONFIG_DIR="$TEST_ROOT/letsencrypt"
source "$REPO_ROOT/tests/helpers/assert.sh"
source "$REPO_ROOT/xrayctl.sh"
trap - ERR
trap cleanup EXIT
ensure_runtime_dependencies() { :; }
setup_certificate_access() { mkdir -p "$CERT_DIR"; }
service_is_active() { return 1; }
for name in first second; do
  openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj /CN=cert.test \
    -addext 'subjectAltName=DNS:cert.test,DNS:*.cert.test,IP:127.0.0.1' \
    -keyout "$TEST_ROOT/$name.key" -out "$TEST_ROOT/$name.crt" >/dev/null 2>&1
done
init_meta
assert_success validate_certificate_pair_files "$TEST_ROOT/first.crt" "$TEST_ROOT/first.key"
assert_failure validate_certificate_pair_files "$TEST_ROOT/first.crt" "$TEST_ROOT/second.key"
names=$(certificate_server_names "$TEST_ROOT/first.crt")
[[ $names == *cert.test* && $names == *127.0.0.1* && $names != *'*.cert.test'* ]] || fail 'certificate SAN selection lost concrete names'
openssl pkey -in "$TEST_ROOT/first.key" -aes256 -passout pass:sample -out "$TEST_ROOT/encrypted.key" >/dev/null 2>&1
assert_failure validate_certificate_pair_files "$TEST_ROOT/first.crt" "$TEST_ROOT/encrypted.key"
import_certificate cert.test "$TEST_ROOT/first.crt" "$TEST_ROOT/first.key" >/dev/null
cmp -s "$CERT_DIR/cert.test.crt" "$TEST_ROOT/first.crt" || fail 'certificate import lost its contents'
assert_eq 640 "$(stat -c %a "$CERT_DIR/cert.test.key")" 'imported key has wrong permissions'
assert_eq imported "$(jq -r '.certificates["cert.test"].source' "$META_FILE")" 'import metadata was not persisted'

# Even under `if`, a permission/setup failure must stop before replacing files.
setup_certificate_access() { return 1; }
if replace_certificate_pair "$TEST_ROOT/second.crt" "$TEST_ROOT/second.key" "$CERT_DIR/cert.test.crt" "$CERT_DIR/cert.test.key"; then
  fail 'certificate replacement ignored permission setup failure'
fi
cmp -s "$CERT_DIR/cert.test.crt" "$TEST_ROOT/first.crt" || fail 'failed permission setup changed the certificate'
setup_certificate_access() { mkdir -p "$CERT_DIR"; }
service_is_active() { return 0; }
restart_service() { return 1; }
if import_certificate cert.test "$TEST_ROOT/second.crt" "$TEST_ROOT/second.key"; then fail 'failed restart reported successful import'; fi
cmp -s "$CERT_DIR/cert.test.crt" "$TEST_ROOT/first.crt" || fail 'failed restart did not roll back the certificate'
cmp -s "$CERT_DIR/cert.test.key" "$TEST_ROOT/first.key" || fail 'failed restart did not roll back the private key'
service_is_active() { return 1; }
mkdir -p "$CONFIG_DIR"
jq -n --arg cert "$CERT_DIR/cert.test.crt" --arg key "$CERT_DIR/cert.test.key" \
  '{inbounds:[{tag:"tls-node",streamSettings:{security:"tls",tlsSettings:{certificates:[{certificateFile:$cert,keyFile:$key}]}}}]}' >"$CONFIG_FILE"
delete_managed_certificate cert.test 1 >/dev/null
[[ -f $CERT_DIR/cert.test.crt && -f $CERT_DIR/cert.test.key ]] || fail 'deletion removed a referenced certificate'
printf '{"inbounds":[]}' >"$CONFIG_FILE"
delete_managed_certificate cert.test 1 >/dev/null
[[ ! -e $CERT_DIR/cert.test.crt && ! -e $CERT_DIR/cert.test.key ]] || fail 'unreferenced certificate was not removed'
pass 'real OpenSSL import, key matching, encrypted-key refusal, rollback, SAN selection, and reference protection'
