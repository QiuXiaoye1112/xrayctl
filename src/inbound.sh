#!/usr/bin/env bash
inbound_exists() { jq -e --arg tag "$1" '.inbounds[] | select(.tag==$tag)' "$CONFIG_FILE" >/dev/null; }

inbound_configuration_is_supported() {
  local tag=$1 protocol method
  protocol=$(jq -r --arg tag "$tag" '.inbounds[]|select(.tag==$tag)|.protocol' "$CONFIG_FILE")
  protocol_is_supported "$protocol" || return 1
  if protocol_supports_stream "$protocol"; then
    method=$(jq -r --arg tag "$tag" '.inbounds[]|select(.tag==$tag)|.streamSettings.network // .streamSettings.method // "raw"' "$CONFIG_FILE")
    case $method in raw|xhttp|websocket) ;; *) return 1;; esac
  elif [[ $protocol == shadowsocks ]]; then
    jq -e --arg tag "$tag" --arg ss2022Method "$SS2022_METHOD" "$SS2022_INBOUND_JQ"'
      .inbounds[] | select(.tag==$tag) | ss2022_inbound
    ' "$CONFIG_FILE" >/dev/null
  fi
}

inbound_require_supported_configuration() {
  inbound_configuration_is_supported "$1" \
    || die "该入站使用已停止支持的协议或传输；仅允许查看或删除。"
}

inbound_obfs_enabled() {
  [[ -r $META_FILE ]] && jq -e --arg tag "$1" '.inbounds[$tag].obfs.enabled==true' "$META_FILE" >/dev/null 2>&1
}

inbound_obfs_field() {
  local tag=$1 field=$2
  [[ -r $META_FILE ]] || return 0
  jq -r --arg tag "$tag" --arg field "$field" '.inbounds[$tag].obfs[$field] // empty' "$META_FILE" 2>/dev/null || true
}

inbound_effective_port() {
  local tag=$1 port=""
  if inbound_obfs_enabled "$tag"; then
    port=$(inbound_obfs_field "$tag" port)
  fi
  if [[ -n $port ]]; then
    printf '%s\n' "$port"
  else
    jq -r --arg tag "$tag" '.inbounds[]|select(.tag==$tag)|.port // empty' "$CONFIG_FILE"
  fi
}

inbound_effective_listen() {
  local tag=$1 listen=""
  if inbound_obfs_enabled "$tag"; then
    listen=$(inbound_obfs_field "$tag" listen)
    printf '%s\n' "${listen:-0.0.0.0}"
  else
    jq -r --arg tag "$tag" '.inbounds[]|select(.tag==$tag)|.listen // "0.0.0.0"' "$CONFIG_FILE"
  fi
}

# shellcheck disable=SC2016
readonly INBOUND_SOCKETS_JQ='
  def obfs($meta): if .protocol=="shadowsocks" and $meta.inbounds[.tag].obfs.enabled==true
    then $meta.inbounds[.tag].obfs else {} end;
  def socket_network:
    if .protocol=="shadowsocks" then (.settings.network // "tcp,udp")
    elif .protocol=="socks" and (.settings.udp != false) then "tcp,udp"
    else "tcp" end;
  def effective_socket($meta):
    obfs($meta) as $obfs |
    {listen:(if $obfs.enabled==true then ($obfs.listen // "0.0.0.0") else (.listen // "0.0.0.0") end),
     port:($obfs.port // .port)};
'

inbound_sockets_for_port() {
  local port=$1 except=${2-} metadata
  [[ -r $CONFIG_FILE ]] || return 0
  metadata=$(meta_json_or_empty)
  jq -r --argjson port "$port" --arg except "$except" --argjson meta "$metadata" "$INBOUND_SOCKETS_JQ"'
    def contains_port:
      tostring | split(",") | any(.[]; split("-") | map(try tonumber catch -1) |
        (.[0] <= $port and $port <= (.[1] // .[0])));
    .inbounds[]? | select(.tag!=$except) | socket_network as $network |
    [ {listen:(.listen // "0.0.0.0"), port:.port}, effective_socket($meta) ] | unique[] |
    select(.port | contains_port) | [.listen, $network] | @tsv
  ' "$CONFIG_FILE"
}

listener_addresses_overlap() {
  local first second
  first=$(normalize_socket_ip "$1") || first='*'
  second=$(normalize_socket_ip "$2") || second='*'
  # Xray can open either wildcard as a dual-stack socket.
  case $first in 0.0.0.0|::|'*') return 0;; esac
  case $second in 0.0.0.0|::|'*') return 0;; esac
  [[ $first == "$second" ]]
}

listener_networks_overlap() {
  [[ (",$1," == *,tcp,* && ",$2," == *,tcp,*) || (",$1," == *,udp,* && ",$2," == *,udp,*) ]]
}

port_in_config() {
  local port=$1 except=${2-} listen=${3:-0.0.0.0} network=${4:-tcp,udp} endpoints bound_listen bound_network
  endpoints=$(inbound_sockets_for_port "$port" "$except") || return 0
  while IFS=$'\t' read -r bound_listen bound_network; do
    [[ -n $bound_listen ]] || continue
    listener_networks_overlap "$network" "$bound_network" && listener_addresses_overlap "$listen" "$bound_listen" && return 0
  done <<<"$endpoints"
  return 1
}

port_in_use_os() {
  local port=$1 listen=${2:-0.0.0.0} network=${3:-tcp,udp} except=${4-}
  local socket_rows socket_type endpoint details addr current_port="" current_listen="" own_binary=${XRAY_BIN##*/}
  if command_exists ss && socket_rows=$(ss -H -lntupe 2>/dev/null || ss -H -lntup 2>/dev/null); then
    socket_rows=$(awk '{print $1 "\t" $5 "\t" $0}' <<<"$socket_rows")
  elif command_exists netstat && socket_rows=$(netstat -lntup 2>/dev/null || netstat -lntu 2>/dev/null); then
    socket_rows=$(awk '$1 ~ /^(tcp|udp)/ {print substr($1,1,3) "\t" $4 "\t" $0}' <<<"$socket_rows")
  else
    return 1
  fi
  if [[ -n $except ]] && service_is_active; then
    current_port=$(inbound_effective_port "$except")
    current_listen=$(inbound_effective_listen "$except")
  fi
  while IFS=$'\t' read -r socket_type endpoint details; do
    [[ ${endpoint##*:} == "$port" ]] || continue
    listener_networks_overlap "$network" "$socket_type" || continue
    addr=${endpoint%:*}; addr=${addr#\[}; addr=${addr%\]}; addr=${addr%%%*}
    # An existing socket of the inbound being edited will be released on restart.
    if [[ $port == "$current_port" ]] &&
       { [[ $details == *"\"${own_binary}\""* || $details == *"/${own_binary}" ]] ||
         { inbound_obfs_enabled "$except" &&
           [[ $details == *"\"${OBFS_SERVER_BIN##*/}\""* || $details == *"/${OBFS_SERVER_BIN##*/}" ]]; }; }; then
      if [[ $(normalize_socket_ip "$addr" || printf '*') == "$(normalize_socket_ip "$current_listen")" ]] ||
         { [[ $addr == '*' || $addr == :: || $addr == 0.0.0.0 ]] &&
           [[ $current_listen == 0.0.0.0 || $current_listen == :: ]]; }; then
        continue
      fi
    fi
    # ss distinguishes a native IPv4 wildcard from a dual-stack wildcard.
    if [[ $addr == 0.0.0.0 && $listen == *:* && $listen != :: ]] ||
       { [[ $addr == :: && $details == *v6only:1* && $listen != 0.0.0.0 && $listen != *:* ]]; }; then
      continue
    fi
    listener_addresses_overlap "$listen" "$addr" && return 0
  done <<<"$socket_rows"
  return 1
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

suggest_available_port_excluding() {
  local __var=$1 excluded=${2-} picked="" i fallback
  for ((i=0; i<32; i++)); do
    suggest_available_port picked || break
    if [[ -z $excluded || $picked != "$excluded" ]]; then
      printf -v "$__var" '%s' "$picked"
      return 0
    fi
  done
  for ((i=0; i<128; i++)); do
    fallback=$((10000 + i))
    [[ $fallback == "$excluded" ]] && continue
    port_in_config "$fallback" && continue
    port_in_use_os "$fallback" && continue
    printf -v "$__var" '%s' "$fallback"
    return 0
  done
  return 1
}

prompt_tag() {
  local __var=$1 default=${2:-node-$(random_hex 2)} value
  while true; do
    prompt_value value "入站标签" "$default" || return 1
    validate_tag "$value" || { warn "标签格式不正确。"; continue; }
    inbound_exists "$value" && { warn "标签已存在。"; continue; }
    printf -v "$__var" '%s' "$value"; return
  done
}

prompt_port() {
  local __var=$1 default=${2:-443} except=${3-} bind_address=${4:-0.0.0.0} bind_network=${5:-tcp,udp} value
  while true; do
    prompt_value value "监听端口" "$default" || return 1
    validate_port "$value" || { warn "端口必须是 1-65535。"; continue; }
    value=$((10#$value))
    if port_in_config "$value" "$except" "$bind_address" "$bind_network" ||
       port_in_use_os "$value" "$bind_address" "$bind_network" "$except"; then
      warn "所选监听地址的端口 ${value} 已被占用，请换一个端口。"
      continue
    fi
    printf -v "$__var" '%s' "$value"; return
  done
}

inbound_report_listener() {
  local address=$1 port=$2
  if [[ $address == *:* ]]; then address="[${address}]"; fi
  info "实际监听：${address}:${port}"
}

add_inbound() {
  ensure_runtime_dependencies inbound-add; require_xray_installed; ensure_config
  local inbound="" host="" public_key="" obfs_meta="" tag tmp
  build_inbound inbound host public_key obfs_meta || return 1
  : "$public_key"
  if [[ -n $obfs_meta ]]; then
    ensure_simple_obfs_installed || return 1
  fi
  tag=$(jq -r '.tag' <<<"$inbound")
  tmp=$(temp_file)
  jq --argjson inbound "$inbound" '.inbounds += [$inbound]' "$CONFIG_FILE" >"$tmp"
  XRAYCTL_QUIET_CONFIG_APPLIED=1 state_apply_candidate_file "$tmp" state_commit_inbound_set "$tag" "$host" "$obfs_meta" || return
  if [[ -n $obfs_meta ]]; then
    obfs_service_setup "$tag" || warn "入站已创建，但 obfs-server 服务创建或启动失败，请检查 simple-obfs 状态。"
  fi
  traffic_after_config_change || warn "入站已创建，但流量规则暂未同步，采集任务会自动重试。"
  info "入站 ${tag} 已创建并部署生效。"
  print_links "$tag" "" || true
}

list_inbounds() {
  ensure_config
  local count tag protocol port method security listen users sec_disp meta_json
  count=$(jq '.inbounds|length' "$CONFIG_FILE")
  if ((count == 0)); then info "还没有入站。"; return; fi
  meta_json=$(meta_json_or_empty)
  printf '  %s' "$C_DIM"
  print_table_cell_clipped "标签" 18; printf '  '
  print_table_cell_clipped "协议" 6; printf '  '
  print_table_cell "端口" 6; printf '  '
  print_table_cell_clipped "传输" 7; printf '  '
  print_table_cell_clipped "安全" 8; printf '  '
  print_table_cell "用户" 4; printf '  监听%s\n' "$C_RESET"
  jq -r --arg ss2022Method "$SS2022_METHOD" --argjson meta "$meta_json" '.inbounds | to_entries[] |
    .value.tag as $tag |
    [$tag,(if .value.protocol=="shadowsocks" then
       (if .value.settings.method==$ss2022Method then "SS2022" else "SS" end)
     else .value.protocol end),
     ((if .value.protocol=="shadowsocks" and $meta.inbounds[$tag].obfs.enabled==true then ($meta.inbounds[$tag].obfs.port // .value.port) else .value.port end)|tostring),
     (if .value.protocol=="vless" then
        (if (.value.streamSettings.network // .value.streamSettings.method // "raw")=="websocket" then "ws" else (.value.streamSettings.network // .value.streamSettings.method // "raw") end)
      elif .value.protocol=="shadowsocks" then
        (if $meta.inbounds[$tag].obfs.enabled==true then "http" else (.value.settings.network // "tcp") end)
      else "-" end),
     (if .value.protocol=="vless" then (.value.streamSettings.security // "none")
      elif .value.protocol=="socks" then (.value.settings.auth // "noauth")
      elif .value.protocol=="shadowsocks" then "AEAD"
      elif (((.value.settings.accounts // .value.settings.users // [])|length)>0) then "password"
      else "noauth" end),
     (if (.value.protocol=="vless" or .value.protocol=="shadowsocks") then (.value.settings.clients // [] | length)
      else ((.value.settings.accounts // .settings.users // []) | length) end | tostring),
     (if .value.protocol=="shadowsocks" and $meta.inbounds[$tag].obfs.enabled==true then ($meta.inbounds[$tag].obfs.listen // "0.0.0.0") else (.value.listen // "0.0.0.0") end)] | @tsv' "$CONFIG_FILE" \
    | while IFS=$'\t' read -r tag protocol port method security users listen; do
        case $security in
          reality) sec_disp="${C_CYAN}${security}${C_RESET}" ;;
          tls|password) sec_disp="${C_GREEN}${security}${C_RESET}" ;;
          none|noauth) sec_disp="${C_YELLOW}${security}${C_RESET}" ;;
          *) sec_disp="$security" ;;
        esac
        printf '  '; print_table_cell_clipped "$tag" 18; printf '%s%s  ' "$C_DIM" "$C_RESET"
        print_table_cell_clipped "$protocol" 6; printf '%s%s  ' "$C_DIM" "$C_RESET"
        print_table_cell "$port" 6; printf '%s%s  ' "$C_DIM" "$C_RESET"
        print_table_cell_clipped "$method" 7; printf '%s%s  ' "$C_DIM" "$C_RESET"
        print_table_cell "$sec_disp" 8; printf '%s%s  ' "$C_DIM" "$C_RESET"
        print_table_cell "$users" 4; printf '%s%s  %s\n' "$C_DIM" "$C_RESET" "$listen"
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
  ((count > 0)) || { warn "没有可选入站。"; pause; return 1; }
  while IFS= read -r selected_tag; do [[ -z $selected_tag ]] || tags+=("$selected_tag"); done <<<"$entries"
  if ((count == 1)); then
    printf -v "$__var" '%s' "${tags[0]}"
    return 0
  fi
  choose answer "选择入站" "${tags[@]}" || return 1
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
  local old_tag=${1-} new_tag=${2-} tmp was_obfs=0
  [[ -n $old_tag ]] || select_inbound old_tag || return
  inbound_exists "$old_tag" || die "找不到入站：$old_tag"
  inbound_require_supported_configuration "$old_tag"
  [[ -n $new_tag ]] || prompt_renamed_inbound_tag new_tag "$old_tag" || return 1
  validate_tag "$new_tag" || die "入站名称格式无效。"
  if [[ $new_tag == "$old_tag" ]]; then info "入站名称未更改。"; return 0; fi
  if inbound_exists "$new_tag" || outbound_exists "$new_tag"; then
    die "名称已被入站或出站使用：$new_tag"
  fi
  inbound_obfs_enabled "$old_tag" && was_obfs=1
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
  XRAYCTL_QUIET_CONFIG_APPLIED=1 state_apply_candidate_file "$tmp" state_commit_inbound_rename "$old_tag" "$new_tag" || return
  if ((was_obfs == 1)); then
    obfs_service_remove "$old_tag"
    obfs_service_setup "$new_tag" || warn "入站已重命名，但新 obfs-server 服务更新失败，请检查 simple-obfs 状态。"
  fi
  traffic_after_config_change "$old_tag" "$new_tag" || warn "入站已重命名，但流量记录暂未同步，采集任务会自动重试。"
  info "入站已重命名：${old_tag} → ${new_tag}。"
}

prompt_inbound_ip() {
  local __out=$1 local_ip canonical family_choice=1 ip_choice
  local label=${2:-选择要绑定的本机} network_v4=0 network_v6=0
  local -a addresses_v4=() addresses_v6=()
  local -A seen=()
  while IFS=$'\t' read -r _ local_ip _; do
    [[ -n $local_ip ]] || continue
    canonical=$(normalize_socket_ip "$local_ip") || continue
    case $canonical in 0.0.0.0|::|fe[89ab][0-9a-f]:*) continue;; esac
    [[ -z ${seen[$canonical]+x} ]] || continue
    seen[$canonical]=1
    if [[ $canonical == *:* ]]; then
      addresses_v6+=("$local_ip")
      if [[ $canonical != 0000:0000:0000:0000:0000:0000:0000:0001 ]]; then network_v6=1; fi
    else
      addresses_v4+=("$canonical")
      if [[ $canonical != 127.* ]]; then network_v4=1; fi
    fi
  done < <(detect_local_ips inbound)

  # A loopback address alone does not make the other family available to clients.
  if ((network_v4 || network_v6)); then
    if ((network_v4 == 0)); then addresses_v4=(); fi
    if ((network_v6 == 0)); then addresses_v6=(); fi
  fi

  if ((${#addresses_v4[@]} == 0 && ${#addresses_v6[@]} == 0)); then
    warn "未检测到可绑定的本机 IPv4 或 IPv6 地址。"
    return 1
  fi
  if ((${#addresses_v4[@]} > 0 && ${#addresses_v6[@]} > 0)); then
    choose family_choice "选择客户端连接地址类型" "IPv4" "IPv6" || return 1
  elif ((${#addresses_v4[@]} == 0)); then
    family_choice=2
  fi

  if ((family_choice == 1)); then
    choose ip_choice "${label} IPv4" "${addresses_v4[@]}" || return 1
    printf -v "$__out" '%s' "${addresses_v4[$((ip_choice-1))]}"
  else
    choose ip_choice "${label} IPv6" "${addresses_v6[@]}" || return 1
    printf -v "$__out" '%s' "${addresses_v6[$((ip_choice-1))]}"
  fi
}

modify_inbound_client_address() {
  local tag=$1 edit_port=${2:-0} current address tls_fallback="" old_listen port old_port network candidate obfs="" old_obfs=""
  local local_port="" reset_socks_udp_ip=false
  if ((edit_port)); then
    ensure_runtime_dependencies inbound-modify || return 1
    ensure_config || return 1
    [[ -n $tag ]] || select_inbound tag || return 1
  else
    ensure_system_context || return 1
  fi
  inbound_exists "$tag" || die "找不到入站：$tag"
  inbound_require_supported_configuration "$tag"
  current=$(jq -r --arg tag "$tag" '.inbounds[$tag].host // empty' "$META_FILE" 2>/dev/null || true)
  old_listen=$(inbound_effective_listen "$tag") || return 1
  old_port=$(inbound_effective_port "$tag") || return 1
  info "监听地址：${old_listen}"
  prompt_inbound_ip address || return 1

  # Older TLS inbounds reused the share host as SNI. Keep the name in links
  # when migrating one of those inbounds to an IP address.
  if jq -e --arg tag "$tag" '.inbounds[] | select(.tag==$tag) |
    .protocol=="vless" and .streamSettings.security=="tls" and
    (.streamSettings.tlsSettings.serverName // "")==""' "$CONFIG_FILE" >/dev/null; then
    tls_fallback=${current:-${XRAYCTL_PUBLIC_HOST:-}}
  fi

  port=$old_port
  network=$(jq -r --arg tag "$tag" "$INBOUND_SOCKETS_JQ"'
    .inbounds[] | select(.tag==$tag) | socket_network' "$CONFIG_FILE") || return 1
  # A wildcard SOCKS UDP reply is unusable for clients that use the advertised
  # address. With ip omitted, Xray uses the local address of the TCP connection.
  if jq -e --arg tag "$tag" '.inbounds[] | select(.tag==$tag) |
    .protocol=="socks" and .settings.udp==true and (.settings.ip=="0.0.0.0" or .settings.ip=="::")' "$CONFIG_FILE" >/dev/null; then
    reset_socks_udp_ip=true
  fi
  if ((edit_port)); then
    prompt_port port "$old_port" "$tag" "$address" "$network" || return 1
  fi
  if inbound_obfs_enabled "$tag"; then
    old_obfs=$(jq -c --arg tag "$tag" '.inbounds[$tag].obfs' "$META_FILE") || return 1
    obfs=$(jq -c --arg address "$address" '.listen=$address | del(.dualStack)' <<<"$old_obfs") || return 1
    if ((edit_port)); then
      local_port=$(jq -r '.localPort // empty' <<<"$obfs") || return 1
      if [[ $local_port == "$port" ]] || ! validate_port "$local_port"; then
        suggest_available_port_excluding local_port "$port" || die "无法分配内部转发端口。"
      fi
      obfs=$(jq -c --argjson port "$port" --argjson localPort "$local_port" \
        '.port=$port | .localPort=$localPort' <<<"$obfs") || return 1
    fi
  fi

  if [[ $address == "$old_listen" && $port == "$old_port" && $obfs == "$old_obfs" && $reset_socks_udp_ip == false ]]; then
    if [[ $address == "$current" ]]; then
      info "客户端连接地址未更改。"
      return 0
    fi
    state_commit_metadata _state_build_inbound_client_address "$tag" "$address" "" "$tls_fallback" || return 1
  else
    if ! validate_port "$port"; then
      warn "此入站的端口无法自动切换监听，请检查现有配置。"
      return 1
    fi
    if port_in_config "$((10#$port))" "$tag" "$address" "$network" ||
       port_in_use_os "$((10#$port))" "$address" "$network" "$tag"; then
      warn "新监听地址与端口 ${port} 上的其他监听冲突，入站未更改。"
      return 1
    fi
    candidate=$(temp_file) || return 1
    if [[ -n $local_port ]]; then
      jq --arg tag "$tag" --argjson localPort "$local_port" '
        (.inbounds[] | select(.tag==$tag)) |= (.listen="127.0.0.1" | .port=$localPort | .settings.network="tcp,udp")
      ' "$CONFIG_FILE" >"$candidate" || { rm -f "$candidate"; return 1; }
    elif [[ -n $obfs ]]; then
      cp "$CONFIG_FILE" "$candidate" || { rm -f "$candidate"; return 1; }
    else
      jq --arg tag "$tag" --arg address "$address" --argjson port "$((10#$port))" --argjson editPort "$edit_port" \
        --argjson resetSocksUdpIP "$reset_socks_udp_ip" '
        (.inbounds[] | select(.tag==$tag)) |=
          (.listen=$address | if $editPort==1 then .port=$port else . end |
           if $resetSocksUdpIP then del(.settings.ip) else . end)
      ' "$CONFIG_FILE" >"$candidate" || { rm -f "$candidate"; return 1; }
    fi
    XRAYCTL_QUIET_CONFIG_APPLIED=1 state_apply_candidate_file "$candidate" state_commit \
      _state_build_inbound_client_address "$tag" "$address" "$obfs" "$tls_fallback" || return 1
  fi
  inbound_report_listener "$address" "$port"
  info "客户端连接地址已更新为 ${address}。请重新获取分享链接或订阅内容。"
}

modify_inbound_basic() {
  modify_inbound_client_address "${1-}" 1
}

modify_inbound_transport() {
  ensure_runtime_dependencies inbound-transport; require_xray_installed; ensure_config
  local tag=${1-} protocol stream public_key="" tmp method security
  local obfs_choice obfs_host ext_listen ext_port local_port obfs_meta="" was_obfs=0 had_active=0 dual_stack=false
  [[ -n $tag ]] || select_inbound tag '^(vless|shadowsocks)$' || return
  inbound_exists "$tag" || die "找不到入站：$tag"
  inbound_require_supported_configuration "$tag"
  protocol=$(jq -r --arg tag "$tag" '.inbounds[]|select(.tag==$tag)|.protocol' "$CONFIG_FILE")
  case $protocol in
    vless)
      warn "修改传输后，所有客户端都要同步更新配置。"
      confirm "为 ${tag} 重新选择传输和安全方式？" N || return 0
      build_stream_settings "$protocol" stream public_key || return 1
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
      XRAYCTL_QUIET_CONFIG_APPLIED=1 state_apply_candidate_file "$tmp" state_commit_inbound_set "$tag" "$(public_host_for_tag "$tag")" || return
      traffic_after_config_change || warn "入站已修改，但流量规则暂未同步，采集任务会自动重试。"
      info "传输已更新，请重新导出客户端分享链接。"
      ;;
    shadowsocks)
      inbound_obfs_enabled "$tag" && was_obfs=1
      ext_listen=$(inbound_effective_listen "$tag")
      ext_port=$(inbound_effective_port "$tag")
      choose obfs_choice "HTTP 混淆 (simple-obfs)" "关闭" "开启" || return 1
      if [[ $obfs_choice == 2 ]]; then
        prompt_validated_value obfs_host "混淆域名 (obfs-host)" "" validate_domain "混淆域名格式无效，请重新输入。" || return 1
        ensure_simple_obfs_installed || return 1
        local_port=$(inbound_obfs_field "$tag" localPort)
        if [[ -z $local_port || $local_port == "$ext_port" ]] || ! validate_port "$local_port"; then
          suggest_available_port_excluding local_port "$ext_port" || die "无法分配内部转发端口。"
        fi
        tmp=$(temp_file)
        jq --arg tag "$tag" --argjson localPort "$local_port" '
          (.inbounds[]|select(.tag==$tag)) |= (.listen="127.0.0.1" | .port=$localPort | .settings.network="tcp,udp")
        ' "$CONFIG_FILE" >"$tmp"
        if [[ $ext_listen == :: ]] && { ((was_obfs == 0)) ||
          [[ $(inbound_obfs_field "$tag" dualStack) == true ]]; }; then dual_stack=true; fi
        obfs_meta=$(_inbound_build_obfs_meta "$tag" "$obfs_host" "$ext_listen" "$ext_port" "$local_port" "$dual_stack")
        XRAYCTL_QUIET_CONFIG_APPLIED=1 state_apply_candidate_file "$tmp" state_commit_inbound_set "$tag" "$(public_host_for_tag "$tag")" "$obfs_meta" || return
        obfs_service_setup "$tag" || warn "混淆参数已更新，但 obfs-server 服务启动失败，请检查 simple-obfs 状态。"
        traffic_after_config_change || warn "入站已修改，但流量规则暂未同步，采集任务会自动重试。"
        info "HTTP 混淆已启用/更新，请重新导出客户端分享链接。"
      else
        if ((was_obfs == 0)); then
          info "该入站当前未开启 HTTP 混淆，配置未变更。"
          return 0
        fi
        confirm "关闭 ${tag} 的 HTTP 混淆并恢复直连 TCP/UDP？" N || return 0
        obfs_service_is_active "$tag" && had_active=1
        tmp=$(temp_file)
        jq --arg tag "$tag" --arg listen "$ext_listen" --argjson port "$ext_port" '
          (.inbounds[]|select(.tag==$tag)) |= (.listen=$listen | .port=$port | .settings.network="tcp,udp")
        ' "$CONFIG_FILE" >"$tmp"
        if ! validate_candidate "$tmp"; then
          rm -f "$tmp"
          return 1
        fi
        obfs_service_stop "$tag" || true
        if ! XRAYCTL_QUIET_CONFIG_APPLIED=1 state_apply_candidate_file "$tmp" state_commit_inbound_set "$tag" "$(public_host_for_tag "$tag")" none; then
          if ((had_active == 1)); then
            obfs_service_setup "$tag" || true
          fi
          return 1
        fi
        obfs_service_remove "$tag"
        traffic_after_config_change || warn "入站已修改，但流量规则暂未同步，采集任务会自动重试。"
        info "HTTP 混淆已关闭，请重新导出客户端分享链接。"
      fi
      ;;
    *)
      die "${protocol} 已停止支持或没有可修改的流式传输。"
      ;;
  esac
}

delete_inbound() {
  ensure_runtime_dependencies inbound-delete; ensure_config
  local tag=${1-} assume_yes=${2:-0} tmp user_count rule_tag had_obfs=0
  [[ -n $tag ]] || select_inbound tag || return
  inbound_exists "$tag" || die "找不到入站：$tag"
  inbound_obfs_enabled "$tag" && had_obfs=1
  user_count=$(jq --arg tag "$tag" '
    [.inbounds[]|select(.tag==$tag)|((.settings.clients // .settings.accounts // .settings.users // [])|length)][0]' "$CONFIG_FILE")
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
  XRAYCTL_QUIET_CONFIG_APPLIED=1 state_apply_candidate_file "$tmp" state_commit_inbound_delete "$tag" || return
  if ((had_obfs == 1)) || obfs_service_exists "$tag" 2>/dev/null; then
    obfs_service_remove "$tag"
  fi
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
  local tag=${1-} protocol count number label credential credential_field credential_name
  [[ -n $tag ]] || select_inbound tag '^(vless|shadowsocks|socks|http)$' || return
  protocol=$(jq -r --arg tag "$tag" '.inbounds[]|select(.tag==$tag)|.protocol' "$CONFIG_FILE")
  inbound_require_supported_configuration "$tag"
  heading "${tag} 的用户"
  if [[ $protocol == socks || $protocol == http ]]; then
    count=$(jq --arg tag "$tag" '.inbounds[]|select(.tag==$tag)|(.settings.accounts // .settings.users // [])|length' "$CONFIG_FILE")
  else
    count=$(jq --arg tag "$tag" '.inbounds[]|select(.tag==$tag)|(.settings.clients // [])|length' "$CONFIG_FILE")
  fi
  if ((count == 0)); then info "还没有用户。"; return; fi
  printf '  %s' "$C_DIM"
  print_table_cell "序号" 5; printf '  '
  case $protocol in
    vless) credential_name=UUID ;;
    shadowsocks) credential_name=密钥 ;;
    *) credential_name=密码 ;;
  esac
  print_table_cell "用户" 16; printf '  凭据 (%s)%s\n' "$credential_name" "$C_RESET"
  case $protocol in
    vless|shadowsocks)
      credential_field=$(protocol_client_credential_field "$protocol")
      jq -r --arg tag "$tag" --arg field "$credential_field" '.inbounds[]|select(.tag==$tag)|.settings.clients|to_entries[]|[.key+1,(.value.xrayctlLabel // .value.email // "-"),.value[$field]]|@tsv' "$CONFIG_FILE" \
        | while IFS=$'\t' read -r number label credential; do
        printf '  '; print_table_cell "$number" 5; printf '%s%s  ' "$C_DIM" "$C_RESET"
        print_table_cell_clipped "$label" 16; printf '%s%s  %s\n' "$C_DIM" "$C_RESET" "$credential"
      done
      ;;
    socks|http)
      jq -r --arg tag "$tag" '.inbounds[]|select(.tag==$tag)|(.settings.accounts // .settings.users // [])|to_entries[]|[.key+1,.value.user,(.value.pass // "-")]|@tsv' "$CONFIG_FILE" \
        | while IFS=$'\t' read -r number label credential; do
        printf '  '; print_table_cell "$number" 5; printf '%s%s  ' "$C_DIM" "$C_RESET"
        print_table_cell_clipped "$label" 16; printf '%s%s  %s\n' "$C_DIM" "$C_RESET" "$credential"
      done
      ;;
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
      jq -r --arg tag "$tag" '.inbounds[]|select(.tag==$tag)|(.settings.clients // [])[] | (.xrayctlLabel // .email)' "$CONFIG_FILE"
    )
  fi
  ((${#labels[@]} > 0)) || { warn "该入站没有可选用户。"; pause; return 1; }
  choose answer "选择用户" "${labels[@]}" || return 1
  printf -v "$__var" '%s' "${labels[$((answer-1))]}"
}

client_label_exists() {
  local tag=$1 label=$2 protocol
  protocol=$(jq -r --arg tag "$tag" '.inbounds[]|select(.tag==$tag)|.protocol' "$CONFIG_FILE")
  if [[ $protocol == socks || $protocol == http ]]; then
    jq -e --arg tag "$tag" --arg client_label "$label" '.inbounds[]|select(.tag==$tag)|(.settings.accounts // .settings.users // [])[]?|select(.user==$client_label)' "$CONFIG_FILE" >/dev/null
  else
    jq -e --arg tag "$tag" --arg client_label "$label" '.inbounds[]|select(.tag==$tag)|.settings.clients[]?|select((.xrayctlLabel // .email)==$client_label)' "$CONFIG_FILE" >/dev/null
  fi
}

client_account_identity_exists_globally() {
  local label=$1 except_tag=${2-} except_label=${3-}
  [[ -r $CONFIG_FILE ]] || return 1
  jq -e --arg user_label "$label" --arg exceptTag "$except_tag" --arg exceptLabel "$except_label" '
    [.inbounds[]? as $inbound | select($inbound.protocol=="socks" or $inbound.protocol=="http") |
      ($inbound.settings.accounts // $inbound.settings.users // [])[]? |
      select(.user==$user_label and ($inbound.tag!=$exceptTag or .user!=$exceptLabel))] | length>0
  ' "$CONFIG_FILE" >/dev/null
}


prompt_client_label() {
  local __var=$1 tag=$2 prompt=$3 default=${4-} current=${5-} protocol=${6-} label_candidate
  [[ -n $protocol ]] || protocol=$(jq -r --arg tag "$tag" '.inbounds[]?|select(.tag==$tag)|.protocol' "$CONFIG_FILE")
  while true; do
    prompt_validated_value label_candidate "$prompt" "$default" validate_email_label "用户名称无效，请重新输入。" || return 1
    if [[ $label_candidate != "$current" ]]; then
      if client_label_exists "$tag" "$label_candidate"; then
        if [[ $protocol == socks || $protocol == http ]]; then warn "此用户名已存在"; else warn "用户名称已存在，请重新输入。"; fi
        continue
      fi
      if [[ $protocol == socks || $protocol == http ]] && client_account_identity_exists_globally "$label_candidate" "$tag" "$current"; then
        warn "此用户名已存在"
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
  [[ -n $tag ]] || select_inbound tag '^(vless|shadowsocks|socks|http)$' || return
  protocol=$(jq -r --arg tag "$tag" '.inbounds[]|select(.tag==$tag)|.protocol' "$CONFIG_FILE")
  inbound_require_supported_configuration "$tag"
  prompt_client_label label "$tag" "用户名称/邮箱" "user-$(random_hex 2)" || return 1
  case $protocol in
    vless)
      id=$(generate_uuid)
      method=$(jq -r --arg tag "$tag" '.inbounds[]|select(.tag==$tag)|.streamSettings.network // .streamSettings.method // "raw"' "$CONFIG_FILE")
      security=$(jq -r --arg tag "$tag" '.inbounds[]|select(.tag==$tag)|.streamSettings.security // "none"' "$CONFIG_FILE")
      [[ $method == raw && $security != none ]] && flow=xtls-rprx-vision || flow=""
      user=$(jq -n --arg id "$id" --arg email "$label" --arg flow "$flow" '{id:$id,email:$email,level:0}+(if $flow!="" then {flow:$flow} else {} end)')
      ;;
    shadowsocks)
      password=$(protocol_generate_ss2022_key) || { error "无法生成 SS2022 用户密钥。"; return 1; }
      user=$(jq -n --arg email "$label" --arg password "$password" '{email:$email,password:$password,level:0}')
      ;;
    socks|http) prompt_secret password "密码" "$(random_password)" || return 1; user=$(jq -n --arg user "$label" --arg pass "$password" '{user:$user,pass:$pass}') ;;
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
  XRAYCTL_QUIET_CONFIG_APPLIED=1 state_apply_candidate_file "$tmp" apply_candidate || return
  info "用户 ${label} 已添加。"
  print_links "$tag" "$label" || true
}

delete_client() {
  ensure_runtime_dependencies client-delete; ensure_config
  local tag=${1-} label=${2-} assume_yes=${3:-0} protocol tmp count managed_id=""
  [[ -n $tag ]] || select_inbound tag '^(vless|shadowsocks|socks|http)$' || return
  protocol=$(jq -r --arg tag "$tag" '.inbounds[]|select(.tag==$tag)|.protocol' "$CONFIG_FILE")
  inbound_require_supported_configuration "$tag"
  [[ -n $label ]] || select_client label "$tag" || return
  if [[ $protocol == shadowsocks ]] && jq -e --arg tag "$tag" --arg label "$label" '
    .inbounds[] | select(.tag==$tag) | .settings.clients |
    all(.[]; (.xrayctlLabel // .email)==$label)
  ' "$CONFIG_FILE" >/dev/null; then
    error "SS2022 入站至少需要一个用户。要停用全部访问，请删除该入站。"
    return 1
  fi
  [[ $assume_yes == 1 ]] || confirm "从 ${tag} 删除用户 ${label}？" N || return 0
  tmp=$(temp_file)
  if [[ $protocol == socks || $protocol == http ]]; then
    managed_id=$label
    count=$(jq --arg tag "$tag" --arg client_label "$label" '[.inbounds[]|select(.tag==$tag)|(.settings.accounts // .settings.users // [])[]|select(.user==$client_label)]|length' "$CONFIG_FILE")
    ((count > 0)) || die "找不到用户：$label"
    jq --arg tag "$tag" --arg client_label "$label" --arg id "$managed_id" '
      (.inbounds[]|select(.tag==$tag)|.settings) |= (
        ((.accounts // .users // [])|map(select(.user!=$client_label))) as $all |
        .accounts=$all | .users=$all
      ) |
      if (.routing.rules|type)=="array" then .routing.rules |= map(select(
        (.ruleTag // "") != ("xrayctl-user-limit:"+$id) and
        ((((.ruleTag // "") | startswith("xrayctl-user-outbound:")) and .inboundTag==[$tag] and .user==[$id])|not) and
        ((((.ruleTag // "") | startswith("xrayctl-user-domain:")) and .inboundTag==[$tag] and .user==[$id])|not)
      )) else . end |
      del(.accounts,.users,.auth)' "$CONFIG_FILE" >"$tmp"
  else
    managed_id=$(jq -r --arg tag "$tag" --arg client_label "$label" '.inbounds[]|select(.tag==$tag)|.settings.clients[]?|select((.xrayctlLabel // .email)==$client_label)|.email // empty' "$CONFIG_FILE")
    count=$(jq --arg tag "$tag" --arg client_label "$label" '[.inbounds[]|select(.tag==$tag)|.settings.clients[]|select((.xrayctlLabel // .email)==$client_label)]|length' "$CONFIG_FILE")
    ((count > 0)) || die "找不到用户：$label"
    jq --arg tag "$tag" --arg client_label "$label" --arg id "$managed_id" '
      (.inbounds[]|select(.tag==$tag)|.settings.clients) |= map(select((.xrayctlLabel // .email)!=$client_label)) |
      if (.routing.rules|type)=="array" then .routing.rules |= map(select(
        ($id=="" or (.ruleTag // "") != ("xrayctl-user-limit:"+$id)) and
        ((((.ruleTag // "") | startswith("xrayctl-user-outbound:")) and .inboundTag==[$tag] and .user==[$id])|not) and
        ((((.ruleTag // "") | startswith("xrayctl-user-domain:")) and .inboundTag==[$tag] and .user==[$id])|not)
      )) else . end
    ' "$CONFIG_FILE" >"$tmp"
  fi
  state_apply_candidate_file "$tmp" state_commit_user_template_identity "$tag" "$managed_id" "" || return
  if [[ -n $managed_id ]]; then
    traffic_user_forget_client "$tag" "$managed_id" || warn "用户已删除，但流量记录暂未清理。"
  fi
}

rotate_client_credential() {
  local tag=${1-} label=${2-} assume_yes=${3:-0} protocol value generated tmp
  if [[ $label == --yes ]]; then label=""; assume_yes=1; fi
  if [[ ! -t 0 ]]; then
    if [[ -z $tag || -z $label ]]; then
      error "非交互模式必须指定入站和用户：xrayctl client rotate <入站> <用户> --yes"
      return 2
    fi
    if [[ $assume_yes != 1 ]]; then
      error "非交互凭据轮换必须显式添加 --yes；未修改任何凭据。"
      return 2
    fi
  fi
  ensure_runtime_dependencies client-rotate; ensure_config
  [[ -n $tag ]] || select_inbound tag '^(vless|shadowsocks|socks|http)$' || return
  inbound_exists "$tag" || die "找不到入站：$tag"
  [[ -n $label ]] || select_client label "$tag" || return
  client_label_exists "$tag" "$label" || die "找不到入站 ${tag} 的用户 ${label}。"
  protocol=$(jq -r --arg tag "$tag" '.inbounds[]|select(.tag==$tag)|.protocol' "$CONFIG_FILE")
  inbound_require_supported_configuration "$tag"
  [[ $assume_yes == 1 ]] || confirm "旧凭据会立即失效，继续吗？" N || return 0
  tmp=$(temp_file)
  case $protocol in
    vless)
      generated=$(generate_uuid) || { rm -f "$tmp"; error "无法生成新 UUID，未修改凭据。"; return 1; }
      validate_uuid "$generated" || { rm -f "$tmp"; error "生成的 UUID 无效，未修改凭据。"; return 1; }
      if [[ $assume_yes == 1 ]]; then
        value=$generated
      else
        prompt_validated_value value "新 UUID" "$generated" validate_uuid "UUID 格式无效，请重新输入。" || { rm -f "$tmp"; return 1; }
      fi
      jq --arg tag "$tag" --arg client_label "$label" --arg value "$value" '(.inbounds[]|select(.tag==$tag)|.settings.clients[]|select((.xrayctlLabel // .email)==$client_label)|.id)=$value' "$CONFIG_FILE" >"$tmp" ;;
    shadowsocks)
      value=$(protocol_generate_ss2022_key) || { rm -f "$tmp"; error "无法生成 SS2022 用户密钥。"; return 1; }
      jq --arg tag "$tag" --arg client_label "$label" --arg value "$value" '
        (.inbounds[]|select(.tag==$tag)|.settings.clients[]|select((.xrayctlLabel // .email)==$client_label)|.password)=$value
      ' "$CONFIG_FILE" >"$tmp" ;;
    socks|http)
      generated=$(random_password) || { rm -f "$tmp"; error "无法生成新密码，未修改凭据。"; return 1; }
      [[ -n $generated ]] || { rm -f "$tmp"; error "无法生成新密码，未修改凭据。"; return 1; }
      if [[ $assume_yes == 1 ]]; then
        value=$generated
      else
        prompt_secret value "新密码" "$generated" || { rm -f "$tmp"; return 1; }
      fi
      jq --arg tag "$tag" --arg client_label "$label" --arg value "$value" '
        (.inbounds[]|select(.tag==$tag)|.settings) |= (
          ((.accounts // .users // [])|map(if .user==$client_label then .pass=$value else . end)) as $all |
          .accounts=$all | .users=$all
        ) |
        del(.accounts,.users,.auth)' "$CONFIG_FILE" >"$tmp" ;;
    *) die "不支持此协议。";;
  esac
  XRAYCTL_QUIET_CONFIG_APPLIED=1 state_apply_candidate_file "$tmp" apply_candidate || return
  info "新凭据：$value"
}

rename_client() {
  ensure_runtime_dependencies client-rename; require_xray_installed; ensure_config
  local tag=${1-} old_label=${2-} new_label=${3-} protocol count tmp old_identity new_identity
  [[ -n $tag ]] || select_inbound tag '^(vless|shadowsocks|socks|http)$' || return
  [[ -n $old_label ]] || select_client old_label "$tag" || return
  protocol=$(jq -r --arg tag "$tag" '.inbounds[]|select(.tag==$tag)|.protocol' "$CONFIG_FILE")
  inbound_require_supported_configuration "$tag"
  if [[ -z $new_label ]]; then
    prompt_client_label new_label "$tag" "新的用户名称/邮箱" "" "$old_label" "$protocol" || return 1
  else
    validate_email_label "$new_label" || die "新用户名称无效。"
    if [[ $new_label != "$old_label" ]]; then
      if client_label_exists "$tag" "$new_label"; then die "用户名称已存在。"; fi
      if [[ $protocol == socks || $protocol == http ]] && client_account_identity_exists_globally "$new_label" "$tag" "$old_label"; then die "SOCKS5/HTTP 用户名必须在所有入站中唯一。"; fi
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
      if (.routing.rules|type)=="array" then .routing.rules |= map(
        if (.ruleTag // "")==("xrayctl-user-limit:"+$old) then .ruleTag="xrayctl-user-limit:"+$new | .user=[$new]
        elif .inboundTag==[$tag] and .user==[$old] and (((.ruleTag // "")|startswith("xrayctl-user-outbound:")) or ((.ruleTag // "")|startswith("xrayctl-user-domain:"))) then .user=[$new]
        else . end
      ) else . end |
      del(.accounts,.users,.auth)' "$CONFIG_FILE" >"$tmp"
  else
    count=$(jq --arg tag "$tag" --arg client_label "$old_label" '[.inbounds[]|select(.tag==$tag)|.settings.clients[]|select((.xrayctlLabel // .email)==$client_label)]|length' "$CONFIG_FILE")
    ((count > 0)) || { rm -f "$tmp"; die "找不到用户：$old_label"; }
    old_identity=$(jq -r --arg tag "$tag" --arg old "$old_label" '.inbounds[]|select(.tag==$tag)|.settings.clients[]?|select((.xrayctlLabel // .email)==$old)|.email' "$CONFIG_FILE")
    new_identity=$(jq -r --arg tag "$tag" --arg old "$old_label" --arg new "$new_label" '.inbounds[]|select(.tag==$tag)|.settings.clients[]?|select((.xrayctlLabel // .email)==$old)|if .xrayctlLabel!=null then .email else $new end' "$CONFIG_FILE")
    jq --arg tag "$tag" --arg old "$old_label" --arg new "$new_label" --arg oldIdentity "$old_identity" --arg newIdentity "$new_identity" '
      (.inbounds[]|select(.tag==$tag)|.settings.clients) |= map(if (.xrayctlLabel // .email)==$old then if .xrayctlLabel != null then .xrayctlLabel=$new else .email=$new end else . end) |
      if (.routing.rules|type)=="array" then .routing.rules |= map(
        if .inboundTag==[$tag] and .user==[$oldIdentity] and (((.ruleTag // "")|startswith("xrayctl-user-outbound:")) or ((.ruleTag // "")|startswith("xrayctl-user-domain:"))) then .user=[$newIdentity] else . end
      ) else . end
    ' "$CONFIG_FILE" >"$tmp"
  fi
  local lock_owned=0
  if [[ $protocol == socks || $protocol == http ]]; then
    if [[ -f $TRAFFIC_FILE && ${TRAFFIC_LOCK_HELD:-0} != 1 ]]; then
      traffic_lock_acquire || { rm -f "$tmp"; return 1; }
      lock_owned=1
    fi
    if [[ -f $TRAFFIC_FILE ]] && jq -e --arg old "$old_label" --arg new "$new_label" '$old!=$new and any(.inbounds[]?; .users[$new]!=null)' "$TRAFFIC_FILE" >/dev/null; then
      ((lock_owned == 0)) || traffic_lock_release
      rm -f "$tmp"
      warn "目标用户名已有历史流量记录，无法安全合并；请先清理该旧账号记录。"
      return 1
    fi
  fi
  if ! XRAYCTL_QUIET_CONFIG_APPLIED=1 state_apply_candidate_file "$tmp" state_commit_user_template_identity "$tag" "${old_identity:-$old_label}" "${new_identity:-$new_label}"; then
    ((lock_owned == 0)) || traffic_lock_release
    return 1
  fi
  if [[ ($protocol == socks || $protocol == http) && -f $TRAFFIC_FILE ]]; then
    traffic_user_rename_client_record_locked "$tag" "$old_label" "$new_label" || {
      ((lock_owned == 0)) || traffic_lock_release
      warn "账号已重命名，但历史流量记录迁移失败，请检查 traffic.json。"
      return 1
    }
  fi
  ((lock_owned == 0)) || traffic_lock_release
  info "用户已重命名：${old_label} -> ${new_label}"
}

public_host_for_tag() {
  local tag=$1 host listen canonical
  host=$(jq -r --arg tag "$tag" '.inbounds[$tag].host // empty' "$META_FILE" 2>/dev/null || true)
  host=${host:-${XRAYCTL_PUBLIC_HOST:-}}
  if [[ -z $host ]]; then
    listen=$(inbound_effective_listen "$tag") || return 1
    if canonical=$(normalize_socket_ip "$listen") && [[ $canonical != 0.0.0.0 && $canonical != :: ]]; then
      host=$listen
    elif [[ -t 0 ]]; then
      prompt_inbound_ip host "选择分享链接使用的本机" >&2 || return 1
    else
      die "缺少客户端连接地址。请在入站 ${tag} 的「修改入站信息」中设置，或指定 XRAYCTL_PUBLIC_HOST。"
    fi
  fi
  printf '%s' "$host"
}
