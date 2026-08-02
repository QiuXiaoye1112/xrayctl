#!/usr/bin/env bash
# xrayctl - Xray Linux terminal manager
# Project home: generated as a standalone administration script.

set -Eeuo pipefail
IFS=$'\n\t'

readonly XRAYCTL_VERSION="1.2.0"
readonly OFFICIAL_INSTALLER_URL="https://github.com/XTLS/Xray-install/raw/main/install-release.sh"
readonly JQ_VERSION="1.8.2"

XRAY_BIN="${XRAYCTL_XRAY_BIN:-/usr/local/bin/xray}"
CONFIG_DIR="${XRAYCTL_CONFIG_DIR:-/usr/local/etc/xray}"
CONFIG_FILE="${XRAYCTL_CONFIG_FILE:-${CONFIG_DIR}/config.json}"
META_FILE="${XRAYCTL_META_FILE:-${CONFIG_DIR}/xrayctl.meta.json}"
CERT_DIR="${XRAYCTL_CERT_DIR:-${CONFIG_DIR}/certs}"
BACKUP_DIR="${XRAYCTL_BACKUP_DIR:-/var/backups/xrayctl}"
QUICK_COMMAND="${XRAYCTL_COMMAND_PATH:-/usr/local/sbin/xrayctl}"
QUICK_SYMLINK="${XRAYCTL_SYMLINK_PATH:-/usr/local/bin/xrayctl}"
SERVICE_NAME="${XRAYCTL_SERVICE_NAME:-xray}"
SYSTEMD_UNIT="${SERVICE_NAME}.service"
RUNTIME_OWNER="${XRAYCTL_RUNTIME_OWNER:-root}"
RUNTIME_GROUP="${XRAYCTL_RUNTIME_GROUP:-xrayctl}"
SYSTEMD_OVERRIDE_DIR="${XRAYCTL_SYSTEMD_OVERRIDE_DIR:-/etc/systemd/system/${SYSTEMD_UNIT}.d}"
LOCK_FILE="${XRAYCTL_LOCK_FILE:-/run/lock/xrayctl.lock}"
JQ_INSTALL_PATH="${XRAYCTL_JQ_INSTALL_PATH:-/usr/local/bin/jq}"
CERT_STOPPED_SERVICE=0

if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
  C_RED=$'\033[31m'; C_GREEN=$'\033[32m'; C_YELLOW=$'\033[33m'
  C_BLUE=$'\033[34m'; C_CYAN=$'\033[36m'; C_BOLD=$'\033[1m'; C_RESET=$'\033[0m'
else
  C_RED=""; C_GREEN=""; C_YELLOW=""; C_BLUE=""; C_CYAN=""; C_BOLD=""; C_RESET=""
fi

info()    { printf '%s[信息]%s %s\n' "$C_GREEN" "$C_RESET" "$*"; }
warn()    { printf '%s[警告]%s %s\n' "$C_YELLOW" "$C_RESET" "$*" >&2; }
error()   { printf '%s[错误]%s %s\n' "$C_RED" "$C_RESET" "$*" >&2; }
die()     { error "$*"; exit 1; }
heading() { printf '\n%s%s%s\n' "$C_BOLD$C_CYAN" "$*" "$C_RESET"; }
clear_screen() { clear 2>/dev/null || true; }

on_error() {
  local exit_code=$? line=${BASH_LINENO[0]:-?}
  error "命令在第 ${line} 行失败（退出码 ${exit_code}）。"
  exit "$exit_code"
}
trap on_error ERR

cleanup_on_exit() {
  if [[ ${CERT_STOPPED_SERVICE:-0} == 1 ]] && command_exists systemctl; then
    systemctl start "$SERVICE_NAME" >/dev/null 2>&1 || true
  fi
}
trap cleanup_on_exit EXIT

is_root() { [[ $(id -u) -eq 0 ]]; }
require_root() { is_root || die "此操作需要 root 权限，请使用 sudo xrayctl $*."; }
command_exists() { command -v "$1" >/dev/null 2>&1; }
is_linux() { [[ $(uname -s) == "Linux" ]]; }
is_systemd() { command_exists systemctl && [[ -d /run/systemd/system || ${XRAYCTL_TESTING:-0} == 1 ]]; }

pause() {
  [[ -t 0 ]] || return 0
  read -r -p "按回车键继续..." _
}

confirm() {
  local prompt=${1:-"确定继续吗？"} default=${2:-N} answer suffix
  if [[ $default == Y ]]; then suffix="[Y/n]"; else suffix="[y/N]"; fi
  if [[ ! -t 0 ]]; then [[ $default == Y ]]; return; fi
  read -r -p "${prompt} ${suffix} " answer
  answer=${answer:-$default}
  [[ $answer =~ ^[Yy]$ ]]
}

prompt_value() {
  local __var=$1 prompt=$2 default=${3-} input_value
  if [[ -n $default ]]; then
    read -r -p "${prompt} [${default}]: " input_value
    input_value=${input_value:-$default}
  else
    read -r -p "${prompt}: " input_value
  fi
  printf -v "$__var" '%s' "$input_value"
}

prompt_secret() {
  local __var=$1 prompt=$2 generated=${3-} secret_value=""
  if [[ -n $generated ]]; then
    read -r -s -p "${prompt}（留空自动生成）: " secret_value; printf '\n'
    secret_value=${secret_value:-$generated}
  else
    while [[ -z $secret_value ]]; do
      read -r -s -p "${prompt}: " secret_value; printf '\n'
    done
  fi
  printf -v "$__var" '%s' "$secret_value"
}

choose() {
  local __var=$1 prompt=$2; shift 2
  local options=("$@") selected_value i
  printf '%s\n' "$prompt"
  for ((i=0; i<${#options[@]}; i++)); do printf '  %d) %s\n' "$((i+1))" "${options[$i]}"; done
  while true; do
    read -r -p "请选择 [1-${#options[@]}]: " selected_value
    if [[ $selected_value =~ ^[0-9]+$ ]] && (( selected_value >= 1 && selected_value <= ${#options[@]} )); then
      printf -v "$__var" '%s' "$selected_value"
      return 0
    fi
    warn "无效选项。"
  done
}

validate_port() { [[ $1 =~ ^[0-9]+$ ]] && (( 10#$1 >= 1 && 10#$1 <= 65535 )); }
validate_tag() { [[ $1 =~ ^[A-Za-z0-9_.-]+$ ]]; }
validate_domain() { [[ $1 =~ ^([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z]{2,63}$ ]]; }
validate_path() { [[ $1 == /* && $1 != *" "* ]]; }
validate_email_label() { [[ -n $1 && ${#1} -le 128 && $1 != *$'\n'* ]]; }

validate_ipv4() {
  local value=$1 a b c d extra
  IFS=. read -r a b c d extra <<<"$value"
  [[ -z ${extra:-} && $a =~ ^[0-9]{1,3}$ && $b =~ ^[0-9]{1,3}$ && $c =~ ^[0-9]{1,3}$ && $d =~ ^[0-9]{1,3}$ ]] \
    && ((10#$a <= 255 && 10#$b <= 255 && 10#$c <= 255 && 10#$d <= 255))
}

validate_ip_literal() {
  validate_ipv4 "$1" || [[ $1 == *:* && $1 =~ ^[0-9A-Fa-f:]+$ && ${#1} -le 45 ]]
}

detect_public_ip() {
  local response raw
  response=$({ curl --fail --silent --show-error --location --proto '=https' --tlsv1.2 \
    --connect-timeout 4 --max-time 8 https://api64.ipify.org 2>/dev/null || true; } | tr -d '[:space:]')
  if validate_ip_literal "$response"; then printf '%s' "$response"; return 0; fi

  response=$({ curl --fail --silent --show-error --location --proto '=https' --tlsv1.2 \
    --connect-timeout 4 --max-time 8 https://checkip.amazonaws.com 2>/dev/null || true; } | tr -d '[:space:]')
  if validate_ip_literal "$response"; then printf '%s' "$response"; return 0; fi

  raw=$(curl --fail --silent --show-error --location --proto '=https' --tlsv1.2 \
    --connect-timeout 4 --max-time 8 https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null || true)
  response=$(awk -F= '$1=="ip" {print $2; exit}' <<<"$raw" | tr -d '[:space:]')
  if validate_ip_literal "$response"; then printf '%s' "$response"; return 0; fi
  return 1
}

json_quote() { jq -Rn --arg value "$1" '$value'; }
url_encode() { jq -rn --arg value "$1" '$value|@uri'; }
base64_nowrap() { base64 | tr -d '\n'; }
base64_urlsafe() { base64_nowrap | tr '+/' '-_' | tr -d '='; }

random_hex() { openssl rand -hex "${1:-8}"; }
random_password() { openssl rand -base64 24 | tr -d '\n=+/' | cut -c1-24; }
generate_uuid() {
  if [[ -x $XRAY_BIN ]]; then "$XRAY_BIN" uuid 2>/dev/null | tail -n1; return; fi
  if command_exists uuidgen; then uuidgen | tr '[:upper:]' '[:lower:]'; return; fi
  local h; h=$(openssl rand -hex 16)
  printf '%s-%s-4%s-%x%s-%s\n' "${h:0:8}" "${h:8:4}" "${h:13:3}" "$(( (0x${h:16:1} & 3) | 8 ))" "${h:17:3}" "${h:20:12}"
}

ensure_linux_systemd() {
  is_linux || die "仅支持 Linux；当前系统是 $(uname -s)。"
  is_systemd || die "需要使用 systemd 的 Linux 发行版。"
}

pkg_manager() {
  if command_exists apt-get; then printf 'apt';
  elif command_exists dnf; then printf 'dnf';
  elif command_exists yum; then printf 'yum';
  elif command_exists pacman; then printf 'pacman';
  elif command_exists zypper; then printf 'zypper';
  else return 1; fi
}

apt_get_guarded() {
  local total_timeout=${XRAYCTL_APT_TIMEOUT:-180}
  local apt_options=(
    -o Acquire::Retries=2
    -o Acquire::http::Timeout=15
    -o Acquire::https::Timeout=15
    -o Dpkg::Use-Pty=0
  )
  [[ ${XRAYCTL_APT_FORCE_IPV4:-1} == 0 ]] || apt_options+=(-o Acquire::ForceIPv4=true)
  if command_exists timeout; then
    timeout --foreground "${total_timeout}s" apt-get "${apt_options[@]}" "$@"
  else
    apt-get "${apt_options[@]}" "$@"
  fi
}

install_jq_standalone() {
  local machine asset expected_hash download_url temp actual_hash
  machine=$(uname -m)
  case $machine in
    x86_64|amd64) asset=jq-linux-amd64; expected_hash=b1c22172dd303f3be49e935aa56aa48a8b7a46e0bc838b4997d3bb451495870f ;;
    aarch64|arm64) asset=jq-linux-arm64; expected_hash=8b85c817833814ddca00a144c33705546355afccf0cf39b188f3cdb48b852309 ;;
    armv7l|armv7|armhf) asset=jq-linux-armhf; expected_hash=78458244fb546469b4042e9e07cf78714ef6848895eb9515df76b4eb0b1dc992 ;;
    armv5*|armv6*|armel) asset=jq-linux-armel; expected_hash=d88f6bd640ef8909b3deb587f12c03a0ed38fe8bd5e2e882e2b1bf88f5dab8d2 ;;
    i386|i486|i586|i686) asset=jq-linux-i386; expected_hash=ba996e8ce436973e2f39e2639405a37e8c81ba8c722b71c83996278ad0af16dd ;;
    riscv64) asset=jq-linux-riscv64; expected_hash=a96e5a78a7b2c5a0575bc2a10dda4b20d84efd8c02c8806539ee5f5e57603e8d ;;
    s390x) asset=jq-linux-s390x; expected_hash=42b3306c786e3352e3097b8aa03ca0e5631bdc7a6bf133bb8ddd9e4b148d20c8 ;;
    ppc64le) asset=jq-linux-ppc64el; expected_hash=0dba61281e525ced2111bc00c8bd8078100e8822c33bfb35feee95314bbeeea2 ;;
    *) warn "没有适用于 ${machine} 的 jq 静态包。"; return 1 ;;
  esac
  download_url="https://github.com/jqlang/jq/releases/download/jq-${JQ_VERSION}/${asset}"
  temp=$(temp_file)
  info "正在从 jq 官方仓库安装静态版 jq ${JQ_VERSION}（跳过 APT）。"
  if ! curl --fail --location --proto '=https' --tlsv1.2 --retry 3 --connect-timeout 15 --max-time 180 "$download_url" -o "$temp"; then
    rm -f "$temp"; warn "jq 静态包下载失败。"; return 1
  fi
  if command_exists sha256sum; then actual_hash=$(sha256sum "$temp" | awk '{print $1}');
  elif command_exists openssl; then actual_hash=$(openssl dgst -sha256 "$temp" | awk '{print $NF}');
  else rm -f "$temp"; warn "缺少 SHA-256 校验工具。"; return 1; fi
  if [[ $actual_hash != "$expected_hash" ]]; then
    rm -f "$temp"; warn "jq 静态包 SHA-256 校验失败，拒绝安装。"; return 1
  fi
  install -d -m 755 "$(dirname "$JQ_INSTALL_PATH")"
  install -m 755 "$temp" "$JQ_INSTALL_PATH"
  rm -f "$temp"
  if [[ ${XRAYCTL_TESTING:-0} != 1 ]]; then
    "$JQ_INSTALL_PATH" --version >/dev/null || { warn "jq 静态包无法运行。"; return 1; }
  fi
  info "jq 已安装：${JQ_INSTALL_PATH}"
}

install_packages() {
  local missing=() remaining=() item manager
  for item in "$@"; do command_exists "$item" || missing+=("$item"); done
  ((${#missing[@]})) || return 0
  for item in "${missing[@]}"; do
    if [[ $item == jq ]] && install_jq_standalone; then continue; fi
    remaining+=("$item")
  done
  missing=("${remaining[@]}")
  ((${#missing[@]})) || return 0
  manager=$(pkg_manager) || die "未识别包管理器，请手动安装：${missing[*]}"
  info "安装依赖：${missing[*]}"
  case $manager in
    apt)
      if ! DEBIAN_FRONTEND=noninteractive apt_get_guarded update -y; then
        warn "APT 软件索引更新失败或超时，尝试使用现有索引继续安装。"
      fi
      DEBIAN_FRONTEND=noninteractive apt_get_guarded install -y --no-install-recommends "${missing[@]}" \
        || die "APT 依赖安装失败。请检查 /etc/apt/sources.list、DNS 和服务器网络后重试。"
      ;;
    dnf) dnf install -y "${missing[@]}" ;;
    yum) yum install -y "${missing[@]}" ;;
    pacman) pacman -Sy --noconfirm "${missing[@]}" ;;
    zypper) zypper --non-interactive install "${missing[@]}" ;;
  esac
}

acquire_lock() {
  command_exists flock || return 0
  mkdir -p "$(dirname "$LOCK_FILE")"
  exec 9>"$LOCK_FILE"
  flock -n 9 || die "另一个 xrayctl 操作正在运行。"
}

ensure_runtime_dependencies() {
  require_root "$@"
  ensure_linux_systemd
  install_packages curl jq openssl
  acquire_lock
}

init_meta() {
  mkdir -p "$CONFIG_DIR"
  if [[ ! -s $META_FILE ]] || ! jq -e 'type=="object" and (.inbounds|type=="object")' "$META_FILE" >/dev/null 2>&1; then
    printf '%s\n' '{"schema":1,"inbounds":{}}' >"$META_FILE"
    chmod 600 "$META_FILE"
  fi
}

write_default_config() {
  mkdir -p "$CONFIG_DIR" /var/log/xray
  cat >"$CONFIG_FILE" <<'JSON'
{
  "log": {
    "loglevel": "warning",
    "access": "/var/log/xray/access.log",
    "error": "/var/log/xray/error.log"
  },
  "inbounds": [],
  "outbounds": [
    {"protocol": "freedom", "tag": "direct"},
    {"protocol": "blackhole", "tag": "blocked"}
  ],
  "routing": {
    "domainStrategy": "IPIfNonMatch",
    "rules": [
      {"type": "field", "ip": ["geoip:private"], "outboundTag": "blocked"},
      {"type": "field", "protocol": ["bittorrent"], "outboundTag": "blocked"}
    ]
  }
}
JSON
  chmod 640 "$CONFIG_FILE"
  init_meta
}

ensure_config() {
  [[ -f $CONFIG_FILE ]] || write_default_config
  jq -e 'type=="object" and (.inbounds|type=="array")' "$CONFIG_FILE" >/dev/null \
    || die "配置文件不是有效的 Xray JSON：$CONFIG_FILE"
  init_meta
}

xray_installed() { [[ -x $XRAY_BIN ]]; }
require_xray_installed() { xray_installed || die "Xray 尚未安装，请先运行：sudo xrayctl install"; }

validate_candidate() {
  local candidate=$1 validation_output
  if ! validation_output=$(jq -e 'type=="object" and (.inbounds|type=="array") and (.outbounds|type=="array")' "$candidate" 2>&1); then
    error "JSON 结构检查失败。"
    [[ -z $validation_output ]] || printf '%s\n' "$validation_output" >&2
    return 1
  fi
  if xray_installed; then
    if ! validation_output=$("$XRAY_BIN" run -test -format json -config "$candidate" 2>&1); then
      error "Xray 核心拒绝了新配置，原始错误如下："
      [[ -z $validation_output ]] || printf '%s\n' "$validation_output" >&2
      return 1
    fi
  fi
}

timestamp() { date '+%Y%m%d-%H%M%S'; }

backup_config_quiet() {
  [[ -f $CONFIG_FILE ]] || return 0
  mkdir -p "$BACKUP_DIR"
  local target
  target="${BACKUP_DIR}/config-$(timestamp).json"
  cp -a "$CONFIG_FILE" "$target"
  [[ ! -f $META_FILE ]] || cp -a "$META_FILE" "${target%.json}.meta.json"
  printf '%s' "$target"
}

service_exists() { command_exists systemctl && systemctl list-unit-files "$SYSTEMD_UNIT" --no-legend 2>/dev/null | grep -q "$SYSTEMD_UNIT"; }
service_is_active() { command_exists systemctl && systemctl is-active --quiet "$SERVICE_NAME" 2>/dev/null; }
service_is_enabled() { command_exists systemctl && systemctl is-enabled --quiet "$SERVICE_NAME" 2>/dev/null; }

restart_service() {
  if service_exists; then
    systemctl daemon-reload
    systemctl restart "$SERVICE_NAME"
    if ! service_is_active; then
      journalctl -u "$SERVICE_NAME" -n 20 --no-pager >&2 || true
      return 1
    fi
  fi
}

apply_candidate() {
  local candidate=$1 backup="" old_active=0
  ensure_config
  validate_candidate "$candidate" || return 1
  service_is_active && old_active=1
  backup=$(backup_config_quiet)
  setup_runtime_access
  install -m 640 -o "$RUNTIME_OWNER" -g "$RUNTIME_GROUP" "$candidate" "$CONFIG_FILE"
  if ((old_active)) && ! restart_service; then
    error "重启失败，正在回滚配置。"
    if [[ -n $backup && -f $backup ]]; then
      install -m 640 -o "$RUNTIME_OWNER" -g "$RUNTIME_GROUP" "$backup" "$CONFIG_FILE"
      restart_service || true
    fi
    return 1
  fi
  info "配置已应用${backup:+；备份：$backup}。"
}

temp_file() { mktemp "${TMPDIR:-/tmp}/xrayctl.XXXXXX"; }

meta_set_inbound() {
  local tag=$1 host=$2 public_key=${3-} key_mode=${4:-keep} tmp
  init_meta; tmp=$(temp_file)
  jq --arg tag "$tag" --arg host "$host" --arg publicKey "$public_key" --arg keyMode "$key_mode" --arg now "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
    '.inbounds[$tag] = ((.inbounds[$tag] // {}) + {host:$host,managed:true,updatedAt:$now}) |
     if $publicKey != "" then .inbounds[$tag].realityPublicKey=$publicKey
     elif $keyMode == "replace" then del(.inbounds[$tag].realityPublicKey)
     else . end' \
    "$META_FILE" >"$tmp"
  install -m 600 "$tmp" "$META_FILE"; rm -f "$tmp"
}

meta_delete_inbound() {
  local tag=$1 tmp; init_meta; tmp=$(temp_file)
  jq --arg tag "$tag" 'del(.inbounds[$tag])' "$META_FILE" >"$tmp"
  install -m 600 "$tmp" "$META_FILE"; rm -f "$tmp"
}

get_service_user() {
  local user
  user=$(systemctl show "$SERVICE_NAME" -p User --value 2>/dev/null || true)
  printf '%s' "${user:-nobody}"
}

setup_runtime_access() {
  getent group "$RUNTIME_GROUP" >/dev/null 2>&1 || groupadd --system "$RUNTIME_GROUP"
  install -d -m 750 -o "$RUNTIME_OWNER" -g "$RUNTIME_GROUP" "$CONFIG_DIR"
  install -d -m 750 -o "$RUNTIME_OWNER" -g "$RUNTIME_GROUP" "$CERT_DIR"
  if [[ -f $CONFIG_FILE ]]; then
    chown "$RUNTIME_OWNER:$RUNTIME_GROUP" "$CONFIG_FILE"
    chmod 640 "$CONFIG_FILE"
  fi
  install -d -m 755 "$SYSTEMD_OVERRIDE_DIR"
  cat >"${SYSTEMD_OVERRIDE_DIR}/20-xrayctl-access.conf" <<EOF
[Service]
SupplementaryGroups=${RUNTIME_GROUP}
EOF
  rm -f "${SYSTEMD_OVERRIDE_DIR}/20-xrayctl-certificates.conf"
  systemctl daemon-reload
}

setup_certificate_access() { setup_runtime_access; }

copy_certificate_pair() {
  local domain=$1 cert_source=$2 key_source=$3 cert_target key_target cert_pub key_pub
  [[ -r $cert_source ]] || die "无法读取证书：$cert_source"
  [[ -r $key_source ]] || die "无法读取私钥：$key_source"
  openssl x509 -in "$cert_source" -noout >/dev/null || die "证书格式无效。"
  openssl pkey -in "$key_source" -noout >/dev/null || die "私钥格式无效。"
  cert_pub=$(openssl x509 -in "$cert_source" -pubkey -noout | openssl pkey -pubin -outform DER 2>/dev/null | openssl sha256)
  key_pub=$(openssl pkey -in "$key_source" -pubout -outform DER 2>/dev/null | openssl sha256)
  [[ $cert_pub == "$key_pub" ]] || die "证书与私钥不匹配。"
  setup_certificate_access
  cert_target="${CERT_DIR}/${domain}.crt"; key_target="${CERT_DIR}/${domain}.key"
  install -m 640 -o "$RUNTIME_OWNER" -g "$RUNTIME_GROUP" "$cert_source" "$cert_target"
  install -m 640 -o "$RUNTIME_OWNER" -g "$RUNTIME_GROUP" "$key_source" "$key_target"
  printf '%s\n%s\n' "$cert_target" "$key_target"
}

install_or_update_xray() {
  ensure_runtime_dependencies install
  local mode=${1:-install} version=${2:-} installer installed_before=0
  xray_installed && installed_before=1
  installer=$(temp_file)
  info "从 XTLS 官方仓库下载安装脚本。"
  curl --fail --location --proto '=https' --tlsv1.2 --retry 3 --connect-timeout 15 --max-time 180 "$OFFICIAL_INSTALLER_URL" -o "$installer"
  chmod 700 "$installer"
  if [[ -n $version ]]; then bash "$installer" install --version "${version#v}";
  else bash "$installer" install; fi
  rm -f "$installer"
  [[ -x $XRAY_BIN ]] || die "Xray 安装后未找到：$XRAY_BIN"
  if ((installed_before == 0)) || [[ ! -f $CONFIG_FILE ]]; then write_default_config; else ensure_config; fi
  setup_runtime_access
  install_quick_command
  validate_candidate "$CONFIG_FILE"
  systemctl enable "$SERVICE_NAME" >/dev/null
  restart_service
  if [[ $mode == upgrade ]]; then
    info "Xray 已升级：$($XRAY_BIN version | sed -n '1p')"
  else
    info "Xray 已安装/修复：$($XRAY_BIN version | sed -n '1p')"
  fi
}

install_quick_command() {
  local source=${BASH_SOURCE[0]}
  [[ -r $source ]] || die "无法定位当前脚本。"
  mkdir -p "$(dirname "$QUICK_COMMAND")" "$(dirname "$QUICK_SYMLINK")"
  if [[ -e $QUICK_COMMAND && ! $source -ef $QUICK_COMMAND ]] && ! grep -q '^# xrayctl - Xray Linux terminal manager' "$QUICK_COMMAND" 2>/dev/null; then
    die "${QUICK_COMMAND} 已存在且不是本脚本，拒绝覆盖。"
  fi
  if [[ ! -e $QUICK_COMMAND ]] || ! [[ $source -ef $QUICK_COMMAND ]]; then
    install -m 755 "$source" "$QUICK_COMMAND"
  else
    chmod 755 "$QUICK_COMMAND"
  fi
  if [[ -e $QUICK_SYMLINK && ! -L $QUICK_SYMLINK && ! $QUICK_SYMLINK -ef $QUICK_COMMAND ]]; then
    die "${QUICK_SYMLINK} 已存在且不是本脚本，拒绝覆盖。"
  fi
  ln -sfn "$QUICK_COMMAND" "$QUICK_SYMLINK"
  info "快捷命令已安装：xrayctl"
}

uninstall_xray() {
  ensure_runtime_dependencies uninstall
  local purge=${1:-0} installer hook
  if [[ $purge == 1 ]]; then
    confirm "将卸载 Xray 并删除配置、证书、日志与元数据，确定吗？" N || return 0
  else
    confirm "卸载 Xray 核心但保留配置和备份，确定吗？" N || return 0
  fi
  backup_all || true
  installer=$(temp_file)
  curl --fail --location --proto '=https' --tlsv1.2 --retry 3 --connect-timeout 15 --max-time 180 "$OFFICIAL_INSTALLER_URL" -o "$installer"
  chmod 700 "$installer"
  if [[ $purge == 1 ]]; then bash "$installer" remove --purge; else bash "$installer" remove; fi
  rm -f "$installer"
  if [[ $purge == 1 ]]; then
    for hook in /etc/letsencrypt/renewal-hooks/deploy/xrayctl-*; do
      [[ -e $hook ]] && rm -f "$hook"
    done
    rm -f "${SYSTEMD_OVERRIDE_DIR}/20-xrayctl-access.conf" "${SYSTEMD_OVERRIDE_DIR}/20-xrayctl-certificates.conf"
    rmdir "$SYSTEMD_OVERRIDE_DIR" 2>/dev/null || true
    if [[ $RUNTIME_GROUP == xrayctl ]]; then
      getent group "$RUNTIME_GROUP" >/dev/null 2>&1 && groupdel "$RUNTIME_GROUP" 2>/dev/null || true
    fi
    systemctl daemon-reload
  fi
  if [[ -L $QUICK_SYMLINK ]] && [[ $(readlink "$QUICK_SYMLINK") == "$QUICK_COMMAND" ]]; then rm -f "$QUICK_SYMLINK"; fi
  if [[ $QUICK_COMMAND == /usr/local/sbin/xrayctl ]] && grep -q '^# xrayctl - Xray Linux terminal manager' "$QUICK_COMMAND" 2>/dev/null; then rm -f "$QUICK_COMMAND"; fi
  info "卸载完成；备份保留在 ${BACKUP_DIR}。"
}

inbound_exists() { jq -e --arg tag "$1" '.inbounds[] | select(.tag==$tag)' "$CONFIG_FILE" >/dev/null; }

port_in_config() {
  local port=$1 except=${2-}
  jq -e --argjson port "$port" --arg except "$except" '.inbounds[] | select(.port==$port and .tag!=$except)' "$CONFIG_FILE" >/dev/null
}

port_in_use_os() {
  local port=$1
  if command_exists ss; then ss -H -lntu 2>/dev/null | awk '{print $5}' | grep -Eq "(^|:)$port$";
  elif command_exists netstat; then netstat -lntu 2>/dev/null | awk '{print $4}' | grep -Eq "(^|:)$port$";
  else return 1; fi
}

prompt_tag() {
  local __var=$1 default=${2:-node-$(random_hex 2)} value
  while true; do
    prompt_value value "节点标签" "$default"
    validate_tag "$value" || { warn "标签格式不正确。"; continue; }
    inbound_exists "$value" && { warn "标签已存在。"; continue; }
    printf -v "$__var" '%s' "$value"; return
  done
}

prompt_port() {
  local __var=$1 default=${2:-443} except=${3-} value current_port=""
  while true; do
    prompt_value value "监听端口" "$default"
    validate_port "$value" || { warn "端口必须是 1-65535。"; continue; }
    port_in_config "$value" "$except" && { warn "该端口已被另一条 Xray 入站使用。"; continue; }
    [[ -z $except ]] || current_port=$(jq -r --arg tag "$except" '.inbounds[]|select(.tag==$tag)|.port // empty' "$CONFIG_FILE")
    if port_in_use_os "$value" && ! { [[ -n $except && $value == "$current_port" ]] && service_is_active; }; then
      confirm "系统检测到端口 ${value} 已被占用，仍然继续吗？" N || continue
    fi
    printf -v "$__var" '%s' "$value"; return
  done
}

prompt_public_host() {
  local __var=$1 default=${2:-${XRAYCTL_PUBLIC_HOST:-}} value
  if [[ -z $default ]]; then
    default=$(detect_public_ip || true)
  fi
  while true; do
    prompt_value value "客户端地址" "$default"
    if [[ -n $value && $value != *" "* ]]; then
      printf -v "$__var" '%s' "$value"
      return
    fi
    warn "地址无效。"
  done
}

generate_reality_keys() {
  local __private=$1 __public=$2 output key_private key_public
  xray_installed || die "生成 REALITY 密钥前请先安装 Xray。"
  output=$("$XRAY_BIN" x25519)
  key_private=$(awk -F': *' 'tolower($1) ~ /private/ {print $2; exit}' <<<"$output")
  key_public=$(awk -F': *' 'tolower($1) ~ /(public|password)/ {print $2; exit}' <<<"$output")
  [[ -n $key_private && -n $key_public ]] || { error "$output"; die "无法解析 Xray 生成的 REALITY 密钥。"; }
  printf -v "$__private" '%s' "$key_private"; printf -v "$__public" '%s' "$key_public"
}

build_stream_settings() {
  local protocol=$1 __json=$2 __public_key=$3
  local transport_choice security_choice method security path service target sni private public short_id cert key alpn json
  choose transport_choice "选择传输方式" \
    "RAW" "XHTTP" "WebSocket" "gRPC"
  case $transport_choice in
    1) method=raw ;;
    2) method=xhttp ;;
    3) method=websocket ;;
    4) method=grpc ;;
  esac

  if [[ $protocol == vless ]]; then
    if [[ $method == raw || $method == xhttp || $method == grpc ]]; then
      choose security_choice "选择传输安全" "REALITY" "TLS" "无"
      case $security_choice in 1) security=reality;; 2) security=tls;; 3) security=none;; esac
    else
      choose security_choice "选择传输安全" "TLS" "无"
      case $security_choice in 1) security=tls;; 2) security=none;; esac
    fi
  elif [[ $protocol == trojan ]]; then
    if [[ $method == raw || $method == xhttp || $method == grpc ]]; then
      choose security_choice "选择传输安全" "TLS" "REALITY" "无"
      case $security_choice in 1) security=tls;; 2) security=reality;; 3) security=none;; esac
    else security=tls; info "Trojan + ${method} 使用 TLS。"; fi
  else
    choose security_choice "选择传输安全" "TLS" "无"
    case $security_choice in 1) security=tls;; 2) security=none;; esac
  fi

  json=$(jq -n --arg method "$method" --arg security "$security" '{method:$method,security:$security}')
  case $method in
    raw) json=$(jq '. + {rawSettings:{acceptProxyProtocol:false,header:{type:"none"}}}' <<<"$json") ;;
    xhttp)
      while true; do prompt_value path "XHTTP 路径" "/$(random_hex 6)"; validate_path "$path" && break; warn "路径必须以 / 开头且不含空格。"; done
      json=$(jq --arg path "$path" '. + {xhttpSettings:{path:$path,mode:"auto"}}' <<<"$json") ;;
    websocket)
      while true; do prompt_value path "WebSocket 路径" "/$(random_hex 6)"; validate_path "$path" && break; warn "路径必须以 / 开头且不含空格。"; done
      json=$(jq --arg path "$path" '. + {wsSettings:{path:$path,acceptProxyProtocol:false}}' <<<"$json") ;;
    grpc)
      prompt_value service "gRPC serviceName" "$(random_hex 6)"
      json=$(jq --arg service "$service" '. + {grpcSettings:{serviceName:$service,multiMode:false}}' <<<"$json") ;;
  esac

  case $security in
    reality)
      prompt_value target "REALITY 目标" "www.microsoft.com:443"
      prompt_value sni "REALITY serverName/SNI" "${target%%:*}"
      [[ $target == *:* && -n $sni ]] || die "REALITY 目标或 SNI 无效。"
      generate_reality_keys private public
      short_id=$(random_hex 8)
      json=$(jq --arg target "$target" --arg sni "$sni" --arg private "$private" --arg short "$short_id" \
        '. + {realitySettings:{show:false,target:$target,xver:0,serverNames:[$sni],privateKey:$private,shortIds:[$short],maxTimeDiff:0}}' <<<"$json")
      printf -v "$__public_key" '%s' "$public"
      ;;
    tls)
      prompt_value cert "证书文件路径（PEM/fullchain）" "${CERT_DIR}/example.com.crt"
      prompt_value key "私钥文件路径（PEM）" "${CERT_DIR}/example.com.key"
      [[ -r $cert && -r $key ]] || warn "证书文件当前不可读；配置校验会失败。可先从证书管理菜单导入/签发。"
      if [[ $method == websocket ]]; then alpn='["http/1.1"]'; else alpn='["h2","http/1.1"]'; fi
      json=$(jq --arg cert "$cert" --arg key "$key" --argjson alpn "$alpn" \
        '. + {tlsSettings:{alpn:$alpn,minVersion:"1.2",certificates:[{certificateFile:$cert,keyFile:$key}]}}' <<<"$json")
      ;;
  esac
  printf -v "$__json" '%s' "$json"
}

build_inbound() {
  local __inbound=$1 __host=$2 __public_key=$3
  local choice protocol tag listen port public_host email uuid password method stream inbound_json user flow auth username generated_public_key=""
  choose choice "选择入站协议" \
    "VLESS" "VMess" "Trojan" "Shadowsocks" "SOCKS5" "HTTP"
  case $choice in
    1) protocol=vless;; 2) protocol=vmess;; 3) protocol=trojan;;
    4) protocol=shadowsocks;; 5) protocol=socks;; 6) protocol=http;;
  esac
  prompt_tag tag "${protocol}-$(random_hex 2)"
  prompt_value listen "监听地址" "0.0.0.0"
  prompt_port port 443
  prompt_public_host public_host

  case $protocol in
    vless|vmess|trojan)
      prompt_value email "首个用户名称/邮箱" "user-$(random_hex 2)"
      validate_email_label "$email" || die "用户名称无效。"
      build_stream_settings "$protocol" stream generated_public_key
      case $protocol in
        vless)
          uuid=$(generate_uuid)
          method=$(jq -r '.method' <<<"$stream")
          if [[ $method == raw && $(jq -r '.security' <<<"$stream") != none ]]; then flow=xtls-rprx-vision; else flow=""; fi
          user=$(jq -n --arg id "$uuid" --arg email "$email" --arg flow "$flow" '{id:$id,email:$email,level:0} + (if $flow!="" then {flow:$flow} else {} end)')
          inbound_json=$(jq -n --arg tag "$tag" --arg listen "$listen" --argjson port "$port" --argjson user "$user" --argjson stream "$stream" \
            '{tag:$tag,listen:$listen,port:$port,protocol:"vless",settings:{clients:[$user],decryption:"none"},streamSettings:$stream,sniffing:{enabled:true,destOverride:["http","tls","quic"],routeOnly:true}}')
          ;;
        vmess)
          uuid=$(generate_uuid)
          user=$(jq -n --arg id "$uuid" --arg email "$email" '{id:$id,alterId:0,email:$email,level:0}')
          inbound_json=$(jq -n --arg tag "$tag" --arg listen "$listen" --argjson port "$port" --argjson user "$user" --argjson stream "$stream" \
            '{tag:$tag,listen:$listen,port:$port,protocol:"vmess",settings:{clients:[$user]},streamSettings:$stream,sniffing:{enabled:true,destOverride:["http","tls","quic"],routeOnly:true}}')
          ;;
        trojan)
          prompt_secret password "Trojan 密码" "$(random_password)"
          user=$(jq -n --arg password "$password" --arg email "$email" '{password:$password,email:$email,level:0}')
          inbound_json=$(jq -n --arg tag "$tag" --arg listen "$listen" --argjson port "$port" --argjson user "$user" --argjson stream "$stream" \
            '{tag:$tag,listen:$listen,port:$port,protocol:"trojan",settings:{clients:[$user]},streamSettings:$stream,sniffing:{enabled:true,destOverride:["http","tls","quic"],routeOnly:true}}')
          ;;
      esac
      ;;
    shadowsocks)
      choose method "选择加密方式" "chacha20-poly1305" "aes-256-gcm" "aes-128-gcm"
      case $method in 1) method=chacha20-poly1305;; 2) method=aes-256-gcm;; 3) method=aes-128-gcm;; esac
      prompt_secret password "Shadowsocks 密码" "$(random_password)"
      inbound_json=$(jq -n --arg tag "$tag" --arg listen "$listen" --argjson port "$port" --arg method "$method" --arg password "$password" \
        '{tag:$tag,listen:$listen,port:$port,protocol:"shadowsocks",settings:{method:$method,password:$password,network:"tcp,udp"},sniffing:{enabled:true,destOverride:["http","tls","quic"],routeOnly:true}}')
      ;;
    socks)
      choose auth "SOCKS5 认证" "用户名密码" "无认证"
      if [[ $auth == 1 ]]; then
        prompt_value username "用户名" "user"; prompt_secret password "密码" "$(random_password)"
        inbound_json=$(jq -n --arg tag "$tag" --arg listen "$listen" --argjson port "$port" --arg user "$username" --arg pass "$password" \
          '{tag:$tag,listen:$listen,port:$port,protocol:"socks",settings:{auth:"password",accounts:[{user:$user,pass:$pass}],udp:true,ip:"0.0.0.0"}}')
      else
        [[ $listen == 127.0.0.1 || $listen == ::1 ]] || warn "公网监听的无认证 SOCKS5 风险极高。"
        inbound_json=$(jq -n --arg tag "$tag" --arg listen "$listen" --argjson port "$port" \
          '{tag:$tag,listen:$listen,port:$port,protocol:"socks",settings:{auth:"noauth",udp:true,ip:"0.0.0.0"}}')
      fi
      ;;
    http)
      prompt_value username "用户名" "user"; prompt_secret password "密码" "$(random_password)"
      inbound_json=$(jq -n --arg tag "$tag" --arg listen "$listen" --argjson port "$port" --arg user "$username" --arg pass "$password" \
        '{tag:$tag,listen:$listen,port:$port,protocol:"http",settings:{accounts:[{user:$user,pass:$pass}],allowTransparent:false}}')
      ;;
  esac
  printf -v "$__inbound" '%s' "$inbound_json"
  printf -v "$__host" '%s' "$public_host"
  printf -v "$__public_key" '%s' "$generated_public_key"
}

add_inbound() {
  ensure_runtime_dependencies inbound-add; require_xray_installed; ensure_config
  local inbound="" host="" public_key="" tag tmp listen_port
  build_inbound inbound host public_key
  tag=$(jq -r '.tag' <<<"$inbound"); listen_port=$(jq -r '.port' <<<"$inbound")
  tmp=$(temp_file)
  jq --argjson inbound "$inbound" '.inbounds += [$inbound]' "$CONFIG_FILE" >"$tmp"
  if apply_candidate "$tmp"; then
    meta_set_inbound "$tag" "$host" "$public_key" replace
    open_firewall_for_port "$listen_port" prompt
    heading "节点已创建"
    show_inbound "$tag"
    print_links "$tag" "" || true
  fi
  rm -f "$tmp"
}

list_inbounds() {
  ensure_config
  local count
  count=$(jq '.inbounds|length' "$CONFIG_FILE")
  if ((count == 0)); then info "还没有入站节点。"; return; fi
  printf '%-4s %-24s %-14s %-10s %-14s %-12s %s\n' "序号" "标签" "协议" "端口" "传输" "安全" "监听"
  jq -r '.inbounds | to_entries[] |
    [(.key+1),.value.tag,.value.protocol,(.value.port|tostring),(.value.streamSettings.method // "raw"),(.value.streamSettings.security // "none"),(.value.listen // "0.0.0.0")] | @tsv' "$CONFIG_FILE" \
    | while IFS=$'\t' read -r n tag protocol port method security listen; do
        printf '%-4s %-22s %-12s %-8s %-12s %-10s %s\n' "$n" "$tag" "$protocol" "$port" "$method" "$security" "$listen"
      done
}

show_inbound() {
  local tag=$1
  inbound_exists "$tag" || die "找不到节点：$tag"
  jq --arg tag "$tag" '.inbounds[] | select(.tag==$tag)' "$CONFIG_FILE"
}

select_inbound() {
  local __var=$1 protocols=${2-} entries count answer selected_tag
  local tags=()
  ensure_config
  if [[ -n $protocols ]]; then
    entries=$(jq -r --arg re "$protocols" '.inbounds[] | select(.protocol|test($re)) | .tag' "$CONFIG_FILE")
  else entries=$(jq -r '.inbounds[].tag' "$CONFIG_FILE"); fi
  count=$(grep -c . <<<"$entries" || true)
  ((count > 0)) || { warn "没有可选节点。"; return 1; }
  while IFS= read -r selected_tag; do [[ -z $selected_tag ]] || tags+=("$selected_tag"); done <<<"$entries"
  if ((count == 1)); then
    printf -v "$__var" '%s' "${tags[0]}"
    return 0
  fi
  choose answer "选择节点" "${tags[@]}"
  selected_tag=${tags[$((answer-1))]}
  printf -v "$__var" '%s' "$selected_tag"
}

modify_inbound_basic() {
  ensure_runtime_dependencies inbound-modify; ensure_config
  local tag=${1-} current listen port host tmp old_port
  [[ -n $tag ]] || select_inbound tag || return
  inbound_exists "$tag" || die "找不到节点：$tag"
  current=$(jq --arg tag "$tag" '.inbounds[]|select(.tag==$tag)' "$CONFIG_FILE")
  old_port=$(jq -r '.port' <<<"$current")
  prompt_value listen "监听地址" "$(jq -r '.listen // "0.0.0.0"' <<<"$current")"
  prompt_port port "$old_port" "$tag"
  prompt_public_host host "$(jq -r --arg tag "$tag" '.inbounds[$tag].host // empty' "$META_FILE")"
  tmp=$(temp_file)
  jq --arg tag "$tag" --arg listen "$listen" --argjson port "$port" \
    '(.inbounds[]|select(.tag==$tag)) |= (.listen=$listen | .port=$port)' "$CONFIG_FILE" >"$tmp"
  if apply_candidate "$tmp"; then
    meta_set_inbound "$tag" "$host" "" keep
    open_firewall_for_port "$port" prompt
  fi
  rm -f "$tmp"
}

modify_inbound_transport() {
  ensure_runtime_dependencies inbound-transport; require_xray_installed; ensure_config
  local tag=${1-} protocol stream public_key="" tmp host method security
  [[ -n $tag ]] || select_inbound tag '^(vless|vmess|trojan)$' || return
  inbound_exists "$tag" || die "找不到节点：$tag"
  protocol=$(jq -r --arg tag "$tag" '.inbounds[]|select(.tag==$tag)|.protocol' "$CONFIG_FILE")
  [[ $protocol =~ ^(vless|vmess|trojan)$ ]] || die "${protocol} 节点没有可修改的流式传输。"
  warn "修改传输后，所有客户端都要同步更新配置。"
  confirm "为 ${tag} 重新选择传输和安全方式？" N || return 0
  build_stream_settings "$protocol" stream public_key
  method=$(jq -r '.method' <<<"$stream"); security=$(jq -r '.security' <<<"$stream")
  tmp=$(temp_file)
  jq --arg tag "$tag" --argjson stream "$stream" --arg method "$method" --arg security "$security" '
    (.inbounds[]|select(.tag==$tag)|.streamSettings)=$stream |
    if (.inbounds[]|select(.tag==$tag)|.protocol)=="vless" then
      (.inbounds[]|select(.tag==$tag)|.settings.clients) |= map(
        if $method=="raw" and $security!="none" then .flow="xtls-rprx-vision" else del(.flow) end
      )
    else . end' "$CONFIG_FILE" >"$tmp"
  if apply_candidate "$tmp"; then
    host=$(public_host_for_tag "$tag")
    meta_set_inbound "$tag" "$host" "$public_key" replace
    info "传输已更新，请重新导出客户端分享链接。"
  fi
  rm -f "$tmp"
}

delete_inbound() {
  ensure_runtime_dependencies inbound-delete; ensure_config
  local tag=${1-} assume_yes=${2:-0} tmp port
  [[ -n $tag ]] || select_inbound tag || return
  inbound_exists "$tag" || die "找不到节点：$tag"
  port=$(jq -r --arg tag "$tag" '.inbounds[]|select(.tag==$tag)|.port' "$CONFIG_FILE")
  [[ $assume_yes == 1 ]] || confirm "删除节点 ${tag}？" N || return 0
  tmp=$(temp_file)
  jq --arg tag "$tag" '.inbounds |= map(select(.tag!=$tag))' "$CONFIG_FILE" >"$tmp"
  if apply_candidate "$tmp"; then meta_delete_inbound "$tag"; info "已删除节点 ${tag}。端口 ${port} 的防火墙规则未自动关闭，以免影响其他服务。"; fi
  rm -f "$tmp"
}

edit_config() {
  ensure_runtime_dependencies config-edit; ensure_config
  local editor=${EDITOR:-vi} tmp
  tmp=$(temp_file); cp "$CONFIG_FILE" "$tmp"
  "$editor" "$tmp"
  if cmp -s "$tmp" "$CONFIG_FILE"; then info "配置未更改。"; else apply_candidate "$tmp"; fi
  rm -f "$tmp"
}

check_config() {
  ensure_config
  if validate_candidate "$CONFIG_FILE"; then info "配置检查通过。"; else return 1; fi
}

set_log_level() {
  ensure_runtime_dependencies config-loglevel; ensure_config
  local choice level tmp
  choose choice "日志级别" "warning" "info" "error" "debug" "none"
  case $choice in 1) level=warning;; 2) level=info;; 3) level=error;; 4) level=debug;; 5) level=none;; esac
  tmp=$(temp_file); jq --arg level "$level" '.log.loglevel=$level' "$CONFIG_FILE" >"$tmp"
  apply_candidate "$tmp"; rm -f "$tmp"
}

client_array_path() {
  local protocol=$1
  case $protocol in vless|vmess|trojan) printf '.settings.clients';; socks|http) printf '.settings.accounts';; *) return 1;; esac
}

list_clients() {
  ensure_config
  local tag=${1-} protocol count
  [[ -n $tag ]] || select_inbound tag '^(vless|vmess|trojan|socks|http)$' || return
  protocol=$(jq -r --arg tag "$tag" '.inbounds[]|select(.tag==$tag)|.protocol' "$CONFIG_FILE")
  heading "${tag} 的用户"
  if [[ $protocol == socks || $protocol == http ]]; then
    count=$(jq --arg tag "$tag" '.inbounds[]|select(.tag==$tag)|(.settings.accounts // [])|length' "$CONFIG_FILE")
  else
    count=$(jq --arg tag "$tag" '.inbounds[]|select(.tag==$tag)|(.settings.clients // [])|length' "$CONFIG_FILE")
  fi
  if ((count == 0)); then info "还没有用户。"; return; fi
  printf '%-4s %-28s %s\n' "序号" "用户" "凭据"
  case $protocol in
    vless|vmess)
      jq -r --arg tag "$tag" '.inbounds[]|select(.tag==$tag)|.settings.clients|to_entries[]|[.key+1,(.value.email // "-"),.value.id]|@tsv' "$CONFIG_FILE" \
        | while IFS=$'\t' read -r number label credential; do printf '%-4s %-28s %s\n' "$number" "$label" "$credential"; done ;;
    trojan)
      jq -r --arg tag "$tag" '.inbounds[]|select(.tag==$tag)|.settings.clients|to_entries[]|[.key+1,(.value.email // "-")]|@tsv' "$CONFIG_FILE" \
        | while IFS=$'\t' read -r number label; do printf '%-4s %-28s %s\n' "$number" "$label" '********'; done ;;
    socks|http)
      jq -r --arg tag "$tag" '.inbounds[]|select(.tag==$tag)|.settings.accounts // []|to_entries[]|[.key+1,.value.user]|@tsv' "$CONFIG_FILE" \
        | while IFS=$'\t' read -r number label; do printf '%-4s %-28s %s\n' "$number" "$label" '********'; done ;;
    *) die "${protocol} 不支持独立多用户管理。";;
  esac
}

add_client() {
  ensure_runtime_dependencies client-add; require_xray_installed; ensure_config
  local tag=${1-} protocol label id password user tmp flow method security
  [[ -n $tag ]] || select_inbound tag '^(vless|vmess|trojan|socks|http)$' || return
  protocol=$(jq -r --arg tag "$tag" '.inbounds[]|select(.tag==$tag)|.protocol' "$CONFIG_FILE")
  prompt_value label "用户名称/邮箱" "user-$(random_hex 2)"
  validate_email_label "$label" || die "用户名称无效。"
  case $protocol in
    vless)
      id=$(generate_uuid)
      method=$(jq -r --arg tag "$tag" '.inbounds[]|select(.tag==$tag)|.streamSettings.method // "raw"' "$CONFIG_FILE")
      security=$(jq -r --arg tag "$tag" '.inbounds[]|select(.tag==$tag)|.streamSettings.security // "none"' "$CONFIG_FILE")
      [[ $method == raw && $security != none ]] && flow=xtls-rprx-vision || flow=""
      user=$(jq -n --arg id "$id" --arg email "$label" --arg flow "$flow" '{id:$id,email:$email,level:0}+(if $flow!="" then {flow:$flow} else {} end)')
      ;;
    vmess) id=$(generate_uuid); user=$(jq -n --arg id "$id" --arg email "$label" '{id:$id,alterId:0,email:$email,level:0}') ;;
    trojan) prompt_secret password "密码" "$(random_password)"; user=$(jq -n --arg password "$password" --arg email "$label" '{password:$password,email:$email,level:0}') ;;
    socks|http) prompt_secret password "密码" "$(random_password)"; user=$(jq -n --arg user "$label" --arg pass "$password" '{user:$user,pass:$pass}') ;;
    *) die "${protocol} 不支持多用户。";;
  esac
  tmp=$(temp_file)
  if [[ $protocol == socks || $protocol == http ]]; then
    jq --arg tag "$tag" --argjson user "$user" '(.inbounds[]|select(.tag==$tag)|.settings.accounts) += [$user]' "$CONFIG_FILE" >"$tmp"
  else jq --arg tag "$tag" --argjson user "$user" '(.inbounds[]|select(.tag==$tag)|.settings.clients) += [$user]' "$CONFIG_FILE" >"$tmp"; fi
  if apply_candidate "$tmp"; then info "用户 ${label} 已添加。"; print_links "$tag" "$label" || true; fi
  rm -f "$tmp"
}

delete_client() {
  ensure_runtime_dependencies client-delete; ensure_config
  local tag=${1-} label=${2-} assume_yes=${3:-0} protocol tmp count
  [[ -n $tag ]] || select_inbound tag '^(vless|vmess|trojan|socks|http)$' || return
  protocol=$(jq -r --arg tag "$tag" '.inbounds[]|select(.tag==$tag)|.protocol' "$CONFIG_FILE")
  if [[ -z $label ]]; then list_clients "$tag"; prompt_value label "要删除的用户名称/邮箱"; fi
  [[ $assume_yes == 1 ]] || confirm "从 ${tag} 删除用户 ${label}？" N || return 0
  tmp=$(temp_file)
  if [[ $protocol == socks || $protocol == http ]]; then
    count=$(jq --arg tag "$tag" --arg label "$label" '[.inbounds[]|select(.tag==$tag)|.settings.accounts[]|select(.user==$label)]|length' "$CONFIG_FILE")
    ((count > 0)) || die "找不到用户：$label"
    jq --arg tag "$tag" --arg label "$label" '(.inbounds[]|select(.tag==$tag)|.settings.accounts) |= map(select(.user!=$label))' "$CONFIG_FILE" >"$tmp"
  else
    count=$(jq --arg tag "$tag" --arg label "$label" '[.inbounds[]|select(.tag==$tag)|.settings.clients[]|select(.email==$label)]|length' "$CONFIG_FILE")
    ((count > 0)) || die "找不到用户：$label"
    jq --arg tag "$tag" --arg label "$label" '(.inbounds[]|select(.tag==$tag)|.settings.clients) |= map(select(.email!=$label))' "$CONFIG_FILE" >"$tmp"
  fi
  apply_candidate "$tmp"; rm -f "$tmp"
}

rotate_client_credential() {
  ensure_runtime_dependencies client-rotate; ensure_config
  local tag=${1-} label=${2-} protocol value tmp
  [[ -n $tag ]] || select_inbound tag '^(vless|vmess|trojan|socks|http)$' || return
  [[ -n $label ]] || { list_clients "$tag"; prompt_value label "要重置凭据的用户名称/邮箱"; }
  protocol=$(jq -r --arg tag "$tag" '.inbounds[]|select(.tag==$tag)|.protocol' "$CONFIG_FILE")
  confirm "旧凭据会立即失效，继续吗？" N || return 0
  tmp=$(temp_file)
  case $protocol in
    vless|vmess)
      value=$(generate_uuid)
      jq --arg tag "$tag" --arg label "$label" --arg value "$value" '(.inbounds[]|select(.tag==$tag)|.settings.clients[]|select(.email==$label)|.id)=$value' "$CONFIG_FILE" >"$tmp" ;;
    trojan)
      value=$(random_password)
      jq --arg tag "$tag" --arg label "$label" --arg value "$value" '(.inbounds[]|select(.tag==$tag)|.settings.clients[]|select(.email==$label)|.password)=$value' "$CONFIG_FILE" >"$tmp" ;;
    socks|http)
      value=$(random_password)
      jq --arg tag "$tag" --arg label "$label" --arg value "$value" '(.inbounds[]|select(.tag==$tag)|.settings.accounts[]|select(.user==$label)|.pass)=$value' "$CONFIG_FILE" >"$tmp" ;;
    *) die "不支持此协议。";;
  esac
  apply_candidate "$tmp"; rm -f "$tmp"
  info "新凭据：$value"
}

rename_client() {
  ensure_runtime_dependencies client-rename; require_xray_installed; ensure_config
  local tag=${1-} old_label=${2-} new_label=${3-} protocol count tmp
  [[ -n $tag ]] || select_inbound tag '^(vless|vmess|trojan|socks|http)$' || return
  [[ -n $old_label ]] || { list_clients "$tag"; prompt_value old_label "当前用户名称/邮箱"; }
  [[ -n $new_label ]] || prompt_value new_label "新的用户名称/邮箱"
  validate_email_label "$new_label" || die "新用户名称无效。"
  protocol=$(jq -r --arg tag "$tag" '.inbounds[]|select(.tag==$tag)|.protocol' "$CONFIG_FILE")
  tmp=$(temp_file)
  if [[ $protocol == socks || $protocol == http ]]; then
    count=$(jq --arg tag "$tag" --arg label "$old_label" '[.inbounds[]|select(.tag==$tag)|.settings.accounts[]|select(.user==$label)]|length' "$CONFIG_FILE")
    ((count > 0)) || { rm -f "$tmp"; die "找不到用户：$old_label"; }
    jq --arg tag "$tag" --arg old "$old_label" --arg new "$new_label" '(.inbounds[]|select(.tag==$tag)|.settings.accounts[]|select(.user==$old)|.user)=$new' "$CONFIG_FILE" >"$tmp"
  else
    count=$(jq --arg tag "$tag" --arg label "$old_label" '[.inbounds[]|select(.tag==$tag)|.settings.clients[]|select(.email==$label)]|length' "$CONFIG_FILE")
    ((count > 0)) || { rm -f "$tmp"; die "找不到用户：$old_label"; }
    jq --arg tag "$tag" --arg old "$old_label" --arg new "$new_label" '(.inbounds[]|select(.tag==$tag)|.settings.clients[]|select(.email==$old)|.email)=$new' "$CONFIG_FILE" >"$tmp"
  fi
  apply_candidate "$tmp"; rm -f "$tmp"
  info "用户已重命名：${old_label} -> ${new_label}"
}

public_host_for_tag() {
  local tag=$1 host
  host=$(jq -r --arg tag "$tag" '.inbounds[$tag].host // empty' "$META_FILE" 2>/dev/null || true)
  if [[ -z $host ]]; then
    if [[ -n ${XRAYCTL_PUBLIC_HOST:-} ]]; then host=$XRAYCTL_PUBLIC_HOST;
    elif [[ -t 0 ]]; then prompt_public_host host;
    else die "缺少公网地址。请先运行 xrayctl inbound modify ${tag}，或设置 XRAYCTL_PUBLIC_HOST。"; fi
  fi
  printf '%s' "$host"
}

reality_public_key() {
  local tag=$1 private output public
  public=$(jq -r --arg tag "$tag" '.inbounds[$tag].realityPublicKey // empty' "$META_FILE" 2>/dev/null || true)
  if [[ -z $public ]]; then
    private=$(jq -r --arg tag "$tag" '.inbounds[]|select(.tag==$tag)|.streamSettings.realitySettings.privateKey // empty' "$CONFIG_FILE")
    [[ -n $private ]] || return 1
    output=$("$XRAY_BIN" x25519 -i "$private" 2>/dev/null)
    public=$(awk -F': *' 'tolower($1) ~ /(public|password)/ {print $2; exit}' <<<"$output")
  fi
  [[ -n $public ]] || return 1
  printf '%s' "$public"
}

share_separator() { printf '%s\n' '------------------------------------------------------------------------'; }

print_share_entry() {
  local label=$1 field=$2 value=$3
  share_separator
  printf '用户: %s\n%s:\n%s\n' "$label" "$field" "$value"
}

link_query_for_stream() {
  local tag=$1 protocol=$2 stream method security query="" path service sni sid pbk flow
  stream=$(jq --arg tag "$tag" '.inbounds[]|select(.tag==$tag)|.streamSettings // {method:"raw",security:"none"}' "$CONFIG_FILE")
  method=$(jq -r '.method // "raw"' <<<"$stream"); security=$(jq -r '.security // "none"' <<<"$stream")
  case $method in
    raw) query="type=tcp" ;;
    websocket) path=$(jq -r '.wsSettings.path // "/"' <<<"$stream"); query="type=ws&path=$(url_encode "$path")" ;;
    grpc) service=$(jq -r '.grpcSettings.serviceName // ""' <<<"$stream"); query="type=grpc&serviceName=$(url_encode "$service")&mode=gun" ;;
    xhttp) path=$(jq -r '.xhttpSettings.path // "/"' <<<"$stream"); query="type=xhttp&path=$(url_encode "$path")&mode=auto" ;;
    *) query="type=$(url_encode "$method")" ;;
  esac
  query+="&security=$(url_encode "$security")"
  case $security in
    tls)
      sni=$(public_host_for_tag "$tag")
      query+="&sni=$(url_encode "$sni")"
      [[ $method == websocket ]] && query+="&host=$(url_encode "$sni")"
      [[ $method == grpc ]] && query+="&authority=$(url_encode "$sni")"
      query+="&fp=chrome"
      ;;
    reality)
      sni=$(jq -r '.realitySettings.serverNames[0]' <<<"$stream")
      sid=$(jq -r '.realitySettings.shortIds[0]' <<<"$stream")
      pbk=$(reality_public_key "$tag") || die "无法获得 REALITY 公钥。"
      query+="&sni=$(url_encode "$sni")&fp=chrome&pbk=$(url_encode "$pbk")&sid=$(url_encode "$sid")&spx=%2F"
      ;;
  esac
  if [[ $protocol == vless ]]; then
    flow=$(jq -r --arg tag "$tag" '.inbounds[]|select(.tag==$tag)|.settings.clients[0].flow // empty' "$CONFIG_FILE")
    [[ -n $flow ]] && query+="&flow=$(url_encode "$flow")"
  fi
  printf '%s' "$query"
}

print_links() {
  ensure_config; init_meta
  local tag=${1-} filter=${2-} protocol host uri_host port query label id password method vmess_net payload link
  [[ -n $tag ]] || select_inbound tag || return
  inbound_exists "$tag" || die "找不到节点：$tag"
  protocol=$(jq -r --arg tag "$tag" '.inbounds[]|select(.tag==$tag)|.protocol' "$CONFIG_FILE")
  host=$(public_host_for_tag "$tag"); uri_host=$host
  [[ $uri_host == *:* && $uri_host != \[*\] ]] && uri_host="[${uri_host}]"
  port=$(jq -r --arg tag "$tag" '.inbounds[]|select(.tag==$tag)|.port' "$CONFIG_FILE")
  heading "${tag} 分享信息"
  case $protocol in
    vless|trojan)
      query=$(link_query_for_stream "$tag" "$protocol")
      while IFS=$'\t' read -r label id; do
        [[ -z $filter || $label == "$filter" ]] || continue
        [[ $protocol == vless ]] && link="vless://${id}@${uri_host}:${port}?${query}#$(url_encode "${tag}-${label}")" \
          || link="trojan://${id}@${uri_host}:${port}?${query}#$(url_encode "${tag}-${label}")"
        print_share_entry "$label" "链接" "$link"
      done < <(jq -r --arg tag "$tag" --arg protocol "$protocol" '.inbounds[]|select(.tag==$tag)|.settings.clients[]|[.email,(if $protocol=="vless" then .id else .password end)]|@tsv' "$CONFIG_FILE")
      ;;
    vmess)
      method=$(jq -r --arg tag "$tag" '.inbounds[]|select(.tag==$tag)|.streamSettings.method // "raw"' "$CONFIG_FILE")
      case $method in raw) vmess_net=tcp;; websocket) vmess_net=ws;; *) vmess_net=$method;; esac
      while IFS=$'\t' read -r label id; do
        [[ -z $filter || $label == "$filter" ]] || continue
        payload=$(jq -nc --arg ps "${tag}-${label}" --arg add "$host" --arg port "$port" --arg id "$id" --arg net "$vmess_net" \
          --arg type "none" --arg host "$([[ $method == websocket ]] && printf '%s' "$host" || true)" \
          --arg path "$(jq -r --arg tag "$tag" '.inbounds[]|select(.tag==$tag)|(.streamSettings.wsSettings.path // .streamSettings.xhttpSettings.path // .streamSettings.grpcSettings.serviceName // "")' "$CONFIG_FILE")" \
          --arg tls "$(jq -r --arg tag "$tag" '.inbounds[]|select(.tag==$tag)|if .streamSettings.security=="tls" then "tls" elif .streamSettings.security=="reality" then "reality" else "" end' "$CONFIG_FILE")" \
          '{v:"2",ps:$ps,add:$add,port:$port,id:$id,aid:"0",scy:"auto",net:$net,type:$type,host:$host,path:$path,tls:$tls,sni:$add,alpn:""}')
        link="vmess://$(printf '%s' "$payload" | base64_nowrap)"
        print_share_entry "$label" "链接" "$link"
      done < <(jq -r --arg tag "$tag" '.inbounds[]|select(.tag==$tag)|.settings.clients[]|[.email,.id]|@tsv' "$CONFIG_FILE")
      ;;
    shadowsocks)
      method=$(jq -r --arg tag "$tag" '.inbounds[]|select(.tag==$tag)|.settings.method' "$CONFIG_FILE")
      password=$(jq -r --arg tag "$tag" '.inbounds[]|select(.tag==$tag)|.settings.password' "$CONFIG_FILE")
      link="ss://$(printf '%s' "${method}:${password}" | base64_urlsafe)@${uri_host}:${port}#$(url_encode "$tag")"
      print_share_entry "default" "链接" "$link"
      ;;
    socks)
      if [[ $(jq -r --arg tag "$tag" '.inbounds[]|select(.tag==$tag)|.settings.auth' "$CONFIG_FILE") == password ]]; then
        while IFS=$'\t' read -r label password; do
          print_share_entry "$label" "配置" "SOCKS5  ${uri_host}:${port}  用户: ${label}  密码: ${password}"
        done < <(jq -r --arg tag "$tag" '.inbounds[]|select(.tag==$tag)|.settings.accounts[]|[.user,.pass]|@tsv' "$CONFIG_FILE")
      else
        print_share_entry "无认证" "配置" "SOCKS5  ${uri_host}:${port}"
      fi
      ;;
    http)
      while IFS=$'\t' read -r label password; do
        print_share_entry "$label" "配置" "HTTP  ${uri_host}:${port}  用户: ${label}  密码: ${password}"
      done < <(jq -r --arg tag "$tag" '.inbounds[]|select(.tag==$tag)|.settings.accounts[]|[.user,.pass]|@tsv' "$CONFIG_FILE")
      ;;
  esac
  share_separator
}

print_subscription() {
  ensure_config; init_meta
  local tag=${1-} links current_tag
  if [[ -n $tag ]]; then
    links=$(print_links "$tag" "" | grep -E '^(vless|vmess|trojan|ss)://' || true)
  else
    links=""
    while IFS= read -r current_tag; do
      links+="$(print_links "$current_tag" "" | grep -E '^(vless|vmess|trojan|ss)://' || true)"$'\n'
    done < <(jq -r '.inbounds[]|select(.protocol|test("^(vless|vmess|trojan|shadowsocks)$"))|.tag' "$CONFIG_FILE")
    links=${links%$'\n'}
  fi
  [[ -n $links ]] || die "没有可生成订阅的代理分享链接。"
  printf '%s' "$links" | base64_nowrap
  printf '\n'
}

install_firewall() {
  ensure_runtime_dependencies firewall-install
  local manager ssh_port=${XRAYCTL_SSH_PORT:-}
  if ! command_exists ufw && ! command_exists firewall-cmd; then
    manager=$(pkg_manager) || { error "无法识别包管理器。"; return 0; }
    case $manager in
      apt)
        DEBIAN_FRONTEND=noninteractive apt_get_guarded update -y || true
        DEBIAN_FRONTEND=noninteractive apt_get_guarded install -y ufw || { error "UFW 安装失败。"; return 0; }
        ;;
      dnf) dnf install -y firewalld || { error "firewalld 安装失败。"; return 0; } ;;
      yum) yum install -y firewalld || { error "firewalld 安装失败。"; return 0; } ;;
      pacman) pacman -Sy --noconfirm ufw || { error "UFW 安装失败。"; return 0; } ;;
      zypper) zypper --non-interactive install firewalld || { error "firewalld 安装失败。"; return 0; } ;;
    esac
  fi
  if command_exists ufw; then
    if ufw status 2>/dev/null | grep -q '^Status: active'; then info "UFW 已安装并启用。"; return; fi
    info "UFW 已安装。"
    [[ -t 0 ]] && confirm "启用 UFW？" N || return 0
    [[ -n $ssh_port ]] || ssh_port=$(awk '{print $4}' <<<"${SSH_CONNECTION:-}" 2>/dev/null || true)
    validate_port "${ssh_port:-}" || ssh_port=22
    ufw allow "${ssh_port}/tcp" >/dev/null
    if ufw --force enable >/dev/null; then info "UFW 已启用；SSH ${ssh_port}/tcp 已放行。";
    else error "UFW 启用失败，当前主机可能缺少 NET_ADMIN 权限。"; fi
  elif command_exists firewall-cmd; then
    if firewall-cmd --state >/dev/null 2>&1; then info "firewalld 已安装并启用。"; return; fi
    info "firewalld 已安装。"
    [[ -t 0 ]] && confirm "启用 firewalld？" N || return 0
    if systemctl enable --now firewalld; then
      [[ -n $ssh_port ]] || ssh_port=$(awk '{print $4}' <<<"${SSH_CONNECTION:-}" 2>/dev/null || true)
      validate_port "${ssh_port:-}" || ssh_port=22
      firewall-cmd --permanent --add-port="${ssh_port}/tcp" >/dev/null
      firewall-cmd --reload >/dev/null
      info "firewalld 已启用；SSH ${ssh_port}/tcp 已放行。"
    else error "firewalld 启用失败，当前主机可能缺少 NET_ADMIN 权限。"; fi
  fi
}

open_firewall_for_port() {
  local port=$1 mode=${2:-force}
  validate_port "$port" || die "无效端口：$port"
  if [[ $mode == prompt ]] && ! confirm "是否自动放行 TCP/UDP 端口 ${port}？" Y; then return 0; fi
  if command_exists ufw && ufw status 2>/dev/null | grep -q '^Status: active'; then
    ufw allow "${port}/tcp" >/dev/null; ufw allow "${port}/udp" >/dev/null
    info "UFW 已放行 TCP/UDP ${port}。"
  elif command_exists firewall-cmd && firewall-cmd --state >/dev/null 2>&1; then
    firewall-cmd --permanent --add-port="${port}/tcp" >/dev/null
    firewall-cmd --permanent --add-port="${port}/udp" >/dev/null
    firewall-cmd --reload >/dev/null; info "firewalld 已放行 TCP/UDP ${port}。"
  else
    warn "未检测到启用的 UFW/firewalld。请在云安全组和系统防火墙手动放行 ${port}。"
  fi
}

close_firewall_for_port() {
  local port=$1
  validate_port "$port" || die "无效端口：$port"
  confirm "关闭 TCP/UDP ${port} 的防火墙规则？请确认没有其他服务使用。" N || return
  if command_exists ufw && ufw status 2>/dev/null | grep -q '^Status: active'; then
    ufw delete allow "${port}/tcp" >/dev/null || true; ufw delete allow "${port}/udp" >/dev/null || true
  elif command_exists firewall-cmd && firewall-cmd --state >/dev/null 2>&1; then
    firewall-cmd --permanent --remove-port="${port}/tcp" >/dev/null || true
    firewall-cmd --permanent --remove-port="${port}/udp" >/dev/null || true; firewall-cmd --reload >/dev/null
  else warn "未检测到启用的 UFW/firewalld。"; return; fi
  info "防火墙规则已关闭。"
}

certbot_supports_ip() {
  command_exists certbot && certbot --help all 2>/dev/null | grep -q -- '--ip-address'
}

setup_certbot_renewal_timer() {
  local certbot_path
  certbot_path=$(command -v certbot) || return 1
  cat >/etc/systemd/system/xrayctl-certbot-renew.service <<EOF
[Unit]
Description=Renew certificates managed by xrayctl

[Service]
Type=oneshot
ExecStart=${certbot_path} renew --quiet
EOF
  cat >/etc/systemd/system/xrayctl-certbot-renew.timer <<'EOF'
[Unit]
Description=Renew certificates managed by xrayctl

[Timer]
OnCalendar=*-*-* 00,12:00:00
RandomizedDelaySec=1h
Persistent=true

[Install]
WantedBy=timers.target
EOF
  systemctl daemon-reload
  systemctl enable --now xrayctl-certbot-renew.timer >/dev/null
}

install_certbot_ip_support() {
  local manager venv_dir=/opt/xrayctl/certbot
  manager=$(pkg_manager) || die "无法安装支持 IP 证书的 Certbot。"
  if ! command_exists python3 || ! python3 -m venv --help >/dev/null 2>&1; then
    info "安装 Python venv。"
    case $manager in
      apt)
        DEBIAN_FRONTEND=noninteractive apt_get_guarded update -y || true
        DEBIAN_FRONTEND=noninteractive apt_get_guarded install -y python3 python3-venv ;;
      dnf) dnf install -y python3 python3-pip ;;
      yum) yum install -y python3 python3-pip ;;
      pacman) pacman -Sy --noconfirm python python-pip ;;
      zypper) zypper --non-interactive install python3 python3-pip ;;
    esac
  fi
  install -d -m 755 "$(dirname "$venv_dir")"
  if ! python3 -m venv "$venv_dir" >/dev/null 2>&1; then
    case $manager in
      apt) DEBIAN_FRONTEND=noninteractive apt_get_guarded install -y python3-venv ;;
      dnf|yum) "$manager" install -y python3-pip ;;
      pacman) pacman -Sy --noconfirm python-pip ;;
      zypper) zypper --non-interactive install python3-pip ;;
    esac
    python3 -m venv "$venv_dir" || die "无法创建 Certbot Python 环境。"
  fi
  "$venv_dir/bin/pip" install --disable-pip-version-check --upgrade 'certbot>=5.4' \
    || die "新版 Certbot 安装失败。"
  if [[ -e /usr/local/bin/certbot && ! -L /usr/local/bin/certbot ]]; then
    die "/usr/local/bin/certbot 已存在且不是符号链接。"
  fi
  ln -sfn "$venv_dir/bin/certbot" /usr/local/bin/certbot
  hash -r
  certbot_supports_ip || die "当前 Certbot 不支持 IP 证书。"
  setup_certbot_renewal_timer
}

install_certbot() {
  local mode=${1:-domain} manager
  if command_exists certbot && { [[ $mode != ip ]] || certbot_supports_ip; }; then return 0; fi
  if [[ $mode == ip ]]; then install_certbot_ip_support; return; fi
  manager=$(pkg_manager) || die "无法自动安装 certbot。"
  info "安装 certbot。"
  case $manager in
    apt)
      DEBIAN_FRONTEND=noninteractive apt_get_guarded update -y \
        || warn "APT 软件索引更新失败或超时，尝试使用现有索引。"
      DEBIAN_FRONTEND=noninteractive apt_get_guarded install -y certbot \
        || die "certbot 安装失败，请检查 APT 软件源。"
      ;;
    dnf) dnf install -y certbot ;;
    yum) yum install -y epel-release; yum install -y certbot ;;
    pacman) pacman -Sy --noconfirm certbot ;;
    zypper) zypper --non-interactive install certbot ;;
  esac
}

write_certbot_deploy_hook() {
  local domain=$1 hook_dir=/etc/letsencrypt/renewal-hooks/deploy hook
  hook="${hook_dir}/xrayctl-${domain}"
  mkdir -p "$hook_dir"
  cat >"$hook" <<EOF
#!/usr/bin/env bash
set -Eeuo pipefail
install -m 640 -o "${RUNTIME_OWNER}" -g "${RUNTIME_GROUP}" "/etc/letsencrypt/live/${domain}/fullchain.pem" "${CERT_DIR}/${domain}.crt"
install -m 640 -o "${RUNTIME_OWNER}" -g "${RUNTIME_GROUP}" "/etc/letsencrypt/live/${domain}/privkey.pem" "${CERT_DIR}/${domain}.key"
systemctl try-restart "${SERVICE_NAME}.service"
EOF
  chmod 750 "$hook"
}

apply_certificate_to_inbound() {
  local identifier=$1 cert_path=$2 key_path=$3 tag tmp method
  select_inbound tag '^(vless|vmess|trojan)$' || return
  method=$(jq -r --arg tag "$tag" '.inbounds[]|select(.tag==$tag)|.streamSettings.method // "raw"' "$CONFIG_FILE")
  tmp=$(temp_file)
  jq --arg tag "$tag" --arg cert "$cert_path" --arg key "$key_path" --arg method "$method" '
    (.inbounds[]|select(.tag==$tag)|.streamSettings) |= (
      .security="tls" |
      del(.realitySettings) |
      .tlsSettings={
        alpn:(if $method=="websocket" then ["http/1.1"] else ["h2","http/1.1"] end),
        minVersion:"1.2",
        certificates:[{certificateFile:$cert,keyFile:$key}]
      }
    ) |
    if (.inbounds[]|select(.tag==$tag)|.protocol)=="vless" then
      (.inbounds[]|select(.tag==$tag)|.settings.clients) |= map(
        if $method=="raw" then .flow="xtls-rprx-vision" else del(.flow) end
      )
    else . end' "$CONFIG_FILE" >"$tmp"
  if apply_candidate "$tmp"; then
    meta_set_inbound "$tag" "$identifier" "" replace
    info "证书已应用：${tag}"
  fi
  rm -f "$tmp"
}

issue_certificate() {
  ensure_runtime_dependencies cert-issue
  local domain=${1-} email=${2-} was_active=0 paths cert_path key_path default_domain="" mode=domain
  if [[ -z $domain ]]; then
    default_domain=$(detect_public_ip || true)
    prompt_value domain "证书域名/IP" "$default_domain"
  fi
  if validate_ip_literal "$domain"; then mode=ip;
  elif ! validate_domain "$domain"; then die "证书域名/IP 无效。"; fi
  [[ -n $email ]] || prompt_value email "Let's Encrypt 联系邮箱"
  [[ $email == *@*.* ]] || die "邮箱格式无效。"
  install_certbot "$mode"
  open_firewall_for_port 80 prompt
  service_is_active && { was_active=1; systemctl stop "$SERVICE_NAME"; CERT_STOPPED_SERVICE=1; }
  local certbot_args=(certonly --standalone --non-interactive --agree-tos --preferred-challenges http -m "$email")
  if [[ $mode == ip ]]; then
    certbot_args+=(--preferred-profile shortlived --ip-address "$domain")
  else
    certbot_args+=(-d "$domain")
  fi
  if ! certbot "${certbot_args[@]}"; then
    if ((was_active)); then systemctl start "$SERVICE_NAME" || true; CERT_STOPPED_SERVICE=0; fi
    die "证书签发失败；确认 ${domain} 的 TCP 80 可从公网访问。"
  fi
  paths=$(copy_certificate_pair "$domain" "/etc/letsencrypt/live/${domain}/fullchain.pem" "/etc/letsencrypt/live/${domain}/privkey.pem")
  cert_path=$(head -n1 <<<"$paths"); key_path=$(tail -n1 <<<"$paths")
  write_certbot_deploy_hook "$domain"
  [[ $mode != ip ]] || setup_certbot_renewal_timer
  if ((was_active)); then systemctl start "$SERVICE_NAME"; CERT_STOPPED_SERVICE=0; fi
  info "证书已保存：${cert_path}"
  if [[ -t 0 ]] && confirm "应用到现有节点？" N; then
    apply_certificate_to_inbound "$domain" "$cert_path" "$key_path"
  fi
}

import_certificate() {
  ensure_runtime_dependencies cert-import
  local domain=${1-} cert=${2-} key=${3-} paths
  [[ -n $domain ]] || prompt_value domain "证书标识/域名"
  [[ $domain =~ ^[A-Za-z0-9.-]+$ ]] || die "证书标识无效。"
  [[ -n $cert ]] || prompt_value cert "证书文件路径"
  [[ -n $key ]] || prompt_value key "私钥文件路径"
  paths=$(copy_certificate_pair "$domain" "$cert" "$key")
  info "证书已导入：$(head -n1 <<<"$paths")"
}

list_certificates() {
  if [[ ! -d $CERT_DIR ]]; then info "还没有托管证书。"; return; fi
  local cert found=0
  for cert in "$CERT_DIR"/*.crt; do
    [[ -e $cert ]] || continue
    found=1
    printf '%s\n' "$(basename "$cert")"
    openssl x509 -in "$cert" -noout -subject -issuer -dates 2>/dev/null | sed 's/^/  /'
  done
  ((found)) || info "还没有托管证书。"
}

certificate_count() {
  local cert count=0
  for cert in "$CERT_DIR"/*.crt; do [[ -e $cert ]] && ((count+=1)); done
  printf '%s' "$count"
}

select_managed_certificate() {
  local __var=$1 cert answer identifier
  local identifiers=()
  for cert in "$CERT_DIR"/*.crt; do
    [[ -e $cert ]] || continue
    identifier=$(basename "$cert" .crt)
    [[ -r "${CERT_DIR}/${identifier}.key" ]] && identifiers+=("$identifier")
  done
  ((${#identifiers[@]} > 0)) || { warn "没有可用的托管证书。"; return 1; }
  if ((${#identifiers[@]} == 1)); then
    printf -v "$__var" '%s' "${identifiers[0]}"
    return 0
  fi
  choose answer "选择证书" "${identifiers[@]}"
  printf -v "$__var" '%s' "${identifiers[$((answer-1))]}"
}

apply_managed_certificate() {
  local identifier
  select_managed_certificate identifier || return
  apply_certificate_to_inbound "$identifier" "${CERT_DIR}/${identifier}.crt" "${CERT_DIR}/${identifier}.key"
}

backup_all() {
  require_root backup; ensure_config
  local target=${1:-${BACKUP_DIR}/xrayctl-$(timestamp).tar.gz}
  local paths=("${CONFIG_FILE#/}")
  mkdir -p "$BACKUP_DIR" "$(dirname "$target")"
  [[ ! -f $META_FILE ]] || paths+=("${META_FILE#/}")
  [[ ! -d $CERT_DIR ]] || paths+=("${CERT_DIR#/}")
  tar -czf "$target" -C / "${paths[@]}" 2>/dev/null || { rm -f "$target"; die "备份失败。"; }
  chmod 600 "$target"
  info "备份已创建：$target"
}

restore_backup() {
  ensure_runtime_dependencies restore; ensure_config
  local archive=${1-} temp extract_config current_backup
  [[ -n $archive ]] || prompt_value archive "备份文件路径"
  [[ -r $archive ]] || die "无法读取备份：$archive"
  tar -tzf "$archive" >/dev/null || die "不是有效的 tar.gz 备份。"
  if tar -tzf "$archive" | awk 'BEGIN{bad=0} /^\// || /(^|\/)\.\.($|\/)/ {bad=1} END{exit !bad}'; then
    die "备份包含不安全的路径。"
  fi
  extract_config="${CONFIG_FILE#/}"
  tar -tzf "$archive" | grep -Fxq "$extract_config" || die "备份中没有 ${extract_config}。"
  temp=$(mktemp -d "${TMPDIR:-/tmp}/xrayctl-restore.XXXXXX")
  tar -xzf "$archive" -C "$temp"
  if find "$temp" -type l -print -quit | grep -q .; then rm -rf "$temp"; die "备份中不允许包含符号链接。"; fi
  [[ -f "$temp/$extract_config" ]] || { rm -rf "$temp"; die "备份配置不是普通文件。"; }
  validate_candidate "$temp/$extract_config" || { rm -rf "$temp"; die "备份配置验证失败。"; }
  confirm "恢复会覆盖当前配置和托管证书，继续吗？" N || { rm -rf "$temp"; return; }
  current_backup=$(backup_config_quiet)
  cp -a "$temp/$extract_config" "$CONFIG_FILE"
  [[ ! -f "$temp/${META_FILE#/}" ]] || cp -a "$temp/${META_FILE#/}" "$META_FILE"
  if [[ -d "$temp/${CERT_DIR#/}" ]]; then setup_certificate_access; cp -a "$temp/${CERT_DIR#/}/." "$CERT_DIR/"; fi
  setup_runtime_access
  if ! restart_service; then
    install -m 640 -o "$RUNTIME_OWNER" -g "$RUNTIME_GROUP" "$current_backup" "$CONFIG_FILE"
    restart_service || true; rm -rf "$temp"; die "恢复后服务失败，已回滚配置。"
  fi
  rm -rf "$temp"; info "备份已恢复。"
}

show_status() {
  heading "Xray 状态"
  if xray_installed; then "$XRAY_BIN" version | sed -n '1,2p'; else printf 'Xray: 未安装\n'; fi
  if service_exists; then
    systemctl --no-pager --full status "$SERVICE_NAME" 2>/dev/null | sed -n '1,12p' || true
  else printf 'systemd 服务: 未安装\n'; fi
  [[ -f $CONFIG_FILE ]] && printf '节点数: %s\n配置: %s\n' "$(jq '.inbounds|length' "$CONFIG_FILE" 2>/dev/null || printf '?')" "$CONFIG_FILE"
}

service_action() {
  ensure_runtime_dependencies service
  local action=$1
  service_exists || die "Xray systemd 服务不存在。"
  case $action in
    start|stop|restart) systemctl "$action" "$SERVICE_NAME" ;;
    enable) systemctl enable --now "$SERVICE_NAME" ;;
    disable) systemctl disable --now "$SERVICE_NAME" ;;
    *) die "未知服务操作：$action";;
  esac
  info "服务操作完成：$action"
}

show_logs() {
  local lines=${1:-100}
  [[ $lines =~ ^[0-9]+$ ]] || die "日志行数必须是数字。"
  journalctl -u "$SERVICE_NAME" -n "$lines" --no-pager
}

enable_bbr() {
  ensure_runtime_dependencies bbr
  local available qdisc_enabled=0 config=/etc/sysctl.d/99-xrayctl-bbr.conf
  if [[ ! -r /proc/sys/net/ipv4/tcp_available_congestion_control || ! -e /proc/sys/net/ipv4/tcp_congestion_control ]]; then
    warn "当前内核未暴露 TCP 拥塞控制接口，无法在此容器内启用 BBR。"
    return 0
  fi
  command_exists modprobe && modprobe tcp_bbr >/dev/null 2>&1 || true
  available=$(< /proc/sys/net/ipv4/tcp_available_congestion_control)
  if [[ " $available " != *" bbr "* ]]; then
    warn "当前内核不支持 BBR：${available}"
    return 0
  fi
  if [[ -e /proc/sys/net/core/default_qdisc ]]; then
    if sysctl -w net.core.default_qdisc=fq >/dev/null 2>&1; then qdisc_enabled=1;
    else warn "无法设置 net.core.default_qdisc，跳过 fq。"; fi
  fi
  if ! sysctl -w net.ipv4.tcp_congestion_control=bbr >/dev/null 2>&1; then
    error "无法写入拥塞控制参数；当前容器可能缺少内核权限。"
    return 0
  fi
  if ((qdisc_enabled)); then
    printf '%s\n' 'net.core.default_qdisc=fq' 'net.ipv4.tcp_congestion_control=bbr' >"$config"
  else
    printf '%s\n' 'net.ipv4.tcp_congestion_control=bbr' >"$config"
  fi
  if [[ $(< /proc/sys/net/ipv4/tcp_congestion_control) != bbr ]]; then
    error "BBR 校验失败。"
    return 0
  fi
  info "BBR 已启用。"
}

system_diagnostics() {
  local os_name=unknown
  if [[ -r /etc/os-release ]]; then
    os_name=$(sed -n 's/^PRETTY_NAME=//p' /etc/os-release)
    os_name=${os_name#\"}; os_name=${os_name%\"}
  fi
  heading "系统诊断"
  printf '系统: %s\n内核: %s\n架构: %s\n时间: %s\n' "$os_name" "$(uname -r)" "$(uname -m)" "$(date -Is)"
  printf '拥塞控制: %s\n' "$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || printf unknown)"
  printf 'IPv4 转发: %s\n' "$(sysctl -n net.ipv4.ip_forward 2>/dev/null || printf unknown)"
  if command_exists timedatectl; then timedatectl show -p NTPSynchronized -p Timezone 2>/dev/null || true; fi
  if command_exists ss; then heading "Xray 监听端口"; ss -lntup 2>/dev/null | grep -E 'xray|State|Netid' || true; fi
  heading "最近服务日志"; journalctl -u "$SERVICE_NAME" -n 20 --no-pager 2>/dev/null || true
}

node_count_summary() {
  if command_exists jq && [[ -r $CONFIG_FILE ]]; then
    jq -r '.inbounds|length' "$CONFIG_FILE" 2>/dev/null || printf '?'
  else
    printf '0'
  fi
}

xray_version_summary() {
  local output first
  xray_installed || { printf '未安装'; return; }
  output=$("$XRAY_BIN" version 2>/dev/null || true)
  first=${output%%$'\n'*}
  if [[ $first =~ ^Xray[[:space:]]+([^[:space:]]+) ]]; then printf '%s' "${BASH_REMATCH[1]}"; else printf '已安装'; fi
}

service_state_summary() {
  if ! service_exists; then printf '未安装';
  elif service_is_active; then printf '运行中';
  else printf '已停止'; fi
}

startup_state_summary() {
  if ! service_exists; then printf '未安装';
  elif service_is_enabled; then printf '已开启';
  else printf '已关闭'; fi
}

show_main_summary() {
  printf '服务: %s  |  节点: %s  |  Xray: %s\n\n' \
    "$(service_state_summary)" "$(node_count_summary)" "$(xray_version_summary)"
}

show_node_summary() {
  local tag=$1 protocol port method security listen
  IFS=$'\t' read -r protocol port method security listen < <(
    jq -r --arg tag "$tag" '.inbounds[]|select(.tag==$tag)|[
      .protocol,(.port|tostring),(.streamSettings.method // "raw"),
      (.streamSettings.security // "none"),(.listen // "0.0.0.0")]|@tsv' "$CONFIG_FILE"
  )
  printf '协议: %s  |  端口: %s  |  传输: %s  |  安全: %s\n监听: %s\n\n' \
    "$protocol" "$port" "$method" "$security" "$listen"
}

client_menu_for_tag() {
  local tag=$1 choice
  while inbound_exists "$tag"; do
    clear_screen
    heading "用户管理 · ${tag}"
    list_clients "$tag"
    printf '\n1) 添加用户\n2) 重命名用户\n3) 重置用户凭据\n4) 删除用户\n0) 返回节点\n'
    read -r -p "请选择: " choice
    case $choice in
      1) add_client "$tag"; pause;; 2) rename_client "$tag"; pause;;
      3) rotate_client_credential "$tag"; pause;; 4) delete_client "$tag"; pause;;
      0) return;; *) warn "无效选项。"; pause;;
    esac
  done
}

manage_inbound_menu() {
  local tag=$1 choice protocol auth
  while inbound_exists "$tag"; do
    clear_screen
    protocol=$(jq -r --arg tag "$tag" '.inbounds[]|select(.tag==$tag)|.protocol' "$CONFIG_FILE")
    heading "节点 · ${tag}"
    show_node_summary "$tag"
    case $protocol in
      vless|vmess|trojan)
        printf '1) 分享信息\n2) 用户管理\n3) 修改地址/端口\n4) 修改传输/安全\n5) 查看 JSON\n6) 删除节点\n0) 返回列表\n'
        read -r -p "请选择: " choice
        case $choice in
          1) print_links "$tag"; pause;; 2) client_menu_for_tag "$tag";; 3) modify_inbound_basic "$tag"; pause;;
          4) modify_inbound_transport "$tag"; pause;; 5) show_inbound "$tag"; pause;;
          6) delete_inbound "$tag"; pause;; 0) return;; *) warn "无效选项。"; pause;;
        esac
        ;;
      http)
        printf '1) 客户端配置\n2) 用户管理\n3) 修改地址/端口\n4) 查看 JSON\n5) 删除节点\n0) 返回列表\n'
        read -r -p "请选择: " choice
        case $choice in
          1) print_links "$tag"; pause;; 2) client_menu_for_tag "$tag";; 3) modify_inbound_basic "$tag"; pause;;
          4) show_inbound "$tag"; pause;; 5) delete_inbound "$tag"; pause;;
          0) return;; *) warn "无效选项。"; pause;;
        esac
        ;;
      socks)
        auth=$(jq -r --arg tag "$tag" '.inbounds[]|select(.tag==$tag)|.settings.auth // "noauth"' "$CONFIG_FILE")
        printf '认证: %s\n\n' "$auth"
        if [[ $auth == password ]]; then
          printf '1) 客户端配置\n2) 用户管理\n3) 修改地址/端口\n4) 查看 JSON\n5) 删除节点\n0) 返回列表\n'
          read -r -p "请选择: " choice
          case $choice in
            1) print_links "$tag"; pause;; 2) client_menu_for_tag "$tag";; 3) modify_inbound_basic "$tag"; pause;;
            4) show_inbound "$tag"; pause;; 5) delete_inbound "$tag"; pause;;
            0) return;; *) warn "无效选项。"; pause;;
          esac
        else
          printf '1) 客户端配置\n2) 修改地址/端口\n3) 查看 JSON\n4) 删除节点\n0) 返回列表\n'
          read -r -p "请选择: " choice
          case $choice in
            1) print_links "$tag"; pause;; 2) modify_inbound_basic "$tag"; pause;;
            3) show_inbound "$tag"; pause;; 4) delete_inbound "$tag"; pause;;
            0) return;; *) warn "无效选项。"; pause;;
          esac
        fi
        ;;
      shadowsocks)
        printf '1) 分享信息\n2) 修改地址/端口\n3) 查看 JSON\n4) 删除节点\n0) 返回列表\n'
        read -r -p "请选择: " choice
        case $choice in
          1) print_links "$tag"; pause;; 2) modify_inbound_basic "$tag"; pause;;
          3) show_inbound "$tag"; pause;; 4) delete_inbound "$tag"; pause;;
          0) return;; *) warn "无效选项。"; pause;;
        esac
        ;;
      *) warn "不支持的节点协议：${protocol}"; return;;
    esac
  done
}

inbound_menu() {
  local choice tag
  while true; do
    clear_screen
    heading "节点管理"
    list_inbounds
    printf '\n1) 新增节点\n2) 管理已有节点\n3) 输出全部节点订阅\n4) 高级编辑完整配置\n0) 返回\n'
    read -r -p "请选择: " choice
    case $choice in
      1) add_inbound; pause;;
      2) select_inbound tag && manage_inbound_menu "$tag";;
      3) print_subscription; pause;; 4) edit_config; pause;;
      0) return;; *) warn "无效选项。"; pause;;
    esac
  done
}

certificate_menu() {
  local choice
  while true; do
    clear_screen
    heading "TLS 证书"
    printf '托管证书: %s\n\n' "$(certificate_count)"
    printf '1) Let\x27s Encrypt 自动签发\n2) 导入已有证书\n3) 应用证书到节点\n4) 查看托管证书\n5) 测试自动续期\n0) 返回\n'
    read -r -p "请选择: " choice
    case $choice in
      1) issue_certificate; pause;; 2) import_certificate; pause;; 3) apply_managed_certificate; pause;;
      4) list_certificates; pause;;
      5) ensure_runtime_dependencies cert-renew; install_certbot; certbot renew --dry-run; pause;;
      0) return;; *) warn "无效选项。"; pause;;
    esac
  done
}

toggle_service_running() {
  if service_is_active; then service_action stop; else service_action start; fi
}

toggle_service_startup() {
  ensure_runtime_dependencies service
  service_exists || die "Xray systemd 服务不存在。"
  if service_is_enabled; then
    systemctl disable "$SERVICE_NAME" >/dev/null
    info "开机自启已关闭；当前服务运行状态未改变。"
  else
    systemctl enable "$SERVICE_NAME" >/dev/null
    info "开机自启已开启。"
  fi
}

service_menu() {
  local choice
  while true; do
    clear_screen
    heading "服务管理"
    printf '状态: %s  |  开机自启: %s  |  Xray: %s\n\n' \
      "$(service_state_summary)" "$(startup_state_summary)" "$(xray_version_summary)"
    printf '1) 启动/停止\n2) 重启服务\n3) 开关开机自启\n4) 查看日志\n5) 安装/更新/修复 Xray\n0) 返回\n'
    read -r -p "请选择: " choice
    case $choice in
      1) toggle_service_running; pause;; 2) service_action restart; pause;;
      3) toggle_service_startup; pause;; 4) show_logs 100; pause;;
      5) install_or_update_xray install; pause;; 0) return;; *) warn "无效选项。"; pause;;
    esac
  done
}

firewall_state_summary() {
  if command_exists ufw; then
    if ufw status 2>/dev/null | grep -q '^Status: active'; then printf 'UFW 运行中'; else printf 'UFW 未启用'; fi
  elif command_exists firewall-cmd; then
    if firewall-cmd --state >/dev/null 2>&1; then printf 'firewalld 运行中'; else printf 'firewalld 未启用'; fi
  else
    printf '未安装'
  fi
}

firewall_menu() {
  local choice port
  while true; do
    clear_screen
    heading "防火墙"
    printf '状态: %s\n\n' "$(firewall_state_summary)"
    printf '1) 安装/启用\n2) 放行端口\n3) 关闭端口\n0) 返回\n'
    read -r -p "请选择: " choice
    case $choice in
      1) install_firewall; pause;;
      2) prompt_value port "端口"; ensure_runtime_dependencies firewall; open_firewall_for_port "$port" force; pause;;
      3) prompt_value port "端口"; ensure_runtime_dependencies firewall; close_firewall_for_port "$port"; pause;;
      0) return;; *) warn "无效选项。"; pause;;
    esac
  done
}

bbr_state_summary() {
  if [[ -r /proc/sys/net/ipv4/tcp_congestion_control ]]; then
    if [[ $(< /proc/sys/net/ipv4/tcp_congestion_control) == bbr ]]; then printf '已启用'; else printf '未启用'; fi
  else
    printf '不可用'
  fi
}

system_menu() {
  local choice
  while true; do
    clear_screen
    heading "系统工具"
    printf 'BBR: %s  |  防火墙: %s\n\n' "$(bbr_state_summary)" "$(firewall_state_summary)"
    printf '1) 防火墙管理\n2) 启用 BBR\n3) 系统诊断\n4) 修复快捷命令\n0) 返回\n'
    read -r -p "请选择: " choice
    case $choice in
      1) firewall_menu;; 2) enable_bbr; pause;; 3) system_diagnostics; pause;;
      4) ensure_runtime_dependencies quick-command; install_quick_command; pause;;
      0) return;; *) warn "无效选项。"; pause;;
    esac
  done
}

uninstall_menu() {
  local choice
  while true; do
    clear_screen
    heading "卸载"
    printf '1) 卸载 Xray（保留配置）\n2) 彻底卸载\n0) 返回\n'
    read -r -p "请选择: " choice
    case $choice in
      1) uninstall_xray 0; pause;; 2) uninstall_xray 1; pause;;
      0) return;; *) warn "无效选项。"; pause;;
    esac
  done
}

main_menu() {
  local choice
  while true; do
    clear_screen
    printf '%sXray Linux 管理脚本%s  v%s\n' "$C_BOLD$C_BLUE" "$C_RESET" "$XRAYCTL_VERSION"
    show_main_summary
    printf '1) 节点管理\n2) TLS 证书\n3) 服务管理\n4) 系统工具\n5) 卸载\n0) 退出\n'
    read -r -p "请选择: " choice
    case $choice in
      1) inbound_menu;; 2) certificate_menu;; 3) service_menu;;
      4) system_menu;; 5) uninstall_menu;;
      0) return;; *) warn "无效选项。"; pause;;
    esac
  done
}

show_help() {
  cat <<'EOF'
xrayctl - Xray Linux 管理脚本

用法:
  xrayctl                         打开交互菜单
  xrayctl install [版本]          安装/修复（版本示例: 25.6.8）
  xrayctl update [版本]           升级 Xray
  xrayctl uninstall [--purge]     卸载；--purge 删除 Xray 配置
  xrayctl status                  查看状态
  xrayctl start|stop|restart      服务控制
  xrayctl logs [行数]             查看 systemd 日志
  xrayctl inbound list            列出节点
  xrayctl inbound add             交互新增节点
  xrayctl inbound show <标签>     查看节点 JSON
  xrayctl inbound modify <标签>   修改监听端口/地址
  xrayctl inbound transport <标签> 修改传输与安全方式
  xrayctl inbound delete <标签> [--yes]
  xrayctl client list [标签]
  xrayctl client add [标签]
  xrayctl client rename [标签] [旧名称] [新名称]
  xrayctl client rotate [标签] [用户]
  xrayctl client delete [标签] [用户] [--yes]
  xrayctl link [标签] [用户]      输出分享链接
  xrayctl subscription [标签]     输出 Base64 订阅内容
  xrayctl config check|show|edit
  xrayctl backup [文件.tar.gz]
  xrayctl restore [文件.tar.gz]
  xrayctl cert list
  xrayctl cert issue [域名] [邮箱]
  xrayctl cert import [标识] [证书] [私钥]
  xrayctl firewall install|open|close [端口]
  xrayctl bbr                     启用 BBR
  xrayctl diagnose                系统诊断
  xrayctl version

支持协议: VLESS、VMess、Trojan、Shadowsocks、SOCKS5、HTTP
支持传输: RAW、XHTTP、WebSocket、gRPC；支持 TLS 和 REALITY。
EOF
}

dispatch() {
  local command=${1:-menu}; shift || true
  case $command in
    menu) main_menu;;
    help|-h|--help) show_help;;
    version|-v|--version) printf 'xrayctl %s\n' "$XRAYCTL_VERSION";;
    install) install_or_update_xray install "${1-}";;
    update|upgrade) install_or_update_xray upgrade "${1-}";;
    uninstall) if [[ ${1-} == --purge ]]; then uninstall_xray 1; else uninstall_xray 0; fi;;
    status) show_status;;
    start|stop|restart|enable|disable) service_action "$command";;
    logs) show_logs "${1:-100}";;
    inbound)
      case ${1:-list} in
        list) ensure_config; list_inbounds;; add) add_inbound;; show) ensure_config; show_inbound "${2:?请提供节点标签}";;
        modify|edit) modify_inbound_basic "${2-}";; transport|stream) modify_inbound_transport "${2-}";;
        delete|remove) delete_inbound "${2-}" "$([[ ${3-} == --yes ]] && printf 1 || printf 0)";;
        *) die "未知 inbound 子命令：${1}";; esac;;
    client)
      case ${1:-list} in
        list) ensure_config; list_clients "${2-}";; add) add_client "${2-}";; rename) rename_client "${2-}" "${3-}" "${4-}";;
        rotate|reset) rotate_client_credential "${2-}" "${3-}";;
        delete|remove) delete_client "${2-}" "${3-}" "$([[ ${4-} == --yes ]] && printf 1 || printf 0)";;
        *) die "未知 client 子命令：${1}";; esac;;
    link|links|share) ensure_config; print_links "${1-}" "${2-}";;
    subscription|subscribe|sub) ensure_config; print_subscription "${1-}";;
    config)
      case ${1:-check} in check|test) check_config;; show) ensure_config; jq . "$CONFIG_FILE";; edit) edit_config;; *) die "未知 config 子命令。";; esac;;
    backup) backup_all "${1-}";; restore) restore_backup "${1-}";;
    cert)
      case ${1:-list} in list) list_certificates;; issue) issue_certificate "${2-}" "${3-}";; import) import_certificate "${2-}" "${3-}" "${4-}";; renew) ensure_runtime_dependencies cert-renew; install_certbot; certbot renew;; *) die "未知 cert 子命令。";; esac;;
    firewall)
      case ${1-} in install) install_firewall;; open) ensure_runtime_dependencies firewall; open_firewall_for_port "${2:?请提供端口}" force;; close) ensure_runtime_dependencies firewall; close_firewall_for_port "${2:?请提供端口}";; *) die "用法: xrayctl firewall install|open|close [端口]";; esac;;
    bbr) enable_bbr;; diagnose|doctor) system_diagnostics;; quick-command) ensure_runtime_dependencies quick-command; install_quick_command;;
    *) error "未知命令：$command"; show_help; return 2;;
  esac
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
  dispatch "$@"
fi
