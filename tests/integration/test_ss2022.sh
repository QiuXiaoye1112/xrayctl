#!/usr/bin/env bash

set -Eeuo pipefail

readonly REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
readonly TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/xrayctl-ss2022.XXXXXX")
cleanup() { rm -rf "$TEST_ROOT"; }
trap cleanup EXIT

export XRAYCTL_CONFIG_DIR="$TEST_ROOT"
export XRAYCTL_CONFIG_FILE="$TEST_ROOT/config.json"
export XRAYCTL_META_FILE="$TEST_ROOT/xrayctl.meta.json"
export XRAYCTL_CERT_DIR="$TEST_ROOT/certs"
export XRAYCTL_TMP_DIR="$TEST_ROOT/tmp"
export XRAYCTL_TRAFFIC_FILE="$TEST_ROOT/traffic.json"
export XRAYCTL_LOG_DIR="$TEST_ROOT/logs"
export XRAYCTL_SYSTEMD_UNIT_DIR="$TEST_ROOT/systemd"
export XRAYCTL_OPENRC_INIT_DIR="$TEST_ROOT/openrc"
export XRAYCTL_OBFS_SERVER_BIN="$TEST_ROOT/bin/obfs-server"
export XRAYCTL_OBFS_UDP_CONFIG="$TEST_ROOT/obfs-udp.json"
export XRAYCTL_XRAY_BIN=${XRAYCTL_REAL_XRAY_BIN:-$TEST_ROOT/missing-xray}
export XRAYCTL_RUNTIME_OWNER XRAYCTL_RUNTIME_GROUP
XRAYCTL_RUNTIME_OWNER=$(id -un)
XRAYCTL_RUNTIME_GROUP=$(id -gn)

mkdir -p "$TEST_ROOT/bin" "$XRAYCTL_LOG_DIR" "$XRAYCTL_SYSTEMD_UNIT_DIR" "$XRAYCTL_OPENRC_INIT_DIR"
printf '#!/bin/sh\nexit 0\n' >"$XRAYCTL_OBFS_SERVER_BIN"
chmod 755 "$XRAYCTL_OBFS_SERVER_BIN"

source "$REPO_ROOT/tests/helpers/assert.sh"
source "$REPO_ROOT/xrayctl.sh"
trap - ERR
trap cleanup EXIT
original_prompt_value=$(declare -f prompt_value)

ensure_runtime_dependencies() { :; }
setup_runtime_access() { :; }
service_is_active() { return 1; }
require_xray_installed() { :; }
traffic_after_config_change() { :; }
traffic_user_choose_address() { printf '%s\n' '127.0.0.1:39083'; }
next_obfs_choice=1
choose() {
  case $2 in
    "选择入站协议")
      assert_eq 'VLESS SS2022 SOCKS5 HTTP' "$3 $4 $5 $6" "inbound protocol menu order"
      printf -v "$1" '%s' 2
      ;;
    "HTTP 混淆 (simple-obfs)")
      assert_eq '关闭 开启' "$3 $4" "SS2022 obfs toggle choices"
      printf -v "$1" '%s' "$next_obfs_choice"
      ;;
    *)
      fail "unexpected choose prompt: $2"
      ;;
  esac
}
prompt_tag() { printf -v "$1" '%s' "${next_tag:-ss2022-test}"; }
prompt_value() {
  case ${2-} in
    "监听地址") printf -v "$1" '%s' "${next_listen:-127.0.0.1}" ;;
    *) printf -v "$1" '%s' "${3-}" ;;
  esac
}
prompt_port() { printf -v "$1" '%s' "${next_port:-39082}"; }
prompt_public_host() { printf -v "$1" '%s' "${next_public_host:-2001:db8::1}"; }
prompt_client_label() { printf -v "$1" '%s' "$next_user"; }

jq -n '{inbounds:[],outbounds:[{protocol:"freedom",tag:"direct"}],routing:{rules:[]}}' >"$CONFIG_FILE"
next_user=alice
dispatch inbound add >"$TEST_ROOT/add.out"
validate_candidate "$CONFIG_FILE"
assert_eq $'tcp\nudp' "$(traffic_protocols_for_inbound shadowsocks)" "SS2022 must count both transports"
jq -e '.inbounds[0].settings | .network=="tcp,udp" and .method=="2022-blake3-aes-256-gcm" and .password!=.clients[0].password' "$CONFIG_FILE" >/dev/null
alice_id=$(traffic_user_id ss2022-test alice)
[[ $alice_id == xrayctl-user-* ]]
assert_eq "$alice_id" "$(_outbound_user_identity identity ss2022-test alice; printf '%s' "$identity")" "routing and statistics must share the identity"

cp "$CONFIG_FILE" "$TEST_ROOT/before.json"
assert_failure dispatch client delete ss2022-test alice --yes
assert_file_eq "$TEST_ROOT/before.json" "$CONFIG_FILE" "deleting the last user changed the inbound"
candidate="$TEST_ROOT/candidate.json"
jq '.inbounds[0].settings.clients=[]' "$CONFIG_FILE" >"$candidate"
assert_failure validate_supported_capabilities "$candidate"
jq '.inbounds[0].settings.method="aes-256-gcm"' "$CONFIG_FILE" >"$candidate"
assert_failure validate_supported_capabilities "$candidate"

next_user=bob
dispatch client add ss2022-test >/dev/null
dispatch client rename ss2022-test alice alicia >/dev/null
assert_eq "$alice_id" "$(traffic_user_id ss2022-test alicia)" "renaming changed the statistics identity"
before_rotation=$(jq -c '.inbounds[0].settings' "$CONFIG_FILE")
dispatch client rotate ss2022-test alicia --yes </dev/null >/dev/null
jq -e --argjson before "$before_rotation" '.inbounds[0].settings |
  .password==$before.password and .clients[1]==$before.clients[1] and
  .clients[0].email==$before.clients[0].email and .clients[0].password!=$before.clients[0].password
' "$CONFIG_FILE" >/dev/null
dispatch client delete ss2022-test bob --yes >/dev/null
assert_eq alicia "$(jq -r '.inbounds[0].settings.clients[].xrayctlLabel' "$CONFIG_FILE")" "deleting a user affected the remaining account"

jq --slurpfile inbound "$REPO_ROOT/tests/fixtures/protocols/shadowsocks.json" '.inbounds=$inbound' "$CONFIG_FILE" >"$candidate"
cp "$candidate" "$CONFIG_FILE"
expected='ss://2022-blake3-aes-256-gcm:AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8%3D%3A0NHS09TV1tfY2drb3N3e3%2BDh4uPk5ebn6Onq6%2Bzt7u8%3D@[2001:db8::1]:39082#ss2022-test-alice'
assert_eq "$expected" "$(dispatch subscription ss2022-test | base64 --decode)" "SS2022 URI must percent-encode the combined keys"
jq '.inbounds = [{tag:"legacy-ss", protocol:"shadowsocks", settings:{method:"aes-256-gcm"}}] + .inbounds' "$CONFIG_FILE" >"$candidate"
cp "$candidate" "$CONFIG_FILE"
assert_eq "$expected" "$(dispatch subscription | base64 --decode)" "all-inbound subscription omitted SS2022"

# --- SS2022 + simple-obfs (HTTP obfuscation, TCP+UDP) ---
(
  XRAYCTL_PLATFORM=systemd
  SYSTEMCTL_LOG="$TEST_ROOT/systemctl.log"
  systemctl() {
    local IFS=' '
    printf '%s\n' "$*" >>"$SYSTEMCTL_LOG"
    case ${1-} in
      is-active|is-enabled) return 0 ;;
      list-unit-files) printf 'xray.service enabled\n' ;;
    esac
    return 0
  }
  journalctl() { printf 'obfs-journal-line:%s\n' "$(printf ' %s' "$@")"; }
  rc-service() { printf 'rc-service %s\n' "$*" >>"$SYSTEMCTL_LOG"; return 0; }
  rc-update() { printf 'rc-update %s\n' "$*" >>"$SYSTEMCTL_LOG"; return 0; }

  # Exercise mandatory obfs-host validation (reject empty and invalid domain, accept valid domain).
  validated_host=""
  printf '\nbad host\nobfs.example.com\n' >"$TEST_ROOT/obfs-host-input"
  eval "$original_prompt_value"
  prompt_validated_value validated_host "混淆域名 (obfs-host)" "" validate_domain "混淆域名格式无效，请重新输入。" \
    <"$TEST_ROOT/obfs-host-input" >"$TEST_ROOT/obfs-host.out" 2>&1
  assert_eq "obfs.example.com" "$validated_host" "mandatory obfs-host validation failed"
  grep -Fq '此项不能为空' "$TEST_ROOT/obfs-host.out"
  grep -Fq '混淆域名格式无效' "$TEST_ROOT/obfs-host.out"

  prompt_value() {
    case ${2-} in
      "混淆域名 (obfs-host)") printf -v "$1" '%s' "${next_obfs_host:-obfs.example.com}" ;;
      "监听地址") printf -v "$1" '%s' "${next_listen:-0.0.0.0}" ;;
      *) printf -v "$1" '%s' "${3-}" ;;
    esac
  }

  jq -n '{inbounds:[],outbounds:[{protocol:"freedom",tag:"direct"}],routing:{rules:[]}}' >"$CONFIG_FILE"
  printf '%s\n' '{"schema":4,"inbounds":{},"certificates":{},"managedResources":{},"migrations":{"legacyCertScanV1":true,"legacyCertbotSymlinkV1":true}}' >"$META_FILE"
  next_obfs_choice=2
  next_obfs_host=obfs.example.com
  next_tag=ss2022-obfs
  next_listen=0.0.0.0
  next_port=39182
  next_public_host=edge.example.com
  next_user=alice
  dispatch inbound add >"$TEST_ROOT/obfs-add.out"
  validate_candidate "$CONFIG_FILE"

  local_port=$(jq -r '.inbounds[0].port' "$CONFIG_FILE")
  [[ $local_port != 39182 ]]
  jq -e '.inbounds[0] | .listen=="127.0.0.1" and .settings.network=="tcp,udp" and .settings.method=="2022-blake3-aes-256-gcm"' "$CONFIG_FILE" >/dev/null
  jq -e --argjson lp "$local_port" '.inbounds["ss2022-obfs"].obfs | .enabled==true and .type=="http" and .host=="obfs.example.com" and .listen=="0.0.0.0" and .port==39182 and .localPort==$lp and .service=="xrayctl-obfs-ss2022-obfs"' "$META_FILE" >/dev/null
  unit_file="$SYSTEMD_UNIT_DIR/xrayctl-obfs-ss2022-obfs.service"
  [[ -f $unit_file ]]
  grep -Fq "ExecStart=${OBFS_SERVER_BIN} -s 0.0.0.0 -p 39182 --obfs http -r 127.0.0.1:${local_port}" "$unit_file"

  udp_unit_file="$SYSTEMD_UNIT_DIR/xrayctl-ss2022-udp.service"
  [[ -f $OBFS_UDP_CONFIG && -f $udp_unit_file ]]
  jq -e --argjson lp "$local_port" '
    (.inbounds | length)==1 and
    (.inbounds[0] | .tag=="obfs-udp-ss2022-obfs" and .protocol=="dokodemo-door" and .listen=="0.0.0.0" and .port==39182 and .settings.address=="127.0.0.1" and .settings.port==$lp and .settings.network=="udp") and
    (.outbounds[0] | .protocol=="freedom" and .settings.finalRules==[{"ip":["127.0.0.1/32"],"action":"allow"}])
  ' "$OBFS_UDP_CONFIG" >/dev/null
  grep -Fq 'Environment=GOGC=20' "$udp_unit_file"
  grep -Fq 'Environment=GOMEMLIMIT=32MiB' "$udp_unit_file"
  grep -Fq "ExecStart=${XRAY_BIN} run -format json -config ${OBFS_UDP_CONFIG}" "$udp_unit_file"

  assert_eq "39182" "$(traffic_inventory_json | jq -r '.["ss2022-obfs"].port')" "traffic inventory must use external obfs port"
  assert_eq "tcp,udp" "$(traffic_inventory_json | jq -r '.["ss2022-obfs"].network')" "traffic inventory must reflect tcp,udp network"
  assert_eq $'tcp\nudp' "$(traffic_protocols_for_inbound shadowsocks tcp,udp)" "obfs SS2022 must count TCP and UDP"
  assert_eq "tcp" "$(traffic_protocols_for_inbound shadowsocks tcp)" "legacy tcp-only obfs SS2022 still counts TCP only"

  grep -Fq 'SS2022 · TCP/UDP · HTTP 混淆' "$TEST_ROOT/obfs-add.out"
  grep -Fq 'plugin: obfs, mode: http, host: obfs.example.com' "$TEST_ROOT/obfs-add.out"
  sub_uri=$(dispatch subscription ss2022-obfs | base64 --decode)
  [[ $sub_uri == *"@edge.example.com:39182/?plugin=obfs-local%3Bobfs%3Dhttp%3Bobfs-host%3Dobfs.example.com#ss2022-obfs-alice" ]]

  next_user=bob
  dispatch client add ss2022-obfs >/dev/null
  dispatch client rename ss2022-obfs alice alicia >/dev/null
  dispatch client rotate ss2022-obfs alicia --yes </dev/null >/dev/null
  dispatch client delete ss2022-obfs bob --yes >/dev/null
  assert_eq 1 "$(jq '.inbounds[0].settings.clients|length' "$CONFIG_FILE")" "obfs client lifecycle failed"

  obfs_list=$(dispatch inbound list)
  grep -Fq '39182' <<<"$obfs_list"
  grep -Fq 'http' <<<"$obfs_list"
  if grep -Fq 'obfs-udp' <<<"$obfs_list"; then fail "obfs-udp leaked into inbound list"; fi

  obfs_status=$(dispatch obfs status)
  grep -Fq 'xrayctl-obfs-ss2022-obfs' <<<"$obfs_status"
  grep -Fq 'xrayctl-ss2022-udp' <<<"$obfs_status"
  grep -Fq 'TCP 混淆' <<<"$obfs_status"
  grep -Fq 'UDP 直通' <<<"$obfs_status"
  grep -Fq 'obfs.example.com' <<<"$obfs_status"
  full_status=$(show_status)
  grep -Fq 'HTTP 混淆' <<<"$full_status"
  grep -Fq 'xrayctl-obfs-ss2022-obfs' <<<"$full_status"
  obfs_logs=$(dispatch obfs logs 20)
  grep -Fq 'obfs-journal-line: -u xrayctl-obfs-ss2022-obfs -n 20 --no-pager' <<<"$obfs_logs"
  grep -Fq 'obfs-journal-line: -u xrayctl-ss2022-udp -n 20 --no-pager' <<<"$obfs_logs"
  all_logs=$(dispatch logs 20)
  grep -Fq 'obfs-journal-line: -u xrayctl-obfs-ss2022-obfs -n 20 --no-pager' <<<"$all_logs"
  grep -Fq 'obfs-journal-line: -u xrayctl-ss2022-udp -n 20 --no-pager' <<<"$all_logs"

  next_listen=192.0.2.10
  next_port=39183
  next_public_host=edge.example.com
  dispatch inbound modify ss2022-obfs >/dev/null
  grep -Fq "ExecStart=${OBFS_SERVER_BIN} -s 192.0.2.10 -p 39183 --obfs http -r 127.0.0.1:${local_port}" "$unit_file"
  jq -e '.inbounds[0] | .listen=="192.0.2.10" and .port==39183' "$OBFS_UDP_CONFIG" >/dev/null

  dispatch inbound rename ss2022-obfs ss2022-obfs2 >/dev/null
  [[ ! -e $unit_file ]]
  unit_file="$SYSTEMD_UNIT_DIR/xrayctl-obfs-ss2022-obfs2.service"
  [[ -f $unit_file ]]
  assert_eq "xrayctl-obfs-ss2022-obfs2" "$(jq -r '.inbounds["ss2022-obfs2"].obfs.service' "$META_FILE")"
  assert_eq "obfs-udp-ss2022-obfs2" "$(jq -r '.inbounds[0].tag' "$OBFS_UDP_CONFIG")"

  # OpenRC unit generation check.
  (
    XRAYCTL_PLATFORM=openrc
    obfs_service_setup ss2022-obfs2 0
    rc_file="$OPENRC_INIT_DIR/xrayctl-obfs-ss2022-obfs2"
    rc_udp_file="$OPENRC_INIT_DIR/xrayctl-ss2022-udp"
    [[ -x $rc_file && -x $rc_udp_file ]]
    grep -Fq 'command_args="-s 192.0.2.10 -p 39183 --obfs http -r 127.0.0.1:'"$local_port"'"' "$rc_file"
    grep -Fq "command_args=\"run -format json -config ${OBFS_UDP_CONFIG}\"" "$rc_udp_file"
    grep -Fq 'export GOGC=20' "$rc_udp_file"
    grep -Fq 'export GOMEMLIMIT=32MiB' "$rc_udp_file"
    obfs_service_remove ss2022-obfs2
    [[ ! -e $rc_file ]]
  )

  # Refusing simple-obfs uninstall while an obfs inbound is active.
  assert_failure dispatch obfs uninstall --yes

  # Disabling obfs via inbound transport reverts to direct TCP/UDP and deletes units + obfs-udp config.
  confirm() { return 0; }
  next_obfs_choice=1
  dispatch inbound transport ss2022-obfs2 >/dev/null
  jq -e '.inbounds[0] | .listen=="192.0.2.10" and .port==39183 and .settings.network=="tcp,udp"' "$CONFIG_FILE" >/dev/null
  jq -e '.inbounds["ss2022-obfs2"].obfs == null' "$META_FILE" >/dev/null
  [[ ! -e $unit_file && ! -e $udp_unit_file && ! -e $OBFS_UDP_CONFIG ]]

  # Re-enable obfs and test inbound delete cleanup.
  next_obfs_choice=2
  next_obfs_host=cdn.example.com
  dispatch inbound transport ss2022-obfs2 >/dev/null
  [[ -f $unit_file && -f $udp_unit_file && -f $OBFS_UDP_CONFIG ]]
  dispatch inbound delete ss2022-obfs2 --yes >/dev/null
  [[ ! -e $unit_file && ! -e $udp_unit_file && ! -e $OBFS_UDP_CONFIG ]]
  assert_eq 0 "$(jq '.inbounds|length' "$CONFIG_FILE")" "obfs inbound delete failed"

  # Owned simple-obfs binary uninstall after all obfs inbounds are removed.
  meta_resource_register simpleObfsBin "$XRAYCTL_OBFS_SERVER_BIN"
  dispatch obfs uninstall --yes >/dev/null
  [[ ! -e $XRAYCTL_OBFS_SERVER_BIN ]]

  # Install/update & package-managed uninstall via apt path.
  pkg_manager() { printf 'apt\n'; }
  apt_get_guarded() {
    case ${1-} in
      install)
        printf '#!/bin/sh\nexit 0\n' >"$XRAYCTL_OBFS_SERVER_BIN"
        chmod 755 "$XRAYCTL_OBFS_SERVER_BIN"
        ;;
      remove)
        rm -f "$XRAYCTL_OBFS_SERVER_BIN"
        ;;
    esac
    return 0
  }
  dispatch obfs install >/dev/null
  [[ -x $XRAYCTL_OBFS_SERVER_BIN ]]
  assert_eq "simple-obfs" "$(jq -r '.managedResources.simpleObfsPackage' "$META_FILE")"
  dispatch obfs uninstall --yes >/dev/null
  [[ ! -e $XRAYCTL_OBFS_SERVER_BIN ]]
  assert_eq "null" "$(jq -r '.managedResources.simpleObfsPackage' "$META_FILE")"
)

# Regression test: SIGHUP during Xray restart must not abort obfs or UDP relay setup.
(
  XRAYCTL_PLATFORM=systemd
  SYSTEMCTL_LOG="$TEST_ROOT/sighup-systemctl.log"
  : >"$SYSTEMCTL_LOG"
  systemctl() {
    local IFS=' '
    printf '%s\n' "$*" >>"$SYSTEMCTL_LOG"
    case ${1-} in
      is-active|is-enabled) return 0 ;;
      list-unit-files) printf 'xray.service enabled\n' ;;
    esac
    return 0
  }
  service_is_active() { return 0; }
  service_exists() { return 0; }
  restart_service() { kill -HUP "$BASHPID"; }
  printf '#!/bin/sh\nexit 0\n' >"$XRAYCTL_OBFS_SERVER_BIN"
  chmod 755 "$XRAYCTL_OBFS_SERVER_BIN"
  jq -n '{inbounds:[],outbounds:[{protocol:"freedom",tag:"direct"}],routing:{rules:[]}}' >"$CONFIG_FILE"
  printf '%s\n' '{"schema":4,"inbounds":{},"certificates":{},"managedResources":{},"migrations":{"legacyCertScanV1":true,"legacyCertbotSymlinkV1":true}}' >"$META_FILE"

  next_obfs_choice=2
  prompt_value() {
    case ${2-} in
      "混淆域名 (obfs-host)") printf -v "$1" '%s' "hup.example.com" ;;
      "监听地址") printf -v "$1" '%s' "0.0.0.0" ;;
      *) printf -v "$1" '%s' "${3-}" ;;
    esac
  }
  next_tag=ss2022-hup
  next_port=39192
  next_public_host=edge.example.com
  next_user=alice
  dispatch inbound add >"$TEST_ROOT/hup-add.out"

  unit_file="$SYSTEMD_UNIT_DIR/xrayctl-obfs-ss2022-hup.service"
  udp_unit_file="$SYSTEMD_UNIT_DIR/xrayctl-ss2022-udp.service"
  [[ -f $unit_file && -f $udp_unit_file && -f $OBFS_UDP_CONFIG ]]
  grep -Fq 'restart xrayctl-obfs-ss2022-hup' "$SYSTEMCTL_LOG"
  grep -Fq 'restart xrayctl-ss2022-udp' "$SYSTEMCTL_LOG"
)

pass "SS2022 menu order, validated config, independent keys, user lifecycle, HTTP obfs + UDP relay, and share links"
