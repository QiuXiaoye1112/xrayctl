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
  # Xray's equivalent of an address-family-bound direct outbound is
  # sendThrough + UseIP: the core infers IPv4/IPv6 from the source address.
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

_short_ipv6() {
  local ip=$1 first last
  [[ $ip == *:* ]] || { printf '%s' "$ip"; return; }
  first=${ip%%:*}
  last=${ip##*:}
  [[ -n $first ]] || first=:
  [[ -n $last ]] || last=:
  printf '%s:...:%s' "$first" "$last"
}

_outbound_display_name() {
  local tag=$1 ip
  [[ $tag == direct ]] && { printf 'direct'; return; }
  ip=$(jq -r --arg tag "$tag" '.outbounds[]?|select(.tag==$tag)|.sendThrough // empty' "$CONFIG_FILE" 2>/dev/null || true)
  if [[ $ip == *:* ]]; then _short_ipv6 "$ip"; else printf '%s' "${ip:-$tag}"; fi
}

_outbound_endpoint_display() {
  local address=$1 port=$2 raw=$1
  if [[ $raw == \[*\] ]]; then
    raw=${raw#\[}
    raw=${raw%\]}
  fi
  if [[ $raw == *:* ]]; then
    printf '[%s]:%s' "$(_short_ipv6 "$raw")" "$port"
  else
    printf '%s:%s' "$address" "$port"
  fi
}

_xrayctl_domain_rule_jq() {
  cat <<'JQ'
def xrayctl_domain_rule:
  type == "object" and
  ((.ruleTag // "") | type == "string") and
  ((.ruleTag // "") | startswith("xrayctl-domain:"));
JQ
}

list_outbound_overview() {
  local rows number tag protocol address port username endpoint
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
          local display; display=$(_outbound_display_name "$outbound")
          print_table_cell "$number" 6; print_table_cell "$tag" 28; printf '%s\n' "$display"
        done
  fi

  heading "代理出站"
  if jq -e '.outbounds[]?|select(.protocol=="socks" or .protocol=="http")' "$CONFIG_FILE" >/dev/null; then
    rows=$(jq -r '[.outbounds[]?|select(.protocol=="socks" or .protocol=="http")] | to_entries[] |
      [.key+1,.value.tag,.value.protocol,
       .value.settings.address,(.value.settings.port|tostring),
       (if (.value.settings.user // "")=="" then "无" else .value.settings.user end)] | @tsv' "$CONFIG_FILE")
    print_table_cell "序号" 4; printf '| '
    print_table_cell_clipped "标签" 16; printf '| '
    print_table_cell "协议" 7; printf '| '
    print_table_cell_clipped "地址" 22; printf '| 用户\n'
    while IFS=$'\t' read -r number tag protocol address port username; do
      endpoint=$(_outbound_endpoint_display "$address" "$port")
      print_table_cell "$number" 4; printf '| '
      print_table_cell_clipped "$tag" 16; printf '| '
      print_table_cell "$protocol" 7; printf '| '
      print_table_cell_clipped "$endpoint" 22; printf '| %s\n' "$username"
    done <<<"$rows"
  else
    info "还没有代理出站。"
  fi

  printf '\n'
}

show_outbound_details() {
  ensure_config
  local tag=${1-} answer item
  local -a tags=()
  while IFS= read -r item; do
    [[ -n $item ]] && tags+=("$item")
  done < <(jq -r '.outbounds[]?|select(.protocol=="socks" or .protocol=="http")|.tag' "$CONFIG_FILE")
  ((${#tags[@]})) || { info "还没有手动添加的代理出站。"; return 0; }

  if [[ -z $tag ]]; then
    if ((${#tags[@]} == 1)); then
      tag=${tags[0]}
    else
      choose answer "选择要查看的代理出站" "${tags[@]}" || return 0
      tag=${tags[$((answer-1))]}
    fi
  fi
  jq -e --arg tag "$tag" '.outbounds[]?|select((.protocol=="socks" or .protocol=="http") and .tag==$tag)' "$CONFIG_FILE" >/dev/null \
    || die "找不到手动添加的代理出站：$tag"

  heading "出站详情"
  printf '出站：%s\n\n' "$tag"
  jq --arg tag "$tag" '.outbounds[]|select((.protocol=="socks" or .protocol=="http") and .tag==$tag)' "$CONFIG_FILE"
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
  local __var=$1 include_direct=${2:-0} include_detected_local=${3:-1} candidate_tag answer local_tag
  local tags=() local_ips=() local_ip_tags=() local_raw_ips=()
  ((include_direct == 0)) || tags+=("direct")
  while IFS= read -r candidate_tag; do [[ -z $candidate_tag ]] || tags+=("$candidate_tag"); done < <(
    jq -r '.outbounds[]?|select((.protocol=="socks" or .protocol=="http" or .protocol=="freedom") and .tag!="direct" and .tag!="blocked")|.tag' "$CONFIG_FILE"
  )
  # 检测本地 IP，对已存在的 freedom 出站加备注
  while ((include_detected_local)) && IFS=$'\t' read -r label ip iface; do
    local_tag=$(_freedom_tag_for_ip "$ip")
    local_ip_tags+=("$local_tag")
    # 如果这个 freedom 出站不在列表里，追加到 tags
    local found=0
    for t in "${tags[@]}"; do [[ $t == "$local_tag" ]] && { found=1; break; }; done
    if ((!found)); then tags+=("$local_tag"); fi
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
    .routing.rules=(
      [(.routing.rules // [])[] | select((.ruleTag // "") != $ruleTag)] +
      [{type:"field",inboundTag:[$inbound],outboundTag:$outbound,ruleTag:$ruleTag}]
    )' "$CONFIG_FILE" >"$tmp"
  state_apply_candidate_file "$tmp" apply_candidate || return
  info "入站 ${inbound} 已使用出站 ${outbound}。"
}

_normalize_domain_input() {
  local __var=$1 candidate
  candidate=$(printf '%s' "${2-}" | tr '[:upper:]' '[:lower:]')
  if [[ $candidate == \*.* ]]; then
    # shellcheck disable=SC1111
    warn "请输入 ${candidate#\*.}，并选择“域名及所有子域名”。"
    return 1
  fi
  validate_domain "$candidate" || {
    warn "域名格式无效，请输入类似 openai.com 的域名。"
    return 1
  }
  printf -v "$__var" '%s' "$candidate"
}

generate_domain_rule_id() {
  local id
  while true; do
    id=$(random_hex 4)
    if ! jq -e --arg ruleTag "xrayctl-domain:${id}" \
      '[.routing.rules[]?|select(.ruleTag==$ruleTag)]|length>0' "$CONFIG_FILE" >/dev/null 2>&1; then
      printf '%s' "$id"
      return 0
    fi
  done
}

list_domain_rules() {
  ensure_runtime_dependencies outbound-rule-list; ensure_config
  local inbound=${1-} rows group_inbound="" number=0 match domain outbound display display_match
  [[ -z $inbound ]] || inbound_exists "$inbound" || die "找不到入站：$inbound"
  rows=$(jq -r --arg inbound "$inbound" "$(_xrayctl_domain_rule_jq)
    ([.routing.rules[]? |
      select(xrayctl_domain_rule) |
      (if (.inboundTag|type)==\"array\" then (.inboundTag[0] // \"?\") else \"?\" end) as \$rule_inbound |
      (if (.domain|type)==\"array\" then (.domain[0] // \"\") else \"\" end) as \$domain_value |
      (if (\$domain_value|startswith(\"full:\")) then \"exact\" elif (\$domain_value|startswith(\"domain:\")) then \"suffix\" else \"?\" end) as \$match |
      (if \$match==\"exact\" then \$domain_value[5:] elif \$match==\"suffix\" then \$domain_value[7:] else \$domain_value end) as \$domain |
      [\$rule_inbound,\$match,\$domain,(.outboundTag // \"?\")]] ) as \$rows |
    [.inbounds[].tag] as \$inbound_order |
    \$inbound_order[] as \$group |
    select(\$inbound==\"\" or \$group==\$inbound) |
    (\$rows[] | select(.[0]==\$group)) | @tsv" "$CONFIG_FILE")
  heading "域名分流规则"
  [[ -n $rows ]] || { info "还没有域名分流规则。"; return 0; }
  while IFS=$'\t' read -r inbound match domain outbound; do
    [[ -n $inbound ]] || continue
    [[ $match == suffix ]] && display_match="子域名" || display_match="精确"
    display=$(_outbound_display_name "$outbound")
    if [[ $inbound != "$group_inbound" ]]; then
      group_inbound=$inbound
      number=0
      printf '\n入站：%s\n' "$group_inbound"
      print_table_cell "序号" 6; printf '| '
      print_table_cell "匹配" 7; printf '| '
      print_table_cell_clipped "域名" 24; printf '| 出站\n'
    fi
    ((number+=1))
    print_table_cell "$number" 6; printf '| '
    print_table_cell "$display_match" 7; printf '| '
    print_table_cell_clipped "$domain" 24; printf '| %s\n' "$display"
  done <<<"$rows"
}

_normalize_domain_list() {
  local raw=$1 candidate normalized
  local -a candidates=()

  [[ $raw != ,* && $raw != *, && $raw != *,,* ]] || {
    warn "域名列表中不能有空项，请使用英文逗号分隔。"
    return 1
  }
  IFS=',' read -r -a candidates <<<"$raw"
  ((${#candidates[@]} > 0)) || return 1

  for candidate in "${candidates[@]}"; do
    candidate="${candidate#"${candidate%%[![:space:]]*}"}"
    candidate="${candidate%"${candidate##*[![:space:]]}"}"
    [[ -n $candidate ]] || {
      warn "域名列表中不能有空项，请使用英文逗号分隔。"
      return 1
    }
    _normalize_domain_input normalized "$candidate" || return 1
    printf '%s\n' "$normalized"
  done
}

add_domain_rule() {
  ensure_runtime_dependencies outbound-rule-add; ensure_config
  local inbound=${1-} match=${2-} domain=${3-} outbound=${4-}
  local choice normalized_domains rule_tag new_rule tmp existing_domains domains_json
  local -a domains=()
  if [[ -n $inbound || -n $match || -n $domain || -n $outbound ]]; then
    [[ -n $inbound && -n $match && -n $domain && -n $outbound ]] || \
      die "用法：xrayctl outbound rule add <入站> <suffix|exact> <域名[,域名...]> <出站>"
    inbound_exists "$inbound" || die "找不到入站：$inbound"
    case $match in suffix|exact) ;; *) die "匹配方式只能是 suffix 或 exact。";; esac
    normalized_domains=$(_normalize_domain_list "$domain") || die "域名格式无效。"
    outbound_exists "$outbound" || [[ $outbound == direct ]] || die "找不到出站：$outbound"
  else
    select_inbound inbound || return
    choose choice "匹配方式" "域名及所有子域名" "仅精确域名" || return
    [[ $choice == 1 ]] && match=suffix || match=exact
    while true; do
      prompt_value domain "域名（多个请用英文逗号分隔）" || return
      if normalized_domains=$(_normalize_domain_list "$domain"); then
        break
      fi
    done
    # Domain rules intentionally share the existing outbound selector with
    # default outbound assignment, including direct, local IP, SOCKS and HTTP.
    select_outbound outbound 1 || return
  fi

  while IFS= read -r domain; do
    [[ -n $domain ]] && domains+=("$domain")
  done <<<"$normalized_domains"
  ((${#domains[@]} > 0)) || die "域名格式无效。"

  domains_json=$(printf '%s\n' "${domains[@]}" | jq -Rsc 'split("\n") | map(select(length > 0))')
  if ! jq -e 'length == (unique | length)' <<<"$domains_json" >/dev/null; then
    warn "域名列表中不能重复添加同一个域名。"
    return 0
  fi
  existing_domains=$(jq -r --arg inbound "$inbound" --arg match "$match" --argjson domains "$domains_json" "$(_xrayctl_domain_rule_jq)
    [.routing.rules[]? |
      select(xrayctl_domain_rule and ((.inboundTag // []) == [\$inbound])) |
      .domain[0] as \$rule_domain |
      select(any(\$domains[]; \$rule_domain == ((if \$match==\"suffix\" then \"domain:\" else \"full:\" end) + .))) |
      if \$match==\"suffix\" then \$rule_domain[7:] else \$rule_domain[5:] end] |
      unique | join(\",\")" "$CONFIG_FILE")
  if [[ -n $existing_domains ]]; then
    warn "已有此域名规则：${inbound} ${match} ${existing_domains}！"
    return 0
  fi

  for domain in "${domains[@]}"; do
    rule_tag="xrayctl-domain:$(generate_domain_rule_id)"
    new_rule=$(jq -n --arg inbound "$inbound" --arg match "$match" --arg domain "$domain" \
      --arg outbound "$outbound" --arg ruleTag "$rule_tag" '
      {type:"field",inboundTag:[$inbound],
       domain:(if $match=="suffix" then ["domain:"+$domain] else ["full:"+$domain] end),
       outboundTag:$outbound,ruleTag:$ruleTag}')

  tmp=$(temp_file)
  jq --arg inbound "$inbound" --arg match "$match" --arg domain "$domain" \
    --arg outbound "$outbound" --argjson new_rule "$new_rule" "$(_xrayctl_domain_rule_jq)
    def domain_value:
      if (.domain|type)==\"array\" and (.domain|length)==1 and (.domain[0]|type)==\"string\" then .domain[0] else \"\" end;
    def managed_for_inbound:
      xrayctl_domain_rule and ((.inboundTag // []) == [\$inbound]);
    def managed_suffix:
      managed_for_inbound and (domain_value|startswith(\"domain:\"));
    def lower_priority_suffix:
      managed_suffix and
      (((domain_value[7:]|split(\".\")|length) < (\$domain|split(\".\")|length)) or
       (((domain_value[7:]|split(\".\")|length) == (\$domain|split(\".\")|length)) and
        ((domain_value[7:]|length) < (\$domain|length))));
    .routing=(.routing // {domainStrategy:\"IPIfNonMatch\",rules:[]}) |
    (.routing.rules // []) as \$rules |
    ([range(0; (\$rules|length)) as \$i |
      select(\$rules[\$i] | (if \$match==\"exact\" then managed_suffix else lower_priority_suffix end)) |
      \$i] | .[0] // null) as \$priority_index |
    ([range(0; (\$rules|length)) as \$i |
      select((\$rules[\$i].ruleTag // \"\") == (\"xrayctl-outbound:\"+\$inbound)) |
      \$i] | .[0] // null) as \$default_index |
    ([range(0; (\$rules|length)) as \$i |
      select(\$rules[\$i] | managed_for_inbound) |
      \$i] | .[-1] // null) as \$last_domain_index |
    (if \$priority_index==null then
       \$default_index
     elif \$default_index==null then
       \$priority_index
     elif \$priority_index < \$default_index then
       \$priority_index
     else
       \$default_index
     end) as \$boundary_index |
    (if \$boundary_index!=null then \$boundary_index
     elif \$last_domain_index!=null then \$last_domain_index+1
     else \$rules|length
     end) as \$insert_index |
    .routing.rules=[range(0; ((\$rules|length)+1)) as \$i |
      if \$i==\$insert_index then \$new_rule
      elif \$i < \$insert_index then \$rules[\$i]
      else \$rules[\$i-1]
      end]" "$CONFIG_FILE" >"$tmp"
    state_apply_candidate_file "$tmp" apply_candidate >/dev/null || return
  done
  info "已添加域名规则：${inbound} ${match}（${#domains[@]} 条） -> ${outbound}。"
}

delete_domain_rule() {
  ensure_runtime_dependencies outbound-rule-delete; ensure_config
  local inbound=${1-} match=${2-} domain=${3-} rows choice selected_inbound tmp selection token idx
  local row_inbound row_match row_domain row_outbound
  local -a rule_matches=() rule_domains=() rule_outbounds=() delete_indices=()
  local -a inbound_tags=() inbound_labels=() inbound_counts=()

  if [[ -n $match || -n $domain ]]; then
    [[ -n $inbound && -n $match && -n $domain ]] || \
      die "用法：xrayctl outbound rule delete [入站] [suffix|exact] [域名]"
    case $match in suffix|exact) ;; *) die "匹配方式只能是 suffix 或 exact。";; esac
    _normalize_domain_input domain "$domain" || die "域名格式无效。"
    inbound_exists "$inbound" || die "找不到入站：$inbound"
    selected_inbound=$inbound
  elif [[ -n $inbound ]]; then
    inbound_exists "$inbound" || die "找不到入站：$inbound"
    selected_inbound=$inbound
  fi

  rows=$(jq -r --arg inbound "${selected_inbound:-$inbound}" "$(_xrayctl_domain_rule_jq)
    [.routing.rules[]? |
      select(xrayctl_domain_rule) |
      select(\$inbound==\"\" or ((.inboundTag // [])|index(\$inbound))!=null) |
      (if (.inboundTag|type)==\"array\" then (.inboundTag[0] // \"?\") else \"?\" end) as \$rule_inbound |
      (if (.domain|type)==\"array\" then (.domain[0] // \"\") else \"\" end) as \$domain_value |
      (if (\$domain_value|startswith(\"full:\")) then \"exact\" elif (\$domain_value|startswith(\"domain:\")) then \"suffix\" else \"?\" end) as \$rule_match |
      (if \$rule_match==\"exact\" then \$domain_value[5:] elif \$rule_match==\"suffix\" then \$domain_value[7:] else \$domain_value end) as \$rule_domain |
      [\$rule_inbound,\$rule_match,\$rule_domain,(.outboundTag // \"?\")] | @tsv] | .[]" "$CONFIG_FILE")

  if [[ -n $match ]]; then
    local matching_count=0
    while IFS=$'\t' read -r row_inbound row_match row_domain row_outbound; do
      [[ $row_inbound == "$selected_inbound" && $row_match == "$match" && $row_domain == "$domain" ]] || continue
      ((matching_count+=1))
    done <<<"$rows"
    ((matching_count > 0)) || die "找不到域名规则：${selected_inbound} ${match} ${domain}"
    ((matching_count == 1)) || die "域名规则存在重复项，请先使用交互菜单处理。"
    delete_indices=(1)
    rule_matches=("$match")
    rule_domains=("$domain")
    rule_outbounds=("$(jq -r --arg inbound "$selected_inbound" --arg match "$match" --arg domain "$domain" "$(_xrayctl_domain_rule_jq)
      [.routing.rules[]? | select(xrayctl_domain_rule and (.inboundTag // [])==[\$inbound]) |
       select((if \$match==\"suffix\" then .domain else .domain end)==(if \$match==\"suffix\" then [\"domain:\"+\$domain] else [\"full:\"+\$domain] end)) | .outboundTag][0] // \"?\"" "$CONFIG_FILE")")
  else
    if [[ -z $selected_inbound ]]; then
      while IFS=$'\t' read -r row_inbound row_match row_domain row_outbound; do
        [[ -n $row_inbound ]] || continue
        local found=0 i
        for ((i=0; i<${#inbound_tags[@]}; i++)); do
          if [[ ${inbound_tags[$i]} == "$row_inbound" ]]; then
            inbound_counts[i]=$((inbound_counts[i]+1)); found=1; break
          fi
        done
        if (( !found )); then
          inbound_tags+=("$row_inbound"); inbound_counts+=(1)
        fi
      done <<<"$rows"
      ((${#inbound_tags[@]})) || { warn "没有可删除的域名分流规则。"; return 0; }
      for ((i=0; i<${#inbound_tags[@]}; i++)); do
        inbound_labels+=("${inbound_tags[$i]}（${inbound_counts[$i]} 条）")
      done
      if ((${#inbound_tags[@]} == 1)); then
        selected_inbound=${inbound_tags[0]}
      else
        choose choice "选择入站" "${inbound_labels[@]}" || return
        selected_inbound=${inbound_tags[$((choice-1))]}
      fi
      rows=$(jq -r --arg inbound "$selected_inbound" "$(_xrayctl_domain_rule_jq)
        [.routing.rules[]? | select(xrayctl_domain_rule and (.inboundTag // [])==[\$inbound]) |
         (if .domain[0]|startswith(\"full:\") then \"exact\" else \"suffix\" end) as \$match |
         (if \$match==\"exact\" then .domain[0][5:] else .domain[0][7:] end) as \$domain |
         [\$match,\$domain,(.outboundTag // \"?\")] | @tsv] | .[]" "$CONFIG_FILE")
    else
      rows=$(jq -r --arg inbound "$selected_inbound" "$(_xrayctl_domain_rule_jq)
        [.routing.rules[]? | select(xrayctl_domain_rule and (.inboundTag // [])==[\$inbound]) |
         (if .domain[0]|startswith(\"full:\") then \"exact\" else \"suffix\" end) as \$match |
         (if \$match==\"exact\" then .domain[0][5:] else .domain[0][7:] end) as \$domain |
         [\$match,\$domain,(.outboundTag // \"?\")] | @tsv] | .[]" "$CONFIG_FILE")
    fi

    while IFS=$'\t' read -r row_match row_domain row_outbound; do
      [[ -n $row_domain ]] || continue
      rule_matches+=("$row_match"); rule_domains+=("$row_domain"); rule_outbounds+=("$row_outbound")
    done <<<"$rows"
    ((${#rule_domains[@]})) || { warn "没有可删除的域名分流规则。"; return 0; }
    printf '\n入站：%s\n\n' "$selected_inbound"
    for ((idx=0; idx<${#rule_domains[@]}; idx++)); do
      printf '%d) %s\n' "$((idx+1))" "${rule_domains[$idx]}"
    done
    while true; do
      read -r -p '请选择要删除的规则（支持 1,3,2）: ' selection || return
      selection=$(printf '%s' "$selection" | tr -d '[:space:]')
      delete_indices=()
      IFS=',' read -r -a tokens <<<"$selection"
      local valid=1
      for token in "${tokens[@]}"; do
        if [[ ! $token =~ ^[0-9]+$ ]] || ((10#$token < 1 || 10#$token > ${#rule_domains[@]})); then
          valid=0; break
        fi
        idx=$((10#$token))
        if ((${#delete_indices[@]})); then
          for choice in "${delete_indices[@]}"; do
            if ((choice == idx)); then valid=0; break 2; fi
          done
        fi
        delete_indices+=("$idx")
      done
      ((valid)) && ((${#delete_indices[@]})) && break
      warn "请输入有效且不重复的序号，例如 1,3,2。"
    done

    printf '\n将删除：\n'
    local match_label display selected_json='[]'
    for choice in "${delete_indices[@]}"; do
      idx=$((choice-1))
      [[ ${rule_matches[$idx]} == suffix ]] && match_label=子域名 || match_label=精确
      display=$(_outbound_display_name "${rule_outbounds[$idx]}")
      printf -- '- %s（%s → %s）\n' "${rule_domains[$idx]}" "$match_label" "$display"
      selected_json=$(jq -c --arg match "${rule_matches[$idx]}" --arg domain "${rule_domains[$idx]}" \
        '. + [{match:$match,domain:$domain}]' <<<"$selected_json")
    done
    confirm "确认删除这些规则？" N || return
  fi

  if [[ -n $match ]]; then
    local selected_json='[]'
    selected_json=$(jq -c --arg match "$match" --arg domain "$domain" '. + [{match:$match,domain:$domain}]' <<<"$selected_json")
  fi
  tmp=$(temp_file)
  jq --arg inbound "$selected_inbound" --argjson selected "$selected_json" "$(_xrayctl_domain_rule_jq)
    def selected_rule(\$rule; \$selected):
      any(\$selected[]; . as \$target |
        (\$rule | if \$target.match==\"suffix\" then .domain == [\"domain:\"+\$target.domain] else .domain == [\"full:\"+\$target.domain] end));
    .routing=(.routing // {}) |
    .routing.rules=[(.routing.rules // [])[] |
      (.) as \$rule |
      select(((\$rule | xrayctl_domain_rule) and
        (\$rule.inboundTag // [])==[\$inbound] and
        selected_rule(\$rule;\$selected)) | not)]" "$CONFIG_FILE" >"$tmp"
  if state_apply_candidate_file "$tmp" apply_candidate >/dev/null; then
    if [[ -n $match ]]; then
      info "已删除域名规则：${selected_inbound} ${match} ${domain}。"
    else
      info "已删除 ${#delete_indices[@]} 条域名规则（入站：${selected_inbound}）。"
    fi
  fi
}

delete_outbound() {
  ensure_runtime_dependencies outbound-delete; ensure_config
  local tag=${1-} tmp default_refs domain_refs custom_refs
  [[ -n $tag ]] || select_outbound tag 0 0 || return
  outbound_exists "$tag" || die "找不到出站：$tag"
  [[ $tag != direct && $tag != blocked ]] || { warn "${tag} 出站不能删除。"; return 0; }

  default_refs=$(jq -r --arg tag "$tag" '
    [.routing.rules[]? |
      select(.outboundTag==$tag and (.ruleTag|type)=="string" and (.ruleTag|startswith("xrayctl-outbound:")))] | length' "$CONFIG_FILE")
  domain_refs=$(jq -r --arg tag "$tag" '
    [.routing.rules[]? |
      select(.outboundTag==$tag and (.ruleTag|type)=="string" and (.ruleTag|startswith("xrayctl-domain:")))] | length' "$CONFIG_FILE")
  custom_refs=$(jq -r --arg tag "$tag" '
    [.routing.rules[]? |
      select(.outboundTag==$tag) |
      select(
        ((.ruleTag|type)!="string") or
        (((.ruleTag|startswith("xrayctl-outbound:"))|not) and
         ((.ruleTag|startswith("xrayctl-domain:"))|not))
      )] | length' "$CONFIG_FILE")
  if ((custom_refs > 0)); then
    die "该出站仍被自定义路由规则引用，请先在完整配置中处理。"
  fi
  if ((default_refs > 0 || domain_refs > 0)); then
    warn "出站 ${tag} 当前被 xrayctl 管理规则引用："
    ((default_refs > 0)) && printf '%s 个入站默认出站使用\n' "$default_refs"
    ((domain_refs > 0)) && printf '%s 条域名规则使用\n' "$domain_refs"
    warn "删除后这些管理规则会一并删除。"
    confirm "继续删除出站 ${tag}？" N || return 0
  else
    confirm "删除出站 ${tag}？" N || return 0
  fi
  tmp=$(temp_file)
  jq --arg tag "$tag" '
    .outbounds |= map(select(.tag!=$tag)) |
    .routing.rules=((.routing.rules // []) | map(select(.outboundTag!=$tag)))' "$CONFIG_FILE" >"$tmp"
  state_apply_candidate_file "$tmp" apply_candidate || return
  info "出站 ${tag} 已删除。"
}
