#!/usr/bin/env bash
# xrayctl - Xray Linux terminal manager
# Project home: generated as a standalone administration script.

set -Eeuo pipefail
IFS=$'\n\t'

readonly XRAYCTL_VERSION="1.2.30"
readonly XRAYCTL_BUILD_COMMIT="${XRAYCTL_BUILD_COMMIT:-development}"
readonly OFFICIAL_INSTALLER_URL="https://github.com/XTLS/Xray-install/raw/main/install-release.sh"
readonly XRAY_RELEASE_API="https://api.github.com/repos/XTLS/Xray-core/releases/latest"
readonly XRAY_RELEASE_BASE="https://github.com/XTLS/Xray-core/releases/download"
readonly SCRIPT_DOWNLOAD_URL="${XRAYCTL_SCRIPT_URL:-https://raw.githubusercontent.com/QiuXiaoye1112/xrayctl/main/dist/xrayctl}"
readonly JQ_VERSION="1.8.2"

XRAY_BIN="${XRAYCTL_XRAY_BIN:-/usr/local/bin/xray}"
CONFIG_DIR="${XRAYCTL_CONFIG_DIR:-/usr/local/etc/xray}"
CONFIG_FILE="${XRAYCTL_CONFIG_FILE:-${CONFIG_DIR}/config.json}"
META_FILE="${XRAYCTL_META_FILE:-${CONFIG_DIR}/xrayctl.meta.json}"
CERT_DIR="${XRAYCTL_CERT_DIR:-${CONFIG_DIR}/certs}"
LOG_DIR="${XRAYCTL_LOG_DIR:-/var/log/xray}"
XRAY_SHARE_DIR="${XRAYCTL_SHARE_DIR:-/usr/local/share/xray}"
export XRAY_LOCATION_ASSET="$XRAY_SHARE_DIR"
BACKUP_DIR="${XRAYCTL_BACKUP_DIR:-/var/backups/xrayctl}"
BACKUP_OWNERSHIP_MARKER="${BACKUP_DIR}/.xrayctl-owned"
readonly BACKUP_OWNERSHIP_MAGIC="xrayctl-backup-directory-v1"
QUICK_COMMAND="${XRAYCTL_COMMAND_PATH:-/usr/local/sbin/xrayctl}"
QUICK_SYMLINK="${XRAYCTL_SYMLINK_PATH:-/usr/local/bin/xrayctl}"
SERVICE_NAME="${XRAYCTL_SERVICE_NAME:-xray}"
SYSTEMD_UNIT="${SERVICE_NAME}.service"
OPENRC_SERVICE="${XRAYCTL_OPENRC_SERVICE:-/etc/init.d/${SERVICE_NAME}}"
RUNTIME_OWNER="${XRAYCTL_RUNTIME_OWNER:-root}"
RUNTIME_USER="${XRAYCTL_RUNTIME_USER:-xray}"
RUNTIME_GROUP="${XRAYCTL_RUNTIME_GROUP:-xrayctl}"
SYSTEMD_OVERRIDE_DIR="${XRAYCTL_SYSTEMD_OVERRIDE_DIR:-/etc/systemd/system/${SYSTEMD_UNIT}.d}"
LOCK_FILE="${XRAYCTL_LOCK_FILE:-/run/lock/xrayctl.lock}"
JQ_INSTALL_PATH="${XRAYCTL_JQ_INSTALL_PATH:-/usr/local/bin/jq}"
SBCTL_CONFIG_FILE="${XRAYCTL_SBCTL_CONFIG_FILE:-/etc/sing-box/config.json}"
SBCTL_META_FILE="${XRAYCTL_SBCTL_META_FILE:-/var/lib/sbctl/meta.json}"
BBR_CONFIG="${XRAYCTL_BBR_CONFIG:-/etc/sysctl.d/99-xrayctl-bbr.conf}"
SBCTL_BBR_CONFIG="${XRAYCTL_SBCTL_BBR_CONFIG:-/etc/sysctl.d/99-sbctl-bbr.conf}"
CERT_STOPPED_SERVICE=0
APT_IPV4_AVAILABLE_CACHE=""

CERTBOT_VENV="${XRAYCTL_CERTBOT_VENV:-/opt/xrayctl/certbot}"
CERTBOT_BIN="${CERTBOT_VENV}/bin/certbot"
CERTBOT_CONFIG_DIR="${XRAYCTL_CERTBOT_CONFIG_DIR:-/var/lib/xrayctl/letsencrypt}"
CERTBOT_WORK_DIR="${XRAYCTL_CERTBOT_WORK_DIR:-/var/lib/xrayctl/certbot-work}"
CERTBOT_LOGS_DIR="${XRAYCTL_CERTBOT_LOGS_DIR:-/var/log/xrayctl/certbot}"
_default_certbot_shared_lock=/run/lock/xrayctl-sbctl-certbot.lock
if [[ ${XRAYCTL_TESTING:-0} == 1 ]]; then _default_certbot_shared_lock="${LOCK_FILE%/*}/xrayctl-sbctl-certbot.lock"; fi
CERTBOT_SHARED_LOCK="${XRAYCTL_CERTBOT_SHARED_LOCK:-$_default_certbot_shared_lock}"
unset _default_certbot_shared_lock
CERTBOT_SHARED_LOCK_WAIT="${XRAYCTL_CERTBOT_SHARED_LOCK_WAIT:-300}"
CLOUDFLARE_INI="${XRAYCTL_CLOUDFLARE_INI:-/etc/xrayctl/cloudflare.ini}"
CERT_RENEW_HOOK="${XRAYCTL_CERT_RENEW_HOOK:-/etc/periodic/daily/xrayctl-certbot-renew}"

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
  if [[ ${CERT_STOPPED_SERVICE:-0} == 1 ]]; then
    platform_service_start >/dev/null 2>&1 || true
  fi
}
trap cleanup_on_exit EXIT

is_root() { [[ $(id -u) -eq 0 ]]; }
require_root() { is_root || die "此操作需要 root 权限，请使用 sudo xrayctl $*."; }
command_exists() { command -v "$1" >/dev/null 2>&1; }
is_linux() { [[ $(uname -s) == "Linux" ]]; }

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

prompt_hidden_secret() {
  local __var=$1 prompt=$2 value=""
  while [[ -z $value ]]; do
    printf '%s: ' "$prompt"
    if ! read -r -s value; then printf '\n'; warn "输入已中断。"; return 1; fi
    printf '\n'
    [[ -n $value ]] || warn "不能为空，请重新输入。"
  done
  printf -v "$__var" '%s' "$value"
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
  local action_status previous_err_trap
  previous_err_trap=$(trap -p ERR || true)
  trap - ERR
  set +e
  (
    set -Eeuo pipefail
    trap 'exit $?' ERR
    trap cleanup_on_exit EXIT
    "$@"
  )
  action_status=$?
  set -e
  if [[ -n $previous_err_trap ]]; then
    eval "$previous_err_trap"
  else
    trap - ERR
  fi
  if ((action_status != 0)); then
    warn "操作未完成，脚本仍在运行，请检查输入后重试。"
  fi
  return 0
}

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
