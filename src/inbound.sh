inbound_exists() { jq -e --arg tag "$1" '.inbounds[] | select(.tag==$tag)' "$CONFIG_FILE" >/dev/null; }

port_in_config() {
  local port=$1 except=${2-}
  [[ -r $CONFIG_FILE ]] || return 1
  jq -e --argjson port "$port" --arg except "$except" '.inbounds[] | select(.port==$port and .tag!=$except)' "$CONFIG_FILE" >/dev/null 2>&1
}

port_in_use_os() {
  local port=$1
  if command_exists ss; then ss -H -lntu 2>/dev/null | awk '{print $5}' | grep -Eq "(^|:)$port$";
  elif command_exists netstat; then netstat -lntu 2>/dev/null | awk '{print $4}' | grep -Eq "(^|:)$port$";
  else return 1; fi
}

sbctl_port_conflict_reason() {
  local port=$1 range start end
  validate_port "$port" || return 1
  if [[ -r $SBCTL_CONFIG_FILE ]] && jq -e --argjson port "$port" \
    '.inbounds[]? | select(.listen_port==$port)' "$SBCTL_CONFIG_FILE" >/dev/null 2>&1; then
    printf 'sbctl/sing-box 入站正在使用该端口'
    return 0
  fi
  [[ -r $SBCTL_META_FILE ]] || return 1
  while IFS= read -r range; do
    [[ $range =~ ^([0-9]{1,5})-([0-9]{1,5})$ ]] || continue
    start=${BASH_REMATCH[1]}; end=${BASH_REMATCH[2]}
    if ! validate_port "$start" || ! validate_port "$end"; then continue; fi
    if ((10#$port >= 10#$start && 10#$port <= 10#$end)); then
      printf '该端口位于 sbctl Hysteria2 UDP 跳跃范围 %s 内' "$range"
      return 0
    fi
  done < <(jq -r '.inbounds[]? | select(.hysteria2PortHopping.enabled==true) | .hysteria2PortHopping.range // empty' "$SBCTL_META_FILE" 2>/dev/null || true)
  return 1
}

suggest_available_port() {
  local __var=$1 candidate hex i
  for ((i=0; i<128; i++)); do
    hex=$(random_hex 2)
    candidate=$((10000 + (16#$hex % 55536)))
    port_in_config "$candidate" && continue
    sbctl_port_conflict_reason "$candidate" >/dev/null && continue
    port_in_use_os "$candidate" && continue
    printf -v "$__var" '%s' "$candidate"
    return 0
  done
  return 1
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
  local __var=$1 default=${2:-443} except=${3-} value current_port="" peer_reason=""
  while true; do
    prompt_value value "监听端口" "$default"
    validate_port "$value" || { warn "端口必须是 1-65535。"; continue; }
    port_in_config "$value" "$except" && { warn "该端口已被另一条 Xray 入站使用。"; continue; }
    if peer_reason=$(sbctl_port_conflict_reason "$value"); then
      warn "端口 ${value} 与 sbctl 冲突：${peer_reason}。"
      continue
    fi
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
  local inbound="" host="" public_key="" tag tmp
  build_inbound inbound host public_key
  : "$public_key"
  tag=$(jq -r '.tag' <<<"$inbound")
  tmp=$(temp_file)
  jq --argjson inbound "$inbound" '.inbounds += [$inbound]' "$CONFIG_FILE" >"$tmp"
  state_apply_candidate_file "$tmp" state_commit_inbound_set "$tag" "$host" || return
  heading "入站已创建"
  show_inbound "$tag"
  print_links "$tag" "" || true
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
  state_apply_candidate_file "$tmp" state_commit_inbound_rename "$old_tag" "$new_tag" || return
  info "入站已重命名：${old_tag} → ${new_tag}。"
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
  state_apply_candidate_file "$tmp" state_commit_inbound_set "$tag" "$host" || return
  current=$(jq --arg tag "$tag" '.inbounds[]|select(.tag==$tag)' "$CONFIG_FILE")
}

modify_inbound_transport() {
  ensure_runtime_dependencies inbound-transport; require_xray_installed; ensure_config
  local tag=${1-} protocol stream public_key="" tmp method security
  [[ -n $tag ]] || select_inbound tag '^(vless|vmess|trojan)$' || return
  inbound_exists "$tag" || die "找不到入站：$tag"
  protocol=$(jq -r --arg tag "$tag" '.inbounds[]|select(.tag==$tag)|.protocol' "$CONFIG_FILE")
  [[ $protocol =~ ^(vless|vmess|trojan)$ ]] || die "${protocol} 入站没有可修改的流式传输。"
  warn "修改传输后，所有客户端都要同步更新配置。"
  confirm "为 ${tag} 重新选择传输和安全方式？" N || return 0
  build_stream_settings "$protocol" stream public_key
  : "$public_key"
  method=$(jq -r '.method' <<<"$stream"); security=$(jq -r '.security' <<<"$stream")
  tmp=$(temp_file)
  jq --arg tag "$tag" --argjson stream "$stream" --arg method "$method" --arg security "$security" '
    (.inbounds[]|select(.tag==$tag)|.streamSettings)=$stream |
    if (.inbounds[]|select(.tag==$tag)|.protocol)=="vless" then
      (.inbounds[]|select(.tag==$tag)|.settings.clients) |= map(
        if $method=="raw" and $security!="none" then .flow="xtls-rprx-vision" else del(.flow) end
      )
    else . end' "$CONFIG_FILE" >"$tmp"
  state_apply_candidate_file "$tmp" state_commit_inbound_set "$tag" "$(public_host_for_tag "$tag")" || return
  info "传输已更新，请重新导出客户端分享链接。"
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
  state_apply_candidate_file "$tmp" state_commit_inbound_delete "$tag" || return
  info "已删除入站 ${tag} 及其 ${user_count} 个用户。"
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
  state_apply_candidate_file "$tmp" apply_candidate || return
  info "用户 ${label} 已添加。"
  print_links "$tag" "$label" || true
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
  state_apply_candidate_file "$tmp" apply_candidate
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
  state_apply_candidate_file "$tmp" apply_candidate || return
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
  state_apply_candidate_file "$tmp" apply_candidate || return
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
