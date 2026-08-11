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

