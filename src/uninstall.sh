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
  if [[ $(platform_init_system) == openrc ]]; then
    if [[ $(_snapshot_meta_resource_get "renewHook") == "$CERT_RENEW_HOOK" ]]; then rm -f "$CERT_RENEW_HOOK"; fi
    meta_resource_remove_existing "renewHook"
  else
    systemctl disable --now xrayctl-certbot-renew.timer >/dev/null 2>&1 || true
    systemctl stop xrayctl-certbot-renew.service >/dev/null 2>&1 || true
    rm -f /etc/systemd/system/xrayctl-certbot-renew.service /etc/systemd/system/xrayctl-certbot-renew.timer
    platform_daemon_reload
    meta_resource_remove_existing "renewTimer"; meta_resource_remove_existing "renewService"
  fi
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
  local owned_group owned_user
  owned_group=$(_snapshot_meta_resource_get "runtimeGroupOwned")
  owned_user=$(_snapshot_meta_resource_get "runtimeUserOwned")
  if [[ -n $owned_user && $owned_user == "$RUNTIME_USER" ]] && id "$RUNTIME_USER" >/dev/null 2>&1; then
    if [[ $(platform_init_system) == openrc ]]; then deluser "$RUNTIME_USER" 2>/dev/null || true; fi
  fi
  if [[ -n $owned_group && $owned_group == "$RUNTIME_GROUP" ]]; then
    if [[ $(platform_init_system) == openrc ]]; then
      grep -qE "^${RUNTIME_GROUP}:" /etc/group 2>/dev/null && delgroup "$RUNTIME_GROUP" 2>/dev/null || true
    else
      getent group "$RUNTIME_GROUP" >/dev/null 2>&1 && groupdel "$RUNTIME_GROUP" 2>/dev/null || true
    fi
  elif [[ $(platform_init_system) == systemd && $RUNTIME_GROUP == xrayctl ]]; then
    getent group "$RUNTIME_GROUP" >/dev/null 2>&1 && groupdel "$RUNTIME_GROUP" 2>/dev/null || true
  fi
  meta_resource_remove_existing "runtimeUserOwned"
  meta_resource_remove_existing "runtimeGroupOwned"
  meta_resource_remove_existing "runtimeGroup"
}

_uninstall_remove_systemd_overrides() {
  if [[ $(platform_init_system) == systemd ]]; then
    rm -f "${SYSTEMD_OVERRIDE_DIR}/20-xrayctl-access.conf" "${SYSTEMD_OVERRIDE_DIR}/20-xrayctl-certificates.conf"
    rmdir "$SYSTEMD_OVERRIDE_DIR" 2>/dev/null || true
    platform_daemon_reload
  fi
}

_uninstall_remove_quick_command() {
  if is_xrayctl_symlink; then rm -f "$QUICK_SYMLINK"; fi
  if is_xrayctl_quick_command; then rm -f "$QUICK_COMMAND"; fi
  meta_resource_remove_existing "quickCommand"; meta_resource_remove_existing "quickSymlink"
  hash -r 2>/dev/null || true
}

_backup_dir_has_ownership_marker() {
  [[ -d $BACKUP_DIR && ! -L $BACKUP_DIR ]] || return 1
  [[ -f $BACKUP_OWNERSHIP_MARKER && ! -L $BACKUP_OWNERSHIP_MARKER ]] || return 1
  [[ $(cat "$BACKUP_OWNERSHIP_MARKER" 2>/dev/null) == "$BACKUP_OWNERSHIP_MAGIC" ]]
}

_uninstall_remove_backups() {
  local recorded
  [[ -e $BACKUP_DIR ]] || return 0
  recorded=$(_snapshot_meta_resource_get "backupDir")
  if [[ $recorded == "$BACKUP_DIR" ]] || _backup_dir_has_ownership_marker; then
    safe_remove_dir "$BACKUP_DIR" "$BACKUP_DIR"
  else
    warn "备份目录缺少有效资产登记或 ownership marker，拒绝删除：$BACKUP_DIR"
    return 1
  fi
}

_uninstall_remove_logs() {
  safe_remove_dir "$LOG_DIR" "$LOG_DIR"
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
  platform_service_stop >/dev/null 2>&1 || true
  platform_service_disable >/dev/null 2>&1 || true
  if [[ $(platform_init_system) == openrc ]]; then
    rm -f "$OPENRC_SERVICE"
  else
    systemctl disable --now xray@.service >/dev/null 2>&1 || true
    rm -f /etc/systemd/system/xray.service /etc/systemd/system/xray@.service
    rm -rf /etc/systemd/system/xray.service.d 2>/dev/null || true
  fi
  rm -f /usr/local/bin/xray /usr/local/bin/xray-linux-*
  rm -rf /usr/local/share/xray 2>/dev/null || true
  platform_daemon_reload
}

_uninstall_xray_core() {
  local installer
  if [[ $(platform_init_system) == openrc ]]; then _uninstall_xray_core_fallback; return 0; fi
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
  if [[ $(platform_init_system) == openrc ]]; then _uninstall_xray_core_fallback; return 0; fi
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
  local __count_var=${1:-} scan_backups=${2:-1} count=0
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
    /etc/systemd/system/xrayctl-certbot-renew.timer
    /etc/systemd/system/xrayctl-certbot-renew.service
    /etc/systemd/system/xray.service
    /etc/systemd/system/xray@.service
    /etc/systemd/system/xray.service.d
    "$OPENRC_SERVICE"
    "$CERT_RENEW_HOOK"
    /etc/sysctl.d/99-xrayctl-bbr.conf
    /var/log/xray
  )
  ((scan_backups == 0)) || paths+=("$BACKUP_DIR")

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

  if [[ $(platform_init_system) == systemd ]] && systemctl list-unit-files 2>/dev/null | grep -qE 'xrayctl|xray[.]service'; then
    printf '  ✗ 残留: systemd 单元仍存在\n'
    ((count+=1))
  fi

  if pgrep -x xray >/dev/null 2>&1; then
    printf '  ✗ 残留: xray 运行中进程\n'
    ((count+=1))
  fi

  if service_is_active; then
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

  _scan_xrayctl_residuals residual_count 0

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
