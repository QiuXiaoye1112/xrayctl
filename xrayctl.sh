#!/usr/bin/env bash
# xrayctl development entrypoint. Business code lives in src/.

readonly XRAYCTL_SOURCE_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=src/core.sh
source "${XRAYCTL_SOURCE_DIR}/src/core.sh"

# shellcheck source=src/platform.sh
source "${XRAYCTL_SOURCE_DIR}/src/platform.sh"

# shellcheck source=src/state.sh
source "${XRAYCTL_SOURCE_DIR}/src/state.sh"

# shellcheck source=src/security.sh
source "${XRAYCTL_SOURCE_DIR}/src/security.sh"

# shellcheck source=src/certificate.sh
source "${XRAYCTL_SOURCE_DIR}/src/certificate.sh"

# shellcheck source=src/protocols.sh
source "${XRAYCTL_SOURCE_DIR}/src/protocols.sh"

_freedom_tag_for_ip() {
  local ip=$1
  printf 'local-%s' "$(printf '%s' "$ip" | tr ':.' '--')"
}

_ensure_freedom_outbound() {
  # 确保指定 IP 的 freedom 出站存在，返回其 tag
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

is_xrayctl_certbot_venv() {
  [[ -d $CERTBOT_VENV ]] || return 1
  [[ -x ${CERTBOT_VENV}/bin/python ]] || return 1
  [[ -x ${CERTBOT_VENV}/bin/certbot ]] || return 1
  [[ -x ${CERTBOT_VENV}/bin/pip ]] || return 1
}

is_xrayctl_quick_command() {
  [[ -f $QUICK_COMMAND ]] || return 1
  grep -q '^# xrayctl - Xray Linux terminal manager' "$QUICK_COMMAND" 2>/dev/null
}

is_xrayctl_symlink() {
  [[ -L $QUICK_SYMLINK ]] || return 1
  local target
  target=$(readlink -f "$QUICK_SYMLINK" 2>/dev/null || true)
  [[ $target == "$QUICK_COMMAND" ]]
}

is_xrayctl_certbot_symlink() {
  [[ -L /usr/local/bin/certbot ]] || return 1
  local target
  target=$(readlink -f /usr/local/bin/certbot 2>/dev/null || true)
  [[ $target == "${CERTBOT_VENV}/bin/certbot" ]]
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
  meta_resource_register "configDir" "$CONFIG_DIR"
  meta_resource_register "certDir" "$CERT_DIR"
  meta_resource_register "runtimeGroup" "$RUNTIME_GROUP"
}

setup_certificate_access() { setup_runtime_access; }

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
  local mode=${1:-install} version=${2:-} installer installed_before=0
  xray_installed && installed_before=1
  installer=$(temp_file)
  info "从 XTLS 官方仓库下载安装脚本。"
  curl --fail --location --proto '=https' --tlsv1.2 --retry 3 --connect-timeout 15 --max-time 180 "$OFFICIAL_INSTALLER_URL" -o "$installer"
  chmod 700 "$installer"
  if [[ -n $version ]]; then TERM="${TERM:-xterm}" bash "$installer" install --version "${version#v}";
  else TERM="${TERM:-xterm}" bash "$installer" install; fi
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
  local source=${BASH_SOURCE[0]:-} downloaded=""
  mkdir -p "$(dirname "$QUICK_COMMAND")" "$(dirname "$QUICK_SYMLINK")"

  if [[ -n $source && -r $source ]] && grep -q '^# xrayctl - Xray Linux terminal manager' "$source" 2>/dev/null; then
    :
  elif [[ -f $QUICK_COMMAND ]] && grep -q '^# xrayctl - Xray Linux terminal manager' "$QUICK_COMMAND" 2>/dev/null; then
    source=$QUICK_COMMAND
  else
    downloaded=$(temp_file)
    info "正在下载快捷命令脚本。"
    if ! curl --fail --location --proto '=https' --tlsv1.2 --retry 3 \
      --connect-timeout 15 --max-time 120 "$SCRIPT_DOWNLOAD_URL" -o "$downloaded"; then
      rm -f "$downloaded"
      die "快捷命令脚本下载失败。"
    fi
    grep -q '^# xrayctl - Xray Linux terminal manager' "$downloaded" \
      || { rm -f "$downloaded"; die "快捷命令脚本校验失败。"; }
    source=$downloaded
  fi
  if [[ -e $QUICK_COMMAND && ! $source -ef $QUICK_COMMAND ]] && ! grep -q '^# xrayctl - Xray Linux terminal manager' "$QUICK_COMMAND" 2>/dev/null; then
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
  meta_resource_register "quickCommand" "$QUICK_COMMAND"
  meta_resource_register "quickSymlink" "$QUICK_SYMLINK"
}

# ============================================================
# Uninstall — three levels
#   Level 0: remove Xray core, keep config/certs/backups/xrayctl/timer
#   Level 1: full uninstall, keep backups
#   Level 2: purge everything xrayctl ever created
# ============================================================

cleanup_step() {
  local description=$1
  shift
  printf '  %s ... ' "$description"
  if "$@" 2>/dev/null; then
    printf '✓\n'
    return 0
  else
    printf '✗\n'
    return 1
  fi
}

safe_remove_dir() {
  local path=$1 allowed matched=0
  [[ -n $path ]] || return 1
  [[ $path == /* ]] || return 1
  case $path in
    /|/usr|/usr/local|/etc|/var|/var/lib|/var/log|/opt|/home|/root)
      warn "拒绝删除危险路径：$path"; return 1 ;;
  esac
  shift
  for allowed in "$@"; do
    [[ $path == "$allowed" ]] && { matched=1; break; }
  done
  ((matched)) || { warn "路径不在允许删除列表：$path"; return 1; }
  [[ -e $path ]] || return 0
  rm -rf -- "$path"
}

safe_remove_file() {
  local path=$1 allowed matched=0
  [[ -n $path ]] || return 1
  [[ $path == /* ]] || return 1
  shift
  for allowed in "$@"; do
    [[ $path == "$allowed" ]] && { matched=1; break; }
  done
  ((matched)) || { warn "路径不在允许删除列表：$path"; return 1; }
  [[ -e $path ]] || return 0
  rm -f -- "$path"
}

safe_remove_managed_dir() {
  local resource_key=$1 path=$2 recorded
  [[ -n $path && $path == /* ]] || return 1
  case $path in
    /|/usr|/usr/local|/etc|/var|/var/lib|/var/log|/opt|/home|/root)
      warn "拒绝删除危险路径：$path"; return 1 ;;
  esac
  [[ -e $path ]] || return 0
  recorded=$(_snapshot_meta_resource_get "$resource_key")
  [[ -n $recorded ]] || { warn "缺少资产登记，拒绝删除：$path"; return 1; }
  [[ $recorded == "$path" ]] || { warn "资产路径不匹配，拒绝删除：$path (登记: $recorded)"; return 1; }
  rm -rf -- "$path"
}

safe_remove_managed_file() {
  local resource_key=$1 path=$2 recorded
  [[ -n $path && $path == /* ]] || return 1
  case $path in
    /|/etc|/usr|/usr/local|/var|/opt|/home|/root)
      warn "拒绝删除危险路径：$path"; return 1 ;;
  esac
  [[ -e $path ]] || return 0
  recorded=$(_snapshot_meta_resource_get "$resource_key")
  [[ -n $recorded ]] || { warn "缺少资产登记，拒绝删除：$path"; return 1; }
  [[ $recorded == "$path" ]] || { warn "资产路径不匹配，拒绝删除：$path (登记: $recorded)"; return 1; }
  rm -f -- "$path"
}

meta_resource_remove_existing() {
  local key=$1 tmp
  [[ -f $META_FILE ]] || return 0
  jq -e 'type=="object"' "$META_FILE" >/dev/null 2>&1 || return 0
  tmp=$(temp_file)
  jq --arg key "$key" 'del(.managedResources[$key])' "$META_FILE" >"$tmp" || { rm -f "$tmp"; return 1; }
  install -m 600 "$tmp" "$META_FILE"; rm -f "$tmp"
}

meta_resource_get_existing() {
  [[ -f $META_FILE ]] || return 1
  jq -r --arg key "$1" '.managedResources[$key] // empty' "$META_FILE" 2>/dev/null
}

_uninstall_snapshot_metadata() {
  SNAPSHOT_META=$(temp_file)
  if [[ -f $META_FILE ]]; then
    cp "$META_FILE" "$SNAPSHOT_META"
  else
    printf '{"certificates":{},"managedResources":{}}' >"$SNAPSHOT_META"
  fi
}

_snapshot_meta_cert_list() {
  jq -r '.certificates | keys[]' "$SNAPSHOT_META" 2>/dev/null
}

_snapshot_meta_cert_get_field() {
  jq -r --arg id "$1" --arg field "$2" ".certificates[\$id][\$field] // empty" "$SNAPSHOT_META"
}

_snapshot_meta_resource_get() {
  jq -r --arg key "$1" ".managedResources[\$key] // empty" "$SNAPSHOT_META" 2>/dev/null
}

can_remove_certbot_venv() {
  local recorded
  recorded=$(_snapshot_meta_resource_get "certbotVenv")
  [[ -n $recorded && $recorded == "$CERTBOT_VENV" ]] || return 1
  is_xrayctl_certbot_venv
}

_uninstall_disable_timers() {
  systemctl disable --now xrayctl-certbot-renew.timer >/dev/null 2>&1 || true
  systemctl stop xrayctl-certbot-renew.service >/dev/null 2>&1 || true
  rm -f /etc/systemd/system/xrayctl-certbot-renew.service /etc/systemd/system/xrayctl-certbot-renew.timer
  systemctl daemon-reload 2>/dev/null || true
  meta_resource_remove_existing "renewTimer"; meta_resource_remove_existing "renewService"
}

_uninstall_remove_managed_certs() {
  local id cert_name source rc=0
  while IFS= read -r id; do
    [[ -n $id ]] || continue
    cert_name=$(_snapshot_meta_cert_get_field "$id" certName)
    source=$(_snapshot_meta_cert_get_field "$id" source)
    case $source in
      letsencrypt)
        if [[ -n $cert_name ]]; then
          if ! certbot_cmd delete --cert-name "$cert_name" --non-interactive >/dev/null 2>&1; then
            warn "Certbot 证书 ${cert_name} 删除失败，将随 Certbot 目录一并清理。"
            rc=1
          fi
        fi
        ;;
    esac
    rm -f "${CERT_DIR}/${id}.crt" "${CERT_DIR}/${id}.key"
    meta_cert_delete "$id"
  done < <(_snapshot_meta_cert_list)
  return $rc
}

_uninstall_remove_certbot() {
  if can_remove_certbot_venv; then
    if is_xrayctl_certbot_symlink; then rm -f /usr/local/bin/certbot; fi
    safe_remove_managed_dir "certbotConfigDir" "$CERTBOT_CONFIG_DIR"
    safe_remove_managed_dir "certbotWorkDir" "$CERTBOT_WORK_DIR"
    safe_remove_managed_dir "certbotLogsDir" "$CERTBOT_LOGS_DIR"
    safe_remove_managed_dir "certbotVenv" "$CERTBOT_VENV"
    meta_resource_remove_existing "certbotVenv"; meta_resource_remove_existing "certbotConfigDir"
    meta_resource_remove_existing "certbotWorkDir"; meta_resource_remove_existing "certbotLogsDir"
  elif [[ ! -d $CERTBOT_VENV ]]; then
    return 0
  else
    warn "Certbot 环境未通过所有权验证，跳过删除。"
    return 1
  fi
}

_uninstall_remove_cloudflare() {
  safe_remove_managed_file "cloudflareCredentials" "$CLOUDFLARE_INI"
  rmdir "$(dirname "$CLOUDFLARE_INI")" 2>/dev/null || true
  meta_resource_remove_existing "cloudflareCredentials"
}

_uninstall_remove_config() {
  [[ -f $CONFIG_FILE ]] && rm -f "$CONFIG_FILE"
  [[ -d $CERT_DIR ]] && safe_remove_managed_dir "certDir" "$CERT_DIR"
  [[ -f $META_FILE ]] && rm -f "$META_FILE"
  [[ -d $CONFIG_DIR ]] && rmdir "$CONFIG_DIR" 2>/dev/null || true
}

_uninstall_remove_runtime_group() {
  if [[ $RUNTIME_GROUP == xrayctl ]]; then
    getent group "$RUNTIME_GROUP" >/dev/null 2>&1 && groupdel "$RUNTIME_GROUP" 2>/dev/null || true
  fi
  meta_resource_remove_existing "runtimeGroup"
}

_uninstall_remove_systemd_overrides() {
  rm -f "${SYSTEMD_OVERRIDE_DIR}/20-xrayctl-access.conf" "${SYSTEMD_OVERRIDE_DIR}/20-xrayctl-certificates.conf"
  rmdir "$SYSTEMD_OVERRIDE_DIR" 2>/dev/null || true
  systemctl daemon-reload 2>/dev/null || true
}

_uninstall_remove_quick_command() {
  if is_xrayctl_symlink; then rm -f "$QUICK_SYMLINK"; fi
  if is_xrayctl_quick_command; then rm -f "$QUICK_COMMAND"; fi
  meta_resource_remove_existing "quickCommand"; meta_resource_remove_existing "quickSymlink"
  hash -r 2>/dev/null || true
}

_uninstall_remove_backups() {
  safe_remove_managed_dir "backupDir" "$BACKUP_DIR"
}

_uninstall_remove_logs() {
  safe_remove_dir /var/log/xray /var/log/xray
}

_cleanup_legacy_resources() {
  for hook in /etc/letsencrypt/renewal-hooks/deploy/xrayctl-*; do
    [[ -e $hook ]] && rm -f "$hook"
  done
  if [[ -L /usr/local/bin/certbot ]] && is_xrayctl_certbot_symlink; then
    rm -f /usr/local/bin/certbot
  fi
  rm -f /etc/letsencrypt/renewal/xrayctl-*.conf 2>/dev/null || true
}

_uninstall_xray_core_fallback() {
  systemctl disable --now xray.service >/dev/null 2>&1 || true
  systemctl disable --now xray@.service >/dev/null 2>&1 || true
  rm -f /etc/systemd/system/xray.service /etc/systemd/system/xray@.service
  rm -rf /etc/systemd/system/xray.service.d 2>/dev/null || true
  rm -f /usr/local/bin/xray /usr/local/bin/xray-linux-*
  rm -rf /usr/local/share/xray 2>/dev/null || true
  systemctl daemon-reload 2>/dev/null || true
}

_uninstall_xray_core() {
  local installer
  installer=$(temp_file)
  if curl --fail --location --proto '=https' --tlsv1.2 --retry 3 --connect-timeout 15 --max-time 180 \
    "$OFFICIAL_INSTALLER_URL" -o "$installer" 2>/dev/null; then
    chmod 700 "$installer"
    TERM="${TERM:-xterm}" bash "$installer" remove --purge >/dev/null 2>&1 || true
    rm -f "$installer"
    return 0
  else
    rm -f "$installer"
    warn "无法下载 Xray 官方卸载脚本，使用本地安全回退。"
    _uninstall_xray_core_fallback
    return 0
  fi
}

_uninstall_xray_core_keep_config() {
  local installer
  installer=$(temp_file)
  if curl --fail --location --proto '=https' --tlsv1.2 --retry 3 --connect-timeout 15 --max-time 180 \
    "$OFFICIAL_INSTALLER_URL" -o "$installer" 2>/dev/null; then
    chmod 700 "$installer"
    TERM="${TERM:-xterm}" bash "$installer" remove >/dev/null 2>&1 || true
    rm -f "$installer"
    return 0
  else
    rm -f "$installer"
    warn "无法下载 Xray 官方卸载脚本，使用本地安全回退。"
    _uninstall_xray_core_fallback
    return 0
  fi
}

_uninstall_remove_bbr() {
  local bbr_config
  bbr_config=$(_snapshot_meta_resource_get "bbrConfig")
  if [[ -n $bbr_config && -f $bbr_config ]]; then
    _disable_bbr >/dev/null 2>&1 || true
    rm -f "$bbr_config"
    meta_resource_remove_existing "bbrConfig"
  fi
}

_uninstall_remove_owned_jq() {
  local jq_path jq_hash current_hash
  jq_path=$(_snapshot_meta_resource_get "standaloneJqPath")
  [[ -n $jq_path ]] || return 0
  jq_hash=$(_snapshot_meta_resource_get "standaloneJqSha256")
  [[ -n $jq_hash ]] || return 0
  if [[ -f $jq_path ]]; then
    current_hash=$(sha256sum "$jq_path" 2>/dev/null | cut -d' ' -f1)
    if [[ $current_hash == "$jq_hash" ]]; then
      rm -f "$jq_path"
      meta_resource_remove_existing "standaloneJqPath"
      meta_resource_remove_existing "standaloneJqSha256"
    else
      info "jq 已被修改/替换，保留：${jq_path}"
    fi
  fi
}

_scan_xrayctl_residuals() {
  local __count_var=${1:-} count=0
  local paths=(
    "$XRAY_BIN"
    /usr/local/bin/xray-linux-*
    "$QUICK_COMMAND"
    "$QUICK_SYMLINK"
    "$CONFIG_DIR"
    "$CERTBOT_VENV"
    "$CLOUDFLARE_INI"
    "$CERTBOT_CONFIG_DIR"
    "$CERTBOT_WORK_DIR"
    "$CERTBOT_LOGS_DIR"
    "$BACKUP_DIR"
    /etc/systemd/system/xrayctl-certbot-renew.timer
    /etc/systemd/system/xrayctl-certbot-renew.service
    /etc/systemd/system/xray.service
    /etc/systemd/system/xray@.service
    /etc/systemd/system/xray.service.d
    /etc/sysctl.d/99-xrayctl-bbr.conf
    /var/log/xray
  )

  for p in "${paths[@]}"; do
    if compgen -G "$p" >/dev/null 2>&1 || [[ -e $p ]]; then
      printf '  ✗ 残留: %s\n' "$p"
      ((count+=1))
    fi
  done

  if is_xrayctl_certbot_symlink && [[ -L /usr/local/bin/certbot ]]; then
    printf '  ✗ 残留: /usr/local/bin/certbot → xrayctl venv\n'
    ((count+=1))
  fi

  for hook in /etc/letsencrypt/renewal-hooks/deploy/xrayctl-*; do
    [[ -e $hook ]] || continue
    printf '  ✗ 残留: %s\n' "$hook"
    ((count+=1))
  done

  if systemctl list-unit-files 2>/dev/null | grep -qE 'xrayctl|xray[.]service'; then
    printf '  ✗ 残留: systemd 单元仍存在\n'
    ((count+=1))
  fi

  if pgrep -x xray >/dev/null 2>&1; then
    printf '  ✗ 残留: xray 运行中进程\n'
    ((count+=1))
  fi

  if systemctl is-active xray.service >/dev/null 2>&1; then
    printf '  ✗ 残留: xray.service 仍在运行\n'
    ((count+=1))
  fi

  if [[ -n $__count_var ]]; then
    printf -v "$__count_var" '%s' "$count"
  fi
  return 0
}

# ============================================================
# Three uninstall level implementations
# ============================================================

_xrayctl_purge_level_2() {
  heading "彻底删除"
  cat <<'EOF'

⚠  即将永久删除 xrayctl 管理的全部数据：

  - Xray 核心
  - 所有入站配置及用户凭据
  - TLS 证书副本
  - xrayctl 签发的 Let's Encrypt 证书
  - Cloudflare Global API Key
  - Certbot 独立环境
  - 自动续期任务
  - xrayctl 配置的 BBR 设置
  - 日志、元数据
  - 所有 xrayctl 备份

不会删除：
  - 系统 Nginx / Apache / 其他程序
  - 系统 Certbot
  - /etc/letsencrypt（其他网站证书）
  - Cloudflare DNS 记录
  - 系统软件包 (curl / python3 / jq)
  - xrayctl 未修改过的文件

完全删除不会创建或保留备份。
EOF
  printf '输入 DELETE 确认：'
  local answer
  read -r answer || { echo; return; }
  if [[ $answer != "DELETE" ]]; then
    info "已取消彻底删除。"
    return 0
  fi
  echo

  _uninstall_snapshot_metadata
  local step_failures=0 residual_count=0

  cleanup_step "停止续期任务"           _uninstall_disable_timers          || ((step_failures+=1))
  cleanup_step "删除托管证书"           _uninstall_remove_managed_certs    || ((step_failures+=1))
  cleanup_step "删除 Cloudflare 凭据"   _uninstall_remove_cloudflare       || ((step_failures+=1))
  cleanup_step "删除 Certbot 环境"      _uninstall_remove_certbot          || ((step_failures+=1))
  cleanup_step "卸载 Xray 核心"         _uninstall_xray_core               || ((step_failures+=1))
  cleanup_step "清理 systemd 覆盖"      _uninstall_remove_systemd_overrides || ((step_failures+=1))
  cleanup_step "删除运行用户组"         _uninstall_remove_runtime_group    || ((step_failures+=1))
  cleanup_step "删除快捷命令"           _uninstall_remove_quick_command    || ((step_failures+=1))
  cleanup_step "撤销 BBR 设置"          _uninstall_remove_bbr              || ((step_failures+=1))
  cleanup_step "删除独立安装的 jq"      _uninstall_remove_owned_jq         || ((step_failures+=1))
  cleanup_step "清理旧版本残留"         _cleanup_legacy_resources          || ((step_failures+=1))
  cleanup_step "删除 xrayctl 配置"      _uninstall_remove_config           || ((step_failures+=1))
  cleanup_step "删除日志"               _uninstall_remove_logs             || ((step_failures+=1))
  cleanup_step "删除备份"               _uninstall_remove_backups          || ((step_failures+=1))

  echo
  heading "残留检查"
  _scan_xrayctl_residuals residual_count

  echo
  printf '执行结果：失败步骤 %d，检测残留 %d\n' "$step_failures" "$residual_count"
  echo
  printf '未修改：\n  - 系统 Certbot\n  - /etc/letsencrypt\n  - 其他网站证书\n  - 系统软件包\n'
  rm -f "$SNAPSHOT_META"
}

_xrayctl_uninstall_level_1() {
  heading "完全卸载"
  confirm "将卸载 Xray 并删除配置、证书、日志与元数据，保留备份。确定吗？" N || return 0

  local final_backup
  final_backup="${BACKUP_DIR}/pre-uninstall-$(timestamp).tar.gz"
  if backup_all "$final_backup" >/dev/null 2>&1; then
    info "最终备份已创建：${final_backup}"
  else
    warn "最终备份失败，已取消完全卸载。"
    return 1
  fi

  _uninstall_snapshot_metadata
  local step_failures=0 residual_count=0
  _uninstall_disable_timers           || ((step_failures+=1))
  _uninstall_remove_managed_certs     || ((step_failures+=1))
  _uninstall_remove_cloudflare        || ((step_failures+=1))
  _uninstall_remove_certbot           || ((step_failures+=1))
  _uninstall_xray_core                || ((step_failures+=1))
  _uninstall_remove_systemd_overrides || ((step_failures+=1))
  _uninstall_remove_runtime_group     || ((step_failures+=1))
  _uninstall_remove_quick_command     || ((step_failures+=1))
  _cleanup_legacy_resources           || ((step_failures+=1))
  _uninstall_remove_config            || ((step_failures+=1))
  _uninstall_remove_logs              || ((step_failures+=1))

  _scan_xrayctl_residuals residual_count

  if ((step_failures > 0)); then
    warn "完全卸载有 ${step_failures} 个清理步骤失败，请结合残留检查确认。"
  fi

  if ((residual_count > 0)); then
    warn "检测到 ${residual_count} 项残留，请手动检查。"
  fi
  info "完全卸载完成；备份保留在 ${BACKUP_DIR}。"
  rm -f "$SNAPSHOT_META"
}

_xrayctl_uninstall_level_0() {
  heading "卸载程序"
  confirm "卸载 Xray 核心但保留配置、证书、备份和 xrayctl。确定吗？" N || return 0

  local final_backup
  final_backup="${BACKUP_DIR}/pre-uninstall-$(timestamp).tar.gz"
  backup_all "$final_backup" >/dev/null 2>&1 || true

  _uninstall_xray_core_keep_config
  info "Xray 已卸载。配置、证书、备份和自动续期仍保留。"
  info "需要时可运行 xrayctl install 重新安装 Xray。"
}

# ============================================================
# Unified uninstall entry point
# ============================================================

uninstall_xray() {
  ensure_system_context uninstall
  local level=${1:-0}
  case $level in
    0) _xrayctl_uninstall_level_0;;
    1) _xrayctl_uninstall_level_1;;
    2) _xrayctl_purge_level_2;;
    *) die "无效卸载级别：$level";;
  esac
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

add_inbound() {
  ensure_runtime_dependencies inbound-add; require_xray_installed; ensure_config
  local inbound="" host="" public_key="" tag tmp listen_port
  build_inbound inbound host public_key
  tag=$(jq -r '.tag' <<<"$inbound"); listen_port=$(jq -r '.port' <<<"$inbound")
  tmp=$(temp_file)
  jq --argjson inbound "$inbound" '.inbounds += [$inbound]' "$CONFIG_FILE" >"$tmp"
  if state_commit_inbound_set "$tmp" "$tag" "$host"; then
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
  if state_commit_inbound_rename "$tmp" "$old_tag" "$new_tag"; then
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
  if state_commit_inbound_set "$tmp" "$tag" "$host"; then
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
  if state_commit_inbound_set "$tmp" "$tag" "$(public_host_for_tag "$tag")"; then
    host=$(public_host_for_tag "$tag")
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
  if state_commit_inbound_delete "$tmp" "$tag"; then
    info "已删除入站 ${tag} 及其 ${user_count} 个用户。"
  fi
  rm -f "$tmp"
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
  # HTTP: refuse to delete the last user on a non-localhost address
  if [[ $protocol == http ]]; then
    local total_users listen_addr
    total_users=$(jq --arg tag "$tag" '.inbounds[]|select(.tag==$tag)|(.settings.accounts // .settings.users // [])|length' "$CONFIG_FILE")
    if ((total_users == 1)); then
      listen_addr=$(jq -r --arg tag "$tag" '.inbounds[]|select(.tag==$tag)|.listen // "0.0.0.0"' "$CONFIG_FILE")
      if [[ $listen_addr != "127.0.0.1" && $listen_addr != "::1" ]]; then
        warn "这是 HTTP 入站 ${tag} 的最后一个用户。"
        warn "当前监听地址为 ${listen_addr}，删除后将变成无认证公网代理。"
        warn "如需无认证 HTTP，请先将监听地址改为 127.0.0.1/::1。"
        return 1
      fi
      confirm "删除最后一个用户后 HTTP 入站将变为无认证，确定？" N || return 0
    fi
  fi

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

print_all_share_links() {
  ensure_config; init_meta
  local tag found=0
  while IFS= read -r tag; do
    found=1
    print_links "$tag" ""
  done < <(jq -r '.inbounds[]|select(.protocol|test("^(vless|vmess|trojan|socks|http)$"))|.tag' "$CONFIG_FILE")
  ((found == 1)) || { warn "没有可生成分享链接的入站。"; return 0; }
}


# ============================================================
# Unified Certbot environment — all certbot calls go through
# the isolated venv at /opt/xrayctl/certbot (see certbot_cmd).
# ============================================================

show_status() {
  heading "Xray 状态"
  if xray_installed; then "$XRAY_BIN" version | sed -n '1,2p'; else printf 'Xray: 未安装\n'; fi
  if service_exists; then
    systemctl --no-pager --full status "$SERVICE_NAME" 2>/dev/null | sed -n '1,12p' || true
  else printf 'systemd 服务: 未安装\n'; fi
  [[ -f $CONFIG_FILE ]] && printf '入站数: %s\n配置: %s\n' "$(jq '.inbounds|length' "$CONFIG_FILE" 2>/dev/null || printf '?')" "$CONFIG_FILE"
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
  meta_resource_register "bbrConfig" "$config"
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
  heading "最近服务日志"; journalctl -u "$SERVICE_NAME" -n 20 --no-pager 2>/dev/null || true
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
  # 检测本地 IP，对已存在的 freedom 出站加备注
  while IFS=$'\t' read -r label ip iface; do
    local tag; tag=$(_freedom_tag_for_ip "$ip")
    local_ip_tags+=("$tag")
    # 如果这个 freedom 出站不在列表里，追加到 tags
    local found=0
    for t in "${tags[@]}"; do [[ $t == "$tag" ]] && { found=1; break; }; done
    if ((!found)); then tags+=("$tag"); fi
    local_ips+=("$label")
    local_raw_ips+=("$ip")
  done < <(ensure_config 2>/dev/null || true; detect_local_ips 2>/dev/null)
  ((${#tags[@]} > 0)) || { warn "没有可选出站。"; return 1; }
  # 构建带有类型标注的显示标签
  local display_labels=()
  for t in "${tags[@]}"; do
    if [[ $t == direct ]]; then
      display_labels+=("direct (系统默认)")
    elif [[ $t =~ ^local- ]]; then
      # 找到对应的原始 IP 标签
      local dlabel="" found=0 i
      for ((i=0; i<${#local_ip_tags[@]}; i++)); do
        [[ ${local_ip_tags[$i]} == "$t" ]] && { dlabel="${local_ips[$i]}"; found=1; break; }
      done
      if ((found)); then display_labels+=("${dlabel}"); else display_labels+=("$t (本地)"); fi
    else
      # socks/http 代理
      local proto; proto=$(jq -r --arg tag "$t" '.outbounds[]?|select(.tag==$tag)|.protocol' "$CONFIG_FILE" 2>/dev/null || printf '?')
      local addr; addr=$(jq -r --arg tag "$t" '.outbounds[]?|select(.tag==$tag)|"\(.settings.address // "?"):\(.settings.port // "?")"' "$CONFIG_FILE" 2>/dev/null || printf '?:?')
      display_labels+=("$t ($proto · $addr)")
    fi
  done
  choose answer "选择出站" "${display_labels[@]}"
  local chosen="${tags[$((answer-1))]}"
  # 如果选的是本地 IP 但 freedom 出站还不存在，自动创建
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
    printf '1) 新增入站\n2) 管理已有入站\n3) 全部分享链接\n4) 删除入站\n0) 返回\n'
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
    printf '1) Let\x27s Encrypt 自动签发\n2) 导入已有证书\n3) 查看托管证书\n4) 删除托管证书\n5) Cloudflare 凭据\n'
    printf '6) 立即续期所有证书\n0) 返回\n'
    read -r -p "请选择: " choice || { echo; return; }
    case $choice in
      1) run_menu_action issue_certificate; pause;;
      2) run_menu_action import_certificate; pause;;
      3) run_menu_action list_certificates; pause;;
      4) run_menu_action delete_managed_certificate; pause;;
      5) cloudflare_credentials_menu;;
      6) run_menu_action renew_managed_certificates; pause;;
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
    printf '1) 卸载程序 — 删除 Xray 核心，保留配置、证书、备份、xrayctl、续期\n'
    printf '2) 完全卸载 — 删除 Xray + xrayctl 管理数据，保留备份\n'
    printf '3) 彻底删除 — 删除 xrayctl 创建的全部内容（含备份、Certbot、凭据）\n'
    printf '0) 返回\n'
    read -r -p "请选择: " choice || { echo; return; }
    case $choice in
      1) uninstall_xray 0; pause;;
      2) uninstall_xray 1; pause;;
      3) uninstall_xray 2; pause;;
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
xrayctl - Xray Linux 管理脚本

用法:
  xrayctl                         打开交互菜单
  xrayctl install [版本]          安装/修复（版本示例: 25.6.8）
  xrayctl update [版本]           升级 Xray
  xrayctl uninstall                 卸载 Xray 核心（保留配置）
  xrayctl uninstall --purge          完全卸载（保留备份）
  xrayctl uninstall --erase          彻底删除（清除全部 xrayctl 数据）
  xrayctl status                  查看状态
  xrayctl start|stop|restart      服务控制
  xrayctl logs [行数]             查看 systemd 日志
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
  xrayctl config check|show|edit
  xrayctl backup [文件.tar.gz]
  xrayctl restore [文件.tar.gz]
  xrayctl cert list                 列出托管证书
  xrayctl cert issue [域名] [邮箱]   Let's Encrypt 自动签发
  xrayctl cert import [标识] [证书] [私钥]  导入已有证书
  xrayctl cert delete <标识> [--yes] 删除托管证书
  xrayctl cert renew-auto            立即续期所有托管证书
  xrayctl cert renew <标识>          续期单个证书
  xrayctl cert cloudflare            管理 Cloudflare DNS 凭据
  xrayctl bbr                        管理 BBR（交互式开启/关闭）
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
    uninstall) if [[ ${1-} == --purge ]]; then uninstall_xray 1; elif [[ ${1-} == --erase ]]; then uninstall_xray 2; else uninstall_xray 0; fi;;
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
    config)
      case ${1:-check} in check|test) check_config;; show) ensure_config; jq . "$CONFIG_FILE";; edit) edit_config;; *) die "未知 config 子命令。";; esac;;
    backup) backup_all "${1-}";; restore) restore_backup "${1-}";;
    cert)
      case ${1:-list} in
        list) list_certificates;;
        issue) issue_certificate "${2-}" "${3-}";;
        import) import_certificate "${2-}" "${3-}" "${4-}";;
        delete|remove) delete_managed_certificate "${2-}" "$([[ ${3-} == --yes ]] && printf 1 || printf 0)";;
        renew-auto) renew_managed_certificates;;
        renew) renew_certificate_command "${2-}";;
        cloudflare) cloudflare_credentials_menu;;
        *) die "未知 cert 子命令：${1}";; esac;;

    bbr) manage_bbr;; diagnose|doctor) system_diagnostics;; quick-command) ensure_runtime_dependencies quick-command; install_quick_command;;
    *) error "未知命令：$command"; show_help; return 2;;
  esac
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
  dispatch "$@"
fi
