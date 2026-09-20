outbound_menu() {
  local choice
  while true; do
    clear_screen
    heading "出站管理"
    list_outbound_overview
    printf '\n1) 设置入站默认出站\n2) 域名分流\n3) 添加代理出站 (SOCKS5/HTTP)\n4) 查看出站详情\n5) 删除出站\n0) 返回\n'
    read -r -p "请选择: " choice || { echo; return; }
    case $choice in
      1) run_menu_action assign_outbound; pause;; 2) domain_rule_menu;;
      3) run_menu_action add_outbound; pause;; 4) run_menu_action show_outbound_details; pause;;
      5) run_menu_action delete_outbound; pause;;
      0) return;; *) warn "无效选项。"; pause;;
    esac
  done
}

domain_rule_detail_menu() {
  local tag=$1 choice template outbound has_binding=0
  while inbound_exists "$tag"; do
    clear_screen
    heading "域名分流 · ${tag}"
    printf '模板：\n'
    has_binding=0
    while IFS=$'\t' read -r template outbound; do
      [[ -n $template ]] || continue
      printf '  %s → %s\n' "$template" "$outbound"
      has_binding=1
    done < <(list_inbound_template_bindings "$tag")
    ((has_binding)) || printf '  无\n'
    printf '\n'
    list_domain_rules "$tag" --menu
    printf '\n1) 管理模板\n2) 添加规则\n3) 删除规则\n0) 返回\n'
    read -r -p "请选择: " choice || { echo; return; }
    case $choice in
      1) inbound_template_manage_menu "$tag";;
      2) if run_menu_action add_domain_rule "$tag" "" "" "" --prompt; then pause; fi;;
      3) if run_menu_action delete_domain_rule "$tag" "" "" --direct-only; then pause; fi;;
      0) return;; *) warn "无效选项。"; pause;;
    esac
  done
}

domain_rule_inbound_templates() {
  local tag=$1 template outbound summary=''
  while IFS=$'\t' read -r template outbound; do
    [[ -n $template ]] || continue
    [[ -n $summary ]] && summary+=', '
    summary+="$template"
  done < <(list_inbound_template_bindings "$tag")
  printf '%s' "${summary:-无}"
}

domain_rule_inbound_count() {
  local tag=$1
  jq -r --arg tag "$tag" "$(_xrayctl_domain_rule_jq)
    [.routing.rules[]? | select(xrayctl_domain_rule and (.inboundTag // [])==[\$tag])] | length" \
    "$CONFIG_FILE"
}

domain_rule_menu() {
  local choice tag number=0
  local -a tags=()
  ensure_config
  while true; do
    clear_screen
    heading '域名分流'
    printf '入站列表\n\n'
    tags=()
    while IFS= read -r tag; do
      [[ -n $tag ]] && tags+=("$tag")
    done < <(jq -r '.inbounds[] | select(.protocol|test("^(vless|socks|http)$")) | .tag' "$CONFIG_FILE")
    if ((${#tags[@]} == 0)); then
      info '还没有可管理的入站。'
    else
      for ((number=0; number<${#tags[@]}; number++)); do
        tag=${tags[$number]}
        printf '%d) %s\n' "$((number + 1))" "$tag"
        printf '   模板：%s\n' "$(domain_rule_inbound_templates "$tag")"
        printf '   域名规则：%s 条\n\n' "$(domain_rule_inbound_count "$tag")"
      done
    fi
    printf '操作：\n'
    printf '  [%d] 管理模板\n' "$(( ${#tags[@]} + 1 ))"
    printf '  [0] 返回\n'
    read -r -p '请选择: ' choice || return
    case $choice in
      0) return;;
      ''|*[!0-9]*) warn '无效选项。'; pause;;
      *)
        if ((choice == ${#tags[@]} + 1)); then
          template_library_menu
        elif ((choice >= 1 && choice <= ${#tags[@]})); then
          domain_rule_detail_menu "${tags[$((choice-1))]}"
        else
          warn '无效选项。'
          pause
        fi
        ;;
    esac
  done
}

select_inbound_template() {
  local inbound=$1 __var=$2 answer template_name template_outbound
  local -a names=()
  while IFS=$'\t' read -r template_name template_outbound; do
    [[ -n $template_name ]] && names+=("$template_name")
  done < <(list_inbound_template_bindings "$inbound")
  ((${#names[@]})) || { warn "当前入站还没有应用模板。"; return 1; }
  choose answer "选择模板" "${names[@]}" || return 1
  printf -v "$__var" '%s' "${names[$((answer-1))]}"
}

inbound_template_manage_menu() {
  local inbound=$1 choice name outbound
  while inbound_exists "$inbound"; do
    clear_screen
    heading "入站模板 · ${inbound}"
    printf '已应用模板：\n'
    while IFS=$'\t' read -r name outbound; do
      [[ -n $name ]] || continue
      printf '  %s → %s\n' "$name" "$outbound"
    done < <(list_inbound_template_bindings "$inbound")
    printf '\n1) 添加模板\n2) 移除模板\n3) 修改出站\n0) 返回\n'
    read -r -p '请选择: ' choice || return
    case $choice in
      1) if apply_domain_template_menu "$inbound"; then pause; fi;;
      2)
        select_inbound_template "$inbound" name || continue
        confirm "从入站 ${inbound} 移除模板 ${name}？" N || continue
        run_menu_action remove_domain_template "$inbound" "$name"
        pause
        ;;
      3)
        select_inbound_template "$inbound" name || continue
        select_outbound outbound 1 || continue
        run_menu_action update_domain_template_outbound "$inbound" "$name" "$outbound"
        pause
        ;;
      0) return;; *) warn '无效选项。'; pause;;
    esac
  done
}

select_domain_template() {
  local __var=$1 answer template_name
  local -a names=()
  while IFS=$'\t' read -r template_name _ _; do
    [[ -n $template_name ]] && names+=("$template_name")
  done < <(list_domain_templates)
  ((${#names[@]})) || { warn "还没有模板。"; return 1; }
  choose answer "选择模板" "${names[@]}" || return 1
  printf -v "$__var" '%s' "${names[$((answer-1))]}"
}

delete_domain_template_domains_menu() {
  local name=$1 match=$2 selection token idx valid type_label choice joined domain
  local -a domains=() selected=() tokens=()
  if [[ $match == suffix ]]; then type_label=子域名; else type_label=精确域名; fi
  while IFS= read -r domain; do
    [[ -n $domain ]] && domains+=("$domain")
  done < <(jq -r --arg name "$name" --arg match "$match" \
    '.domainTemplates.templates[]? | select(.name==$name) | .[$match][]? // empty' "$META_FILE")
  ((${#domains[@]})) || { warn "当前模板没有${type_label}。"; return 1; }
  printf '\n%s：\n\n' "$type_label"
  for ((idx=0; idx<${#domains[@]}; idx++)); do
    printf '%d) %s\n' "$((idx+1))" "${domains[$idx]}"
  done
  while true; do
    read -r -p '请选择要删除的域名（支持 1,3,2）: ' selection || return 1
    selection=$(printf '%s' "$selection" | tr -d '[:space:]')
    [[ -n $selection ]] || return 1
    selected=()
    IFS=',' read -r -a tokens <<<"$selection"
    valid=1
    for token in "${tokens[@]}"; do
      if [[ ! $token =~ ^[0-9]+$ ]] || ((10#$token < 1 || 10#$token > ${#domains[@]})); then
        valid=0
        break
      fi
      idx=$((10#$token))
      if ((${#selected[@]})); then
        for choice in "${selected[@]}"; do
          if ((choice == idx)); then
            valid=0
            break 2
          fi
        done
      fi
      selected+=("$idx")
    done
    ((valid)) && ((${#selected[@]})) && break
    warn "请输入有效且不重复的序号，例如 1,3,2。"
  done
  printf '\n将删除：\n'
  for idx in "${selected[@]}"; do
    printf -- '- %s\n' "${domains[$((idx-1))]}"
  done
  confirm "确认从模板 ${name} 删除这些域名？" N || return 1
  joined=''
  for idx in "${selected[@]}"; do
    [[ -n $joined ]] && joined+=','
    joined+="${domains[$((idx-1))]}"
  done
  run_menu_action delete_domain_template_domains "$name" "$match" "$joined"
}

template_manage_menu() {
  local name=$1 choice type domains match
  while domain_template_exists "$name"; do
    clear_screen
    heading "模板 · ${name}"
    printf '精确域名：\n'
    jq -r --arg name "$name" '.domainTemplates.templates[]? |
      select(.name==$name) | .exact[]? // empty | "  "+.' "$META_FILE"
    printf '子域名：\n'
    jq -r --arg name "$name" '.domainTemplates.templates[]? |
      select(.name==$name) | .suffix[]? // empty | "  "+.' "$META_FILE"
    printf '\n1) 添加域名\n2) 删除域名\n0) 返回\n'
    read -r -p '请选择: ' choice || return
    case $choice in
      1)
        choose type "域名类型" "精确域名" "域名及所有子域名" || continue
        [[ $type == 1 ]] && match=exact || match=suffix
        prompt_value domains "域名（多个请用英文逗号分隔）" || continue
        run_menu_action add_domain_template_domains "$name" "$match" "$domains"
        pause
        ;;
      2)
        choose type "域名类型" "精确域名" "域名及所有子域名" || continue
        [[ $type == 1 ]] && match=exact || match=suffix
        if delete_domain_template_domains_menu "$name" "$match"; then pause; fi
        ;;
      0) return;; *) warn '无效选项。'; pause;;
    esac
  done
}

template_library_menu() {
  local choice name number=0
  local -a names=()
  while true; do
    clear_screen
    heading '模板库'
    names=()
    number=0
    while IFS=$'\t' read -r name exact suffix; do
      [[ -n $name ]] || continue
      names+=("$name")
      ((number+=1))
      printf '%s) %-16s 精确 %s 个，子域名 %s 个\n' "$number" "$name" "$exact" "$suffix"
    done < <(list_domain_templates)
    printf '\n%s) 新建模板\n0) 返回\n' "$((number + 1))"
    read -r -p '请选择: ' choice || return
    case $choice in
      0) return;;
      ''|*[!0-9]*) warn '无效选项。'; pause;;
      *)
        if ((choice == ${#names[@]} + 1)); then
          run_menu_action create_domain_template
          pause
        elif ((choice >= 1 && choice <= ${#names[@]})); then
          template_manage_menu "${names[$((choice-1))]}"
        else
          warn '无效选项。'
          pause
        fi
        ;;
    esac
  done
}

apply_domain_template_menu() {
  local inbound=$1 name outbound
  select_domain_template name || return 1
  select_outbound outbound 1 || return 1
  run_menu_action apply_domain_template "$inbound" "$name" "$outbound"
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
    if [[ $protocol == vless ]]; then
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
      vless)
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
  service_exists || die "Xray 服务不存在。"
  if service_is_enabled; then
    platform_service_disable >/dev/null
    info "开机自启已关闭；当前服务运行状态未改变。"
  else
    platform_service_enable >/dev/null
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
    printf '1) 启动/停止\n2) 重启服务\n3) 开关开机自启\n4) 查看日志\n5) 安装/更新/修复 Xray\n6) 系统诊断\n7) 修复快捷命令\n0) 返回\n'
    read -r -p "请选择: " choice || { echo; return; }
    case $choice in
      1) run_menu_action toggle_service_running; pause;; 2) run_menu_action service_action restart; pause;;
      3) run_menu_action toggle_service_startup; pause;; 4) run_menu_action show_logs 100; pause;;
      5) run_menu_action install_or_update_xray install; pause;; 6) run_menu_action system_diagnostics; pause;;
      7) run_menu_action repair_quick_command; pause;; 0) return;; *) warn "无效选项。"; pause;;
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
      1) run_menu_action uninstall_xray 0; pause;;
      2) run_menu_action uninstall_xray 1; pause;;
      3) run_menu_action uninstall_xray 2; pause;;
      0) return;; *) warn "无效选项。"; pause;;
    esac
  done
}

traffic_menu() {
  local choice start end
  start=$(traffic_retention_start); end=$(traffic_today)
  traffic_is_enabled && run_menu_action traffic_collect
  while true; do
    clear_screen
    traffic_show "$start" "$end" || true
    printf '\n1) 刷新\n2) 设置时间范围\n3) 流量限制\n4) 清空指定入站记录\n5) 清空全部流量记录\n'
    if traffic_is_enabled; then printf '6) 停止流量统计\n'; else printf '6) 开启流量统计\n'; fi
    printf '0) 返回\n'
    read -r -p "请选择: " choice || { echo; return; }
    case $choice in
      1) run_menu_action traffic_collect;;
      2) traffic_prompt_range start end || true;;
      3) traffic_limit_menu;;
      4) run_menu_action traffic_clear_tag_records; pause;;
      5) run_menu_action traffic_clear_all_records; pause;;
      6)
        if traffic_is_enabled; then run_menu_action traffic_disable; else run_menu_action traffic_enable; fi
        pause
        ;;
      0) return;;
      *) warn "无效选项。"; pause;;
    esac
  done
}

traffic_limit_menu() {
  local choice
  while true; do
    if traffic_is_enabled; then run_menu_action traffic_collect || true; fi
    clear_screen
    traffic_limits_show || true
    if traffic_limits_are_enabled; then
      printf '操作\n1) 刷新状态\n2) 设置/修改入站额度\n3) 取消入站额度\n4) 关闭流量限制\n0) 返回\n'
    else
      printf '操作\n1) 启用流量限制\n0) 返回\n'
    fi
    read -r -p "请选择: " choice || { echo; return; }
    if traffic_limits_are_enabled; then
      case $choice in
        1) continue;;
        2) run_menu_action traffic_limit_set; pause;;
        3) run_menu_action traffic_limit_remove; pause;;
        4) run_menu_action traffic_limits_disable; pause;;
        0) return 0;;
        *) warn "无效选项。"; pause;;
      esac
    else
      case $choice in
        1) run_menu_action traffic_limits_enable; pause;;
        0) return 0;;
        *) warn "无效选项。"; pause;;
      esac
    fi
  done
}

main_menu() {
  local choice
  while true; do
    clear_screen
    printf '%sXray Linux 管理脚本%s  v%s\n' "$C_BOLD$C_BLUE" "$C_RESET" "$XRAYCTL_VERSION"
    show_main_summary
    show_main_inbounds
    printf '1) 入站管理\n2) 出站管理\n3) TLS 证书\n4) 流量信息\n5) BBR启用/关闭\n6) 服务管理\n7) 卸载\n0) 退出\n'
    read -r -p "请选择: " choice || { echo; return; }
    case $choice in
      1) inbound_menu;; 2) outbound_menu;; 3) certificate_menu;; 4) traffic_menu;;
      5) run_menu_action manage_bbr; pause;; 6) service_menu;; 7) uninstall_menu;;
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
  xrayctl logs [行数]             查看服务日志
  xrayctl traffic [开始日期] [结束日期] 查看按入站累计流量
  xrayctl traffic enable|disable       开启/停止流量统计
  xrayctl traffic limit show|enable|disable
  xrayctl traffic limit set <标签> <GB> <重置日>
  xrayctl traffic limit remove <标签>
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
  xrayctl outbound rule list [入站]
  xrayctl outbound rule add <入站> <suffix|exact> <域名[,域名...]> <出站>
  xrayctl outbound rule delete [入站] [suffix|exact] [域名]
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
  xrayctl cert list                 列出托管证书
  xrayctl cert issue [域名] [邮箱]   Let's Encrypt 自动签发
  xrayctl cert import [标识] [证书] [私钥]  导入已有证书
  xrayctl cert delete <标识> [--yes] 删除托管证书
  xrayctl cert renew-auto            立即续期所有托管证书
  xrayctl cert renew <标识>          续期单个证书
  xrayctl cert cloudflare            管理 Cloudflare DNS 凭据
  xrayctl bbr                        启用/关闭 BBR（交互式）
  xrayctl diagnose                系统诊断
  xrayctl version

支持协议: VLESS、SOCKS5、HTTP
支持传输: RAW、XHTTP、WebSocket；支持 TLS 和 REALITY。
EOF
}

dispatch() {
  local command=${1:-menu}; shift || true
  case $command in
    menu) main_menu;;
    help|-h|--help) show_help;;
    version|-v|--version)
      printf 'xrayctl %s' "$XRAYCTL_VERSION"
      [[ $XRAYCTL_BUILD_COMMIT == development ]] || printf ' (commit %s)' "$XRAYCTL_BUILD_COMMIT"
      printf '\n'
      ;;
    install) install_or_update_xray install "${1-}";;
    update|upgrade) install_or_update_xray upgrade "${1-}";;
    uninstall) if [[ ${1-} == --purge ]]; then uninstall_xray 1; elif [[ ${1-} == --erase ]]; then uninstall_xray 2; else uninstall_xray 0; fi;;
    status) show_status;;
    start|stop|restart|enable|disable) service_action "$command";;
    logs) show_logs "${1:-100}";;
    traffic)
      case ${1:-show} in
        show) traffic_collect || true; traffic_show "${2:-$(traffic_retention_start)}" "${3:-$(traffic_today)}";;
        enable|start) traffic_enable;;
        disable|stop) traffic_disable;;
        collect|refresh) traffic_collect;;
        reset)
          if [[ ${2-} == --all ]]; then traffic_clear_all_records; else traffic_clear_tag_records "${2-}"; fi
          ;;
        limit)
          case ${2:-show} in
            show) traffic_limits_show;;
            enable|start) traffic_limits_enable;;
            disable|stop) traffic_limits_disable;;
            set) traffic_limit_set "${3-}" "${4-}" "${5-}";;
            remove|delete) traffic_limit_remove "${3-}";;
            *) die "未知 traffic limit 子命令：${2}";;
          esac
          ;;
        [0-9][0-9][0-9][0-9]-*) traffic_collect || true; traffic_show "$1" "${2:-$(traffic_today)}";;
        *) die "未知 traffic 子命令：${1}";;
      esac
      ;;
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
        delete|remove) delete_outbound "${2-}";;
        rule)
          case ${2:-list} in
            list) list_domain_rules "${3-}";;
            add) add_domain_rule "${3-}" "${4-}" "${5-}" "${6-}";;
            delete|remove) delete_domain_rule "${3-}" "${4-}" "${5-}";;
            *) die "未知 outbound rule 子命令：${2}";;
          esac
          ;;
        *) die "未知 outbound 子命令：${1}";; esac;;
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
    internal-traffic-collect) internal_traffic_collect;;
    internal-traffic-watch) internal_traffic_watch;;
    *) error "未知命令：$command"; show_help; return 2;;
  esac
}
