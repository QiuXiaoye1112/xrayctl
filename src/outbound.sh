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
  if state_apply_candidate_file "$tmp" apply_candidate >&2; then
    printf '%s' "$tag"
  else
    return 1
  fi
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
  state_apply_candidate_file "$tmp" apply_candidate || return
  info "出站 ${tag} 已添加。"
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
  state_apply_candidate_file "$tmp" apply_candidate || return
  info "入站 ${inbound} 已使用出站 ${outbound}。"
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
  state_apply_candidate_file "$tmp" apply_candidate || return
  info "出站 ${tag} 已删除。"
}
