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

# shellcheck source=src/inbound.sh
source "${XRAYCTL_SOURCE_DIR}/src/inbound.sh"

# shellcheck source=src/share.sh
source "${XRAYCTL_SOURCE_DIR}/src/share.sh"

# shellcheck source=src/outbound.sh
source "${XRAYCTL_SOURCE_DIR}/src/outbound.sh"

# shellcheck source=src/service.sh
source "${XRAYCTL_SOURCE_DIR}/src/service.sh"

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
