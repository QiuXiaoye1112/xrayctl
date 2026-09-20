#!/usr/bin/env bash

set -Eeuo pipefail

readonly TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/xrayctl-cert-transaction.XXXXXX")
cleanup() { rm -rf "$TEST_ROOT"; }
trap cleanup EXIT

export XRAYCTL_TESTING=1
export XRAYCTL_CONFIG_DIR="$TEST_ROOT/config"
export XRAYCTL_META_FILE="$TEST_ROOT/meta.json"
export XRAYCTL_CERT_DIR="$TEST_ROOT/certs"
export XRAYCTL_TMP_DIR="$TEST_ROOT/tmp"
export XRAYCTL_RUNTIME_OWNER
XRAYCTL_RUNTIME_OWNER=$(id -un)
export XRAYCTL_RUNTIME_GROUP
XRAYCTL_RUNTIME_GROUP=$(id -gn)

mkdir -p "$XRAYCTL_CONFIG_DIR" "$XRAYCTL_CERT_DIR" "$XRAYCTL_TMP_DIR"
printf '%s\n' '{"schema":4,"inbounds":{},"certificates":{"example.com":{"source":"old"}},"managedResources":{},"migrations":{}}' >"$XRAYCTL_META_FILE"
printf 'old certificate\n' >"$XRAYCTL_CERT_DIR/example.com.crt"
printf 'old key\n' >"$XRAYCTL_CERT_DIR/example.com.key"

readonly REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
grep -Fq 'apk) install_packages python3 py3-pip py3-virtualenv' "$REPO_ROOT/src/certificate.sh"

source "$REPO_ROOT/xrayctl.sh"
trap - ERR

ensure_runtime_dependencies() { :; }
validate_certificate_pair_files() { :; }
replace_certificate_pair() {
  printf 'new certificate\n' >"$3"
  printf 'new key\n' >"$4"
  printf -v "$5" '%s' 1
}
meta_cert_set() { return 1; }
if import_certificate example.com ignored.crt ignored.key; then
  printf 'metadata failure unexpectedly succeeded\n' >&2
  exit 1
fi
[[ $(<"$XRAYCTL_CERT_DIR/example.com.crt") == 'old certificate' ]]
[[ $(<"$XRAYCTL_CERT_DIR/example.com.key") == 'old key' ]]
[[ $(jq -r '.certificates["example.com"].source' "$XRAYCTL_META_FILE") == old ]]

snapshot=''
certificate_transaction_snapshot snapshot "$XRAYCTL_CERT_DIR/example.com.crt" "$XRAYCTL_CERT_DIR/example.com.key"
printf 'new key\n' >"$XRAYCTL_CERT_DIR/example.com.key"
certificate_transaction_rollback "$snapshot" "$XRAYCTL_CERT_DIR/example.com.crt" "$XRAYCTL_CERT_DIR/example.com.key"
[[ $(<"$XRAYCTL_CERT_DIR/example.com.crt") == 'old certificate' ]]
[[ $(<"$XRAYCTL_CERT_DIR/example.com.key") == 'old key' ]]
[[ $(jq -r '.certificates["example.com"].source' "$XRAYCTL_META_FILE") == old ]]

rm -f "$XRAYCTL_CERT_DIR/example.com.crt" "$XRAYCTL_CERT_DIR/example.com.key" "$XRAYCTL_META_FILE"
certificate_transaction_snapshot snapshot "$XRAYCTL_CERT_DIR/example.com.crt" "$XRAYCTL_CERT_DIR/example.com.key"
certificate_transaction_rollback "$snapshot" "$XRAYCTL_CERT_DIR/example.com.crt" "$XRAYCTL_CERT_DIR/example.com.key"
[[ ! -e $XRAYCTL_CERT_DIR/example.com.crt ]]
[[ ! -e $XRAYCTL_CERT_DIR/example.com.key ]]
[[ ! -e $XRAYCTL_META_FILE ]]

printf 'ok - certificate transactions restore certificate pairs and metadata\n'
