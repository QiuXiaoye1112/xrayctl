#!/usr/bin/env bash
# xrayctl - Xray Alpine Linux terminal manager
# Alpine/OpenRC edition. Kept separate from the systemd edition.

set -Eeuo pipefail
IFS=$'\n\t'

readonly XRAYCTL_VERSION="1.0.19-alpine"
readonly XRAY_RELEASE_API="https://api.github.com/repos/XTLS/Xray-core/releases/latest"
readonly XRAY_RELEASE_BASE="https://github.com/XTLS/Xray-core/releases/download"
readonly SCRIPT_DOWNLOAD_URL="${XRAYCTL_SCRIPT_URL:-https://raw.githubusercontent.com/QiuXiaoye1112/xrayctl/main/alpine/xrayctl.sh}"
readonly JQ_VERSION="1.8.2"

XRAY_BIN="${XRAYCTL_XRAY_BIN:-/usr/local/bin/xray}"
CONFIG_DIR="${XRAYCTL_CONFIG_DIR:-/usr/local/etc/xray}"
CONFIG_FILE="${XRAYCTL_CONFIG_FILE:-${CONFIG_DIR}/config.json}"
META_FILE="${XRAYCTL_META_FILE:-${CONFIG_DIR}/xrayctl.meta.json}"
CERT_DIR="${XRAYCTL_CERT_DIR:-${CONFIG_DIR}/certs}"
LOG_DIR="${XRAYCTL_LOG_DIR:-/var/log/xray}"
XRAY_SHARE_DIR="${XRAYCTL_SHARE_DIR:-/usr/local/share/xray}"
export XRAY_LOCATION_ASSET="$XRAY_SHARE_DIR"
CERTBOT_VENV="${XRAYCTL_CERTBOT_VENV:-/opt/xrayctl-alpine/certbot}"
CERTBOT_COMMAND="${XRAYCTL_CERTBOT_COMMAND:-/usr/local/bin/certbot}"
CERT_RENEW_HOOK="${XRAYCTL_CERT_RENEW_HOOK:-/etc/periodic/daily/xrayctl-certbot-renew}"
CF_CREDENTIALS_FILE="${XRAYCTL_CF_CREDENTIALS:-/etc/letsencrypt/cloudflare.ini}"
BACKUP_DIR="${XRAYCTL_BACKUP_DIR:-/var/backups/xrayctl}"
QUICK_COMMAND="${XRAYCTL_COMMAND_PATH:-/usr/local/sbin/xrayctl}"
QUICK_SYMLINK="${XRAYCTL_SYMLINK_PATH:-/usr/local/bin/xrayctl}"
SERVICE_NAME="${XRAYCTL_SERVICE_NAME:-xray}"
OPENRC_SERVICE="${XRAYCTL_OPENRC_SERVICE:-/etc/init.d/${SERVICE_NAME}}"
RUNTIME_OWNER="${XRAYCTL_RUNTIME_OWNER:-root}"
RUNTIME_USER="${XRAYCTL_RUNTIME_USER:-xray}"
RUNTIME_GROUP="${XRAYCTL_RUNTIME_GROUP:-xray}"
LOCK_FILE="${XRAYCTL_LOCK_FILE:-/run/lock/xrayctl.lock}"
JQ_INSTALL_PATH="${XRAYCTL_JQ_INSTALL_PATH:-/usr/local/bin/jq}"
CERT_STOPPED_SERVICE=0
APT_IPV4_AVAILABLE_CACHE=""

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
  if [[ ${CERT_STOPPED_SERVICE:-0} == 1 ]] && is_openrc; then
    rc-service "$SERVICE_NAME" start >/dev/null 2>&1 || true
  fi
}
trap cleanup_on_exit EXIT

is_root() { [[ $(id -u) -eq 0 ]]; }
require_root() { is_root || die "此操作需要 root 权限，请使用 sudo xrayctl $*."; }
command_exists() { command -v "$1" >/dev/null 2>&1; }
is_linux() { [[ $(uname -s) == "Linux" ]]; }
is_alpine() { [[ -r /etc/os-release ]] && grep -q '^ID=alpine$' /etc/os-release; }
is_openrc() { command_exists rc-service && command_exists rc-update; }

pause() {
  [[ -t 0 ]] || return 0
  read -r -p "按回车键继续..." _ || true
}

confirm() {
  local prompt=${1:-"确定继续吗？"} default=${2:-N} answer suffix
  if [[ $default == Y ]]; then suffix="[Y/n]"; else suffix="[y/N]"; fi
  if [[ ! -t 0 ]]; then [[ $default == Y ]]; return; fi
  read -r -p "${prompt} ${suffix} " answer || { echo; answer=${default}; }
  answer=${answer:-$default}
  [[ $answer =~ ^[Yy]$ ]]
}

prompt_value() {
  local __var=$1 prompt=$2 default=${3-} input_value
  while true; do
    if [[ -n $default ]]; then
      if ! read -r -p "${prompt} [${default}]: " input_value; then warn "输入已中断。"; return 1; fi
      input_value=${input_value:-$default}
    else
      if ! read -r -p "${prompt}: " input_value; then warn "输入已中断。"; return 1; fi
      if [[ -z $input_value ]]; then warn "此项不能为空，请重新输入。"; continue; fi
    fi
    printf -v "$__var" '%s' "$input_value"
    return 0
  done
}

prompt_optional_value() {
  local __var=$1 prompt=$2 input_value=""
  if ! read -r -p "${prompt}: " input_value; then warn "输入已中断。"; return 1; fi
  printf -v "$__var" '%s' "$input_value"
}

prompt_secret() {
  local __var=$1 prompt=$2 generated=${3-} secret_value=""
  if [[ -n $generated ]]; then
    if ! read -r -p "${prompt}（留空自动生成）: " secret_value; then warn "输入已中断。"; return 1; fi
    secret_value=${secret_value:-$generated}
  else
    while [[ -z $secret_value ]]; do
      if ! read -r -p "${prompt}: " secret_value; then warn "输入已中断。"; return 1; fi
      [[ -n $secret_value ]] || warn "密码不能为空，请重新输入。"
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
    read -r -p "请选择 [1-${#options[@]}]: " selected_value || { echo; return 1; }
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
validate_email_label() {
  [[ -n $1 && ${#1} -le 128 && $1 != *$'\n'* && $1 != *$'\r'* && $1 != *$'\t'* && $1 != *'>>>'* ]]
}
validate_email_address() { [[ $1 == *@*.* && $1 != *" "* ]]; }
validate_domain_or_ip() { validate_ip_literal "$1" || validate_domain "$1"; }
validate_certificate_identifier() { [[ $1 =~ ^[A-Za-z0-9.-]+$ ]]; }
validate_readable_file() { [[ -f $1 && -r $1 ]]; }
validate_proxy_address() { [[ -n $1 && $1 != *" "* ]]; }
validate_uuid() { [[ $1 =~ ^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$ ]]; }

validate_reality_target() {
  local value=$1 host port
  [[ $value == *:* ]] || return 1
  host=${value%:*}; port=${value##*:}
  [[ -n $host ]] && validate_port "$port"
}

prompt_validated_value() {
  local __var=$1 prompt=$2 default=$3 validator=$4 invalid_message=$5 validated_candidate
  while true; do
    prompt_value validated_candidate "$prompt" "$default" || return 1
    if "$validator" "$validated_candidate"; then printf -v "$__var" '%s' "$validated_candidate"; return 0; fi
    warn "$invalid_message"
  done
}

display_width() {
  local __var=$1 value=$2 char code computed_width=0 i
  for ((i=0; i<${#value}; i++)); do
    char=${value:i:1}
    printf -v code '%d' "'$char"
    if ((code < 0 || code > 127)); then ((computed_width+=2)); else ((computed_width+=1)); fi
  done
  printf -v "$__var" '%s' "$computed_width"
}

print_table_cell() {
  local value=$1 target_width=$2 width padding
  display_width width "$value"
  padding=$((target_width-width))
  ((padding > 0)) || padding=1
  printf '%s%*s' "$value" "$padding" ''
}

print_table_cell_clipped() {
  local value=$1 target_width=$2 width limit clipped="" used=0 char char_width i
  display_width width "$value"
  if ((width < target_width)); then print_table_cell "$value" "$target_width"; return; fi
  limit=$((target_width-4)); ((limit > 0)) || limit=1
  for ((i=0; i<${#value}; i++)); do
    char=${value:i:1}; display_width char_width "$char"
    ((used+char_width <= limit)) || break
    clipped+=$char; ((used+=char_width))
  done
  print_table_cell "${clipped}..." "$target_width"
}

run_menu_action() {
  local action_status
  set +e
  (
    set -Eeuo pipefail
    trap cleanup_on_exit EXIT
    "$@"
  )
  action_status=$?
  set -e
  if ((action_status != 0)); then
    warn "操作未完成，脚本仍在运行，请检查输入后重试。"
  fi
  return 0
}

validate_ipv4() {
  local value=$1 a b c d extra
  IFS=. read -r a b c d extra <<<"$value"
  [[ -z ${extra:-} && $a =~ ^[0-9]{1,3}$ && $b =~ ^[0-9]{1,3}$ && $c =~ ^[0-9]{1,3}$ && $d =~ ^[0-9]{1,3}$ ]] \
    && ((10#$a <= 255 && 10#$b <= 255 && 10#$c <= 255 && 10#$d <= 255))
}

validate_ip_literal() {
  validate_ipv4 "$1" || [[ $1 == *:* && $1 =~ ^[0-9A-Fa-f:]+$ && ${#1} -le 45 ]]
}

detect_public_ipv4() {
  local response raw
  command_exists curl || return 1
  response=$({ curl -4 --fail --silent --show-error --location --proto '=https' --tlsv1.2 \
    --connect-timeout 3 --max-time 5 https://api.ipify.org 2>/dev/null || true; } | tr -d '[:space:]')
  if validate_ipv4 "$response"; then printf '%s' "$response"; return 0; fi

  response=$({ curl -4 --fail --silent --show-error --location --proto '=https' --tlsv1.2 \
    --connect-timeout 3 --max-time 5 https://checkip.amazonaws.com 2>/dev/null || true; } | tr -d '[:space:]')
  if validate_ipv4 "$response"; then printf '%s' "$response"; return 0; fi

  raw=$(curl -4 --fail --silent --show-error --location --proto '=https' --tlsv1.2 \
    --connect-timeout 3 --max-time 5 https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null || true)
  response=$(awk -F= '$1=="ip" {print $2; exit}' <<<"$raw" | tr -d '[:space:]')
  if validate_ipv4 "$response"; then printf '%s' "$response"; return 0; fi
  return 1
}

detect_public_ipv6() {
  local response raw
  command_exists curl || return 1
  response=$({ curl -6 --fail --silent --show-error --location --proto '=https' --tlsv1.2 \
    --connect-timeout 3 --max-time 5 https://api6.ipify.org 2>/dev/null || true; } | tr -d '[:space:]')
  if validate_ip_literal "$response" && ! validate_ipv4 "$response"; then printf '%s' "$response"; return 0; fi

  raw=$(curl -6 --fail --silent --show-error --location --proto '=https' --tlsv1.2 \
    --connect-timeout 3 --max-time 5 https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null || true)
  response=$(awk -F= '$1=="ip" {print $2; exit}' <<<"$raw" | tr -d '[:space:]')
  if validate_ip_literal "$response" && ! validate_ipv4 "$response"; then printf '%s' "$response"; return 0; fi
  return 1
}

detect_public_ip() { detect_public_ipv4 || detect_public_ipv6; }

detect_local_ips() {
  local iface ip line
  if command_exists ip; then
    while IFS= read -r line; do
      iface=$(awk '{print $2}' <<<"$line")
      ip=$(awk '{print $4}' <<<"$line"); ip=${ip%/*}
      [[ $iface =~ ^(docker|br-|veth|virbr|lo|lxc|cali|flannel|cilium) ]] && continue
      validate_ipv4 "$ip" || continue
      [[ $ip =~ ^127\. ]] && continue
      printf '%s (IPv4)\t%s\t%s\n' "$ip" "$ip" "$iface"
    done < <(ip -o -4 addr show 2>/dev/null)
    while IFS= read -r line; do
      iface=$(awk '{print $2}' <<<"$line")
      ip=$(awk '{print $4}' <<<"$line"); ip=${ip%/*}
      ip=${ip%%%*}
      [[ $iface =~ ^(docker|br-|veth|virbr|lo|lxc|cali|flannel|cilium) ]] && continue
      [[ -z $ip || $ip == ::1 || $ip == fe80:* ]] && continue
      printf '%s (IPv6)\t%s\t%s\n' "$ip" "$ip" "$iface"
    done < <(ip -o -6 addr show 2>/dev/null)
  elif command_exists ifconfig; then
    while IFS= read -r line; do
      iface=$(awk '{print $1}' <<<"$line" | sed 's/:$//')
      ip=$(awk '{print $2}' <<<"$line")
      validate_ipv4 "$ip" || continue
      [[ $ip =~ ^127\. ]] && continue
      printf '%s (IPv4)\t%s\t%s\n' "$ip" "$ip" "$iface"
    done < <(ifconfig 2>/dev/null | grep 'inet ' | grep -v '127\.')
    while IFS= read -r line; do
      iface=$(awk '{print $1}' <<<"$line" | sed 's/:$//')
      ip=$(awk '{print $2}' <<<"$line")
      ip=${ip%%%*}
      [[ -z $ip || $ip == ::1 || $ip == fe80:* ]] && continue
      printf '%s (IPv6)\t%s\t%s\n' "$ip" "$ip" "$iface"
    done < <(ifconfig 2>/dev/null | grep 'inet6 ' | grep -v '::1\|fe80:')
  fi
}

_freedom_tag_for_ip() {
  local ip=$1
  printf 'local-%s' "$(printf '%s' "$ip" | tr ':.' '--')"
}

_ensure_freedom_outbound() {
  local ip=$1 tag tmp
  tag=$(_freedom_tag_for_ip "$ip")
  outbound_exists "$tag" && { printf '%s' "$tag"; return 0; }
  tmp=$(temp_file)
  jq --arg tag "$tag" --arg ip "$ip" \
    '.outbounds += [{tag:$tag,protocol:"freedom",sendThrough:$ip,settings:{domainStrategy:"UseIP"}}]' \
    "$CONFIG_FILE" >"$tmp"
  if apply_candidate "$tmp" >&2; then
    printf '%s' "$tag"
  else
    rm -f "$tmp"
    return 1
  fi
  rm -f "$tmp"
}

json_quote() { jq -Rn --arg value "$1" '$value'; }
url_encode() { jq -rn --arg value "$1" '$value|@uri'; }
base64_nowrap() { base64 | tr -d '\n'; }

random_hex() { openssl rand -hex "${1:-8}"; }
random_password() { openssl rand -base64 24 | tr -d '\n=+/' | cut -c1-24; }
generate_uuid() {
  if [[ -x $XRAY_BIN ]]; then "$XRAY_BIN" uuid 2>/dev/null | tail -n1; return; fi
  if command_exists uuidgen; then uuidgen | tr '[:upper:]' '[:lower:]'; return; fi
  local h; h=$(openssl rand -hex 16)
  printf '%s-%s-4%s-%x%s-%s\n' "${h:0:8}" "${h:8:4}" "${h:13:3}" "$(( (0x${h:16:1} & 3) | 8 ))" "${h:17:3}" "${h:20:12}"
}

ensure_alpine_openrc() {
  is_linux || die "仅支持 Linux；当前系统是 $(uname -s)。"
  is_alpine || die "此安装包仅支持 Alpine Linux。"
  is_openrc || die "需要 Alpine OpenRC；容器内请先确认 OpenRC 可以运行。"
}

pkg_manager() {
  command_exists apk && printf 'apk'
}

apt_get_guarded() {
  local total_timeout=${XRAYCTL_APT_TIMEOUT:-180}
  local apt_options=(
    -o Acquire::Retries=2
    -o Acquire::http::Timeout=15
    -o Acquire::https::Timeout=15
    -o Dpkg::Use-Pty=0
  )
  case ${XRAYCTL_APT_FORCE_IPV4:-auto} in
    1|true|yes) apt_options+=(-o Acquire::ForceIPv4=true) ;;
    0|false|no) ;;
    *)
      if [[ -z $APT_IPV4_AVAILABLE_CACHE ]]; then
        if detect_public_ipv4 >/dev/null; then APT_IPV4_AVAILABLE_CACHE=1; else APT_IPV4_AVAILABLE_CACHE=0; fi
      fi
      [[ $APT_IPV4_AVAILABLE_CACHE == 0 ]] || apt_options+=(-o Acquire::ForceIPv4=true)
      ;;
  esac
  if command_exists timeout; then
    timeout --foreground "${total_timeout}s" apt-get "${apt_options[@]}" "$@"
  else
    apt-get "${apt_options[@]}" "$@"
  fi
}

apt_package_index_available() {
  [[ -d /var/lib/apt/lists ]] &&
    find /var/lib/apt/lists -maxdepth 1 -type f -size +0c ! -name lock -print -quit 2>/dev/null | grep -q .
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
  info "正在安装 jq ${JQ_VERSION}。"
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
    apk) apk add --no-cache "${missing[@]}" ;;
  esac
}

acquire_lock() {
  mkdir -p "$(dirname "$LOCK_FILE")"
  if command_exists flock; then
    exec 9>"$LOCK_FILE"
    flock -n 9 || die "另一个 xrayctl 操作正在运行。"
  else
    local lock_dir="${LOCK_FILE}.d"
    mkdir "$lock_dir" 2>/dev/null || die "另一个 xrayctl 操作正在运行。"
    trap 'rmdir "'"$lock_dir"'" 2>/dev/null || true' EXIT HUP INT TERM
  fi
}

ensure_runtime_dependencies() {
  require_root "$@"
  ensure_alpine_openrc
  install_packages curl jq openssl
  acquire_lock
}

ensure_system_context() {
  require_root "$@"
  ensure_alpine_openrc
  acquire_lock
}

run_bounded() {
  local seconds=$1; shift
  if command_exists timeout; then timeout "${seconds}s" "$@"; else "$@"; fi
}

has_net_admin() {
  local cap
  [[ -r /proc/self/status ]] || return 0
  cap=$(awk '/^CapEff:/ {print $2; exit}' /proc/self/status)
  [[ -n $cap ]] || return 0
  cap=${cap: -8}
  (( (16#$cap & 0x1000) != 0 ))
}

init_meta() {
  mkdir -p "$CONFIG_DIR"
  if [[ ! -s $META_FILE ]] || ! jq -e 'type=="object" and (.inbounds|type=="object")' "$META_FILE" >/dev/null 2>&1; then
    printf '%s\n' '{"schema":1,"inbounds":{}}' >"$META_FILE"
    chmod 600 "$META_FILE"
  fi
}

write_default_config() {
  local tmp
  mkdir -p "$CONFIG_DIR" "$LOG_DIR"
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
  tmp=$(temp_file)
  jq --arg logDir "$LOG_DIR" '.log.access=($logDir+"/access.log") | .log.error=($logDir+"/error.log")' "$CONFIG_FILE" >"$tmp"
  install -m 640 "$tmp" "$CONFIG_FILE"
  rm -f "$tmp"
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

service_exists() { [[ -x $OPENRC_SERVICE ]]; }
service_is_active() { service_exists && rc-service "$SERVICE_NAME" status >/dev/null 2>&1; }
service_is_enabled() { rc-update show default 2>/dev/null | grep -Eq "[[:space:]]${SERVICE_NAME}([[:space:]]|$)"; }

restart_service() {
  if service_exists; then
    if service_is_active; then
      rc-service "$SERVICE_NAME" restart
    else
      rc-service "$SERVICE_NAME" zap >/dev/null 2>&1 || true
      rm -f "/run/${SERVICE_NAME}.pid"
      rc-service "$SERVICE_NAME" start
    fi
    if ! service_is_active; then
      tail -n 20 "${LOG_DIR}/openrc-error.log" >&2 2>/dev/null || true
      return 1
    fi
  fi
}

apply_candidate() {
  local candidate=$1 rollback="" old_active=0
  ensure_config
  validate_candidate "$candidate" || return 1
  service_is_active && old_active=1
  setup_runtime_access
  rollback=$(temp_file)
  cp -p "$CONFIG_FILE" "$rollback"
  if ! install -m 640 -o "$RUNTIME_OWNER" -g "$RUNTIME_GROUP" "$candidate" "$CONFIG_FILE"; then
    rm -f "$rollback"
    return 1
  fi
  if ((old_active)) && ! restart_service; then
    error "重启失败，正在回滚配置。"
    if [[ -f $rollback ]]; then
      install -m 640 -o "$RUNTIME_OWNER" -g "$RUNTIME_GROUP" "$rollback" "$CONFIG_FILE"
      restart_service || true
    fi
    rm -f "$rollback"
    return 1
  fi
  rm -f "$rollback"
  info "配置已应用。"
}

temp_file() { mktemp "${TMPDIR:-/tmp}/xrayctl.XXXXXX"; }

meta_set_inbound() {
  local tag=$1 host=$2 tmp
  init_meta; tmp=$(temp_file)
  jq --arg tag "$tag" --arg host "$host" --arg now "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
    '.inbounds[$tag] = ((.inbounds[$tag] // {}) + {host:$host,managed:true,updatedAt:$now}) |
     del(.inbounds[$tag].realityPublicKey)' \
    "$META_FILE" >"$tmp"
  install -m 600 "$tmp" "$META_FILE"; rm -f "$tmp"
}

meta_delete_inbound() {
  local tag=$1 tmp; init_meta; tmp=$(temp_file)
  jq --arg tag "$tag" 'del(.inbounds[$tag])' "$META_FILE" >"$tmp"
  install -m 600 "$tmp" "$META_FILE"; rm -f "$tmp"
}

meta_rename_inbound() {
  local old_tag=$1 new_tag=$2 tmp
  init_meta; tmp=$(temp_file)
  jq --arg old "$old_tag" --arg new "$new_tag" --arg now "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" '
    if .inbounds[$old] then
      .inbounds[$new]=(.inbounds[$old] + {updatedAt:$now}) | del(.inbounds[$old])
    else . end' \
    "$META_FILE" >"$tmp"
  install -m 600 "$tmp" "$META_FILE"; rm -f "$tmp"
}

get_service_user() {
  printf '%s' "$RUNTIME_USER"
}

setup_runtime_access() {
  grep -qE "^${RUNTIME_GROUP}:" /etc/group 2>/dev/null || addgroup -S "$RUNTIME_GROUP"
  id "$RUNTIME_USER" >/dev/null 2>&1 || adduser -S -D -H -s /sbin/nologin -G "$RUNTIME_GROUP" "$RUNTIME_USER"
  install -d -m 750 -o "$RUNTIME_OWNER" -g "$RUNTIME_GROUP" "$CONFIG_DIR"
  install -d -m 750 -o "$RUNTIME_OWNER" -g "$RUNTIME_GROUP" "$CERT_DIR"
  install -d -m 750 -o "$RUNTIME_USER" -g "$RUNTIME_GROUP" "$LOG_DIR"
  touch "${LOG_DIR}/access.log" "${LOG_DIR}/error.log" "${LOG_DIR}/openrc.log" "${LOG_DIR}/openrc-error.log"
  chown "$RUNTIME_USER:$RUNTIME_GROUP" "${LOG_DIR}/access.log" "${LOG_DIR}/error.log" \
    "${LOG_DIR}/openrc.log" "${LOG_DIR}/openrc-error.log"
  chmod 640 "${LOG_DIR}/access.log" "${LOG_DIR}/error.log" "${LOG_DIR}/openrc.log" "${LOG_DIR}/openrc-error.log"
  if [[ -f $CONFIG_FILE ]]; then
    chown "$RUNTIME_OWNER:$RUNTIME_GROUP" "$CONFIG_FILE"
    chmod 640 "$CONFIG_FILE"
  fi
}

setup_certificate_access() { setup_runtime_access; }

xray_release_asset() {
  case $(uname -m) in
    x86_64|amd64) printf 'Xray-linux-64.zip' ;;
    aarch64|arm64) printf 'Xray-linux-arm64-v8a.zip' ;;
    armv7l|armv7|armhf) printf 'Xray-linux-arm32-v7a.zip' ;;
    *) die "暂不支持此 Alpine 架构：$(uname -m)" ;;
  esac
}

write_openrc_service() {
  cat >"$OPENRC_SERVICE" <<EOF
#!/sbin/openrc-run
name="Xray"
description="Xray Service managed by xrayctl Alpine edition"
command="${XRAY_BIN}"
command_args="run -config ${CONFIG_FILE}"
command_user="${RUNTIME_USER}:${RUNTIME_GROUP}"
command_background=true
pidfile="/run/${SERVICE_NAME}.pid"
output_log="${LOG_DIR}/openrc.log"
error_log="${LOG_DIR}/openrc-error.log"
export XRAY_LOCATION_ASSET="${XRAY_SHARE_DIR}"

depend() {
  need net
  after firewall
}

start_pre() {
  checkpath --directory --mode 0750 --owner ${RUNTIME_USER}:${RUNTIME_GROUP} "${LOG_DIR}"
  "${XRAY_BIN}" run -test -format json -config "${CONFIG_FILE}"
  checkpath --file --mode 0640 --owner ${RUNTIME_USER}:${RUNTIME_GROUP} "${LOG_DIR}/access.log"
  checkpath --file --mode 0640 --owner ${RUNTIME_USER}:${RUNTIME_GROUP} "${LOG_DIR}/error.log"
  checkpath --file --mode 0640 --owner ${RUNTIME_USER}:${RUNTIME_GROUP} "${LOG_DIR}/openrc.log"
  checkpath --file --mode 0640 --owner ${RUNTIME_USER}:${RUNTIME_GROUP} "${LOG_DIR}/openrc-error.log"
}
EOF
  chmod 755 "$OPENRC_SERVICE"
}

install_xray_core() {
  local requested=${1-} version asset base archive digest expected actual work
  install_packages unzip
  asset=$(xray_release_asset)
  if [[ -n $requested ]]; then
    version="v${requested#v}"
  else
    version=$(curl --fail --silent --show-error --location --proto '=https' --tlsv1.2 \
      --connect-timeout 15 --max-time 60 "$XRAY_RELEASE_API" | jq -r '.tag_name // empty')
    [[ $version == v* ]] || die "无法获取 Xray 最新版本。"
  fi
  base="${XRAY_RELEASE_BASE}/${version}"
  work=$(mktemp -d "${TMPDIR:-/tmp}/xrayctl-alpine.XXXXXX")
  archive="${work}/${asset}"; digest="${archive}.dgst"
  info "正在下载 Xray ${version}。"
  curl --fail --location --proto '=https' --tlsv1.2 --retry 3 --connect-timeout 15 --max-time 180 \
    "${base}/${asset}" -o "$archive" || { find "$work" -mindepth 1 -delete; rmdir "$work"; die "Xray 下载失败。"; }
  curl --fail --silent --show-error --location --proto '=https' --tlsv1.2 --retry 3 --connect-timeout 15 --max-time 60 \
    "${base}/${asset}.dgst" -o "$digest" || { find "$work" -mindepth 1 -delete; rmdir "$work"; die "Xray 校验文件下载失败。"; }
  expected=$(awk -F'= ' '$1=="SHA2-256" {print $2; exit}' "$digest")
  actual=$(sha256sum "$archive" | awk '{print $1}')
  [[ -n $expected && $actual == "$expected" ]] \
    || { find "$work" -mindepth 1 -delete; rmdir "$work"; die "Xray SHA-256 校验失败。"; }
  unzip -q "$archive" -d "$work/unpacked"
  install -d -m 755 "$(dirname "$XRAY_BIN")" "$XRAY_SHARE_DIR"
  install -m 755 "$work/unpacked/xray" "$XRAY_BIN"
  install -m 644 "$work/unpacked/geoip.dat" "${XRAY_SHARE_DIR}/geoip.dat"
  install -m 644 "$work/unpacked/geosite.dat" "${XRAY_SHARE_DIR}/geosite.dat"
  find "$work" -mindepth 1 -delete; rmdir "$work"
}

copy_certificate_pair() {
  local domain=$1 cert_source=$2 key_source=$3 cert_target key_target
  [[ -r $cert_source ]] || die "无法读取证书：$cert_source"
  [[ -r $key_source ]] || die "无法读取私钥：$key_source"
  validate_certificate_pair_files "$cert_source" "$key_source" || die "证书或私钥无效。"
  setup_certificate_access
  cert_target="${CERT_DIR}/${domain}.crt"; key_target="${CERT_DIR}/${domain}.key"
  install -m 640 -o "$RUNTIME_OWNER" -g "$RUNTIME_GROUP" "$cert_source" "$cert_target"
  install -m 640 -o "$RUNTIME_OWNER" -g "$RUNTIME_GROUP" "$key_source" "$key_target"
  printf '%s\n%s\n' "$cert_target" "$key_target"
}

install_or_update_xray() {
  ensure_runtime_dependencies install
  local mode=${1:-install} version=${2:-} installed_before=0
  xray_installed && installed_before=1
  install_xray_core "$version"
  [[ -x $XRAY_BIN ]] || die "Xray 安装后未找到：$XRAY_BIN"
  if ((installed_before == 0)) || [[ ! -f $CONFIG_FILE ]]; then write_default_config; else ensure_config; fi
  setup_runtime_access
  write_openrc_service
  install_quick_command
  validate_candidate "$CONFIG_FILE"
  rc-update add "$SERVICE_NAME" default >/dev/null 2>&1 || true
  restart_service
  if [[ $mode == upgrade ]]; then
    info "Xray 已升级：$($XRAY_BIN version | sed -n '1p')"
  else
    info "Xray 已安装/修复：$($XRAY_BIN version | sed -n '1p')"
  fi
}

install_quick_command() {
  local source=${BASH_SOURCE[0]:-} downloaded=""
  mkdir -p "$(dirname "$QUICK_COMMAND")" "$(dirname "$QUICK_SYMLINK")"

  if [[ -n $source && -r $source ]] && grep -q '^# xrayctl - Xray Alpine Linux terminal manager' "$source" 2>/dev/null; then
    :
  elif [[ -f $QUICK_COMMAND ]] && grep -q '^# xrayctl - Xray Alpine Linux terminal manager' "$QUICK_COMMAND" 2>/dev/null; then
    source=$QUICK_COMMAND
  else
    downloaded=$(temp_file)
    info "正在下载快捷命令脚本。"
    if ! curl --fail --location --proto '=https' --tlsv1.2 --retry 3 \
      --connect-timeout 15 --max-time 120 "$SCRIPT_DOWNLOAD_URL" -o "$downloaded"; then
      rm -f "$downloaded"
      die "快捷命令脚本下载失败。"
    fi
    grep -q '^# xrayctl - Xray Alpine Linux terminal manager' "$downloaded" \
      || { rm -f "$downloaded"; die "快捷命令脚本校验失败。"; }
    source=$downloaded
  fi
  if [[ -e $QUICK_COMMAND && ! $source -ef $QUICK_COMMAND ]] && ! grep -q '^# xrayctl - Xray Alpine Linux terminal manager' "$QUICK_COMMAND" 2>/dev/null; then
    [[ -z $downloaded ]] || rm -f "$downloaded"
    die "${QUICK_COMMAND} 已存在且不是本脚本，拒绝覆盖。"
  fi
  if [[ ! -e $QUICK_COMMAND ]] || ! [[ $source -ef $QUICK_COMMAND ]]; then
    install -m 755 "$source" "$QUICK_COMMAND"
  else
    chmod 755 "$QUICK_COMMAND"
  fi
  [[ -z $downloaded ]] || rm -f "$downloaded"
  if [[ -e $QUICK_SYMLINK && ! -L $QUICK_SYMLINK && ! $QUICK_SYMLINK -ef $QUICK_COMMAND ]]; then
    die "${QUICK_SYMLINK} 已存在且不是本脚本，拒绝覆盖。"
  fi
  ln -sfn "$QUICK_COMMAND" "$QUICK_SYMLINK"
  info "快捷命令已安装：xrayctl"
}

uninstall_xray() {
  ensure_runtime_dependencies uninstall
  local purge=${1:-0} hook
  if [[ $purge == 1 ]]; then
    confirm "将卸载 Xray 并删除配置、证书、日志与元数据，确定吗？" N || return 0
  else
    confirm "卸载 Xray 核心但保留配置和备份，确定吗？" N || return 0
  fi
  service_is_active && rc-service "$SERVICE_NAME" stop >/dev/null 2>&1 || true
  rc-update del "$SERVICE_NAME" default >/dev/null 2>&1 || true
  rm -f "$OPENRC_SERVICE" "$XRAY_BIN" "${XRAY_SHARE_DIR}/geoip.dat" "${XRAY_SHARE_DIR}/geosite.dat"
  if [[ $purge == 1 ]]; then
    for hook in /etc/letsencrypt/renewal-hooks/deploy/xrayctl-*; do
      [[ -e $hook ]] && rm -f "$hook"
    done
    rm -f "$CERT_RENEW_HOOK"
    if [[ -L $CERTBOT_COMMAND && $(readlink "$CERTBOT_COMMAND") == "$CERTBOT_VENV/bin/certbot" ]]; then rm -f "$CERTBOT_COMMAND"; fi
    if [[ -d $CERTBOT_VENV ]]; then find "$CERTBOT_VENV" -mindepth 1 -delete; rmdir "$CERTBOT_VENV" 2>/dev/null || true; fi
    find "$CONFIG_DIR" -mindepth 1 -delete 2>/dev/null || true
    rmdir "$CONFIG_DIR" 2>/dev/null || true
    find "$LOG_DIR" -mindepth 1 -delete 2>/dev/null || true
    rmdir "$LOG_DIR" 2>/dev/null || true
    rmdir "$XRAY_SHARE_DIR" 2>/dev/null || true
    if [[ -d $BACKUP_DIR ]]; then find "$BACKUP_DIR" -mindepth 1 -delete; rmdir "$BACKUP_DIR" 2>/dev/null || true; fi
    id "$RUNTIME_USER" >/dev/null 2>&1 && deluser "$RUNTIME_USER" 2>/dev/null || true
    grep -qE "^${RUNTIME_GROUP}:" /etc/group 2>/dev/null && delgroup "$RUNTIME_GROUP" 2>/dev/null || true
  fi
  if [[ $purge == 1 ]]; then
    if [[ -L $QUICK_SYMLINK ]] && [[ $(readlink "$QUICK_SYMLINK") == "$QUICK_COMMAND" ]]; then rm -f "$QUICK_SYMLINK"; fi
    if grep -q '^# xrayctl - Xray Alpine Linux terminal manager' "$QUICK_COMMAND" 2>/dev/null; then rm -f "$QUICK_COMMAND"; fi
  fi
  if [[ $purge == 1 ]]; then info "Xray 与 Alpine 版管理数据已删除。"; else info "Xray 已卸载，配置和 xrayctl 已保留。"; fi
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
    prompt_value value "入站标签" "$default"
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
  local __var=$1 default=${2:-${XRAYCTL_PUBLIC_HOST:-}} preferred=${3:-} value ipv4="" ipv6="" address_choice prompt_label="客户端连接地址"
  local labels=() values=()
  if [[ -z $default ]]; then
    ipv4=$(detect_public_ipv4 || true)
    ipv6=$(detect_public_ipv6 || true)
    if [[ -n $preferred ]]; then labels+=("证书域名/IP  ${preferred}"); values+=("$preferred"); fi
    if [[ -n $ipv4 && $ipv4 != "$preferred" ]]; then labels+=("IPv4  ${ipv4}"); values+=("$ipv4"); fi
    if [[ -n $ipv6 && $ipv6 != "$preferred" ]]; then labels+=("IPv6  ${ipv6}"); values+=("$ipv6"); fi
    if ((${#values[@]} > 1)); then
      labels+=("域名/其他地址")
      choose address_choice "选择客户端连接地址" "${labels[@]}"
      if ((address_choice <= ${#values[@]})); then
        printf -v "$__var" '%s' "${values[$((address_choice-1))]}"
        return 0
      fi
      prompt_label="客户端连接域名/IP"
    elif ((${#values[@]} == 1)); then
      default=${values[0]}
    else
      prompt_label="客户端连接域名/IP"
    fi
  fi
  while true; do
    prompt_value value "$prompt_label" "$default"
    if [[ -n $value && $value != *" "* ]]; then
      printf -v "$__var" '%s' "$value"
      return
    fi
    warn "地址无效。"
  done
}

certificate_server_names() {
  local cert=$1 san concrete
  san=$(openssl x509 -in "$cert" -noout -text 2>/dev/null \
    | awk '/X509v3 Subject Alternative Name/ {getline; print; exit}' | tr ',' '\n' \
    | sed -n -e 's/^[[:space:]]*DNS://p' -e 's/^[[:space:]]*IP Address://p')
  if [[ -n $san ]]; then
    concrete=$(printf '%s\n' "$san" | awk '$0 !~ /^\*\./ && !seen[$0]++')
    if [[ -n $concrete ]]; then printf '%s\n' "$concrete"; else printf '%s\n' "$san" | awk '!seen[$0]++'; fi
    return 0
  fi
  openssl x509 -in "$cert" -noout -subject -nameopt RFC2253 2>/dev/null \
    | sed -n 's/^subject=.*CN=\([^,]*\).*$/\1/p'
}

prompt_certificate_server_name() {
  local __var=$1 cert=$2 answer selected default_name name
  local names=()
  while IFS= read -r name; do [[ -n $name ]] && names+=("$name"); done < <(certificate_server_names "$cert")
  if ((${#names[@]} == 0)); then
    prompt_validated_value selected "TLS serverName/SNI" "" validate_domain_or_ip "SNI 必须是证书包含的有效域名/IP。"
  elif ((${#names[@]} == 1)); then
    selected=${names[0]}
  else
    choose answer "选择 TLS serverName/SNI" "${names[@]}"
    selected=${names[$((answer-1))]}
  fi
  if [[ $selected == \*.* ]]; then
    default_name="www.${selected#*.}"
    prompt_validated_value selected "TLS serverName/SNI" "$default_name" validate_domain "通配符证书需要填写具体子域名。"
  fi
  printf -v "$__var" '%s' "$selected"
}

validate_certificate_pair_files() {
  local cert=$1 key=$2 cert_pub key_pub
  [[ -r $cert ]] || { warn "证书文件不存在或不可读，请重新输入。"; return 1; }
  [[ -r $key ]] || { warn "私钥文件不存在或不可读，请重新输入。"; return 1; }
  openssl x509 -in "$cert" -noout >/dev/null 2>&1 \
    || { warn "证书格式无效，请重新输入。"; return 1; }
  openssl x509 -in "$cert" -checkend 0 -noout >/dev/null 2>&1 \
    || { warn "证书已经过期，请重新选择。"; return 1; }
  openssl pkey -in "$key" -noout >/dev/null 2>&1 \
    || { warn "私钥格式无效，请重新输入。"; return 1; }
  cert_pub=$(openssl x509 -in "$cert" -pubkey -noout 2>/dev/null | openssl pkey -pubin -outform DER 2>/dev/null | openssl sha256)
  key_pub=$(openssl pkey -in "$key" -pubout -outform DER 2>/dev/null | openssl sha256)
  [[ -n $cert_pub && $cert_pub == "$key_pub" ]] \
    || { warn "证书与私钥不匹配，请重新输入。"; return 1; }
}

prompt_certificate_files() {
  local __cert=$1 __key=$2 default_cert=${3:-} default_key=${4:-} entered_cert entered_key
  while true; do
    prompt_value entered_cert "证书文件路径" "$default_cert"
    prompt_value entered_key "私钥文件路径" "$default_key"
    if validate_certificate_pair_files "$entered_cert" "$entered_key"; then
      printf -v "$__cert" '%s' "$entered_cert"
      printf -v "$__key" '%s' "$entered_key"
      return 0
    fi
  done
}

prompt_tls_certificate() {
  local __cert=$1 __key=$2 __sni=$3 identifier cert_value key_value sni_value
  if (( $(managed_certificate_count) > 0 )) && confirm "使用托管证书？" Y; then
    select_managed_certificate identifier || return 1
    cert_value="${CERT_DIR}/${identifier}.crt"
    key_value="${CERT_DIR}/${identifier}.key"
    validate_certificate_pair_files "$cert_value" "$key_value" || return 1
    info "使用托管证书：${identifier}"
  else
    prompt_certificate_files cert_value key_value
    info "使用证书文件：${cert_value}"
  fi
  prompt_certificate_server_name sni_value "$cert_value"
  info "TLS serverName/SNI：${sni_value}"
  printf -v "$__cert" '%s' "$cert_value"
  printf -v "$__key" '%s' "$key_value"
  printf -v "$__sni" '%s' "$sni_value"
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
  case $protocol in
    vless)
      choose security_choice "选择加密方式" "REALITY" "TLS" "无"
      case $security_choice in 1) security=reality;; 2) security=tls;; 3) security=none;; esac
      ;;
    trojan)
      choose security_choice "选择加密方式" "TLS" "REALITY" "无"
      case $security_choice in 1) security=tls;; 2) security=reality;; 3) security=none;; esac
      ;;
    *)
      choose security_choice "选择加密方式" "TLS" "无"
      case $security_choice in 1) security=tls;; 2) security=none;; esac
      ;;
  esac

  if [[ $security == reality || ( $protocol == trojan && $security != tls ) ]]; then
    choose transport_choice "选择传输方式" "RAW" "XHTTP" "gRPC"
    case $transport_choice in 1) method=raw;; 2) method=xhttp;; 3) method=grpc;; esac
  else
    choose transport_choice "选择传输方式" "RAW" "XHTTP" "WebSocket" "gRPC"
    case $transport_choice in 1) method=raw;; 2) method=xhttp;; 3) method=websocket;; 4) method=grpc;; esac
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
      prompt_validated_value target "REALITY 目标" "www.microsoft.com:443" validate_reality_target "目标格式应为 域名:端口，请重新输入。"
      prompt_validated_value sni "REALITY serverName/SNI" "${target%%:*}" validate_domain "SNI 必须是有效域名，请重新输入。"
      generate_reality_keys private public
      short_id=$(random_hex 8)
      json=$(jq --arg target "$target" --arg sni "$sni" --arg private "$private" --arg short "$short_id" \
        '. + {realitySettings:{show:false,target:$target,xver:0,serverNames:[$sni],privateKey:$private,shortIds:[$short],maxTimeDiff:0}}' <<<"$json")
      printf -v "$__public_key" '%s' "$public"
      ;;
    tls)
      prompt_tls_certificate cert key sni
      if [[ $method == websocket ]]; then alpn='["http/1.1"]'; else alpn='["h2","http/1.1"]'; fi
      json=$(jq --arg cert "$cert" --arg key "$key" --arg sni "$sni" --argjson alpn "$alpn" \
        '. + {tlsSettings:{serverName:$sni,alpn:$alpn,minVersion:"1.2",certificates:[{certificateFile:$cert,keyFile:$key}]}}' <<<"$json")
      ;;
  esac
  printf -v "$__json" '%s' "$json"
}

build_inbound() {
  local __inbound=$1 __host=$2 __public_key=$3
  local choice protocol tag listen port public_host email uuid password method stream="" inbound_json user flow username generated_public_key="" suggested_host=""
  choose choice "选择入站协议" \
    "VLESS" "VMess" "Trojan" "SOCKS5" "HTTP"
  case $choice in
    1) protocol=vless;; 2) protocol=vmess;; 3) protocol=trojan;;
    4) protocol=socks;; 5) protocol=http;;
  esac
  if [[ $protocol == vless || $protocol == vmess || $protocol == trojan ]]; then
    build_stream_settings "$protocol" stream generated_public_key
    suggested_host=$(jq -r '.tlsSettings.serverName // empty' <<<"$stream")
  fi
  prompt_tag tag "${protocol}-$(random_hex 2)"
  prompt_value listen "监听地址" "0.0.0.0"
  prompt_port port 443
  if [[ -n $suggested_host ]]; then
    public_host=$suggested_host
    info "客户端连接地址：${public_host}"
  else
    prompt_public_host public_host "" "$suggested_host"
  fi

  case $protocol in
    vless|vmess|trojan)
      prompt_client_label email "$tag" "首个用户名称/邮箱" "user-$(random_hex 2)" "" "$protocol"
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
    socks)
      prompt_optional_value username "用户名（留空表示无认证）"
      if [[ -n $username ]]; then
        prompt_secret password "密码" "$(random_password)"
        inbound_json=$(jq -n --arg tag "$tag" --arg listen "$listen" --argjson port "$port" --arg user "$username" --arg pass "$password" \
          '{tag:$tag,listen:$listen,port:$port,protocol:"socks",settings:{
            auth:"password",
            accounts:[{user:$user,pass:$pass}],
            users:[{user:$user,pass:$pass}],
            udp:true,
            ip:"0.0.0.0"
          }}')
      else
        [[ $listen == 127.0.0.1 || $listen == ::1 ]] || warn "公网监听的无认证 SOCKS5 风险极高。"
        inbound_json=$(jq -n --arg tag "$tag" --arg listen "$listen" --argjson port "$port" \
          '{tag:$tag,listen:$listen,port:$port,protocol:"socks",settings:{auth:"noauth",udp:true,ip:"0.0.0.0"}}')
      fi
      ;;
    http)
      prompt_optional_value username "用户名（留空表示无认证）"
      if [[ -n $username ]]; then
        prompt_secret password "密码" "$(random_password)"
        inbound_json=$(jq -n --arg tag "$tag" --arg listen "$listen" --argjson port "$port" --arg user "$username" --arg pass "$password" \
          '{tag:$tag,listen:$listen,port:$port,protocol:"http",settings:{
            accounts:[{user:$user,pass:$pass}],
            users:[{user:$user,pass:$pass}],
            allowTransparent:false
          }}')
      else
        [[ $listen == 127.0.0.1 || $listen == ::1 ]] || warn "公网监听的无认证 HTTP 代理风险极高。"
        inbound_json=$(jq -n --arg tag "$tag" --arg listen "$listen" --argjson port "$port" \
          '{tag:$tag,listen:$listen,port:$port,protocol:"http",settings:{allowTransparent:false}}')
      fi
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
    meta_set_inbound "$tag" "$host"
    heading "入站已创建"
    show_inbound "$tag"
    print_links "$tag" "" || true
  fi
  rm -f "$tmp"
}

list_inbounds() {
  ensure_config
  local count
  count=$(jq '.inbounds|length' "$CONFIG_FILE")
  if ((count == 0)); then info "还没有入站。"; return; fi
  print_table_cell_clipped "标签" 20; printf '| '; print_table_cell_clipped "协议" 8; printf '| '
  print_table_cell "端口" 7; printf '| '; print_table_cell_clipped "传输" 7; printf '| '
  print_table_cell_clipped "安全" 10; printf '| 监听\n'
  jq -r '.inbounds | to_entries[] |
    [.value.tag,.value.protocol,(.value.port|tostring),
     (if (.value.streamSettings.method // "raw")=="websocket" then "ws" else (.value.streamSettings.method // "raw") end),
     (.value.streamSettings.security // "none"),(.value.listen // "0.0.0.0")] | @tsv' "$CONFIG_FILE" \
    | while IFS=$'\t' read -r tag protocol port method security listen; do
        print_table_cell_clipped "$tag" 20; printf '| '; print_table_cell_clipped "$protocol" 8; printf '| '
        print_table_cell "$port" 7; printf '| '; print_table_cell_clipped "$method" 7; printf '| '
        print_table_cell_clipped "$security" 10; printf '| %s\n' "$listen"
      done
}

show_inbound() {
  local tag=$1
  inbound_exists "$tag" || die "找不到入站：$tag"
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
  ((count > 0)) || { warn "没有可选入站。"; return 1; }
  while IFS= read -r selected_tag; do [[ -z $selected_tag ]] || tags+=("$selected_tag"); done <<<"$entries"
  if ((count == 1)); then
    printf -v "$__var" '%s' "${tags[0]}"
    return 0
  fi
  choose answer "选择入站" "${tags[@]}"
  selected_tag=${tags[$((answer-1))]}
  printf -v "$__var" '%s' "$selected_tag"
}

prompt_renamed_inbound_tag() {
  local __var=$1 old_tag=$2 candidate
  while true; do
    prompt_validated_value candidate "新的入站名称" "$old_tag" validate_tag "名称只能包含字母、数字、点、下划线和横线。" || return 1
    if [[ $candidate != "$old_tag" ]] && { inbound_exists "$candidate" || outbound_exists "$candidate"; }; then
      warn "名称已被入站或出站使用，请重新输入。"
      continue
    fi
    printf -v "$__var" '%s' "$candidate"
    return 0
  done
}

rename_inbound() {
  ensure_runtime_dependencies inbound-rename; require_xray_installed; ensure_config
  local old_tag=${1-} new_tag=${2-} tmp
  [[ -n $old_tag ]] || select_inbound old_tag || return
  inbound_exists "$old_tag" || die "找不到入站：$old_tag"
  [[ -n $new_tag ]] || prompt_renamed_inbound_tag new_tag "$old_tag"
  validate_tag "$new_tag" || die "入站名称格式无效。"
  if [[ $new_tag == "$old_tag" ]]; then info "入站名称未更改。"; return 0; fi
  if inbound_exists "$new_tag" || outbound_exists "$new_tag"; then
    die "名称已被入站或出站使用：$new_tag"
  fi
  tmp=$(temp_file)
  jq --arg old "$old_tag" --arg new "$new_tag" '
    (.inbounds[]|select(.tag==$old)|.tag)=$new |
    .routing=(.routing // {domainStrategy:"IPIfNonMatch",rules:[]}) |
    .routing.rules=((.routing.rules // []) | map(
      if (.inboundTag|type)=="array" then
        .inboundTag |= map(if .==$old then $new else . end)
      elif .inboundTag==$old then .inboundTag=$new
      else . end |
      if (.ruleTag // "")==("xrayctl-outbound:"+$old) then .ruleTag=("xrayctl-outbound:"+$new) else . end
    ))' "$CONFIG_FILE" >"$tmp"
  if apply_candidate "$tmp"; then
    meta_rename_inbound "$old_tag" "$new_tag"
    info "入站已重命名：${old_tag} → ${new_tag}。"
  fi
  rm -f "$tmp"
}

modify_inbound_basic() {
  ensure_runtime_dependencies inbound-modify; ensure_config
  local tag=${1-} current listen port host tmp old_port
  [[ -n $tag ]] || select_inbound tag || return
  inbound_exists "$tag" || die "找不到入站：$tag"
  current=$(jq --arg tag "$tag" '.inbounds[]|select(.tag==$tag)' "$CONFIG_FILE")
  old_port=$(jq -r '.port' <<<"$current")
  prompt_value listen "监听地址" "$(jq -r '.listen // "0.0.0.0"' <<<"$current")"
  prompt_port port "$old_port" "$tag"
  prompt_public_host host "$(jq -r --arg tag "$tag" '.inbounds[$tag].host // empty' "$META_FILE")"
  tmp=$(temp_file)
  jq --arg tag "$tag" --arg listen "$listen" --argjson port "$port" \
    '(.inbounds[]|select(.tag==$tag)) |= (.listen=$listen | .port=$port)' "$CONFIG_FILE" >"$tmp"
  if apply_candidate "$tmp"; then
    meta_set_inbound "$tag" "$host"
    current=$(jq --arg tag "$tag" '.inbounds[]|select(.tag==$tag)' "$CONFIG_FILE")
  fi
  rm -f "$tmp"
}

modify_inbound_transport() {
  ensure_runtime_dependencies inbound-transport; require_xray_installed; ensure_config
  local tag=${1-} protocol stream public_key="" tmp host method security
  [[ -n $tag ]] || select_inbound tag '^(vless|vmess|trojan)$' || return
  inbound_exists "$tag" || die "找不到入站：$tag"
  protocol=$(jq -r --arg tag "$tag" '.inbounds[]|select(.tag==$tag)|.protocol' "$CONFIG_FILE")
  [[ $protocol =~ ^(vless|vmess|trojan)$ ]] || die "${protocol} 入站没有可修改的流式传输。"
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
    meta_set_inbound "$tag" "$host"
    info "传输已更新，请重新导出客户端分享链接。"
  fi
  rm -f "$tmp"
}

delete_inbound() {
  ensure_runtime_dependencies inbound-delete; ensure_config
  local tag=${1-} assume_yes=${2:-0} tmp port user_count rule_tag
  [[ -n $tag ]] || select_inbound tag || return
  inbound_exists "$tag" || die "找不到入站：$tag"
  port=$(jq -r --arg tag "$tag" '.inbounds[]|select(.tag==$tag)|.port' "$CONFIG_FILE")
  user_count=$(jq --arg tag "$tag" '
    .inbounds[]|select(.tag==$tag)|
    ((.settings.clients // .settings.accounts // .settings.users // [])|length)' "$CONFIG_FILE")
  [[ $assume_yes == 1 ]] || confirm "删除入站 ${tag} 及其 ${user_count} 个用户？" N || return 0
  rule_tag="xrayctl-outbound:${tag}"
  tmp=$(temp_file)
  jq --arg tag "$tag" --arg ruleTag "$rule_tag" '
    .inbounds |= map(select(.tag!=$tag)) |
    .routing.rules = [
      (.routing.rules // [])[] |
      select((.ruleTag // "") != $ruleTag) |
      if (.inboundTag|type)=="array" then .inboundTag |= map(select(.!=$tag)) else . end |
      select(
        if (.inboundTag|type)=="array" then (.inboundTag|length)>0
        elif (.inboundTag|type)=="string" then .inboundTag!=$tag
        else true end
      )
    ]' "$CONFIG_FILE" >"$tmp"
  if apply_candidate "$tmp"; then
    meta_delete_inbound "$tag"
    info "已删除入站 ${tag} 及其 ${user_count} 个用户。"
  fi
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

http_inbound_has_auth() {
  jq -e --arg tag "$1" '
    [.inbounds[]|select(.tag==$tag)|((.settings.accounts // .settings.users // [])|length)][0] > 0' \
    "$CONFIG_FILE" >/dev/null
}


list_clients() {
  ensure_config
  local tag=${1-} protocol count
  [[ -n $tag ]] || select_inbound tag '^(vless|vmess|trojan|socks|http)$' || return
  protocol=$(jq -r --arg tag "$tag" '.inbounds[]|select(.tag==$tag)|.protocol' "$CONFIG_FILE")
  heading "${tag} 的用户"
  if [[ $protocol == socks || $protocol == http ]]; then
    count=$(jq --arg tag "$tag" '.inbounds[]|select(.tag==$tag)|(.settings.accounts // .settings.users // [])|length' "$CONFIG_FILE")
  else
    count=$(jq --arg tag "$tag" '.inbounds[]|select(.tag==$tag)|(.settings.clients // [])|length' "$CONFIG_FILE")
  fi
  if ((count == 0)); then info "还没有用户。"; return; fi
  case $protocol in
    vless|vmess|trojan)
      print_table_cell "序号" 5; print_table_cell "用户" 16; print_table_cell "凭据" 40; printf '\n'
      if [[ $protocol == vless || $protocol == vmess ]]; then
        jq -r --arg tag "$tag" '.inbounds[]|select(.tag==$tag)|.settings.clients|to_entries[]|[.key+1,(.value.email // "-"),.value.id]|@tsv' "$CONFIG_FILE"
      else
        jq -r --arg tag "$tag" '.inbounds[]|select(.tag==$tag)|.settings.clients|to_entries[]|[.key+1,(.value.email // "-"),(.value.password // "-")]|@tsv' "$CONFIG_FILE"
      fi | while IFS=$'\t' read -r number label credential; do
        print_table_cell "$number" 5; print_table_cell "$label" 16; print_table_cell "$credential" 40; printf '\n'
      done
      ;;
    socks|http)
      print_table_cell "序号" 5; print_table_cell "用户" 16; printf '凭据\n'
      jq -r --arg tag "$tag" '.inbounds[]|select(.tag==$tag)|(.settings.accounts // .settings.users // [])|to_entries[]|[.key+1,.value.user,(.value.pass // "-")]|@tsv' "$CONFIG_FILE" \
        | while IFS=$'\t' read -r number label credential; do print_table_cell "$number" 5; print_table_cell "$label" 16; printf '%s\n' "$credential"; done ;;
    *) die "${protocol} 不支持独立多用户管理。";;
  esac
}

select_client() {
  local __var=$1 tag=$2 protocol answer current_label
  local labels=()
  protocol=$(jq -r --arg tag "$tag" '.inbounds[]|select(.tag==$tag)|.protocol' "$CONFIG_FILE")
  if [[ $protocol == socks || $protocol == http ]]; then
    while IFS= read -r current_label; do [[ -z $current_label ]] || labels+=("$current_label"); done < <(
      jq -r --arg tag "$tag" '.inbounds[]|select(.tag==$tag)|(.settings.accounts // .settings.users // [])[].user' "$CONFIG_FILE"
    )
  else
    while IFS= read -r current_label; do [[ -z $current_label ]] || labels+=("$current_label"); done < <(
      jq -r --arg tag "$tag" '.inbounds[]|select(.tag==$tag)|(.settings.clients // [])[].email' "$CONFIG_FILE"
    )
  fi
  ((${#labels[@]} > 0)) || { warn "该入站没有可选用户。"; return 1; }
  choose answer "选择用户" "${labels[@]}"
  printf -v "$__var" '%s' "${labels[$((answer-1))]}"
}

client_label_exists() {
  local tag=$1 label=$2 protocol
  protocol=$(jq -r --arg tag "$tag" '.inbounds[]|select(.tag==$tag)|.protocol' "$CONFIG_FILE")
  if [[ $protocol == socks || $protocol == http ]]; then
    jq -e --arg tag "$tag" --arg client_label "$label" '.inbounds[]|select(.tag==$tag)|(.settings.accounts // .settings.users // [])[]?|select(.user==$client_label)' "$CONFIG_FILE" >/dev/null
  else
    jq -e --arg tag "$tag" --arg client_label "$label" '.inbounds[]|select(.tag==$tag)|.settings.clients[]?|select(.email==$client_label)' "$CONFIG_FILE" >/dev/null
  fi
}


prompt_client_label() {
  local __var=$1 tag=$2 prompt=$3 default=${4-} current=${5-} protocol=${6-} label_candidate
  [[ -n $protocol ]] || protocol=$(jq -r --arg tag "$tag" '.inbounds[]?|select(.tag==$tag)|.protocol' "$CONFIG_FILE")
  while true; do
    prompt_validated_value label_candidate "$prompt" "$default" validate_email_label "用户名称无效，请重新输入。" || return 1
    if [[ $label_candidate != "$current" ]]; then
      if client_label_exists "$tag" "$label_candidate"; then
        warn "用户名称已存在，请重新输入。"
        continue
      fi
    fi
    printf -v "$__var" '%s' "$label_candidate"
    return 0
  done
}

add_client() {
  ensure_runtime_dependencies client-add; require_xray_installed; ensure_config
  local tag=${1-} protocol label id password user tmp flow method security
  [[ -n $tag ]] || select_inbound tag '^(vless|vmess|trojan|socks|http)$' || return
  protocol=$(jq -r --arg tag "$tag" '.inbounds[]|select(.tag==$tag)|.protocol' "$CONFIG_FILE")
  prompt_client_label label "$tag" "用户名称/邮箱" "user-$(random_hex 2)"
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
    jq --arg tag "$tag" --arg protocol "$protocol" --argjson user "$user" '
      (.inbounds[]|select(.tag==$tag)|.settings) |= (
        ((.accounts // .users // [])+[$user]) as $all |
        .accounts=$all | .users=$all |
        if $protocol=="socks" then .auth="password" else . end
      ) |
      del(.accounts,.users,.auth)' "$CONFIG_FILE" >"$tmp"
  else jq --arg tag "$tag" --argjson user "$user" '(.inbounds[]|select(.tag==$tag)|.settings.clients) += [$user]' "$CONFIG_FILE" >"$tmp"; fi
  if apply_candidate "$tmp"; then info "用户 ${label} 已添加。"; print_links "$tag" "$label" || true; fi
  rm -f "$tmp"
}

delete_client() {
  ensure_runtime_dependencies client-delete; ensure_config
  local tag=${1-} label=${2-} assume_yes=${3:-0} protocol tmp count
  [[ -n $tag ]] || select_inbound tag '^(vless|vmess|trojan|socks|http)$' || return
  protocol=$(jq -r --arg tag "$tag" '.inbounds[]|select(.tag==$tag)|.protocol' "$CONFIG_FILE")
  [[ -n $label ]] || select_client label "$tag" || return
  [[ $assume_yes == 1 ]] || confirm "从 ${tag} 删除用户 ${label}？" N || return 0
  tmp=$(temp_file)
  if [[ $protocol == socks || $protocol == http ]]; then
    count=$(jq --arg tag "$tag" --arg client_label "$label" '[.inbounds[]|select(.tag==$tag)|(.settings.accounts // .settings.users // [])[]|select(.user==$client_label)]|length' "$CONFIG_FILE")
    ((count > 0)) || die "找不到用户：$label"
    jq --arg tag "$tag" --arg client_label "$label" '
      (.inbounds[]|select(.tag==$tag)|.settings) |= (
        ((.accounts // .users // [])|map(select(.user!=$client_label))) as $all |
        .accounts=$all | .users=$all
      ) |
      del(.accounts,.users,.auth)' "$CONFIG_FILE" >"$tmp"
  else
    count=$(jq --arg tag "$tag" --arg client_label "$label" '[.inbounds[]|select(.tag==$tag)|.settings.clients[]|select(.email==$client_label)]|length' "$CONFIG_FILE")
    ((count > 0)) || die "找不到用户：$label"
    jq --arg tag "$tag" --arg client_label "$label" '(.inbounds[]|select(.tag==$tag)|.settings.clients) |= map(select(.email!=$client_label))' "$CONFIG_FILE" >"$tmp"
  fi
  apply_candidate "$tmp"; rm -f "$tmp"
}

rotate_client_credential() {
  ensure_runtime_dependencies client-rotate; ensure_config
  local tag=${1-} label=${2-} protocol value generated tmp
  [[ -n $tag ]] || select_inbound tag '^(vless|vmess|trojan|socks|http)$' || return
  [[ -n $label ]] || select_client label "$tag" || return
  protocol=$(jq -r --arg tag "$tag" '.inbounds[]|select(.tag==$tag)|.protocol' "$CONFIG_FILE")
  confirm "旧凭据会立即失效，继续吗？" N || return 0
  tmp=$(temp_file)
  case $protocol in
    vless|vmess)
      generated=$(generate_uuid)
      prompt_validated_value value "新 UUID" "$generated" validate_uuid "UUID 格式无效，请重新输入。" || { rm -f "$tmp"; return 1; }
      jq --arg tag "$tag" --arg client_label "$label" --arg value "$value" '(.inbounds[]|select(.tag==$tag)|.settings.clients[]|select(.email==$client_label)|.id)=$value' "$CONFIG_FILE" >"$tmp" ;;
    trojan)
      prompt_secret value "新密码" "$(random_password)" || { rm -f "$tmp"; return 1; }
      jq --arg tag "$tag" --arg client_label "$label" --arg value "$value" '(.inbounds[]|select(.tag==$tag)|.settings.clients[]|select(.email==$client_label)|.password)=$value' "$CONFIG_FILE" >"$tmp" ;;
    socks|http)
      prompt_secret value "新密码" "$(random_password)" || { rm -f "$tmp"; return 1; }
      jq --arg tag "$tag" --arg client_label "$label" --arg value "$value" '
        (.inbounds[]|select(.tag==$tag)|.settings) |= (
          ((.accounts // .users // [])|map(if .user==$client_label then .pass=$value else . end)) as $all |
          .accounts=$all | .users=$all
        ) |
        del(.accounts,.users,.auth)' "$CONFIG_FILE" >"$tmp" ;;
    *) die "不支持此协议。";;
  esac
  apply_candidate "$tmp"; rm -f "$tmp"
  info "新凭据：$value"
}

rename_client() {
  ensure_runtime_dependencies client-rename; require_xray_installed; ensure_config
  local tag=${1-} old_label=${2-} new_label=${3-} protocol count tmp
  [[ -n $tag ]] || select_inbound tag '^(vless|vmess|trojan|socks|http)$' || return
  [[ -n $old_label ]] || select_client old_label "$tag" || return
  protocol=$(jq -r --arg tag "$tag" '.inbounds[]|select(.tag==$tag)|.protocol' "$CONFIG_FILE")
  if [[ -z $new_label ]]; then
    prompt_client_label new_label "$tag" "新的用户名称/邮箱" "" "$old_label" "$protocol"
  else
    validate_email_label "$new_label" || die "新用户名称无效。"
    if [[ $new_label != "$old_label" ]]; then
      if client_label_exists "$tag" "$new_label"; then die "用户名称已存在。"; fi
    fi
  fi
  tmp=$(temp_file)
  if [[ $protocol == socks || $protocol == http ]]; then
    count=$(jq --arg tag "$tag" --arg client_label "$old_label" '[.inbounds[]|select(.tag==$tag)|(.settings.accounts // .settings.users // [])[]|select(.user==$client_label)]|length' "$CONFIG_FILE")
    ((count > 0)) || { rm -f "$tmp"; die "找不到用户：$old_label"; }
    jq --arg tag "$tag" --arg old "$old_label" --arg new "$new_label" '
      (.inbounds[]|select(.tag==$tag)|.settings) |= (
        ((.accounts // .users // [])|map(if .user==$old then .user=$new else . end)) as $all |
        .accounts=$all | .users=$all
      ) |
      del(.accounts,.users,.auth)' "$CONFIG_FILE" >"$tmp"
  else
    count=$(jq --arg tag "$tag" --arg client_label "$old_label" '[.inbounds[]|select(.tag==$tag)|.settings.clients[]|select(.email==$client_label)]|length' "$CONFIG_FILE")
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
  private=$(jq -r --arg tag "$tag" '.inbounds[]|select(.tag==$tag)|.streamSettings.realitySettings.privateKey // empty' "$CONFIG_FILE")
  [[ -n $private ]] || return 1
  output=$("$XRAY_BIN" x25519 -i "$private" 2>/dev/null) || return 1
  public=$(awk -F': *' 'tolower($1) ~ /(public|password)/ {print $2; exit}' <<<"$output")
  [[ -n $public ]] || return 1
  printf '%s' "$public"
}

share_separator() { printf '%s\n' '------------------------------------------------------------------------'; }

print_share_entry() {
  local label=$1 field=$2 value=$3
  share_separator
  printf '用户: %s\n%s: %s\n' "$label" "$field" "$value"
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
      sni=$(jq -r '.tlsSettings.serverName // empty' <<<"$stream")
      [[ -n $sni ]] || sni=$(public_host_for_tag "$tag")
      query+="&sni=$(url_encode "$sni")"
      [[ $method == websocket ]] && query+="&host=$(url_encode "$sni")"
      [[ $method == grpc ]] && query+="&authority=$(url_encode "$sni")"
      query+="&fp=chrome"
      ;;
    reality)
      sni=$(jq -r '.realitySettings.serverNames[0]' <<<"$stream")
      sid=$(jq -r '.realitySettings.shortIds[0]' <<<"$stream")
      pbk=$(reality_public_key "$tag") || { warn "无法获得 REALITY 公钥。"; return 0; }
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
  local tag=${1-} filter=${2-} protocol host uri_host port query label id password method vmess_net vmess_sni payload link
  [[ -n $tag ]] || select_inbound tag || return
  inbound_exists "$tag" || die "找不到入站：$tag"
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
      vmess_sni=$(jq -r --arg tag "$tag" '.inbounds[]|select(.tag==$tag)|.streamSettings.tlsSettings.serverName // empty' "$CONFIG_FILE")
      [[ -n $vmess_sni ]] || vmess_sni=$host
      while IFS=$'\t' read -r label id; do
        [[ -z $filter || $label == "$filter" ]] || continue
        payload=$(jq -nc --arg ps "${tag}-${label}" --arg add "$host" --arg port "$port" --arg id "$id" --arg net "$vmess_net" \
          --arg type "none" --arg host "$([[ $method == websocket ]] && printf '%s' "$host" || true)" \
          --arg path "$(jq -r --arg tag "$tag" '.inbounds[]|select(.tag==$tag)|(.streamSettings.wsSettings.path // .streamSettings.xhttpSettings.path // .streamSettings.grpcSettings.serviceName // "")' "$CONFIG_FILE")" \
          --arg tls "$(jq -r --arg tag "$tag" '.inbounds[]|select(.tag==$tag)|if .streamSettings.security=="tls" then "tls" elif .streamSettings.security=="reality" then "reality" else "" end' "$CONFIG_FILE")" \
          --arg sni "$vmess_sni" \
          '{v:"2",ps:$ps,add:$add,port:$port,id:$id,aid:"0",scy:"auto",net:$net,type:$type,host:$host,path:$path,tls:$tls,sni:$sni,alpn:""}')
        link="vmess://$(printf '%s' "$payload" | base64_nowrap)"
        print_share_entry "$label" "链接" "$link"
      done < <(jq -r --arg tag "$tag" '.inbounds[]|select(.tag==$tag)|.settings.clients[]|[.email,.id]|@tsv' "$CONFIG_FILE")
      ;;
    shadowsocks) die "Shadowsocks 已停止支持；请迁移或删除入站。" ;;
    socks)
      if [[ $(jq -r --arg tag "$tag" '.inbounds[]|select(.tag==$tag)|.settings.auth' "$CONFIG_FILE") == password ]]; then
        while IFS=$'\t' read -r label password; do
          [[ -z $filter || $label == "$filter" ]] || continue
          link="socks5://$(url_encode "$label"):$(url_encode "$password")@${uri_host}:${port}#$(url_encode "${tag}-${label}")"
          print_share_entry "$label" "链接" "$link"
        done < <(jq -r --arg tag "$tag" '.inbounds[]|select(.tag==$tag)|(.settings.accounts // .settings.users // [])[]|[.user,.pass]|@tsv' "$CONFIG_FILE")
      else
        link="socks5://${uri_host}:${port}#$(url_encode "${tag}")"
        print_share_entry "无认证" "链接" "$link"
      fi
      ;;
    http)
      if http_inbound_has_auth "$tag"; then
        while IFS=$'\t' read -r label password; do
          [[ -z $filter || $label == "$filter" ]] || continue
          link="http://$(url_encode "$label"):$(url_encode "$password")@${uri_host}:${port}#$(url_encode "${tag}-${label}")"
          print_share_entry "$label" "链接" "$link"
        done < <(jq -r --arg tag "$tag" '.inbounds[]|select(.tag==$tag)|(.settings.accounts // .settings.users // [])[]|[.user,.pass]|@tsv' "$CONFIG_FILE")
      else
        link="http://${uri_host}:${port}#$(url_encode "${tag}")"
        print_share_entry "无认证" "链接" "$link"
      fi
      ;;
  esac
  share_separator
}

print_subscription() {
  ensure_config; init_meta
  local tag=${1-} links current_tag
  if [[ -n $tag ]]; then
    links=$(print_links "$tag" "" | grep -E '^(vless|vmess|trojan)://' || true)
  else
    links=""
    while IFS= read -r current_tag; do
      links+="$(print_links "$current_tag" "" | grep -E '^(vless|vmess|trojan)://' || true)"$'\n'
    done < <(jq -r '.inbounds[]|select(.protocol|test("^(vless|vmess|trojan)$"))|.tag' "$CONFIG_FILE")
    links=${links%$'\n'}
  fi
  [[ -n $links ]] || die "没有可生成订阅的代理分享链接。"
  printf '%s' "$links" | base64_nowrap
  printf '\n'
}

print_all_share_links() {
  ensure_config; init_meta
  local tag found=0
  while IFS= read -r tag; do
    found=1
    print_links "$tag" ""
  done < <(jq -r '.inbounds[]|select(.protocol|test("^(vless|vmess|trojan|socks|http)$"))|.tag' "$CONFIG_FILE")
  ((found == 1)) || { warn "没有可生成订阅链接的入站。"; return 0; }
}


certbot_supports_ip() {
  command_exists certbot && certbot --help all 2>/dev/null | grep -q -- '--ip-address'
}

setup_certbot_renewal_timer() {
  local certbot_path
  certbot_path=$(command -v certbot) || return 1
  install -d -m 755 "$(dirname "$CERT_RENEW_HOOK")"
  cat >"$CERT_RENEW_HOOK" <<EOF
#!/bin/sh
${certbot_path} renew --quiet
EOF
  chmod 755 "$CERT_RENEW_HOOK"
  rc-update add crond default >/dev/null 2>&1 || true
  rc-service crond start >/dev/null 2>&1 || true
}

bootstrap_certbot_venv_without_apt() {
  local venv_dir=$1 bootstrap pip_timeout=${XRAYCTL_CERT_PIP_TIMEOUT:-120}
  command_exists python3 || return 1
  install -d -m 755 "$(dirname "$venv_dir")"
  if [[ ! -x $venv_dir/bin/python || ! -x $venv_dir/bin/pip ]]; then
    info "正在准备 Certbot 环境。"
  fi
  if [[ ! -x $venv_dir/bin/python ]]; then
    python3 -m venv --without-pip "$venv_dir" >/dev/null 2>&1 || return 1
  fi
  if [[ ! -x $venv_dir/bin/pip ]]; then
    bootstrap=$(temp_file)
    if ! curl --fail --location --proto '=https' --tlsv1.2 --retry 2 \
      --connect-timeout 15 --max-time 60 https://bootstrap.pypa.io/get-pip.py -o "$bootstrap"; then
      rm -f "$bootstrap"
      return 1
    fi
    if ! run_bounded "$pip_timeout" "$venv_dir/bin/python" "$bootstrap" --disable-pip-version-check; then
      rm -f "$bootstrap"
      return 1
    fi
    rm -f "$bootstrap"
  fi
  [[ -x $venv_dir/bin/pip ]]
}

install_certbot_ip_support() {
  local manager venv_dir=$CERTBOT_VENV
  local apt_timeout=${XRAYCTL_CERT_APT_TIMEOUT:-60} pip_timeout=${XRAYCTL_CERT_PIP_TIMEOUT:-120}
  manager=$(pkg_manager) || die "无法安装支持 IP 证书的 Certbot。"
  if ! bootstrap_certbot_venv_without_apt "$venv_dir"; then
    info "正在切换 Certbot 安装方式。"
    case $manager in
      apk)
        info "正在准备 Python 环境。"
        run_bounded "$apt_timeout" apk add --no-cache python3 py3-pip \
          || die "Python 环境安装失败或超时。" ;;
      apt)
        info "正在准备 Python 环境。"
        DEBIAN_FRONTEND=noninteractive XRAYCTL_APT_TIMEOUT="$apt_timeout" \
          apt_get_guarded install -y --no-install-recommends python3 python3-venv \
          || die "Python venv 安装失败或超时，请检查 APT 软件源。" ;;
      dnf) run_bounded "$apt_timeout" dnf install -y python3 python3-pip || die "Python 环境安装失败或超时。" ;;
      yum) run_bounded "$apt_timeout" yum install -y python3 python3-pip || die "Python 环境安装失败或超时。" ;;
      pacman) run_bounded "$apt_timeout" pacman -Sy --noconfirm python python-pip || die "Python 环境安装失败或超时。" ;;
      zypper) run_bounded "$apt_timeout" zypper --non-interactive install python3 python3-pip || die "Python 环境安装失败或超时。" ;;
    esac
    python3 -m venv "$venv_dir" || die "无法创建 Certbot Python 环境。"
  fi
  info "正在安装 Certbot。"
  run_bounded "$pip_timeout" "$venv_dir/bin/pip" install --disable-pip-version-check \
    --timeout 15 --retries 2 --upgrade 'certbot>=5.4' \
    || die "新版 Certbot 安装失败。"
  if [[ -e $CERTBOT_COMMAND && ! -L $CERTBOT_COMMAND ]]; then
    die "${CERTBOT_COMMAND} 已存在且不是符号链接。"
  fi
  install -d -m 755 "$(dirname "$CERTBOT_COMMAND")"
  ln -sfn "$venv_dir/bin/certbot" "$CERTBOT_COMMAND"
  hash -r
  certbot_supports_ip || die "当前 Certbot 不支持 IP 证书。"
  setup_certbot_renewal_timer
}

install_certbot() {
  local mode=${1:-domain} manager install_timeout=${XRAYCTL_CERT_APT_TIMEOUT:-60}
  if command_exists certbot && { [[ $mode != ip ]] || certbot_supports_ip; }; then return 0; fi
  if [[ $mode == ip ]]; then install_certbot_ip_support; return; fi
  manager=$(pkg_manager) || die "无法自动安装 certbot。"
  info "安装 certbot。"
  case $manager in
    apk) run_bounded "$install_timeout" apk add --no-cache certbot || die "certbot 安装失败或超时。" ;;
    apt)
      DEBIAN_FRONTEND=noninteractive XRAYCTL_APT_TIMEOUT="$install_timeout" apt_get_guarded update -y \
        || warn "APT 软件索引更新失败或超时，尝试使用现有索引。"
      DEBIAN_FRONTEND=noninteractive XRAYCTL_APT_TIMEOUT="$install_timeout" \
        apt_get_guarded install -y --no-install-recommends certbot \
        || die "certbot 安装失败或超时，请检查 APT 软件源。"
      ;;
    dnf) run_bounded "$install_timeout" dnf install -y certbot || die "certbot 安装失败或超时。" ;;
    yum) run_bounded "$install_timeout" yum install -y epel-release || die "EPEL 安装失败或超时。"; run_bounded "$install_timeout" yum install -y certbot || die "certbot 安装失败或超时。" ;;
    pacman) run_bounded "$install_timeout" pacman -Sy --noconfirm certbot || die "certbot 安装失败或超时。" ;;
    zypper) run_bounded "$install_timeout" zypper --non-interactive install certbot || die "certbot 安装失败或超时。" ;;
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
rc-service "${SERVICE_NAME}" restart >/dev/null 2>&1 || true
EOF
  chmod 750 "$hook"
}

update_tls_inbound_certificate() {
  local tag=$1 cert_path=$2 key_path=$3 sni=$4 tmp method
  inbound_exists "$tag" || { warn "入站不存在：${tag}"; return 1; }
  [[ $(jq -r --arg tag "$tag" '.inbounds[]|select(.tag==$tag)|.streamSettings.security // "none"' "$CONFIG_FILE") == tls ]] \
    || { warn "只有使用 TLS 的入站可以更换证书。"; return 1; }
  validate_certificate_pair_files "$cert_path" "$key_path" || return 1
  method=$(jq -r --arg tag "$tag" '.inbounds[]|select(.tag==$tag)|.streamSettings.method // "raw"' "$CONFIG_FILE")
  tmp=$(temp_file)
  jq --arg tag "$tag" --arg cert "$cert_path" --arg key "$key_path" --arg sni "$sni" --arg method "$method" '
    (.inbounds[]|select(.tag==$tag)|.streamSettings) |= (
      .tlsSettings={
        serverName:$sni,
        alpn:(if $method=="websocket" then ["http/1.1"] else ["h2","http/1.1"] end),
        minVersion:"1.2",
        certificates:[{certificateFile:$cert,keyFile:$key}]
      }
    )' "$CONFIG_FILE" >"$tmp"
  if apply_candidate "$tmp"; then
    info "证书已更新：${tag}"
  fi
  rm -f "$tmp"
}

install_certbot_dns_plugin() {
  command_exists pip3 || install_packages python3-pip
  if python3 -c 'import certbot_dns_cloudflare' 2>/dev/null; then return 0; fi
  pip3 install certbot-dns-cloudflare >/dev/null 2>&1 || die "certbot-dns-cloudflare 安装失败。"
}

issue_certificate() {
  ensure_runtime_dependencies cert-issue
  local domain=${1-} email=${2-} was_active=0 paths cert_path default_domain="" mode=domain verify_method=http
  if [[ -z $domain ]]; then
    default_domain=$(detect_public_ip || true)
    prompt_validated_value domain "证书域名/IP" "$default_domain" validate_domain_or_ip "域名/IP 无效，请重新输入。"
  fi
  if validate_ip_literal "$domain"; then mode=ip;
  elif ! validate_domain "$domain"; then die "证书域名/IP 无效。"; fi
  [[ -n $email ]] || prompt_validated_value email "Let's Encrypt 联系邮箱" "" validate_email_address "邮箱格式无效，请重新输入。"
  validate_email_address "$email" || die "邮箱格式无效。"
  # 域名可选 DNS 验证，IP 只能用 HTTP
  if [[ $mode == domain ]]; then
    choose verify_method "选择验证方式" "DNS (Cloudflare, 推荐)" "HTTP (需要 80 端口可访问)"
    if [[ $verify_method == 1 ]]; then
      install_certbot_dns_plugin
      if [[ ! -f $CF_CREDENTIALS_FILE ]]; then
        local cf_token
        prompt_secret cf_token "Cloudflare API Token (Zone:DNS:Edit 权限)"
        [[ -n $cf_token ]] || { warn "API Token 不能为空。"; return 0; }
        mkdir -p "$(dirname "$CF_CREDENTIALS_FILE")"
        printf 'dns_cloudflare_api_token = %s
' "$cf_token" >"$CF_CREDENTIALS_FILE"
        chmod 600 "$CF_CREDENTIALS_FILE"
        info "API Token 已保存至 ${CF_CREDENTIALS_FILE}"
      fi
      verify_method=dns
    fi
  fi

  [[ -n $email ]] || prompt_validated_value email "Let's Encrypt 联系邮箱" "" validate_email_address "邮箱格式无效，请重新输入。"
  validate_email_address "$email" || die "邮箱格式无效。"
  install_certbot "$mode"
  if [[ -f ${CERT_DIR}/${domain}.crt && -f ${CERT_DIR}/${domain}.key ]]; then
    local using_inbounds
    using_inbounds=$(jq -r --arg cert "${CERT_DIR}/${domain}.crt" \
      '.inbounds[]?|select(.streamSettings.tlsSettings.certificates[0].certificateFile==$cert)|.tag' "$CONFIG_FILE" 2>/dev/null | paste -sd ',')
    if [[ -n $using_inbounds ]]; then
      confirm "证书 ${domain} 正在被 ${using_inbounds} 使用，是否强制重新签发？" N || { info "已取消。"; return 0; }
    else
      confirm "证书 ${domain} 已存在，是否强制重新签发？" N || { info "已取消。"; return 0; }
    fi
  fi
  local certbot_args
  if [[ $verify_method == dns ]]; then
    certbot_args=(certonly --non-interactive --agree-tos -m "$email" --force-renewal
      --dns-cloudflare --dns-cloudflare-credentials "$CF_CREDENTIALS_FILE" -d "$domain")
  else
    service_is_active && { was_active=1; rc-service "$SERVICE_NAME" stop; CERT_STOPPED_SERVICE=1; }
    certbot_args=(certonly --standalone --non-interactive --agree-tos --preferred-challenges http -m "$email" --force-renewal -d "$domain")
  fi

  if [[ $mode == ip ]]; then
    certbot_args+=(--preferred-profile shortlived --ip-address "$domain")
  fi
  if ! certbot "${certbot_args[@]}"; then
    if ((was_active)); then rc-service "$SERVICE_NAME" start || true; CERT_STOPPED_SERVICE=0; fi
    warn "证书签发失败，请查看上方 Certbot 输出的具体原因。"
    return 0
  fi
  paths=$(copy_certificate_pair "$domain" "/etc/letsencrypt/live/${domain}/fullchain.pem" "/etc/letsencrypt/live/${domain}/privkey.pem")
  cert_path=$(head -n1 <<<"$paths")
  write_certbot_deploy_hook "$domain"
  setup_certbot_renewal_timer
  if ((was_active)); then rc-service "$SERVICE_NAME" start; CERT_STOPPED_SERVICE=0; fi
  info "证书已保存：${cert_path}"
}

import_certificate() {
  ensure_runtime_dependencies cert-import
  local domain=${1-} cert=${2-} key=${3-} paths
  [[ -n $domain ]] || prompt_validated_value domain "证书标识/域名" "" validate_certificate_identifier "证书标识只能包含字母、数字、点和横线。"
  [[ $domain =~ ^[A-Za-z0-9.-]+$ ]] || die "证书标识无效。"
  [[ -n $cert ]] || prompt_validated_value cert "证书文件路径" "" validate_readable_file "证书文件不存在或不可读，请重新输入。"
  [[ -n $key ]] || prompt_validated_value key "私钥文件路径" "" validate_readable_file "私钥文件不存在或不可读，请重新输入。"
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

managed_certificate_count() {
  local cert identifier count=0
  for cert in "$CERT_DIR"/*.crt; do
    [[ -e $cert ]] || continue
    identifier=$(basename "$cert" .crt)
    [[ -r "${CERT_DIR}/${identifier}.key" ]] && ((count+=1))
  done
  printf '%s' "$count"
}

select_managed_certificate() {
  local __var=$1 always_choose=${2:-0} cert answer cert_identifier
  local identifiers=()
  for cert in "$CERT_DIR"/*.crt; do
    [[ -e $cert ]] || continue
    cert_identifier=$(basename "$cert" .crt)
    [[ -r "${CERT_DIR}/${cert_identifier}.key" ]] && identifiers+=("$cert_identifier")
  done
  ((${#identifiers[@]} > 0)) || { warn "没有可用的托管证书。"; return 1; }
  if ((${#identifiers[@]} == 1)) && [[ $always_choose != 1 ]]; then
    printf -v "$__var" '%s' "${identifiers[0]}"
    return 0
  fi
  choose answer "选择证书" "${identifiers[@]}"
  printf -v "$__var" '%s' "${identifiers[$((answer-1))]}"
}

certificate_inbound_users() {
  local identifier=$1 cert_path="${CERT_DIR}/${identifier}.crt" key_path="${CERT_DIR}/${identifier}.key"
  [[ -r $CONFIG_FILE ]] || return 0
  jq -r --arg cert "$cert_path" --arg key "$key_path" '
    .inbounds[]? |
    select(.streamSettings.security=="tls") |
    select([.streamSettings.tlsSettings.certificates[]? |
      select(.certificateFile==$cert or .keyFile==$key)] | length > 0) |
    .tag' "$CONFIG_FILE"
}

delete_managed_certificate() {
  ensure_runtime_dependencies cert-delete
  local identifier=${1-} assume_yes=${2:-0} cert_path key_path hook renewal users tag
  [[ -n $identifier ]] || select_managed_certificate identifier 1 || return 0
  validate_certificate_identifier "$identifier" || die "证书标识无效。"
  cert_path="${CERT_DIR}/${identifier}.crt"
  key_path="${CERT_DIR}/${identifier}.key"
  [[ -e $cert_path || -e $key_path ]] || { warn "托管证书不存在：${identifier}"; return 0; }
  users=$(certificate_inbound_users "$identifier")
  if [[ -n $users ]]; then
    warn "证书正在被以下 TLS 入站使用，不能删除："
    while IFS= read -r tag; do [[ -n $tag ]] && printf '  - %s\n' "$tag" >&2; done <<<"$users"
    return 0
  fi
  [[ $assume_yes == 1 ]] || confirm "删除托管证书 ${identifier}？" N || return 0
  renewal="/etc/letsencrypt/renewal/${identifier}.conf"
  if [[ -f $renewal ]]; then
    command_exists certbot || { warn "该证书仍有 Let's Encrypt 续期配置，但当前找不到 certbot，未执行删除。"; return 0; }
    certbot delete --cert-name "$identifier" --non-interactive \
      || { warn "Let's Encrypt 证书删除失败，托管副本未改动。"; return 0; }
  fi
  hook="/etc/letsencrypt/renewal-hooks/deploy/xrayctl-${identifier}"
  rm -f "$cert_path" "$key_path" "$hook"
  info "托管证书已删除：${identifier}"
}

manage_inbound_certificate_menu() {
  local tag=$1 choice identifier cert key sni current_cert current_key current_sni
  while inbound_exists "$tag"; do
    [[ $(jq -r --arg tag "$tag" '.inbounds[]|select(.tag==$tag)|.streamSettings.security // "none"' "$CONFIG_FILE") == tls ]] || return 0
    current_cert=$(jq -r --arg tag "$tag" '.inbounds[]|select(.tag==$tag)|.streamSettings.tlsSettings.certificates[0].certificateFile // "未设置"' "$CONFIG_FILE")
    current_key=$(jq -r --arg tag "$tag" '.inbounds[]|select(.tag==$tag)|.streamSettings.tlsSettings.certificates[0].keyFile // "未设置"' "$CONFIG_FILE")
    current_sni=$(jq -r --arg tag "$tag" '.inbounds[]|select(.tag==$tag)|.streamSettings.tlsSettings.serverName // "未设置"' "$CONFIG_FILE")
    clear_screen
    heading "证书管理 · ${tag}"
    printf '证书: %s\n私钥: %s\nSNI: %s\n\n' "$current_cert" "$current_key" "$current_sni"
    printf '1) 更换托管证书\n2) 使用证书文件\n0) 返回入站\n'
    read -r -p "请选择: " choice || { echo; return; }
    case $choice in
      1)
        if select_managed_certificate identifier; then
          cert="${CERT_DIR}/${identifier}.crt"; key="${CERT_DIR}/${identifier}.key"
          info "使用托管证书：${identifier}"
          prompt_certificate_server_name sni "$cert"
          run_menu_action update_tls_inbound_certificate "$tag" "$cert" "$key" "$sni"
          pause
        else
          pause
        fi
        ;;
      2)
        prompt_certificate_files cert key "$current_cert" "$current_key"
        prompt_certificate_server_name sni "$cert"
        run_menu_action update_tls_inbound_certificate "$tag" "$cert" "$key" "$sni"
        pause
        ;;
      0) return;; *) warn "无效选项。"; pause;;
    esac
  done
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
  local archive=${1-} temp extract_config snapshot had_meta=0 had_certs=0
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

  backup_config_quiet >/dev/null || true
  snapshot="$temp/.current"
  mkdir -p "$snapshot"
  cp -a "$CONFIG_FILE" "$snapshot/config.json"
  if [[ -f $META_FILE ]]; then cp -a "$META_FILE" "$snapshot/meta.json"; had_meta=1; fi
  if [[ -d $CERT_DIR ]]; then cp -a "$CERT_DIR" "$snapshot/certs"; had_certs=1; fi

  cp -a "$temp/$extract_config" "$CONFIG_FILE"
  if [[ -f "$temp/${META_FILE#/}" ]]; then cp -a "$temp/${META_FILE#/}" "$META_FILE"; else rm -f "$META_FILE"; fi
  rm -rf "$CERT_DIR"
  setup_certificate_access
  if [[ -d "$temp/${CERT_DIR#/}" ]]; then cp -a "$temp/${CERT_DIR#/}/." "$CERT_DIR/"; fi
  init_meta
  setup_runtime_access

  if ! restart_service; then
    error "恢复后服务失败，正在回滚配置、元数据和证书。"
    cp -a "$snapshot/config.json" "$CONFIG_FILE"
    if ((had_meta)); then cp -a "$snapshot/meta.json" "$META_FILE"; else rm -f "$META_FILE"; fi
    rm -rf "$CERT_DIR"
    setup_certificate_access
    if ((had_certs)); then cp -a "$snapshot/certs/." "$CERT_DIR/"; fi
    init_meta
    setup_runtime_access
    restart_service || true
    rm -rf "$temp"
    die "恢复后服务失败，已回滚配置、元数据和证书。"
  fi
  rm -rf "$temp"; info "备份已恢复。"
}

show_status() {
  heading "Xray 状态"
  if xray_installed; then "$XRAY_BIN" version | sed -n '1,2p'; else printf 'Xray: 未安装\n'; fi
  if service_exists; then
    rc-service "$SERVICE_NAME" status 2>&1 || true
  else printf 'OpenRC 服务: 未安装\n'; fi
  [[ -f $CONFIG_FILE ]] && printf '入站数: %s\n配置: %s\n' "$(jq '.inbounds|length' "$CONFIG_FILE" 2>/dev/null || printf '?')" "$CONFIG_FILE"
}

service_action() {
  ensure_runtime_dependencies service
  local action=$1
  service_exists || die "Xray OpenRC 服务不存在。"
  case $action in
    start|stop|restart) rc-service "$SERVICE_NAME" "$action" ;;
    enable) rc-update add "$SERVICE_NAME" default >/dev/null; rc-service "$SERVICE_NAME" start ;;
    disable) rc-update del "$SERVICE_NAME" default >/dev/null; rc-service "$SERVICE_NAME" stop ;;
    *) die "未知服务操作：$action";;
  esac
  info "服务操作完成：$action"
}

show_logs() {
  local lines=${1:-100}
  [[ $lines =~ ^[0-9]+$ ]] || die "日志行数必须是数字。"
  if [[ -r ${LOG_DIR}/openrc-error.log ]]; then tail -n "$lines" "${LOG_DIR}/openrc-error.log"; fi
  if [[ -r ${LOG_DIR}/error.log ]]; then tail -n "$lines" "${LOG_DIR}/error.log"; fi
  if [[ ! -r ${LOG_DIR}/openrc-error.log && ! -r ${LOG_DIR}/error.log ]]; then info "暂无 Xray 日志。"; fi
}

_check_bbr_available() {
  if [[ ! -r /proc/sys/net/ipv4/tcp_available_congestion_control || ! -e /proc/sys/net/ipv4/tcp_congestion_control ]]; then
    warn "当前内核未暴露 TCP 拥塞控制接口，无法在此容器内管理 BBR。"
    return 1
  fi
  if ! has_net_admin; then
    warn "当前 NAT/容器没有 NET_ADMIN 权限，无法修改内核拥塞控制。"
    return 1
  fi
  local available=$(< /proc/sys/net/ipv4/tcp_available_congestion_control)
  if [[ " $available " != *" bbr "* ]]; then
    warn "当前内核不支持 BBR。可用算法：${available}"
    return 1
  fi
  return 0
}

_enable_bbr() {
  local qdisc_enabled=0 config=/etc/sysctl.d/99-xrayctl-bbr.conf
  command_exists modprobe && run_bounded 5 modprobe tcp_bbr >/dev/null 2>&1 || true
  if [[ -e /proc/sys/net/core/default_qdisc ]]; then
    if run_bounded 5 sysctl -w net.core.default_qdisc=fq >/dev/null 2>&1; then qdisc_enabled=1;
    else warn "无法设置 net.core.default_qdisc，跳过 fq。"; fi
  fi
  if ! run_bounded 5 sysctl -w net.ipv4.tcp_congestion_control=bbr >/dev/null 2>&1; then
    error "无法写入拥塞控制参数或操作超时。"
    return 1
  fi
  if ((qdisc_enabled)); then
    printf '%s\n' 'net.core.default_qdisc=fq' 'net.ipv4.tcp_congestion_control=bbr' >"$config"
  else
    printf '%s\n' 'net.ipv4.tcp_congestion_control=bbr' >"$config"
  fi
  if [[ $(< /proc/sys/net/ipv4/tcp_congestion_control) != bbr ]]; then
    error "BBR 校验失败。"
    return 1
  fi
  info "BBR 已启用。"
}

_disable_bbr() {
  local current default_cc config=/etc/sysctl.d/99-xrayctl-bbr.conf
  current=$(< /proc/sys/net/ipv4/tcp_congestion_control)
  if [[ $current != bbr ]]; then info "BBR 当前未启用，无需关闭。"; return 0; fi
  default_cc=$(sed 's/ /\n/g' /proc/sys/net/ipv4/tcp_available_congestion_control | grep -vF bbr | head -1)
  [[ -n $default_cc ]] || default_cc=cubic
  if ! run_bounded 5 sysctl -w net.ipv4.tcp_congestion_control="$default_cc" >/dev/null 2>&1; then
    error "无法恢复默认拥塞控制算法 ${default_cc}。"
    return 1
  fi
  run_bounded 5 sysctl -w net.core.default_qdisc=fq_codel >/dev/null 2>&1 || true
  rm -f "$config"
  if [[ $(< /proc/sys/net/ipv4/tcp_congestion_control) == bbr ]]; then
    error "BBR 关闭失败，当前仍为 bbr。"
    return 1
  fi
  info "BBR 已关闭，拥塞控制恢复为 ${default_cc}。"
}

manage_bbr() {
  ensure_system_context bbr
  _check_bbr_available || return 0
  local current=$(< /proc/sys/net/ipv4/tcp_congestion_control)
  if [[ $current == bbr ]]; then
    info "当前拥塞控制: BBR"
    if [[ -t 0 ]]; then
      if confirm "BBR 已启用，是否关闭？" N; then
        _disable_bbr
      fi
    fi
  else
    info "当前拥塞控制: ${current}"
    if [[ -t 0 ]]; then
      if confirm "BBR 未启用，是否开启？" Y; then
        _enable_bbr
      fi
    else
      _enable_bbr
    fi
  fi
}

enable_bbr() {
  # 保留旧名称兼容非交互模式 CLI 调用
  ensure_system_context bbr
  _check_bbr_available || return 0
  _enable_bbr
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
  heading "最近服务日志"; show_logs 20 2>/dev/null || true
}

repair_quick_command() {
  ensure_runtime_dependencies quick-command
  install_quick_command
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
  printf '服务: %s  |  入站: %s  |  Xray: %s\n' \
    "$(service_state_summary)" "$(node_count_summary)" "$(xray_version_summary)"
}

show_main_inbounds() {
  command_exists jq && [[ -r $CONFIG_FILE ]] || return 0
  local count tag protocol port method security
  count=$(jq -r '.inbounds|length' "$CONFIG_FILE" 2>/dev/null) || return 0
  heading "当前入站"
  if ((count == 0)); then
    info "还没有入站。"
    printf '\n'
    return 0
  fi
  print_table_cell_clipped "标签" 20; printf '|'; print_table_cell_clipped "协议" 8; printf '|'
  print_table_cell "端口" 7; printf '|'; print_table_cell_clipped "传输" 7; printf '|'
  print_table_cell_clipped "安全" 10; printf '\n'
  jq -r '.inbounds[] | [.tag,.protocol,
    (.port|tostring),(if (.streamSettings.method // "raw")=="websocket" then "ws" else (.streamSettings.method // "raw") end),
    (.streamSettings.security // "none")] | @tsv' "$CONFIG_FILE" \
    | while IFS=$'\t' read -r tag protocol port method security; do
        print_table_cell_clipped "$tag" 20; printf '|'; print_table_cell_clipped "$protocol" 8; printf '|'
        print_table_cell "$port" 7; printf '|'; print_table_cell_clipped "$method" 7; printf '|'
        print_table_cell_clipped "$security" 10; printf '\n'
      done
  printf '\n'
}

show_node_summary() {
  local tag=$1 protocol port method security listen
  IFS=$'\t' read -r protocol port method security listen < <(
    jq -r --arg tag "$tag" '.inbounds[]|select(.tag==$tag)|[
      .protocol,(.port|tostring),(.streamSettings.method // "raw"),
      (.streamSettings.security // "none"),(.listen // "0.0.0.0")]|@tsv' "$CONFIG_FILE"
  )
  printf '协议: %s  |  端口: %s  |  传输: %s  |  安全: %s  |  监听: %s\n\n' \
    "$protocol" "$port" "$method" "$security" "$listen"
}

outbound_exists() { jq -e --arg tag "$1" '.outbounds[]?|select(.tag==$tag)' "$CONFIG_FILE" >/dev/null; }

list_outbound_overview() {
  local rows number tag protocol address username password width
  local number_width=4 tag_width=4 protocol_width=4 address_width=4 username_width=4
  ensure_config
  heading "入站与出站规则"
  if [[ $(jq '.inbounds|length' "$CONFIG_FILE") == 0 ]]; then
    info "还没有入站。"
  else
    print_table_cell "序号" 6; print_table_cell "入站" 28; printf '出站\n'
    jq -r '
      (.routing.rules // []) as $rules |
      .inbounds | to_entries[] |
      (.key+1) as $number | .value.tag as $tag |
      [$number,$tag,([$rules[]? | select((.ruleTag // "")==("xrayctl-outbound:"+$tag)) | .outboundTag][0] // "direct")] | @tsv' "$CONFIG_FILE" \
      | while IFS=$'\t' read -r number tag outbound; do
          local display="$outbound"
          if [[ $outbound == direct ]]; then
            display="direct"
          elif [[ $outbound =~ ^local- ]]; then
            local ip; ip=$(jq -r --arg tag "$outbound" '.outbounds[]?|select(.tag==$tag)|.sendThrough // empty' "$CONFIG_FILE" 2>/dev/null || true)
            display="${ip:-$outbound}"
          fi
          print_table_cell "$number" 6; print_table_cell "$tag" 28; printf '%s\n' "$display"
        done
  fi

  heading "代理出站"
  if jq -e '.outbounds[]?|select(.protocol=="socks" or .protocol=="http")' "$CONFIG_FILE" >/dev/null; then
    rows=$(jq -r '[.outbounds[]?|select(.protocol=="socks" or .protocol=="http")] | to_entries[] |
      [.key+1,.value.tag,.value.protocol,
       ((if (.value.settings.address|contains(":")) then "["+.value.settings.address+"]" else .value.settings.address end)+":"+(.value.settings.port|tostring)),
       (if (.value.settings.user // "")=="" then "无" else .value.settings.user end),
       (if (.value.settings.pass // "")=="" then "无" else .value.settings.pass end)] | @tsv' "$CONFIG_FILE")
    while IFS=$'\t' read -r number tag protocol address username password; do
      display_width width "$number"; if ((width > number_width)); then number_width=$width; fi
      display_width width "$tag"; if ((width > tag_width)); then tag_width=$width; fi
      display_width width "$protocol"; if ((width > protocol_width)); then protocol_width=$width; fi
      display_width width "$address"; if ((width > address_width)); then address_width=$width; fi
      display_width width "$username"; if ((width > username_width)); then username_width=$width; fi
    done <<<"$rows"
    ((number_width+=2, tag_width+=2, protocol_width+=2, address_width+=2, username_width+=2))
    print_table_cell "序号" "$number_width"; printf '| '; print_table_cell "标签" "$tag_width"; printf '| '
    print_table_cell "协议" "$protocol_width"; printf '| '; print_table_cell "地址" "$address_width"; printf '| '
    print_table_cell "用户" "$username_width"; printf '| 密码\n'
    while IFS=$'\t' read -r number tag protocol address username password; do
      print_table_cell "$number" "$number_width"; printf '| '; print_table_cell "$tag" "$tag_width"; printf '| '
      print_table_cell "$protocol" "$protocol_width"; printf '| '; print_table_cell "$address" "$address_width"; printf '| '
      print_table_cell "$username" "$username_width"; printf '| %s\n' "$password"
    done <<<"$rows"
  else
    info "还没有代理出站。"
  fi

  printf '\n'
}

prompt_outbound_tag() {
  local __var=$1 default=$2 tag_candidate
  while true; do
    prompt_validated_value tag_candidate "出站标签" "$default" validate_tag "标签只能包含字母、数字、点、下划线和横线。" || return 1
    if outbound_exists "$tag_candidate" || inbound_exists "$tag_candidate"; then
      warn "标签已存在，请重新输入。"
      continue
    fi
    printf -v "$__var" '%s' "$tag_candidate"
    return 0
  done
}

add_outbound() {
  ensure_runtime_dependencies outbound-add; require_xray_installed; ensure_config
  local choice protocol tag address port auth username password settings outbound tmp
  choose choice "选择出站协议" "SOCKS5" "HTTP"
  if [[ $choice == 1 ]]; then protocol=socks; else protocol=http; fi
  prompt_outbound_tag tag "${protocol}-out-$(random_hex 2)"
  prompt_validated_value address "代理服务器地址" "" validate_proxy_address "地址不能为空或包含空格，请重新输入。"
  prompt_validated_value port "代理服务器端口" "" validate_port "端口必须是 1-65535，请重新输入。"
  choose auth "认证方式" "无认证" "用户名密码"
  settings=$(jq -n --arg address "$address" --argjson port "$port" '{address:$address,port:$port}')
  if [[ $auth == 2 ]]; then
    prompt_value username "用户名"
    prompt_secret password "密码"
    settings=$(jq --arg user "$username" --arg pass "$password" '.+{user:$user,pass:$pass,level:0}' <<<"$settings")
  fi
  outbound=$(jq -n --arg tag "$tag" --arg protocol "$protocol" --argjson settings "$settings" \
    '{tag:$tag,protocol:$protocol,settings:$settings}')
  tmp=$(temp_file)
  jq --argjson outbound "$outbound" '.outbounds += [$outbound]' "$CONFIG_FILE" >"$tmp"
  if apply_candidate "$tmp"; then info "出站 ${tag} 已添加。"; fi
  rm -f "$tmp"
}

select_outbound() {
  local __var=$1 include_direct=${2:-0} candidate_tag answer
  local tags=() local_ips=() local_ip_tags=() local_raw_ips=()
  ((include_direct == 0)) || tags+=("direct")
  while IFS= read -r candidate_tag; do [[ -z $candidate_tag ]] || tags+=("$candidate_tag"); done < <(
    jq -r '.outbounds[]?|select((.protocol=="socks" or .protocol=="http" or .protocol=="freedom") and .tag!="direct" and .tag!="blocked")|.tag' "$CONFIG_FILE"
  )
  while IFS=$'\t' read -r label ip iface; do
    local tag; tag=$(_freedom_tag_for_ip "$ip")
    local_ip_tags+=("$tag")
    local found=0
    for t in "${tags[@]}"; do [[ $t == "$tag" ]] && { found=1; break; }; done
    if ((!found)); then tags+=("$tag"); fi
    local_ips+=("$label")
    local_raw_ips+=("$ip")
  done < <(ensure_config 2>/dev/null || true; detect_local_ips 2>/dev/null)
  ((${#tags[@]} > 0)) || { warn "没有可选出站。"; return 1; }
  local display_labels=()
  for t in "${tags[@]}"; do
    if [[ $t == direct ]]; then
      display_labels+=("direct (系统默认)")
    elif [[ $t =~ ^local- ]]; then
      local dlabel="" found=0 i
      for ((i=0; i<${#local_ip_tags[@]}; i++)); do
        [[ ${local_ip_tags[$i]} == "$t" ]] && { dlabel="${local_ips[$i]}"; found=1; break; }
      done
      if ((found)); then display_labels+=("${dlabel}"); else display_labels+=("$t (本地)"); fi
    else
      local proto; proto=$(jq -r --arg tag "$t" '.outbounds[]?|select(.tag==$tag)|.protocol' "$CONFIG_FILE" 2>/dev/null || printf '?')
      local addr; addr=$(jq -r --arg tag "$t" '.outbounds[]?|select(.tag==$tag)|"\(.settings.address // "?"):\(.settings.port // "?")"' "$CONFIG_FILE" 2>/dev/null || printf '?:?')
      display_labels+=("$t ($proto · $addr)")
    fi
  done
  choose answer "选择出站" "${display_labels[@]}"
  local chosen="${tags[$((answer-1))]}"
  if [[ $chosen =~ ^local- ]]; then
    local ip=""
    ip=$(jq -r --arg tag "$chosen" '.outbounds[]?|select(.tag==$tag)|.sendThrough // empty' "$CONFIG_FILE" 2>/dev/null || true)
    if [[ -z $ip ]]; then
      for ((i=0; i<${#local_ip_tags[@]}; i++)); do
        [[ ${local_ip_tags[$i]} == "$chosen" ]] && { ip="${local_raw_ips[$i]}"; break; }
      done
    fi
    [[ -n $ip ]] || { error "无法解析本地 IP。"; return 1; }
    chosen=$(_ensure_freedom_outbound "$ip") || { error "无法创建本地出口。"; return 1; }
  fi
  printf -v "$__var" '%s' "$chosen"
}

assign_outbound() {
  ensure_runtime_dependencies outbound-assign; ensure_config
  local inbound=${1-} outbound=${2-} rule_tag tmp
  [[ -n $inbound ]] || select_inbound inbound || return
  inbound_exists "$inbound" || die "找不到入站：$inbound"
  [[ -n $outbound ]] || select_outbound outbound 1 || return
  outbound_exists "$outbound" || [[ $outbound == direct ]] || die "找不到出站：$outbound"
  rule_tag="xrayctl-outbound:${inbound}"
  tmp=$(temp_file)
  jq --arg inbound "$inbound" --arg outbound "$outbound" --arg ruleTag "$rule_tag" '
    .routing=(.routing // {domainStrategy:"IPIfNonMatch",rules:[]}) |
    (.routing.rules // [] | map(select((.ruleTag // "")!=$ruleTag))) as $rules |
    .routing.rules=(
      [$rules[] | select((.outboundTag // "") == "blocked")] +
      [{type:"field",inboundTag:[$inbound],outboundTag:$outbound,ruleTag:$ruleTag}] +
      [$rules[] | select((.outboundTag // "") != "blocked")]
    )' "$CONFIG_FILE" >"$tmp"
  if apply_candidate "$tmp"; then info "入站 ${inbound} 已使用出站 ${outbound}。"; fi
  rm -f "$tmp"
}

delete_outbound() {
  ensure_runtime_dependencies outbound-delete; ensure_config
  local tag=${1-} tmp assigned
  [[ -n $tag ]] || select_outbound tag 0 || return
  outbound_exists "$tag" || die "找不到出站：$tag"
  assigned=$(jq -r --arg tag "$tag" '[.routing.rules[]?|select(.outboundTag==$tag)|.inboundTag[]?]|unique|join(", ")' "$CONFIG_FILE")
  if [[ -n $assigned ]]; then warn "正在使用此出站的入站：${assigned}；删除后这些入站恢复 direct。"; fi
  confirm "删除出站 ${tag}？" N || return 0
  tmp=$(temp_file)
  jq --arg tag "$tag" '
    .outbounds |= map(select(.tag!=$tag)) |
    .routing.rules=((.routing.rules // []) | map(select(.outboundTag!=$tag)))' "$CONFIG_FILE" >"$tmp"
  if apply_candidate "$tmp"; then info "出站 ${tag} 已删除。"; fi
  rm -f "$tmp"
}

outbound_menu() {
  local choice
  while true; do
    clear_screen
    heading "出站管理"
    list_outbound_overview
    printf '\n1) 选择入站设置出站\n2) 添加代理出站 (SOCKS5/HTTP)\n3) 删除出站\n0) 返回\n'
    read -r -p "请选择: " choice || { echo; return; }
    case $choice in
      1) run_menu_action assign_outbound; pause;; 2) run_menu_action add_outbound; pause;;
      3) run_menu_action delete_outbound; pause;; 0) return;; *) warn "无效选项。"; pause;;
    esac
  done
}

client_menu_for_tag() {
  local tag=$1 choice
  while inbound_exists "$tag"; do
    clear_screen
    heading "用户管理 · ${tag}"
    list_clients "$tag"
    printf '\n1) 添加用户\n2) 重命名用户\n3) 更换 UUID/密码\n4) 删除用户\n0) 返回入站\n'
    read -r -p "请选择: " choice || { echo; return; }
    case $choice in
      1) run_menu_action add_client "$tag"; pause;; 2) run_menu_action rename_client "$tag"; pause;;
      3) run_menu_action rotate_client_credential "$tag"; pause;; 4) run_menu_action delete_client "$tag"; pause;;
      0) return;; *) warn "无效选项。"; pause;;
    esac
  done
}

modify_inbound_menu() {
  local tag=$1 protocol=$2 choice
  while inbound_exists "$tag"; do
    clear_screen
    heading "修改入站信息 · ${tag}"
    if [[ $protocol == vless || $protocol == vmess || $protocol == trojan ]]; then
      printf '1) 修改入站名称\n2) 修改地址/端口\n3) 修改传输/安全\n0) 返回入站\n'
      read -r -p "请选择: " choice || { echo; return; }
      case $choice in
        1) run_menu_action rename_inbound "$tag"; pause; return;;
        2) run_menu_action modify_inbound_basic "$tag"; pause;;
        3) run_menu_action modify_inbound_transport "$tag"; pause;;
        0) return;; *) warn "无效选项。"; pause;;
      esac
    else
      printf '1) 修改入站名称\n2) 修改地址/端口\n0) 返回入站\n'
      read -r -p "请选择: " choice || { echo; return; }
      case $choice in
        1) run_menu_action rename_inbound "$tag"; pause; return;;
        2) run_menu_action modify_inbound_basic "$tag"; pause;;
        0) return;; *) warn "无效选项。"; pause;;
      esac
    fi
  done
}

manage_inbound_menu() {
  local tag=$1 choice protocol auth security
  while inbound_exists "$tag"; do
    clear_screen
    protocol=$(jq -r --arg tag "$tag" '.inbounds[]|select(.tag==$tag)|.protocol' "$CONFIG_FILE")
    heading "入站 · ${tag}"
    show_node_summary "$tag"
    case $protocol in
      vless|vmess|trojan)
        security=$(jq -r --arg tag "$tag" '.inbounds[]|select(.tag==$tag)|.streamSettings.security // "none"' "$CONFIG_FILE")
        if [[ $security == tls ]]; then
          printf '1) 分享信息\n2) 用户管理\n3) 修改入站信息\n4) 证书管理\n5) 查看 JSON\n0) 返回列表\n'
          read -r -p "请选择: " choice || { echo; return; }
          case $choice in
            1) run_menu_action print_links "$tag"; pause;; 2) client_menu_for_tag "$tag";; 3) modify_inbound_menu "$tag" "$protocol";;
            4) manage_inbound_certificate_menu "$tag";; 5) run_menu_action show_inbound "$tag"; pause;;
            0) return;; *) warn "无效选项。"; pause;;
          esac
        else
          printf '1) 分享信息\n2) 用户管理\n3) 修改入站信息\n4) 查看 JSON\n0) 返回列表\n'
          read -r -p "请选择: " choice || { echo; return; }
          case $choice in
            1) run_menu_action print_links "$tag"; pause;; 2) client_menu_for_tag "$tag";; 3) modify_inbound_menu "$tag" "$protocol";;
            4) run_menu_action show_inbound "$tag"; pause;;
            0) return;; *) warn "无效选项。"; pause;;
          esac
        fi
        ;;
      http)
        if http_inbound_has_auth "$tag"; then auth=password; else auth=noauth; fi
        printf '认证: %s\n\n' "$auth"
        if [[ $auth == password ]]; then
          printf '1) 客户端配置\n2) 用户管理\n3) 修改入站信息\n4) 查看 JSON\n0) 返回列表\n'
          read -r -p "请选择: " choice || { echo; return; }
          case $choice in
            1) run_menu_action print_links "$tag"; pause;; 2) client_menu_for_tag "$tag";; 3) modify_inbound_menu "$tag" "$protocol";;
            4) run_menu_action show_inbound "$tag"; pause;;
            0) return;; *) warn "无效选项。"; pause;;
          esac
        else
          printf '1) 客户端配置\n2) 修改入站信息\n3) 查看 JSON\n0) 返回列表\n'
          read -r -p "请选择: " choice || { echo; return; }
          case $choice in
            1) run_menu_action print_links "$tag"; pause;; 2) modify_inbound_menu "$tag" "$protocol";;
            3) run_menu_action show_inbound "$tag"; pause;;
            0) return;; *) warn "无效选项。"; pause;;
          esac
        fi
        ;;
      socks)
        auth=$(jq -r --arg tag "$tag" '.inbounds[]|select(.tag==$tag)|.settings.auth // "noauth"' "$CONFIG_FILE")
        printf '认证: %s\n\n' "$auth"
        if [[ $auth == password ]]; then
          printf '1) 客户端配置\n2) 用户管理\n3) 修改入站信息\n4) 查看 JSON\n0) 返回列表\n'
          read -r -p "请选择: " choice || { echo; return; }
          case $choice in
            1) run_menu_action print_links "$tag"; pause;; 2) client_menu_for_tag "$tag";; 3) modify_inbound_menu "$tag" "$protocol";;
            4) run_menu_action show_inbound "$tag"; pause;;
            0) return;; *) warn "无效选项。"; pause;;
          esac
        else
          printf '1) 客户端配置\n2) 修改入站信息\n3) 查看 JSON\n0) 返回列表\n'
          read -r -p "请选择: " choice || { echo; return; }
          case $choice in
            1) run_menu_action print_links "$tag"; pause;; 2) modify_inbound_menu "$tag" "$protocol";;
            3) run_menu_action show_inbound "$tag"; pause;;
            0) return;; *) warn "无效选项。"; pause;;
          esac
        fi
        ;;
      shadowsocks)
        warn "此入站使用已停止支持的 Shadowsocks，仅保留查看入口；删除请返回入站列表。"
        printf '1) 查看 JSON\n0) 返回列表\n'
        read -r -p "请选择: " choice || { echo; return; }
        case $choice in
          1) run_menu_action show_inbound "$tag"; pause;;
          0) return;; *) warn "无效选项。"; pause;;
        esac
        ;;
      *) warn "不支持的入站协议：${protocol}"; return;;
    esac
  done
}

inbound_menu() {
  local choice tag
  while true; do
    clear_screen
    heading "入站管理"
    list_inbounds
    printf '\n完整配置: %s\n\n' "$CONFIG_FILE"
    printf '1) 新增入站\n2) 管理已有入站\n3) 订阅链接\n4) 删除入站\n0) 返回\n'
    read -r -p "请选择: " choice || { echo; return; }
    case $choice in
      1) run_menu_action add_inbound; pause;;
      2) select_inbound tag && manage_inbound_menu "$tag";;
      3) run_menu_action print_all_share_links; pause;;
      4) run_menu_action delete_inbound; pause;;
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
    printf '1) Let\x27s Encrypt 自动签发\n2) 导入已有证书\n3) 查看托管证书\n4) 删除托管证书\n0) 返回\n'
    read -r -p "请选择: " choice || { echo; return; }
    case $choice in
      1) run_menu_action issue_certificate; pause;; 2) run_menu_action import_certificate; pause;;
      3) run_menu_action list_certificates; pause;;
      4) run_menu_action delete_managed_certificate; pause;;
      0) return;; *) warn "无效选项。"; pause;;
    esac
  done
}

toggle_service_running() {
  if service_is_active; then service_action stop; else service_action start; fi
}

toggle_service_startup() {
  ensure_runtime_dependencies service
  service_exists || die "Xray OpenRC 服务不存在。"
  if service_is_enabled; then
    rc-update del "$SERVICE_NAME" default >/dev/null
    info "开机自启已关闭；当前服务运行状态未改变。"
  else
    rc-update add "$SERVICE_NAME" default >/dev/null
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
    read -r -p "请选择: " choice || { echo; return; }
    case $choice in
      1) run_menu_action toggle_service_running; pause;; 2) run_menu_action service_action restart; pause;;
      3) run_menu_action toggle_service_startup; pause;; 4) run_menu_action show_logs 100; pause;;
      5) run_menu_action install_or_update_xray install; pause;; 0) return;; *) warn "无效选项。"; pause;;
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
    printf 'BBR: %s\n\n' "$(bbr_state_summary)"
    printf '1) BBR 管理\n2) 系统诊断\n3) 修复快捷命令\n0) 返回\n'
    read -r -p "请选择: " choice || { echo; return; }
    case $choice in
      1) run_menu_action manage_bbr; pause;; 2) run_menu_action system_diagnostics; pause;;
      3) run_menu_action repair_quick_command; pause;;
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
    read -r -p "请选择: " choice || { echo; return; }
    case $choice in
      1) run_menu_action uninstall_xray 0; pause;; 2) run_menu_action uninstall_xray 1; pause;;
      0) return;; *) warn "无效选项。"; pause;;
    esac
  done
}

main_menu() {
  local choice
  while true; do
    clear_screen
    printf '%sXray Alpine 管理脚本%s  v%s\n' "$C_BOLD$C_BLUE" "$C_RESET" "$XRAYCTL_VERSION"
    show_main_summary
    show_main_inbounds
    printf '1) 入站管理\n2) 出站管理\n3) TLS 证书\n4) 服务管理\n5) 系统工具\n6) 卸载\n0) 退出\n'
    read -r -p "请选择: " choice || { echo; return; }
    case $choice in
      1) inbound_menu;; 2) outbound_menu;; 3) certificate_menu;; 4) service_menu;;
      5) system_menu;; 6) uninstall_menu;;
      0) return;; *) warn "无效选项。"; pause;;
    esac
  done
}

show_help() {
  cat <<'EOF'
xrayctl - Xray Alpine Linux 管理脚本

用法:
  xrayctl                         打开交互菜单
  xrayctl install [版本]          安装/修复（版本示例: 25.6.8）
  xrayctl update [版本]           升级 Xray
  xrayctl uninstall [--purge]     卸载；--purge 删除 Xray 配置
  xrayctl status                  查看状态
  xrayctl start|stop|restart      服务控制
  xrayctl logs [行数]             查看 OpenRC/Xray 日志
  xrayctl inbound list            列出入站
  xrayctl inbound add             交互新增入站
  xrayctl inbound show <标签>     查看入站 JSON
  xrayctl inbound rename <旧标签> <新标签>
  xrayctl inbound modify <标签>   修改监听端口/地址
  xrayctl inbound transport <标签> 修改传输与安全方式
  xrayctl inbound delete <标签> [--yes]
  xrayctl outbound list
  xrayctl outbound add
  xrayctl outbound assign <入站> <出站标签|direct>
  xrayctl outbound delete <出站标签>
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
  xrayctl bbr                     管理 BBR（交互式开启/关闭）
  xrayctl diagnose                系统诊断
  xrayctl version

支持协议: VLESS、VMess、Trojan、SOCKS5、HTTP
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
        list) ensure_config; list_inbounds;; add) add_inbound;; show) ensure_config; show_inbound "${2:?请提供入站标签}";;
        rename) rename_inbound "${2-}" "${3-}";;
        modify|edit) modify_inbound_basic "${2-}";; transport|stream) modify_inbound_transport "${2-}";;
        delete|remove) delete_inbound "${2-}" "$([[ ${3-} == --yes ]] && printf 1 || printf 0)";;
        *) die "未知 inbound 子命令：${1}";; esac;;
    outbound)
      case ${1:-list} in
        list) list_outbound_overview;; add) add_outbound;; assign|set) assign_outbound "${2-}" "${3-}";;
        delete|remove) delete_outbound "${2-}";; *) die "未知 outbound 子命令：${1}";; esac;;
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
      case ${1:-list} in list) list_certificates;; issue) issue_certificate "${2-}" "${3-}";; import) import_certificate "${2-}" "${3-}" "${4-}";; delete|remove) delete_managed_certificate "${2-}" "$([[ ${3-} == --yes ]] && printf 1 || printf 0)";; *) die "未知 cert 子命令。";; esac;;

    bbr) manage_bbr;; diagnose|doctor) system_diagnostics;; quick-command) ensure_runtime_dependencies quick-command; install_quick_command;;
    *) error "未知命令：$command"; show_help; return 2;;
  esac
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
  dispatch "$@"
fi
