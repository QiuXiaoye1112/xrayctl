#!/usr/bin/env bash
set -Eeuo pipefail

REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/xrayctl-data-safety.XXXXXX")
cleanup() { rm -rf "$TEST_ROOT"; }
trap cleanup EXIT
export XRAYCTL_TESTING=1 XRAYCTL_TMP_DIR="$TEST_ROOT/tmp"
export XRAYCTL_CONFIG_DIR="$TEST_ROOT/config" XRAYCTL_CERT_DIR="$TEST_ROOT/config/certs"
export XRAYCTL_CONFIG_FILE="$TEST_ROOT/config/config.json" XRAYCTL_META_FILE="$TEST_ROOT/config/meta.json"
export XRAYCTL_LOG_DIR="$TEST_ROOT/logs" XRAYCTL_BACKUP_DIR="$TEST_ROOT/backups"
export XRAYCTL_TRAFFIC_FILE="$TEST_ROOT/traffic.json" XRAYCTL_LOCK_FILE="$TEST_ROOT/lock"
export XRAYCTL_XRAY_BIN="$TEST_ROOT/missing-xray"
export XRAYCTL_RUNTIME_OWNER XRAYCTL_RUNTIME_GROUP
XRAYCTL_RUNTIME_OWNER=$(id -un); XRAYCTL_RUNTIME_GROUP=$(id -gn)
source "$REPO_ROOT/tests/helpers/assert.sh"
source "$REPO_ROOT/xrayctl.sh"
trap - ERR
trap cleanup EXIT
ensure_runtime_dependencies() { :; }
setup_runtime_access() { :; }
service_is_active() { return 1; }
traffic_is_enabled() { return 1; }
reject_action() {
  if ( "$@" ); then fail "unsafe action unexpectedly succeeded: $*"; fi
}
write_default_config
mkdir -p "$CERT_DIR" "$TEST_ROOT/foreign/child"
printf 'preserve unrelated data\n' >"$TEST_ROOT/foreign/sentinel"
bad_path="$TEST_ROOT/foreign/child/.."
assert_failure safe_remove_dir "$bad_path" "$bad_path"
[[ -f $TEST_ROOT/foreign/sentinel ]] || fail 'directory traversal removed unrelated data'
ln -s "$TEST_ROOT/foreign" "$TEST_ROOT/alias"
bad_path="$TEST_ROOT/alias/child"
assert_failure safe_remove_dir "$bad_path" "$bad_path"
[[ -d $TEST_ROOT/foreign/child ]] || fail 'cleanup traversed a symlinked parent'
mkdir "$TEST_ROOT/owned"
safe_remove_dir "$TEST_ROOT/owned" "$TEST_ROOT/owned"
[[ ! -e $TEST_ROOT/owned ]] || fail 'normal owned directory could not be removed'

# A backup must never truncate an existing data file or follow its symlink.
cp "$CONFIG_FILE" "$TEST_ROOT/before-config"
reject_action backup_all "$CONFIG_FILE"
cmp -s "$CONFIG_FILE" "$TEST_ROOT/before-config" || fail 'backup overwrote live configuration'
ln -s "$TEST_ROOT/foreign/sentinel" "$TEST_ROOT/backup-link"
reject_action backup_all "$TEST_ROOT/backup-link"
assert_eq 'preserve unrelated data' "$(cat "$TEST_ROOT/foreign/sentinel")" 'backup followed a destination symlink'
reject_action backup_all "$CERT_DIR/nested.tar.gz"
backup_all "$TEST_ROOT/good.tar.gz" >/dev/null
tar -tzf "$TEST_ROOT/good.tar.gz" | grep -Fx "${CONFIG_FILE#/}" >/dev/null || fail 'normal backup lost configuration'

# Reject links and device-like entries before extracting anything.
stage="$TEST_ROOT/archive"
mkdir -p "$stage/$(dirname "${CONFIG_FILE#/}")"
cp "$CONFIG_FILE" "$stage/${CONFIG_FILE#/}"
printf 'archive data\n' >"$stage/original"
ln "$stage/original" "$stage/hardlink"
ln -s "$TEST_ROOT/foreign" "$stage/symlink"
mkfifo "$stage/fifo"
for kind in hardlink symlink fifo; do
  archive="$TEST_ROOT/$kind.tar.gz"
  tar -czf "$archive" -C "$stage" "${CONFIG_FILE#/}" original "$kind"
  (
    tar() {
      [[ ${1-} != -xzf ]] || touch "$TEST_ROOT/extraction-started"
      command tar "$@"
    }
    reject_action restore_backup "$archive"
  )
  [[ ! -e $TEST_ROOT/extraction-started ]] || fail 'unsafe archive was extracted before validation'
  cmp -s "$CONFIG_FILE" "$TEST_ROOT/before-config" || fail 'invalid restore changed live configuration'
done

# Simulate disk/write failure after install has already truncated the target.
candidate=$(temp_file)
jq '.log.loglevel="debug"' "$CONFIG_FILE" >"$candidate"
cp "$META_FILE" "$TEST_ROOT/before-meta"
install() {
  if [[ ${*: -2:1} == "$candidate" && ${*: -1} == "$CONFIG_FILE" ]]; then
    printf '{partial' >"$CONFIG_FILE"
    return 1
  fi
  command install "$@"
}
if state_commit "$candidate"; then fail 'partial config installation reported success'; fi
cmp -s "$CONFIG_FILE" "$TEST_ROOT/before-config" || fail 'partial write lost the previous configuration'
cmp -s "$META_FILE" "$TEST_ROOT/before-meta" || fail 'partial write changed metadata'
unset -f install
pass 'backup destinations, archive preflight, cleanup paths, and partial-write rollback preserve data'
