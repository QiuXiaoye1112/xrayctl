#!/usr/bin/env bash
outbound_menu() {
  local choice
  while true; do
    clear_screen
    heading "出站管理"
    list_outbound_overview
    printf '\n1) 入站出站管理\n2) 用户域名模板库\n3) 添加代理出站 (SOCKS5/HTTP)\n4) 查看出站详情\n5) 删除出站\n0) 返回\n'
    read -r -p "请选择: " choice || { cancel_selection; return 0; }
    case $choice in
      1) inbound_outbound_menu;;
      2) template_library_menu;;
      3) run_menu_action add_outbound; pause;; 4) run_menu_action show_outbound_details; pause;;
      5) run_menu_action delete_outbound; pause;;
      0) return;; *) warn "无效选项。"; pause;;
    esac
  done
}

_outbound_inbound_tags() {
  jq -r '.inbounds[] | select(.protocol|test("^(vless|socks|http)$")) | .tag' "$CONFIG_FILE"
}

_outbound_user_labels() {
  jq -r --arg inbound "$1" '
    .inbounds[]? | select(.tag==$inbound) |
    if .protocol=="vless" then .settings.clients[]? | (.xrayctlLabel // .email // empty)
    elif .protocol=="socks" and .settings.auth=="password" then (.settings.accounts // .settings.users // [])[]? | .user
    elif .protocol=="http" then (.settings.accounts // .settings.users // [])[]? | .user
    else empty end
  ' "$CONFIG_FILE"
}

_outbound_inbound_default() {
  jq -r --arg inbound "$1" '[.routing.rules[]? | select(.ruleTag==("xrayctl-outbound:"+$inbound)) | .outboundTag][0] // .outbounds[0].tag // "未设置"' "$CONFIG_FILE"
}

_outbound_user_default() {
  local inbound=$1 identity=$2
  jq -r --arg inbound "$inbound" --arg identity "$identity" '
    [.routing.rules[]? | select(((.ruleTag // "")|startswith("xrayctl-user-outbound:")) and .inboundTag==[$inbound] and .user==[$identity]) | .outboundTag][0] // empty
  ' "$CONFIG_FILE"
}

_outbound_user_domain_count() {
  jq -r --arg inbound "$1" --arg identity "$2" '
    [.routing.rules[]? | select(((.ruleTag // "")|startswith("xrayctl-user-domain:")) and .inboundTag==[$inbound] and .user==[$identity])] | length
  ' "$CONFIG_FILE"
}


_outbound_user_domain_rules_display() {
  local inbound=$1 identity=$2 rows type match outbound found=0 number=0 groups=0
  rows=$(jq -r --arg inbound "$inbound" --arg identity "$identity" '
    [ .routing.rules[]? |
      select(((.ruleTag // "")|startswith("xrayctl-user-domain:")) and
        .inboundTag==[$inbound] and .user==[$identity] and (.template // "")=="") |
      (.domain[0] // "") as $value |
      {match:(if ($value|startswith("full:")) then "exact"
              elif ($value|startswith("domain:")) then "suffix" else "" end),
       domain:(if ($value|startswith("full:")) then $value[5:]
               elif ($value|startswith("domain:")) then $value[7:] else $value end),
       outbound:(.outboundTag // "")}
    ] | map(select(.match!="")) |
    sort_by([(if .match=="exact" then 0 else 1 end), (.outbound|ascii_downcase), (.domain|ascii_downcase), .domain]) |
    group_by([.match,.outbound])[] as $group |
    (["group",$group[0].match,$group[0].outbound] | @tsv),
    ($group[] | ["rule",.domain] | @tsv)
  ' "$CONFIG_FILE") || return 1
  if [[ -z $rows ]]; then info '还没有直接域名规则。'; return 0; fi
  while IFS=$'\t' read -r type match outbound domain; do
    case $type in
      group)
        ((groups == 0)) || printf '\n'
        groups=$((groups + 1))
        [[ $match == exact ]] && match='精确' || match='子域名'
        printf '%s%s%s → %s%s%s\n' \
          "$C_BOLD$C_CYAN" "$match" "$C_RESET" \
          "$C_BOLD$C_GREEN" "$( _outbound_display_name "$outbound" )" "$C_RESET"
        ;;
      rule)
        ((number+=1))
        print_table_cell "$number" 4; printf '  %s\n' "$match"
        ;;
    esac
    found=1
  done <<<"$rows"
  ((found)) || info '还没有直接域名规则。'
}
user_domain_add_menu() {
  local inbound=$1 label=$2 match domains outbound local_ip=''
  choose match '匹配方式' '域名及所有子域名' '仅精确域名' || return 0
  [[ $match == 1 ]] && match=suffix || match=exact
  prompt_domain_list domains '域名（多个请用英文逗号分隔）' || return 0
  select_outbound outbound 1 1 local_ip 0 || return 0
  run_menu_action outbound_user_domain_add "$inbound" "$label" "$match" "$domains" "$outbound" "$local_ip"
  pause
}

user_domain_delete_menu() {
  local inbound=$1 label=$2 identity choice
  _outbound_user_identity identity "$inbound" "$label" || return 1
  # Collect all non-template user domain rules (suffix and exact)
  local -a rule_domains=() rule_matches=() rule_outbounds=() display_items=()
  local r_match r_domain r_outbound display_match display_out
  while IFS=$'\t' read -r r_match r_domain r_outbound; do
    [[ -n $r_domain ]] || continue
    rule_matches+=("$r_match")
    rule_domains+=("$r_domain")
    rule_outbounds+=("$r_outbound")
    [[ $r_match == exact ]] && display_match='精确' || display_match='子域名'
    display_out=$(_outbound_display_name "$r_outbound")
    display_items+=("$r_domain（$display_match → $display_out）")
  done < <(jq -r --arg inbound "$inbound" --arg identity "$identity" '
    [ .routing.rules[]? |
      select(((.ruleTag // "")|startswith("xrayctl-user-domain:")) and
        .inboundTag==[$inbound] and .user==[$identity] and (.template // "")==""  ) |
      (.domain[0] // "") as $value |
      {match:(if ($value|startswith("full:")) then "exact"
              elif ($value|startswith("domain:")) then "suffix" else "" end),
       domain:(if ($value|startswith("full:")) then $value[5:]
               elif ($value|startswith("domain:")) then $value[7:] else $value end),
       outbound:(.outboundTag // "")}
    ] | map(select(.match!=""))[] | [.match,.domain,.outbound] | @tsv
  ' "$CONFIG_FILE")
  if (("${#rule_domains[@]}" == 0)); then
    info '还没有可删除的直接域名规则。'
    pause; return 0
  fi
  choose choice '选择要删除的域名规则' "${display_items[@]}" || return 0
  local idx=$((choice - 1))
  local del_domain="${rule_domains[$idx]}"
  local del_match="${rule_matches[$idx]}"
  local del_outbound="${rule_outbounds[$idx]}"
  [[ $del_match == exact ]] && display_match='精确' || display_match='子域名'
  printf '\n将要删除：%s（%s → %s）\n' "$del_domain" "$display_match" "$(_outbound_display_name "$del_outbound")"
  confirm "确认删除？" N || { info '已取消。'; pause; return 0; }
  run_menu_action outbound_user_domain_delete "$inbound" "$label" "$del_match" "$del_domain"
  pause
}

user_template_names() {
  local inbound=$1 identity=$2
  ensure_meta
  jq -r --arg inbound "$inbound" --arg user "$identity" \
    '[.domainTemplates.userBindings[]? | select(.inbound==$inbound and .user==$user) | .template] | if length==0 then "无" else join(", ") end' "$META_FILE"
}

user_template_bindings_display() {
  local inbound=$1 identity=$2 name outbound found=0
  ensure_meta
  while IFS=$'\t' read -r name outbound; do
    [[ -n $name ]] || continue
    printf '  %s → %s\n' "$name" "$( _outbound_display_name "$outbound" )"
    found=1
  done < <(jq -r --arg inbound "$inbound" --arg user "$identity" \
    '.domainTemplates.userBindings[]? | select(.inbound==$inbound and .user==$user) | [.template,.outbound] | @tsv' "$META_FILE")
  if ((found == 0)); then printf '  无\n'; fi
}

user_template_remove_menu() {
  local inbound=$1 label=$2 identity=$3 choice name
  local -a names=()
  mapfile -t names < <(jq -r --arg inbound "$inbound" --arg user "$identity" \
    '.domainTemplates.userBindings[]? | select(.inbound==$inbound and .user==$user) | .template' "$META_FILE")
  if ((${#names[@]}==0)); then info '该用户没有已应用模板。'; pause; return 0; fi
  choose choice '选择要移除的模板' "${names[@]}" || return 0
  name=${names[$((choice-1))]}
  run_menu_action user_template_remove "$inbound" "$label" "$name"
  pause
}

user_template_menu() {
  local inbound=$1 label=$2 identity choice name outbound local_ip=''
  _outbound_user_identity identity "$inbound" "$label" || return 1
  while true; do
    clear_screen
    heading "用户模板 · ${label}"
    printf '已应用模板：\n'
    user_template_bindings_display "$inbound" "$identity"
    printf '\n1) 应用模板\n2) 移除模板\n0) 返回\n'
    read -r -p '请选择: ' choice || { cancel_selection; return 0; }
    case $choice in
      1)
        select_domain_template name || continue
        local_ip=''
        select_outbound outbound 1 1 local_ip 0 || continue
        run_menu_action user_template_apply "$inbound" "$label" "$name" "$outbound" "$local_ip"
        pause;;
      2) user_template_remove_menu "$inbound" "$label" "$identity";;
      0) return;; *) warn '无效选项。'; pause;;
    esac
  done
}

user_outbound_detail_menu() {
  local inbound=$1 label=$2 choice identity default display_default
  while true; do
    clear_screen
    _outbound_user_identity identity "$inbound" "$label" || return 1
    default=$(_outbound_user_default "$inbound" "$identity")
    [[ -n $default ]] || default=$(_outbound_inbound_default "$inbound")
    display_default=$(_outbound_display_name "$default")
    heading "用户出站管理 · ${label}"
    printf '默认出站：%s\n模板：\n' "$display_default"
    user_template_bindings_display "$inbound" "$identity"
    heading '域名分流规则'
    printf '\n'
    _outbound_user_domain_rules_display "$inbound" "$identity"
    printf '\n1) 管理模板\n2) 添加规则\n3) 删除规则\n0) 返回\n'
    read -r -p '请选择: ' choice || { cancel_selection; return 0; }
    case $choice in
      1) user_template_menu "$inbound" "$label";;
      2) user_domain_add_menu "$inbound" "$label";;
      3) user_domain_delete_menu "$inbound" "$label";;
      0) return;; *) warn '无效选项。'; pause;;
    esac
  done
}

inbound_user_outbound_menu() {
  local inbound=$1 choice
  local -a labels=()
  mapfile -t labels < <(_outbound_user_labels "$inbound")
  if ((${#labels[@]}==0)); then info '该入站没有可识别的认证用户。'; pause; return 0; fi
  if ((${#labels[@]}==1)); then
    user_outbound_detail_menu "$inbound" "${labels[0]}"
    return 0
  fi
  choose choice '选择用户' "${labels[@]}" || return 0
  user_outbound_detail_menu "$inbound" "${labels[$((choice-1))]}"
}

inbound_outbound_detail_menu() {
  local inbound=$1 choice label identity default display_default count inbound_default first_user
  local -a labels=()
  while inbound_exists "$inbound"; do
    clear_screen
    heading "入站出站管理 · ${inbound}"
    mapfile -t labels < <(_outbound_user_labels "$inbound")
    inbound_default=$(_outbound_inbound_default "$inbound")
    printf '入站默认出站：%s\n\n用户：\n' "$(_outbound_display_name "$inbound_default")"
    if ((${#labels[@]})); then
      first_user=1
      for label in "${labels[@]}"; do
        if ((first_user)); then first_user=0; else printf '\n'; fi
        if _outbound_user_identity identity "$inbound" "$label" 2>/dev/null; then
          default=$(_outbound_user_default "$inbound" "$identity")
          count=$(_outbound_user_domain_count "$inbound" "$identity")
          [[ -n $default ]] || default=$inbound_default
          display_default=$(_outbound_display_name "$default")
          printf '  %s\n  默认出站：%s\n  分流规则：%s 条\n  模板：%s\n' \
            "$label" "$display_default" "$count" "$(user_template_names "$inbound" "$identity")"
        else
          printf '  %s\n  默认出站：未知\n  分流规则：未知\n  模板：无\n' "$label"
        fi
      done
    else
      printf '  无\n'
    fi
    printf '\n1) 设置默认出站\n2) 用户出站管理\n0) 返回\n'
    read -r -p '请选择: ' choice || { cancel_selection; return 0; }
    case $choice in
      1) run_menu_action assign_outbound "$inbound" ""; pause;;
      2) inbound_user_outbound_menu "$inbound";;
      0) return;; *) warn '无效选项。'; pause;;
    esac
  done
}

inbound_outbound_menu() {
  ensure_config
  local -a tags=()
  local choice
  mapfile -t tags < <(_outbound_inbound_tags)
  ((${#tags[@]})) || { info '还没有可管理的入站。'; pause; return 0; }
  if ((${#tags[@]}==1)); then
    inbound_outbound_detail_menu "${tags[0]}"
    return
  fi
  choose choice '选择入站' "${tags[@]}" || return 0
  inbound_outbound_detail_menu "${tags[$((choice-1))]}"
}

select_domain_template() {
  local __var=$1 answer template_name
  local -a names=()
  while IFS=$'\t' read -r template_name _ _; do
    [[ -n $template_name ]] && names+=("$template_name")
  done < <(list_domain_templates)
  ((${#names[@]})) || { warn "还没有模板。"; pause; return 1; }
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
    read -r -p '请选择要删除的域名（支持 1,3,2）: ' selection || { cancel_selection; return 1; }
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
    read -r -p '请选择: ' choice || { cancel_selection; return 0; }
    case $choice in
      1)
        choose type "域名类型" "精确域名" "域名及所有子域名" || continue
        [[ $type == 1 ]] && match=exact || match=suffix
        prompt_domain_list domains "域名（多个请用英文逗号分隔）" || continue
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
    read -r -p '请选择: ' choice || { cancel_selection; return 0; }
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

client_menu_for_tag() {
  local tag=$1 choice
  while inbound_exists "$tag"; do
    clear_screen
    heading "用户管理 · ${tag}"
    list_clients "$tag"
    printf '\n1) 添加用户\n2) 重命名用户\n3) 更换 UUID/密码\n4) 删除用户\n0) 返回入站\n'
    read -r -p "请选择: " choice || { cancel_selection; return 0; }
    case $choice in
      1) run_menu_action add_client "$tag"; pause;; 2) run_menu_action rename_client "$tag"; pause;;
      3) run_menu_action rotate_client_credential "$tag"; pause;; 4) run_menu_action delete_client "$tag"; pause;;
      0) return;; *) warn "无效选项。"; pause;;
    esac
  done
}

modify_inbound_menu() {
  local current_tag=$1 protocol=$2 parent_tag_var=${3-} choice renamed_tag
  while inbound_exists "$current_tag"; do
    clear_screen
    heading "修改入站信息 · ${current_tag}"
    printf '1) 修改入站名称\n2) 修改地址/端口\n'
    [[ $protocol != vless ]] || printf '3) 修改传输/安全\n'
    printf '0) 返回入站\n'
    read -r -p "请选择: " choice || { cancel_selection; return 0; }
    case $choice in
      1)
        # Keep the requested name in this shell: run_menu_action isolates writes
        # in a subshell, so it cannot update the menus' selected tag for us.
        prompt_renamed_inbound_tag renamed_tag "$current_tag" || continue
        run_menu_action rename_inbound "$current_tag" "$renamed_tag"
        if [[ $renamed_tag != "$current_tag" ]] && ! inbound_exists "$current_tag" && inbound_exists "$renamed_tag"; then
          current_tag=$renamed_tag
          # Update the caller too, so returning one level keeps this inbound.
          [[ -z $parent_tag_var ]] || printf -v "$parent_tag_var" '%s' "$current_tag"
        fi
        pause
        ;;
      2) run_menu_action modify_inbound_basic "$current_tag"; pause;;
      3)
        if [[ $protocol == vless ]]; then run_menu_action modify_inbound_transport "$current_tag"
        else warn "无效选项。"; fi
        pause
        ;;
      0) return;; *) warn "无效选项。"; pause;;
    esac
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
          read -r -p "请选择: " choice || { cancel_selection; return 0; }
          case $choice in
            1) run_menu_action print_links "$tag"; pause;; 2) client_menu_for_tag "$tag";; 3) modify_inbound_menu "$tag" "$protocol" tag;;
            4) manage_inbound_certificate_menu "$tag";; 5) run_menu_action show_inbound "$tag"; pause;;
            0) return;; *) warn "无效选项。"; pause;;
          esac
        else
          printf '1) 分享信息\n2) 用户管理\n3) 修改入站信息\n4) 查看 JSON\n0) 返回列表\n'
          read -r -p "请选择: " choice || { cancel_selection; return 0; }
          case $choice in
            1) run_menu_action print_links "$tag"; pause;; 2) client_menu_for_tag "$tag";; 3) modify_inbound_menu "$tag" "$protocol" tag;;
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
          read -r -p "请选择: " choice || { cancel_selection; return 0; }
          case $choice in
            1) run_menu_action print_links "$tag"; pause;; 2) client_menu_for_tag "$tag";; 3) modify_inbound_menu "$tag" "$protocol" tag;;
            4) run_menu_action show_inbound "$tag"; pause;;
            0) return;; *) warn "无效选项。"; pause;;
          esac
        else
          printf '1) 客户端配置\n2) 修改入站信息\n3) 查看 JSON\n0) 返回列表\n'
          read -r -p "请选择: " choice || { cancel_selection; return 0; }
          case $choice in
            1) run_menu_action print_links "$tag"; pause;; 2) modify_inbound_menu "$tag" "$protocol" tag;;
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
          read -r -p "请选择: " choice || { cancel_selection; return 0; }
          case $choice in
            1) run_menu_action print_links "$tag"; pause;; 2) client_menu_for_tag "$tag";; 3) modify_inbound_menu "$tag" "$protocol" tag;;
            4) run_menu_action show_inbound "$tag"; pause;;
            0) return;; *) warn "无效选项。"; pause;;
          esac
        else
          printf '1) 客户端配置\n2) 修改入站信息\n3) 查看 JSON\n0) 返回列表\n'
          read -r -p "请选择: " choice || { cancel_selection; return 0; }
          case $choice in
            1) run_menu_action print_links "$tag"; pause;; 2) modify_inbound_menu "$tag" "$protocol" tag;;
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
    read -r -p "请选择: " choice || { cancel_selection; return 0; }
    case $choice in
      1) run_menu_action add_inbound; pause;;
      2) if select_inbound tag; then manage_inbound_menu "$tag"; fi;;
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
    read -r -p "请选择: " choice || { cancel_selection; return 0; }
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
    printf '1) 启动/停止\n2) 重启服务\n3) 开关开机自启\n4) 查看日志\n5) 安装 Xray\n6) BBR启用/关闭\n0) 返回\n'
    read -r -p "请选择: " choice || { cancel_selection; return 0; }
    case $choice in
      1) run_menu_action toggle_service_running; pause;; 2) run_menu_action service_action restart; pause;;
      3) run_menu_action toggle_service_startup; pause;; 4) run_menu_action show_logs 100; pause;;
      5) run_menu_action install_or_update_xray; pause;;
      6) run_menu_action manage_bbr; pause;;
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

traffic_menu() {
  local choice
  traffic_is_enabled && run_menu_action traffic_collect
  while true; do
    clear_screen
    traffic_show || true
    printf '\n1) 刷新\n2) 清空指定入站记录\n3) 清空全部入站流量记录\n'
    printf '4) 设置月度统计起点\n'
    printf '0) 返回\n'
    read -r -p "请选择: " choice || { cancel_selection; return 0; }
    case $choice in
      1) run_menu_action traffic_collect;;
      2) run_menu_action traffic_clear_tag_records; pause;;
      3) run_menu_action traffic_clear_all_records; pause;;
      4) run_menu_action traffic_period_set; pause;;
      0) return;;
      *) warn "无效选项。"; pause;;
    esac
  done
}

traffic_limit_menu() {
  local choice
  traffic_user_ensure_configured || true
  while true; do
    if traffic_is_enabled; then run_menu_action traffic_collect || true; fi
    clear_screen
    traffic_users_show "" || true
    printf '\n1) 刷新流量\n2) 管理用户额度\n0) 返回\n'
    read -r -p "请选择: " choice || { cancel_selection; return 0; }
    case $choice in
      1) continue;;
      2) traffic_user_menu;;
      0) return 0;;
      *) warn "无效选项。"; pause;;
    esac
  done
}

traffic_user_menu() {
  local tag label choice current_bytes used quota enabled status id period_start record start end day clock index selected inventory conflict
  local -a user_labels=()
  ensure_config
  select_inbound tag '^(vless|socks|http)$' || return 0
  if ! jq -e --arg tag "$tag" '.inbounds[]? | select(.tag==$tag and (
    (.protocol=="vless" and ((.settings.clients // [])|length)>0) or
    (.protocol=="socks" and .settings.auth=="password" and ((.settings.accounts // .settings.users // [])|length)>0) or
    (.protocol=="http" and ((.settings.accounts // .settings.users // [])|length)>0)
  ))' "$CONFIG_FILE" >/dev/null; then
    warn '该入站没有可统计的认证用户。'
    pause
    return 0
  fi
  if ! traffic_user_managed_config; then
    if ! traffic_user_enable; then pause; return 0; fi
    if ! traffic_user_managed_config; then pause; return 0; fi
  fi
  inventory=$(traffic_user_inventory_json "$CONFIG_FILE") || { pause; return 0; }
  if ! jq -e --arg tag "$tag" 'any(.[]; .tag==$tag)' <<<"$inventory" >/dev/null; then
    warn '该入站没有可统计的认证用户。'
    pause
    return 0
  fi
  while true; do
    clear_screen
    inventory=$(traffic_user_inventory_json "$CONFIG_FILE") || return 1
    mapfile -t user_labels < <(jq -r --arg tag "$tag" '[.[] | select(.tag==$tag) | .label] | reduce .[] as $label ([]; if index($label)==null then .+[$label] else . end) | .[]' <<<"$inventory")
    if ((${#user_labels[@]} == 0)); then warn '该入站没有用户。'; pause; return 0; fi
    IFS=$'\t' read -r period_start _ < <(traffic_period_bounds "$(traffic_now)")
    heading "$tag"
    for index in "${!user_labels[@]}"; do
    label=${user_labels[$index]}
    id=$(traffic_user_id "$tag" "$label")
    record=$(jq -c --arg tag "$tag" --arg id "$id" '.inbounds[$tag].users[$id] // {}' "$TRAFFIC_FILE") || return 1
    conflict=$(jq -r --arg tag "$tag" --arg id "$id" 'any(.[]; .tag==$tag and .id==$id and .ambiguous)' <<<"$inventory")
    current_bytes=$(jq -r --arg periodStart "$period_start" '.cycles[$periodStart] // 0' <<<"$record")
    enabled=$(jq -r '.limit.enabled // false' <<<"$record")
    used=$(jq -r '.limit.usedBytes // 0' <<<"$record")
    quota=$(jq -r '.limit.quotaBytes // 0' <<<"$record")
    printf '用户：%s\n' "$label"
    if [[ $conflict == true ]]; then
      printf '流量：统计冲突\n状态：身份冲突\n\n'
    elif [[ $enabled == true && $quota =~ ^[0-9]+$ ]] && ((quota > 0)); then
      if ((used >= quota)); then status='超额'; else status='正常'; fi
      start=$(jq -r '.limit.cycleStart // ""' <<<"$record")
      end=$(jq -r '.limit.cycleEnd // ""' <<<"$record")
      day=$(jq -r '.limit.anchorDay // .limit.resetDay // "-"' <<<"$record")
      clock=$(jq -r '.limit.anchorTime // ""' <<<"$record")
      printf '流量：%s / %s\n重置：每月 %s 日 %s\n' "$(traffic_format_bytes "$used")" "$(traffic_format_bytes "$quota")" "$day" "${clock:0:5}"
      if traffic_validate_timestamp "$start" && traffic_validate_timestamp "$end"; then
        printf '周期：%s月%s日 %s ～ %s月%s日 %s\n' "$((10#${start:5:2}))" "$((10#${start:8:2}))" "${start:11:5}" "$((10#${end:5:2}))" "$((10#${end:8:2}))" "${end:11:5}"
      fi
      printf '状态：%s\n' "$status"
    else
      printf '流量：%s / ∞\n重置周期：无\n状态：正常\n' "$(traffic_format_bytes "$current_bytes")"
    fi
    printf '\n'
    done
    printf '1) 设置/修改额度\n2) 重置用户流量\n3) 取消用户额度\n0) 返回\n'
    read -r -p '请选择: ' choice || { cancel_selection; return 0; }
    case $choice in 0) return 0;; 1|2|3) ;; *) warn '无效选项。'; pause; continue;; esac
    if ((${#user_labels[@]} == 1)); then
      label=${user_labels[0]}
    else
      printf '\n选择用户\n'
      for index in "${!user_labels[@]}"; do printf '  %s) %s\n' "$((index+1))" "${user_labels[$index]}"; done
      while true; do
        read -r -p '输入用户序号: ' selected || { cancel_selection; return 0; }
        if [[ $selected =~ ^[0-9]+$ ]] && ((${#selected} <= 6)) && ((10#$selected >= 1 && 10#$selected <= ${#user_labels[@]})); then
          label=${user_labels[$((10#$selected-1))]}
          break
        fi
        warn '无效的用户序号。'
      done
      [[ -n $selected ]] || continue
    fi
    case $choice in
      1) run_menu_action traffic_user_limit_set "$tag" "$label"; pause;;
      2) run_menu_action traffic_user_reset "$tag" "$label"; pause;;
      3) run_menu_action traffic_user_limit_remove "$tag" "$label"; pause;;
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
    printf '1) 入站管理\n2) 出站管理\n3) TLS 证书\n4) 流量限制\n5) 流量信息\n6) 服务管理\n7) 卸载\n0) 退出\n'
    read -r -p "请选择: " choice || { cancel_selection; return 0; }
    case $choice in
      1) inbound_menu;; 2) outbound_menu;; 3) certificate_menu;; 4) traffic_limit_menu;;
      5) traffic_menu;; 6) service_menu;;
      7) clear_screen; run_menu_action uninstall_xray; pause;;
      0) return;; *) warn "无效选项。"; pause;;
    esac
  done
}

show_help() {
  cat <<'EOF'
xrayctl - Xray Linux 管理脚本

用法:
  xrayctl                         打开交互菜单
  xrayctl install [版本]              安装/修复 Xray
  xrayctl status                  查看状态
  xrayctl start|stop|restart      服务控制
  xrayctl logs [行数]             查看服务日志
  xrayctl traffic [开始日期] [结束日期] 查看当前周期内按入站累计流量
  xrayctl traffic period [show|set <日期> <HH:MM>] 查看/设置统一月度统计起点
  xrayctl traffic user enable
  xrayctl traffic user show
  xrayctl traffic user set <入站> <用户> <GB> <重置日> [HH:MM]
  xrayctl traffic user remove <入站> <用户> [--yes]
  xrayctl traffic user reset <入站> <用户> [--yes]
  xrayctl inbound list            列出入站
  xrayctl inbound add             交互新增入站
  xrayctl inbound show <标签>     查看入站 JSON
  xrayctl inbound rename <旧标签> <新标签>
  xrayctl inbound modify <标签>   修改监听端口/地址
  xrayctl inbound transport <标签> 修改传输与安全方式
  xrayctl inbound disable <标签> [--yes] 禁用入站
  xrayctl inbound enable <标签> [--yes] 启用入站
  xrayctl inbound delete <标签> [--yes]
  xrayctl outbound list
  xrayctl outbound add
  xrayctl outbound assign <入站> <出站标签|direct>
  xrayctl outbound inbound list
  xrayctl outbound user list <入站>
  xrayctl outbound user set <入站> <用户> <出站>
  xrayctl outbound user unset <入站> <用户>
  xrayctl outbound user rule list <入站> <用户>
  xrayctl outbound user rule add <入站> <用户> <suffix|exact> <域名[,域名...]> <出站>
  xrayctl outbound user rule delete <入站> <用户> <suffix|exact> <域名[,域名...]>
  xrayctl outbound user restore <入站> <用户>
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
  xrayctl cert list                 列出托管证书
  xrayctl cert issue [域名] [邮箱]   Let's Encrypt 自动签发
  xrayctl cert import [标识] [证书] [私钥]  导入已有证书
  xrayctl cert delete <标识> [--yes] 删除托管证书
  xrayctl cert renew-auto            立即续期所有托管证书
  xrayctl cert renew <标识>          续期单个证书
  xrayctl cert cloudflare            管理 Cloudflare DNS 凭据
  xrayctl bbr                        启用/关闭 BBR（交互式）
  xrayctl version

支持协议: VLESS、SOCKS5、HTTP
支持传输: RAW、XHTTP、WebSocket；支持 TLS 和 REALITY。
EOF
}

dispatch() {
  local command=${1:-menu}; shift || true
  case $command in
    menu)
      if [[ ${XRAYCTL_TESTING:-0} == 1 || $(id -u) -eq 0 ]]; then traffic_runtime_ensure || true; fi
      main_menu
      ;;
    help|-h|--help) show_help;;
    version|-v|--version)
      printf 'xrayctl %s' "$XRAYCTL_VERSION"
      [[ $XRAYCTL_BUILD_COMMIT == development ]] || printf ' (commit %s)' "$XRAYCTL_BUILD_COMMIT"
      printf '\n'
      ;;
    install) install_or_update_xray "${1-}";;
    status)
      if [[ ${XRAYCTL_TESTING:-0} == 1 || $(id -u) -eq 0 ]]; then traffic_runtime_ensure || true; fi
      show_status
      ;;
    start|stop|restart|enable|disable) service_action "$command";;
    logs) show_logs "${1:-100}";;
    traffic)
      case ${1:-show} in
        enable|start) traffic_enable;;
        disable|stop) traffic_disable;;
        *)
          traffic_runtime_ensure || true
          case ${1:-show} in
            show) traffic_collect || true; traffic_show "${2-}" "${3-}";;
            collect|refresh) traffic_collect;;
            period)
              case ${2:-show} in
                show) traffic_period_show;;
                set) traffic_period_set "${3-}" "${4-}";;
                *) die "未知 traffic period 子命令：${2}";;
              esac
              ;;
            reset)
              if [[ ${2-} == --all ]]; then traffic_clear_all_records; else traffic_clear_tag_records "${2-}"; fi
              ;;
            user)
              case ${2:-show} in
                show) traffic_user_ensure_configured || true; traffic_collect || true; traffic_users_show "${3-}";;
                enable) traffic_user_enable;;
                set) traffic_user_limit_set "${3-}" "${4-}" "${5-}" "${6-}" "${7-}";;
                remove|delete) traffic_user_limit_remove "${3-}" "${4-}" "$([[ ${5-} == --yes ]] && printf 1 || printf 0)";;
                reset) traffic_user_reset "${3-}" "${4-}" "$([[ ${5-} == --yes ]] && printf 1 || printf 0)";;
                *) die "未知 traffic user 子命令：${2}";;
              esac
              ;;
            [0-9][0-9][0-9][0-9]-*) traffic_collect || true; traffic_show "$1" "${2:-$(traffic_today)}";;
            *) die "未知 traffic 子命令：${1}";;
          esac
          ;;
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
        inbound)
          case ${2:-list} in
            list) list_inbound_outbound_status;;
            set) assign_outbound "${3-}" "${4-}";;
            unset|remove) remove_inbound_default_outbound "${3-}";;
            *) die "未知 outbound inbound 子命令：${2}";;
          esac
          ;;
        user)
          case ${2:-list} in
            list) outbound_user_list "${3-}";;
            set) outbound_user_default_set "${3-}" "${4-}" "${5-}";;
            unset) outbound_user_default_unset "${3-}" "${4-}";;
            restore|inherit) outbound_user_restore "${3-}" "${4-}";;
            rule)
              case ${3:-list} in
                list) outbound_user_domain_list "${4-}" "${5-}";;
                add) outbound_user_domain_add "${4-}" "${5-}" "${6-}" "${7-}" "${8-}";;
                delete|remove) outbound_user_domain_delete "${4-}" "${5-}" "${6-}" "${7-}";;
                *) die "未知 outbound user rule 子命令：${3}";;
              esac
              ;;
            *) die "未知 outbound user 子命令：${2}";;
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

    bbr) manage_bbr;;
    internal-traffic-collect) internal_traffic_collect;;
    internal-traffic-ensure) traffic_runtime_ensure;;
    internal-traffic-watch) internal_traffic_watch;;
    *) error "未知命令：$command"; show_help; return 2;;
  esac
}
