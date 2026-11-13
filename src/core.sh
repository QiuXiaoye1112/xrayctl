#!/usr/bin/env bash
# xrayctl - Xray Linux terminal manager
# Project home: generated as a standalone administration script.

set -Eeuo pipefail
IFS=$'\n\t'

readonly XRAYCTL_VERSION="1.4.0"
readonly XRAYCTL_BUILD_COMMIT="${XRAYCTL_BUILD_COMMIT:-development}"
readonly XRAY_CORE_PINNED_VERSION="26.6.27"
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
TRAFFIC_FILE="${XRAYCTL_TRAFFIC_FILE:-/var/lib/xrayctl/traffic.json}"
SYSTEMD_UNIT_DIR="${XRAYCTL_SYSTEMD_UNIT_DIR:-/etc/systemd/system}"
OPENRC_INIT_DIR="${XRAYCTL_OPENRC_INIT_DIR:-/etc/init.d}"
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
BBR_CONFIG="${XRAYCTL_BBR_CONFIG:-/etc/sysctl.d/99-xrayctl-bbr.conf}"
SBCTL_BBR_CONFIG="${XRAYCTL_SBCTL_BBR_CONFIG:-/etc/sysctl.d/99-sbctl-bbr.conf}"
CERT_STOPPED_SERVICE=0
APT_IPV4_AVAILABLE_CACHE=""

CERTBOT_VENV="${XRAYCTL_CERTBOT_VENV:-/opt/xrayctl/certbot}"
CERTBOT_BIN="${CERTBOT_VENV}/bin/certbot"
CERTBOT_CONFIG_DIR="${XRAYCTL_CERTBOT_CONFIG_DIR:-/var/lib/xrayctl/letsencrypt}"
CERTBOT_WORK_DIR="${XRAYCTL_CERTBOT_WORK_DIR:-/var/lib/xrayctl/certbot-work}"
CERTBOT_LOGS_DIR="${XRAYCTL_CERTBOT_LOGS_DIR:-/var/log/xrayctl/certbot}"
_default_certbot_shared_lock=/run/lock/certbot.lock
if [[ ${XRAYCTL_TESTING:-0} == 1 ]]; then _default_certbot_shared_lock="${LOCK_FILE%/*}/certbot.lock"; fi
CERTBOT_SHARED_LOCK="${XRAYCTL_CERTBOT_SHARED_LOCK:-$_default_certbot_shared_lock}"
unset _default_certbot_shared_lock
CERTBOT_SHARED_LOCK_WAIT="${XRAYCTL_CERTBOT_SHARED_LOCK_WAIT:-300}"
CLOUDFLARE_INI="${XRAYCTL_CLOUDFLARE_INI:-/etc/xrayctl/cloudflare.ini}"
CERT_RENEW_HOOK="${XRAYCTL_CERT_RENEW_HOOK:-/etc/periodic/daily/xrayctl-certbot-renew}"

readonly _ANSI_RED=$'\033[31m' _ANSI_GREEN=$'\033[32m' _ANSI_YELLOW=$'\033[33m'
readonly _ANSI_BLUE=$'\033[34m' _ANSI_CYAN=$'\033[36m'
readonly _ANSI_BOLD=$'\033[1m' _ANSI_DIM=$'\033[2m' _ANSI_RESET=$'\033[0m'

if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
  C_RED=$_ANSI_RED; C_GREEN=$_ANSI_GREEN; C_YELLOW=$_ANSI_YELLOW; C_CYAN=$_ANSI_CYAN
  C_BOLD=$_ANSI_BOLD; C_DIM=$_ANSI_DIM; C_RESET=$_ANSI_RESET
else
  C_RED=""; C_GREEN=""; C_YELLOW=""; C_CYAN=""
  C_BOLD=""; C_DIM=""; C_RESET=""
fi

_ui_put() {
  local style=$1 text=$2 fd=${3:-1}
  if [[ -t $fd && -z ${NO_COLOR:-} ]]; then
    printf '%s%s%s' "$style" "$text" "$_ANSI_RESET" >&"$fd"
  else
    printf '%s' "$text" >&"$fd"
  fi
}

ui_width() {
  local cols=${COLUMNS:-}
  if [[ ! $cols =~ ^[0-9]+$ ]] && [[ -t 1 ]] && command_exists tput; then
    cols=$(tput cols 2>/dev/null || true)
  fi
  if [[ ! $cols =~ ^[0-9]+$ ]] || ((cols <= 0)); then
    cols=72
  fi
  ((cols < 64)) && cols=64
  ((cols > 78)) && cols=78
  printf '%s' "$cols"
}

ui_repeat() {
  local char=$1 count=$2 out="" i
  ((count > 0)) || return 0
  for ((i=0; i<count; i++)); do out+=$char; done
  printf '%s' "$out"
}

ui_rule() {
  local indent=${1:-2} width
  width=$(( $(ui_width) - indent ))
  ((width > 10)) || width=10
  printf '%*s' "$indent" ''
  _ui_put "$_ANSI_DIM" "$(ui_repeat '─' "$width")"
  printf '\n'
}

ui_badge() {
  local tone=$1 text=$2
  case $tone in
    ok)    _ui_put "$_ANSI_GREEN" "● ${text}" ;;
    warn)  _ui_put "$_ANSI_YELLOW" "● ${text}" ;;
    err)   _ui_put "$_ANSI_RED" "● ${text}" ;;
    info)  _ui_put "$_ANSI_CYAN" "◆ ${text}" ;;
    muted) _ui_put "$_ANSI_DIM" "○ ${text}" ;;
    *)     printf '%s' "$text" ;;
  esac
}

ui_banner() {
  local title=$1 right=${2-} width inner pad title_w right_w border
  width=$(ui_width)
  inner=$((width - 4))
  display_width title_w "$title"
  display_width right_w "$right"
  pad=$((inner - title_w - right_w - 2))
  ((pad >= 1)) || pad=1
  border=$(ui_repeat '─' "$inner")
  printf '\n  '; _ui_put "$_ANSI_CYAN" "╭${border}╮"; printf '\n'
  printf '  '; _ui_put "$_ANSI_CYAN" '│'; printf ' '
  _ui_put "${_ANSI_BOLD}${_ANSI_CYAN}" "$title"
  printf '%*s' "$pad" ''
  _ui_put "$_ANSI_DIM" "$right"
  printf ' '; _ui_put "$_ANSI_CYAN" '│'; printf '\n'
  printf '  '; _ui_put "$_ANSI_CYAN" "╰${border}╯"; printf '\n'
}

ui_section() {
  printf '\n  '
  _ui_put "${_ANSI_BOLD}${_ANSI_BLUE}" "▸ ${1}"
  printf '\n'
}

ui_menu_group() {
  printf '\n  '
  _ui_put "${_ANSI_BOLD}${_ANSI_BLUE}" "▸ ${1}"
  printf '\n'
}

ui_menu_item() {
  local key=$1 label=$2 desc=${3-}
  printf '    '
  _ui_put "${_ANSI_BOLD}${_ANSI_CYAN}" "${key})"
  if [[ -n $desc ]]; then
    printf ' '
    print_table_cell "$label" 18
    printf ' '
    _ui_put "$_ANSI_DIM" "$desc"
  else
    printf ' %s' "$label"
  fi
  printf '\n'
}

ui_menu_footer() {
  local label=${1:-返回}
  printf '\n'
  ui_rule 2
  printf '    '
  _ui_put "${_ANSI_DIM}${_ANSI_BOLD}" '0)'
  printf ' %s\n' "$label"
}

ui_kv() {
  local label=$1 value=$2 width=${3:-12} cell
  printf -v cell '%s' "$label"
  printf '  '
  if [[ -t 1 && -z ${NO_COLOR:-} ]]; then
    printf '%s' "$_ANSI_DIM"
    print_table_cell "$cell" "$width"
    printf '%s' "$_ANSI_RESET"
  else
    print_table_cell "$cell" "$width"
  fi
  printf ' %s\n' "$value"
}

ui_card_open() {
  local title=$1 width bar_len title_w
  width=$(ui_width)
  display_width title_w "$title"
  bar_len=$((width - title_w - 6))
  ((bar_len >= 4)) || bar_len=4
  printf '\n  '
  _ui_put "$_ANSI_DIM" '┌─ '
  _ui_put "${_ANSI_BOLD}${_ANSI_CYAN}" "$title"
  printf ' '
  _ui_put "$_ANSI_DIM" "$(ui_repeat '─' "$bar_len")"
  printf '\n'
}

ui_card_kv() {
  local label=$1 value=$2 width=${3:-12}
  printf '  '
  _ui_put "$_ANSI_DIM" '│'
  printf ' '
  if [[ -t 1 && -z ${NO_COLOR:-} ]]; then
    printf '%s' "$_ANSI_DIM"
    print_table_cell "$label" "$width"
    printf '%s' "$_ANSI_RESET"
  else
    print_table_cell "$label" "$width"
  fi
  printf ' %s\n' "$value"
}

ui_card_line() {
  printf '  '
  _ui_put "$_ANSI_DIM" '│'
  printf ' %s\n' "$1"
}

ui_card_close() {
  local width
  width=$(( $(ui_width) - 3 ))
  ((width > 10)) || width=10
  printf '  '
  _ui_put "$_ANSI_DIM" "└$(ui_repeat '─' "$width")"
  printf '\n'
}

ui_wizard_step() {
  local step=$1 total=$2 title=$3 hint=${4-} width bar_len header_text header_w badge
  width=$(ui_width)
  if [[ -n $total && $total != 0 ]]; then
    badge="[${step}/${total}]"
  else
    badge="[步骤 ${step}]"
  fi
  header_text="${badge} ${title}"
  display_width header_w "$header_text"
  bar_len=$((width - header_w - 6))
  ((bar_len >= 4)) || bar_len=4
  printf '\n  '
  _ui_put "$_ANSI_DIM" '┌─ '
  _ui_put "${_ANSI_BOLD}${_ANSI_CYAN}" "$badge"
  printf ' '
  _ui_put "$_ANSI_BOLD" "$title"
  printf ' '
  _ui_put "$_ANSI_DIM" "$(ui_repeat '─' "$bar_len")"
  printf '\n'
  if [[ -n $hint ]]; then
    printf '  '
    _ui_put "$_ANSI_DIM" '│'
    printf ' '
    _ui_put "$_ANSI_DIM" "$hint"
    printf '\n'
  fi
}

ui_progress_enabled() {
  [[ ${XRAYCTL_UI_PROGRESS:-} == 1 ]] && return 0
  [[ ${XRAYCTL_UI_PROGRESS:-} == 0 ]] && return 1
  [[ -t 1 && ${XRAYCTL_TESTING:-0} != 1 ]]
}

ui_step() {
  local step=$1 total=$2 label=$3
  ui_progress_enabled || return 0
  printf '  ' >&2
  _ui_put "$_ANSI_CYAN" "[${step}/${total}]" 2
  printf ' %s ... ' "$label" >&2
}

ui_step_done() {
  local status=${1:-ok} detail=${2-}
  ui_progress_enabled || return 0
  case $status in
    ok)   _ui_put "$_ANSI_GREEN" '✓' 2 ;;
    warn) _ui_put "$_ANSI_YELLOW" '!' 2 ;;
    fail) _ui_put "$_ANSI_RED" '✗' 2 ;;
  esac
  if [[ -n $detail ]]; then
    printf ' ' >&2
    _ui_put "$_ANSI_DIM" "$detail" 2
  fi
  printf '\n' >&2
}

print_notice() {
  local label=$1 color=$2 title=${3-} detail line rendered
  shift 3
  if [[ $title == *$'\n'* ]]; then
    set -- "${title#*$'\n'}" "$@"
    title=${title%%$'\n'*}
  fi
  printf -v rendered '\n%s%s%s · %s\n' "$color" "$label" "$C_RESET" "$title"
  for detail in "$@"; do
    [[ -n $detail ]] || continue
    while IFS= read -r line; do
      if [[ -n $line ]]; then printf -v rendered '%s  %s\n' "$rendered" "$line"
      else printf -v rendered '%s\n' "$rendered"; fi
    done <<<"$detail"
  done
  # Emit one block on one stream so details cannot overtake their warning.
  printf '%s' "$rendered"
}

info()    { print_notice "信息" "$C_GREEN" "${1-}" "${@:2}"; }
warn()    { print_notice "警告" "$C_YELLOW" "${1-}" "${@:2}" >&2; }
error()   { print_notice "错误" "$C_RED" "${1-}" "${@:2}" >&2; }
die()     { error "$*"; exit 1; }
heading() {
  local title="$*" width bar_len title_w
  width=$(ui_width)
  if [[ -n ${XRAYCTL_UI_CRUMB:-} ]]; then
    printf '\n  '
    _ui_put "$_ANSI_DIM" "$XRAYCTL_UI_CRUMB"
    printf '\n'
  else
    printf '\n'
  fi
  display_width title_w "$title"
  bar_len=$((width - title_w - 5))
  ((bar_len >= 4)) || bar_len=4
  printf '  '
  _ui_put "${_ANSI_BOLD}${_ANSI_CYAN}" "▸ ${title}"
  printf ' '
  _ui_put "$_ANSI_DIM" "$(ui_repeat '─' "$bar_len")"
  printf '\n'
}
clear_screen() { clear 2>/dev/null || true; }

on_error() {
  local exit_code=$? line=${BASH_LINENO[0]:-?}
  [[ ${XRAYCTL_INPUT_CANCELLED:-0} != 1 ]] || exit 0
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
  local prompt=${1:-"确定继续吗？"} default=${2:-N} answer
  if [[ ! -t 0 ]]; then [[ $default == Y ]]; return; fi
  printf '\n' >&2
  read -r -p "${prompt} [Y/N]: " answer || { cancel_input; return 1; }
  answer=${answer:-$default}
  [[ $answer =~ ^[Yy]$ ]]
}

cancel_input() {
  XRAYCTL_INPUT_CANCELLED=1
  printf '\n'
  return 0
}

cancel_selection() {
  cancel_input
}

prompt_value() {
  local __var=$1 prompt=$2 default=${3-} input_value
  while true; do
    if [[ -n $default ]]; then
      if ! read -r -p "${prompt} [${default}]: " input_value; then cancel_input; return 1; fi
      input_value=${input_value:-$default}
    else
      if ! read -r -p "${prompt}: " input_value; then cancel_input; return 1; fi
      if [[ -z $input_value ]]; then warn "此项不能为空，请重新输入。"; continue; fi
    fi
    printf -v "$__var" '%s' "$input_value"
    return 0
  done
}

prompt_optional_value() {
  local __var=$1 prompt=$2 input_value=""
  if ! read -r -p "${prompt}: " input_value; then cancel_input; return 1; fi
  printf -v "$__var" '%s' "$input_value"
}

prompt_secret() {
  local __var=$1 prompt=$2 generated=${3-} secret_value=""
  if [[ -n $generated ]]; then
    if ! read -r -p "${prompt}（留空自动生成）: " secret_value; then cancel_input; return 1; fi
    secret_value=${secret_value:-$generated}
  else
    while [[ -z $secret_value ]]; do
      if ! read -r -p "${prompt}: " secret_value; then cancel_input; return 1; fi
      [[ -n $secret_value ]] || warn "密码不能为空，请重新输入。"
    done
  fi
  printf -v "$__var" '%s' "$secret_value"
}

prompt_hidden_secret() {
  local __var=$1 prompt=$2 value=""
  while [[ -z $value ]]; do
    printf '%s: ' "$prompt"
    if ! read -r -s value; then cancel_input; return 1; fi
    printf '\n'
    [[ -n $value ]] || warn "不能为空，请重新输入。"
  done
  printf -v "$__var" '%s' "$value"
}

choose() {
  local __var=$1 prompt=$2; shift 2
  local options=("$@") selected_value i
  printf '\n  '
  _ui_put "$_ANSI_BOLD" "$prompt"
  printf '\n'
  for ((i=0; i<${#options[@]}; i++)); do
    printf '    '
    _ui_put "${_ANSI_BOLD}${_ANSI_CYAN}" "$((i+1)))"
    printf ' %s\n' "${options[$i]}"
  done
  while true; do
    read -r -p "请选择 [1-${#options[@]}]: " selected_value || { cancel_selection; return 1; }
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
  local __var=$1 value=$2 char code b1 b2 cp computed_width=0 i len
  local LC_ALL=C
  len=${#value}
  for ((i=0; i<len; i++)); do
    if [[ ${value:i:2} == $'\033[' ]]; then
      ((i+=2))
      while ((i < len)); do
        char=${value:i:1}
        [[ $char == m ]] && break
        ((i+=1))
      done
      continue
    fi
    char=${value:i:1}
    printf -v code '%d' "'$char"
    # musl represents high C-locale bytes as U+DFxx; restore unsigned bytes.
    code=$((code & 255))
    if ((code < 128)); then
      ((computed_width+=1))
    elif ((code >= 194 && code <= 223 && i + 1 < len)); then
      ((computed_width+=1, i+=1))
    elif ((code >= 224 && code <= 239 && i + 2 < len)); then
      printf -v b1 '%d' "'${value:i+1:1}"; b1=$((b1 & 255))
      printf -v b2 '%d' "'${value:i+2:1}"; b2=$((b2 & 255))
      cp=$(( ((code & 15) << 12) | ((b1 & 63) << 6) | (b2 & 63) ))
      if ((cp >= 0x2010 && cp <= 0x27BF)); then
        ((computed_width+=1))
      else
        ((computed_width+=2))
      fi
      ((i+=2))
    elif ((code >= 240 && code <= 244 && i + 3 < len)); then
      ((computed_width+=2, i+=3))
    elif (( (code & 0xC0) != 0x80 )); then
      ((computed_width+=2))
    fi
  done
  printf -v "$__var" '%s' "$computed_width"
}

print_table_cell() {
  local value=$1 target_width=$2 width padding
  display_width width "$value"
  padding=$((target_width-width))
  ((padding > 0)) || padding=0
  printf '%s%*s' "$value" "$padding" ''
}

print_table_cell_right() {
  local value=$1 target_width=$2 width padding
  display_width width "$value"
  padding=$((target_width-width))
  ((padding > 0)) || padding=0
  printf '%*s%s' "$padding" '' "$value"
}

print_table_cell_clipped() {
  local value=$1 target_width=$2 width limit clipped="" used=0 char char_width i
  display_width width "$value"
  if ((width <= target_width)); then print_table_cell "$value" "$target_width"; return; fi
  limit=$((target_width-4)); ((limit > 0)) || limit=1
  for ((i=0; i<${#value}; i++)); do
    char=${value:i:1}; display_width char_width "$char"
    ((used+char_width <= limit)) || break
    clipped+=$char; ((used+=char_width))
  done
  print_table_cell "${clipped}..." "$target_width"
}

run_menu_action() {
  local action_status previous_err_trap action_error=0
  previous_err_trap=$(trap -p ERR || true)
  trap - ERR
  set +e
  (
    set -Eeuo pipefail
    XRAYCTL_INPUT_CANCELLED=0
    trap 'action_error=$?; if [[ ${XRAYCTL_INPUT_CANCELLED:-0} == 1 ]]; then exit 0; fi; exit "$action_error"' ERR
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
