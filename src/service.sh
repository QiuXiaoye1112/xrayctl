service_exists() { platform_service_exists; }
service_is_active() { platform_service_is_active; }
service_is_enabled() { platform_service_is_enabled; }

restart_service() {
  if service_exists; then
    platform_service_restart
    if ! service_is_active; then
      platform_service_logs 20 >&2 || true
      return 1
    fi
    # A simple service can report active before Xray opens logs/listeners.
    sleep 1
    if ! service_is_active; then
      platform_service_logs 20 >&2 || true
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

setup_runtime_access() {
  local created_group=0 created_user=0 log_user="$RUNTIME_USER"
  local -a log_files=("${LOG_DIR}/access.log" "${LOG_DIR}/error.log")
  if [[ $(platform_init_system) == openrc ]]; then
    if ! grep -qE "^${RUNTIME_GROUP}:" /etc/group 2>/dev/null; then addgroup -S "$RUNTIME_GROUP"; created_group=1; fi
    if ! id "$RUNTIME_USER" >/dev/null 2>&1; then
      adduser -S -D -H -s /sbin/nologin -G "$RUNTIME_GROUP" "$RUNTIME_USER"
      created_user=1
    fi
  else
    if ! getent group "$RUNTIME_GROUP" >/dev/null 2>&1; then groupadd --system "$RUNTIME_GROUP"; created_group=1; fi
  fi
  install -d -m 750 -o "$RUNTIME_OWNER" -g "$RUNTIME_GROUP" "$CONFIG_DIR" || return 1
  install -d -m 750 -o "$RUNTIME_OWNER" -g "$RUNTIME_GROUP" "$CERT_DIR" || return 1
  if [[ $(platform_init_system) == systemd ]]; then
    # The official installer and existing units may use a different service user.
    log_user=root
    if service_exists; then
      log_user=$(systemctl show "$SERVICE_NAME" --property=User --value) || return 1
      log_user=${log_user:-root}
    fi
  else
    log_files+=("${LOG_DIR}/openrc.log" "${LOG_DIR}/openrc-error.log")
  fi
  [[ ! -L $LOG_DIR ]] || { error "日志目录不能是符号链接：$LOG_DIR"; return 1; }
  # Keep directory entries under manager ownership so the service cannot swap
  # a managed log for a symlink before a privileged permission repair.
  install -d -m 750 -o "$RUNTIME_OWNER" -g "$RUNTIME_GROUP" "$LOG_DIR" || return 1
  local log_file
  for log_file in "${log_files[@]}"; do
    if [[ -L $log_file || ( -e $log_file && ! -f $log_file ) ]]; then
      error "日志路径必须是普通文件：$log_file"
      return 1
    fi
  done
  touch "${log_files[@]}" || return 1
  chown "$log_user:$RUNTIME_GROUP" "${log_files[@]}" || return 1
  chmod 640 "${log_files[@]}" || return 1
  if [[ -f $CONFIG_FILE ]]; then
    chown "$RUNTIME_OWNER:$RUNTIME_GROUP" "$CONFIG_FILE"
    chmod 640 "$CONFIG_FILE"
  fi
  if [[ $(platform_init_system) == systemd ]]; then
    install -d -m 755 "$SYSTEMD_OVERRIDE_DIR"
    cat >"${SYSTEMD_OVERRIDE_DIR}/20-xrayctl-access.conf" <<EOF
[Service]
SupplementaryGroups=${RUNTIME_GROUP}
EOF
    rm -f "${SYSTEMD_OVERRIDE_DIR}/20-xrayctl-certificates.conf"
    platform_daemon_reload
  fi
  meta_resource_register "configDir" "$CONFIG_DIR"
  meta_resource_register "certDir" "$CERT_DIR"
  meta_resource_register "runtimeGroup" "$RUNTIME_GROUP"
  ((created_group == 0)) || meta_resource_register "runtimeGroupOwned" "$RUNTIME_GROUP"
  ((created_user == 0)) || meta_resource_register "runtimeUserOwned" "$RUNTIME_USER"
}

setup_certificate_access() { setup_runtime_access; }

install_quick_command() {
  local source=${BASH_SOURCE[0]:-} downloaded="" backup="" download_url="" ref_json="" commit=""
  mkdir -p "$(dirname "$QUICK_COMMAND")" "$(dirname "$QUICK_SYMLINK")"

  if [[ -n $source && -r $source ]] && grep -q '^# xrayctl - Xray Linux terminal manager' "$source" 2>/dev/null; then
    :
  elif [[ -f $QUICK_COMMAND ]] && grep -q '^# xrayctl - Xray Linux terminal manager' "$QUICK_COMMAND" 2>/dev/null; then
    source=$QUICK_COMMAND
  else
    downloaded=$(temp_file)
    info "正在下载快捷命令脚本。"
    download_url=$SCRIPT_DOWNLOAD_URL
    if [[ -z ${XRAYCTL_SCRIPT_URL:-} ]]; then
      ref_json=$(curl --fail --silent --show-error --location --proto '=https' --tlsv1.2 --retry 3 \
        --connect-timeout 15 --max-time 30 \
        "https://api.github.com/repos/QiuXiaoye1112/xrayctl/git/ref/heads/main?xrayctl_cache=$(date +%s)") \
        || die "无法查询 xrayctl main 的提交版本。"
      commit=$(printf '%s\n' "$ref_json" | sed -nE 's/.*"sha":[[:space:]]*"([0-9a-f]{40})".*/\1/p')
      [[ $commit =~ ^[0-9a-f]{40}$ ]] || die "无法确认 xrayctl main 的提交版本，拒绝安装可能过期的文件。"
      download_url="https://raw.githubusercontent.com/QiuXiaoye1112/xrayctl/${commit}/dist/xrayctl"
    fi
    if [[ $download_url == *\?* ]]; then
      download_url="${download_url}&xrayctl_cache=$(date +%s)"
    else
      download_url="${download_url}?xrayctl_cache=$(date +%s)"
    fi
    if ! curl --fail --location --proto '=https' --tlsv1.2 --retry 3 \
      --connect-timeout 15 --max-time 120 "$download_url" -o "$downloaded"; then
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
    if ! grep -q '^# xrayctl - Xray Linux terminal manager' "$QUICK_SYMLINK" 2>/dev/null; then
      die "${QUICK_SYMLINK} 已存在且不是本脚本，拒绝覆盖。"
    fi
    # Older layouts installed a regular script at the symlink path; keep it as
    # a fallback copy instead of refusing the upgrade.
    backup="${QUICK_SYMLINK}.bak-$(timestamp)"
    cp -p "$QUICK_SYMLINK" "$backup" || die "无法备份旧版快捷命令：${QUICK_SYMLINK}"
    info "旧版快捷命令已备份：${backup}"
  fi
  ln -sfn "$QUICK_COMMAND" "$QUICK_SYMLINK"
  info "快捷命令已安装：xrayctl"
  meta_resource_register "quickCommand" "$QUICK_COMMAND"
  meta_resource_register "quickSymlink" "$QUICK_SYMLINK"
}

# ============================================================
# Uninstall
#   Level 0: remove Xray core, keep config/certs/backups/xrayctl/timer
#   Level 1: full uninstall, keep backups
#   Level 2: purge everything xrayctl ever created
# ============================================================

show_status() {
  local traffic_state quota_state backend
  heading "Xray 状态"
  if xray_installed; then "$XRAY_BIN" version | sed -n '1,2p'; else printf 'Xray: 未安装\n'; fi
  if service_exists; then platform_service_status 2>/dev/null | sed -n '1,12p' || true
  else printf '%s 服务: 未安装\n' "$(platform_init_system 2>/dev/null || printf unknown)"; fi
  [[ -f $CONFIG_FILE ]] && printf '入站数: %s\n配置: %s\n' "$(jq '.inbounds|length' "$CONFIG_FILE" 2>/dev/null || printf '?')" "$CONFIG_FILE"
  if traffic_is_enabled; then traffic_state="运行中"; else traffic_state="已停止"; fi
  if traffic_limits_are_enabled; then quota_state="已启用"; else quota_state="未启用"; fi
  backend=$(traffic_recorded_backend); backend=${backend:-未设置}
  printf '流量统计: %s（%s）\n流量限制: %s（已设置 %s 个入站）\n' "$traffic_state" "$backend" "$quota_state" "$(traffic_limit_count)"
}

service_action() {
  ensure_runtime_dependencies service
  local action=$1
  service_exists || die "Xray 服务不存在。"
  case $action in
    start) platform_service_start ;;
    stop) platform_service_stop ;;
    restart) platform_service_restart ;;
    enable) platform_service_enable; platform_service_start ;;
    disable) platform_service_stop || true; platform_service_disable ;;
    *) die "未知服务操作：$action";;
  esac
  info "服务操作完成：$action"
}

show_logs() {
  local lines=${1:-100}
  [[ $lines =~ ^[0-9]+$ ]] || die "日志行数必须是数字。"
  platform_service_logs "$lines"
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
  local available
  available=$(< /proc/sys/net/ipv4/tcp_available_congestion_control)
  if [[ " $available " != *" bbr "* ]]; then
    warn "当前内核不支持 BBR。可用算法：${available}"
    return 1
  fi
  return 0
}

bbr_manager() {
  local own=0 peer=0 current=""
  [[ -f $BBR_CONFIG ]] && own=1
  [[ -f $SBCTL_BBR_CONFIG ]] && peer=1
  if ((own && peer)); then printf 'both'; return; fi
  if ((own)); then printf 'xrayctl'; return; fi
  if ((peer)); then printf 'sbctl'; return; fi
  [[ -r /proc/sys/net/ipv4/tcp_congestion_control ]] && current=$(< /proc/sys/net/ipv4/tcp_congestion_control)
  if [[ $current == bbr ]]; then printf 'external'; else printf 'none'; fi
}

bbr_remove_known_persistence() {
  rm -f -- "$BBR_CONFIG" "$SBCTL_BBR_CONFIG"
  meta_resource_remove_existing "bbrConfig"
}

_enable_bbr() {
  local qdisc_enabled=0 config=$BBR_CONFIG
  if command_exists modprobe; then run_bounded 5 modprobe tcp_bbr >/dev/null 2>&1 || true; fi
  if [[ -e /proc/sys/net/core/default_qdisc ]]; then
    if run_bounded 5 sysctl -w net.core.default_qdisc=fq >/dev/null 2>&1; then qdisc_enabled=1;
    else warn "无法设置 net.core.default_qdisc，跳过 fq。"; fi
  fi
  if ! run_bounded 5 sysctl -w net.ipv4.tcp_congestion_control=bbr >/dev/null 2>&1; then
    error "无法写入拥塞控制参数或操作超时。"
    return 1
  fi
  rm -f -- "$SBCTL_BBR_CONFIG"
  if ((qdisc_enabled)); then
    printf '%s\n' '# managed by xrayctl' 'net.core.default_qdisc=fq' 'net.ipv4.tcp_congestion_control=bbr' >"$config"
  else
    printf '%s\n' '# managed by xrayctl' 'net.ipv4.tcp_congestion_control=bbr' >"$config"
  fi
  if [[ $(< /proc/sys/net/ipv4/tcp_congestion_control) != bbr ]]; then
    error "BBR 校验失败。"
    return 1
  fi
  info "BBR 已启用。"
  meta_resource_register "bbrConfig" "$config"
}

_disable_bbr() {
  local current default_cc
  current=$(< /proc/sys/net/ipv4/tcp_congestion_control)
  if [[ $current != bbr ]]; then
    bbr_remove_known_persistence
    info "BBR 当前未启用；已清理 xrayctl/sbctl 的已知持久化配置。"
    return 0
  fi
  default_cc=$(sed 's/ /\n/g' /proc/sys/net/ipv4/tcp_available_congestion_control | grep -vF bbr | head -1)
  [[ -n $default_cc ]] || default_cc=cubic
  if ! run_bounded 5 sysctl -w net.ipv4.tcp_congestion_control="$default_cc" >/dev/null 2>&1; then
    error "无法恢复默认拥塞控制算法 ${default_cc}。"
    return 1
  fi
  run_bounded 5 sysctl -w net.core.default_qdisc=fq_codel >/dev/null 2>&1 || true
  bbr_remove_known_persistence
  if [[ $(< /proc/sys/net/ipv4/tcp_congestion_control) == bbr ]]; then
    error "BBR 关闭失败，当前仍为 bbr。"
    return 1
  fi
  info "BBR 已关闭，拥塞控制恢复为 ${default_cc}。"
}

manage_bbr() {
  ensure_system_context bbr
  _check_bbr_available || return 0
  local current manager
  current=$(< /proc/sys/net/ipv4/tcp_congestion_control)
  manager=$(bbr_manager)
  if [[ $current == bbr ]]; then
    info "当前拥塞控制: BBR（管理方：${manager}）"
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
  printf '服务: %s  |  入站: %s  |  BBR: %s  |  Xray: %s\n' \
    "$(service_state_summary)" "$(node_count_summary)" "$(bbr_state_summary)" "$(xray_version_summary)"
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
    (.port|tostring),(if (.streamSettings.network // .streamSettings.method // "raw")=="websocket" then "ws" else (.streamSettings.network // .streamSettings.method // "raw") end),
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
      .protocol,(.port|tostring),(.streamSettings.network // .streamSettings.method // "raw"),
      (.streamSettings.security // "none"),(.listen // "0.0.0.0")]|@tsv' "$CONFIG_FILE"
  )
  printf '协议: %s  |  端口: %s  |  传输: %s  |  安全: %s  |  监听: %s\n\n' \
    "$protocol" "$port" "$method" "$security" "$listen"
}
