inbound_exists() { jq -e --arg tag "$1" '.inbounds[] | select(.tag==$tag)' "$CONFIG_FILE" >/dev/null; }

inbound_is_disabled() {
  [[ -f $META_FILE ]] && jq -e --arg tag "$1" '.disabledInbounds[$tag].config != null' "$META_FILE" >/dev/null 2>&1
}

inbound_tag_reserved() { inbound_exists "$1" || inbound_is_disabled "$1"; }

inbound_configuration_is_supported() {
  local tag=$1 protocol method
  protocol=$(jq -r --arg tag "$tag" '.inbounds[]|select(.tag==$tag)|.protocol' "$CONFIG_FILE")
  protocol_is_supported "$protocol" || return 1
  if protocol_supports_stream "$protocol"; then
    method=$(jq -r --arg tag "$tag" '.inbounds[]|select(.tag==$tag)|.streamSettings.network // .streamSettings.method // "raw"' "$CONFIG_FILE")
    case $method in raw|xhttp|websocket) ;; *) return 1;; esac
  fi
}

inbound_require_supported_configuration() {
  inbound_configuration_is_supported "$1" \
    || die "该入站使用已停止支持的协议或传输；仅允许查看或删除。"
}

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

suggest_available_port() {
  local __var=$1 candidate hex offset i
  for ((i=0; i<128; i++)); do
    hex=$(random_hex 2)
    offset=$((16#$hex % 35535))
    if ((offset < 20000)); then
      candidate=$((10000 + offset))
    else
      candidate=$((50001 + offset - 20000))
    fi
    port_in_config "$candidate" && continue
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
    inbound_tag_reserved "$value" && { warn "标签已存在。"; continue; }
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
      warn "系统检测到端口 ${value} 已被占用，请换一个端口。"
      continue
    fi
    printf -v "$__var" '%s' "$value"; return
  done
}

prompt_public_host() {
  local __var=$1 default=${2:-${XRAYCTL_PUBLIC_HOST:-}} preferred=${3:-} value ipv4="" ipv6="" address_choice prompt_label="客户端连接地址" cert_id cert_subject
  local labels=() values=()
  if [[ -z $default ]]; then
    ipv4=$(detect_public_ipv4 || true)
    ipv6=$(detect_public_ipv6 || true)
    if [[ -n $preferred ]]; then labels+=("证书域名/IP  ${preferred}"); values+=("$preferred"); fi
    while IFS= read -r cert_id; do
      [[ -n $cert_id ]] || continue
      cert_subject=$(meta_cert_get_field "$cert_id" subject 2>/dev/null || true)
      [[ -n $cert_subject ]] || continue
      [[ $cert_subject == "$preferred" ]] && continue
      [[ " ${values[*]} " == *" $cert_subject "* ]] && continue
      labels+=("证书域名/IP  ${cert_subject}"); values+=("$cert_subject")
    done < <(meta_cert_list 2>/dev/null || true)
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
  traffic_after_config_change || warn "入站已创建，但流量规则暂未同步，采集任务会自动重试。"
  heading "入站已创建"
  show_inbound "$tag"
  print_links "$tag" "" || true
}

list_inbounds() {
  ensure_config
  local count
  count=$(jq --slurpfile meta "$META_FILE" '(.inbounds|length)+(($meta[0].disabledInbounds // {})|length)' "$CONFIG_FILE")
  if ((count == 0)); then info "还没有入站。"; return; fi
  print_table_cell_clipped "标签" 20; printf '| '; print_table_cell_clipped "协议" 8; printf '| '
  print_table_cell "端口" 7; printf '| '; print_table_cell_clipped "传输" 7; printf '| '
  print_table_cell_clipped "安全" 10; printf '| 监听 | 状态\n'
  jq -r --slurpfile meta "$META_FILE" '
    ([.inbounds[] | {config:.,status:"运行中"}] +
     [($meta[0].disabledInbounds // {})[] | {config:.config,status:"已禁用"}])[] |
    [.config.tag,.config.protocol,(.config.port|tostring),
     (if (.config.streamSettings.network // .config.streamSettings.method // "raw")=="websocket" then "ws" else (.config.streamSettings.network // .config.streamSettings.method // "raw") end),
     (.config.streamSettings.security // "none"),(.config.listen // "0.0.0.0"),.status] | @tsv' "$CONFIG_FILE" \
    | while IFS=$'\t' read -r tag protocol port method security listen status; do
        print_table_cell_clipped "$tag" 20; printf '| '; print_table_cell_clipped "$protocol" 8; printf '| '
        print_table_cell "$port" 7; printf '| '; print_table_cell_clipped "$method" 7; printf '| '
        print_table_cell_clipped "$security" 10; printf '| %s | %s\n' "$listen" "$status"
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

select_inbound_toggle() {
  local __var=$1 answer state __item_tag
  local tags=() labels=()
  ensure_config
  while IFS=$'\t' read -r __item_tag state; do
    [[ -n $__item_tag ]] || continue
    tags+=("$__item_tag"); labels+=("${__item_tag}（${state}）")
  done < <(jq -r --slurpfile meta "$META_FILE" '
    ([.inbounds[] | [.tag,"运行中"]] +
     [($meta[0].disabledInbounds // {}) | keys[] | [.,"已禁用"]])[] | @tsv' "$CONFIG_FILE")
  ((${#tags[@]})) || { warn "没有可选入站。"; return 1; }
  if ((${#tags[@]} == 1)); then answer=1; else choose answer "选择要禁用或启用的入站" "${labels[@]}" || return 1; fi
  printf -v "$__var" '%s' "${tags[$((answer-1))]}"
}

disable_inbound() {
  ensure_runtime_dependencies inbound-disable; ensure_config
  local tag=${1-} assume_yes=${2:-0} inbound position candidate
  [[ -n $tag ]] || select_inbound tag || return 0
  inbound_exists "$tag" || { warn "入站 ${tag} 未启用。"; return 1; }
  [[ $assume_yes == 1 ]] || confirm "禁用入站 ${tag}？连接将中断。" N || return 0
  if traffic_is_enabled; then traffic_collect || return 1; fi
  inbound=$(jq -c --arg tag "$tag" '.inbounds[]|select(.tag==$tag)' "$CONFIG_FILE")
  position=$(jq --arg tag "$tag" '.inbounds|map(.tag)|index($tag)' "$CONFIG_FILE")
  candidate=$(temp_file)
  jq --arg tag "$tag" '.inbounds |= map(select(.tag!=$tag))' "$CONFIG_FILE" >"$candidate"
  state_apply_candidate_file "$candidate" state_commit_inbound_disable "$tag" "$inbound" "$position" || return 1
  traffic_after_config_change || warn "入站已禁用，但流量规则暂未同步，采集任务会自动重试。"
  info "入站 ${tag} 已禁用。"
}

enable_inbound() {
  ensure_runtime_dependencies inbound-enable; ensure_config
  local tag=${1-} entry inbound position port candidate
  [[ -n $tag ]] || select_inbound_toggle tag || return 0
  inbound_is_disabled "$tag" || { warn "入站 ${tag} 未处于禁用状态。"; return 1; }
  inbound_exists "$tag" && { warn "运行配置中已有同名入站：${tag}。"; return 1; }
  entry=$(jq -c --arg tag "$tag" '.disabledInbounds[$tag]' "$META_FILE")
  inbound=$(jq -c '.config' <<<"$entry")
  position=$(jq '.position // 0' <<<"$entry")
  port=$(jq -r '.port' <<<"$inbound")
  if port_in_config "$port" || port_in_use_os "$port"; then
    warn "端口 ${port} 已被占用，无法启用入站 ${tag}。"
    return 1
  fi
  candidate=$(temp_file)
  jq --argjson inbound "$inbound" --argjson position "$position" '
    .inbounds |= (.[0:$position] + [$inbound] + .[$position:])' "$CONFIG_FILE" >"$candidate"
  state_apply_candidate_file "$candidate" state_commit_inbound_enable "$tag" || return 1
  traffic_after_config_change || warn "入站已启用，但流量规则暂未同步，采集任务会自动重试。"
  info "入站 ${tag} 已启用。"
}

toggle_inbound() {
  local tag=${1-}
  [[ -n $tag ]] || select_inbound_toggle tag || return 0
  if inbound_is_disabled "$tag"; then enable_inbound "$tag"; else disable_inbound "$tag"; fi
}

prompt_renamed_inbound_tag() {
  local __var=$1 old_tag=$2 candidate
  while true; do
    prompt_validated_value candidate "新的入站名称" "$old_tag" validate_tag "名称只能包含字母、数字、点、下划线和横线。" || return 1
    if [[ $candidate != "$old_tag" ]] && { inbound_tag_reserved "$candidate" || outbound_exists "$candidate"; }; then
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
  inbound_require_supported_configuration "$old_tag"
  [[ -n $new_tag ]] || prompt_renamed_inbound_tag new_tag "$old_tag"
  validate_tag "$new_tag" || die "入站名称格式无效。"
  if [[ $new_tag == "$old_tag" ]]; then info "入站名称未更改。"; return 0; fi
  if inbound_tag_reserved "$new_tag" || outbound_exists "$new_tag"; then
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
  traffic_after_config_change "$old_tag" "$new_tag" || warn "入站已重命名，但流量记录暂未同步，采集任务会自动重试。"
  info "入站已重命名：${old_tag} → ${new_tag}。"
}

modify_inbound_basic() {
  ensure_runtime_dependencies inbound-modify; ensure_config
  local tag=${1-} current listen port host tmp old_port
  [[ -n $tag ]] || select_inbound tag || return
  inbound_exists "$tag" || die "找不到入站：$tag"
  inbound_require_supported_configuration "$tag"
  current=$(jq --arg tag "$tag" '.inbounds[]|select(.tag==$tag)' "$CONFIG_FILE")
  old_port=$(jq -r '.port' <<<"$current")
  prompt_value listen "监听地址" "$(jq -r '.listen // "0.0.0.0"' <<<"$current")"
  prompt_port port "$old_port" "$tag"
  prompt_public_host host "$(jq -r --arg tag "$tag" '.inbounds[$tag].host // empty' "$META_FILE")"
  tmp=$(temp_file)
  jq --arg tag "$tag" --arg listen "$listen" --argjson port "$port" \
    '(.inbounds[]|select(.tag==$tag)) |= (.listen=$listen | .port=$port)' "$CONFIG_FILE" >"$tmp"
  state_apply_candidate_file "$tmp" state_commit_inbound_set "$tag" "$host" || return
  traffic_after_config_change || warn "入站已修改，但流量规则暂未同步，采集任务会自动重试。"
  current=$(jq --arg tag "$tag" '.inbounds[]|select(.tag==$tag)' "$CONFIG_FILE")
}

modify_inbound_transport() {
  ensure_runtime_dependencies inbound-transport; require_xray_installed; ensure_config
  local tag=${1-} protocol stream public_key="" tmp method security
  [[ -n $tag ]] || select_inbound tag '^vless$' || return
  inbound_exists "$tag" || die "找不到入站：$tag"
  inbound_require_supported_configuration "$tag"
  protocol=$(jq -r --arg tag "$tag" '.inbounds[]|select(.tag==$tag)|.protocol' "$CONFIG_FILE")
  [[ $protocol == vless ]] || die "${protocol} 已停止支持或没有可修改的流式传输。"
  warn "修改传输后，所有客户端都要同步更新配置。"
  confirm "为 ${tag} 重新选择传输和安全方式？" N || return 0
  build_stream_settings "$protocol" stream public_key
  : "$public_key"
  method=$(jq -r '.network // .method // "raw"' <<<"$stream"); security=$(jq -r '.security // "none"' <<<"$stream")
  tmp=$(temp_file)
  jq --arg tag "$tag" --argjson stream "$stream" --arg method "$method" --arg security "$security" '
    (.inbounds[]|select(.tag==$tag)|.streamSettings)=$stream |
    if (.inbounds[]|select(.tag==$tag)|.protocol)=="vless" then
      (.inbounds[]|select(.tag==$tag)|.settings.clients) |= map(
        if $method=="raw" and $security!="none" then .flow="xtls-rprx-vision" else del(.flow) end
      )
    else . end' "$CONFIG_FILE" >"$tmp"
  state_apply_candidate_file "$tmp" state_commit_inbound_set "$tag" "$(public_host_for_tag "$tag")" || return
  traffic_after_config_change || warn "入站已修改，但流量规则暂未同步，采集任务会自动重试。"
  info "传输已更新，请重新导出客户端分享链接。"
}

delete_inbound() {
  ensure_runtime_dependencies inbound-delete; ensure_config
  local tag=${1-} assume_yes=${2:-0} tmp user_count rule_tag
  [[ -n $tag ]] || select_inbound_toggle tag || return
  inbound_tag_reserved "$tag" || die "找不到入站：$tag"
  user_count=$(jq --arg tag "$tag" --slurpfile meta "$META_FILE" '
    ([.inbounds[]|select(.tag==$tag)][0] // $meta[0].disabledInbounds[$tag].config) |
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
  traffic_after_config_change "$tag" || warn "入站已删除，但流量记录暂未同步，采集任务会自动重试。"
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
  [[ -n $tag ]] || select_inbound tag '^(vless|socks|http)$' || return
  protocol=$(jq -r --arg tag "$tag" '.inbounds[]|select(.tag==$tag)|.protocol' "$CONFIG_FILE")
  inbound_require_supported_configuration "$tag"
  heading "${tag} 的用户"
  if [[ $protocol == socks || $protocol == http ]]; then
    count=$(jq --arg tag "$tag" '.inbounds[]|select(.tag==$tag)|(.settings.accounts // .settings.users // [])|length' "$CONFIG_FILE")
  else
    count=$(jq --arg tag "$tag" '.inbounds[]|select(.tag==$tag)|(.settings.clients // [])|length' "$CONFIG_FILE")
  fi
  if ((count == 0)); then info "还没有用户。"; return; fi
  case $protocol in
    vless)
      print_table_cell "序号" 5; print_table_cell "用户" 16; print_table_cell "凭据" 40; printf '\n'
      jq -r --arg tag "$tag" '.inbounds[]|select(.tag==$tag)|.settings.clients|to_entries[]|[.key+1,(.value.email // "-"),.value.id]|@tsv' "$CONFIG_FILE" \
        | while IFS=$'\t' read -r number label credential; do
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
  [[ -n $tag ]] || select_inbound tag '^(vless|socks|http)$' || return
  protocol=$(jq -r --arg tag "$tag" '.inbounds[]|select(.tag==$tag)|.protocol' "$CONFIG_FILE")
  inbound_require_supported_configuration "$tag"
  prompt_client_label label "$tag" "用户名称/邮箱" "user-$(random_hex 2)"
  case $protocol in
    vless)
      id=$(generate_uuid)
      method=$(jq -r --arg tag "$tag" '.inbounds[]|select(.tag==$tag)|.streamSettings.network // .streamSettings.method // "raw"' "$CONFIG_FILE")
      security=$(jq -r --arg tag "$tag" '.inbounds[]|select(.tag==$tag)|.streamSettings.security // "none"' "$CONFIG_FILE")
      [[ $method == raw && $security != none ]] && flow=xtls-rprx-vision || flow=""
      user=$(jq -n --arg id "$id" --arg email "$label" --arg flow "$flow" '{id:$id,email:$email,level:0}+(if $flow!="" then {flow:$flow} else {} end)')
      ;;
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
  [[ -n $tag ]] || select_inbound tag '^(vless|socks|http)$' || return
  protocol=$(jq -r --arg tag "$tag" '.inbounds[]|select(.tag==$tag)|.protocol' "$CONFIG_FILE")
  inbound_require_supported_configuration "$tag"
  [[ -n $label ]] || select_client label "$tag" || return
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
  [[ -n $tag ]] || select_inbound tag '^(vless|socks|http)$' || return
  [[ -n $label ]] || select_client label "$tag" || return
  protocol=$(jq -r --arg tag "$tag" '.inbounds[]|select(.tag==$tag)|.protocol' "$CONFIG_FILE")
  inbound_require_supported_configuration "$tag"
  confirm "旧凭据会立即失效，继续吗？" N || return 0
  tmp=$(temp_file)
  case $protocol in
    vless)
      generated=$(generate_uuid)
      prompt_validated_value value "新 UUID" "$generated" validate_uuid "UUID 格式无效，请重新输入。" || { rm -f "$tmp"; return 1; }
      jq --arg tag "$tag" --arg client_label "$label" --arg value "$value" '(.inbounds[]|select(.tag==$tag)|.settings.clients[]|select(.email==$client_label)|.id)=$value' "$CONFIG_FILE" >"$tmp" ;;
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
  [[ -n $tag ]] || select_inbound tag '^(vless|socks|http)$' || return
  [[ -n $old_label ]] || select_client old_label "$tag" || return
  protocol=$(jq -r --arg tag "$tag" '.inbounds[]|select(.tag==$tag)|.protocol' "$CONFIG_FILE")
  inbound_require_supported_configuration "$tag"
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
