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

_meta_template_add() {
  local current=$1 candidate=$2 name=$3
  jq --arg name "$name" '
    .domainTemplates = (.domainTemplates // {templates:[],bindings:[]}) |
    if any(.domainTemplates.templates[]?; .name==$name) then
      error("模板已存在")
    else
      .domainTemplates.templates += [{name:$name,exact:[],suffix:[]}]
    end' "$current" >"$candidate"
}

_meta_template_domains_add() {
  local current=$1 candidate=$2 name=$3 match=$4 domains_json=$5
  jq --arg name "$name" --arg match "$match" --argjson domains "$domains_json" '
    .domainTemplates.templates |= map(
      if .name==$name then
        .[$match] = (((.[$match] // []) + $domains) | unique)
      else . end
    )' "$current" >"$candidate"
}

_meta_template_domains_delete() {
  local current=$1 candidate=$2 name=$3 match=$4 domains_json=$5
  jq --arg name "$name" --arg match "$match" --argjson domains "$domains_json" '
    .domainTemplates.templates |= map(
      if .name==$name then
        .[$match] = [(.[$match] // [])[] | . as $d | select(($domains | index($d)) == null)]
      else . end
    )' "$current" >"$candidate"
}

_meta_template_bind() {
  local current=$1 candidate=$2 inbound=$3 name=$4 outbound=$5
  jq --arg inbound "$inbound" --arg name "$name" --arg outbound "$outbound" '
    .domainTemplates = (.domainTemplates // {templates:[],bindings:[]}) |
    if any(.domainTemplates.templates[]?; .name==$name) then
      .domainTemplates.bindings = ([.domainTemplates.bindings[]? |
        select(.inbound!=$inbound or .template!=$name)] +
        [{inbound:$inbound,template:$name,outbound:$outbound}])
    else error("找不到模板") end' "$current" >"$candidate"
}

_meta_template_unbind() {
  local current=$1 candidate=$2 inbound=$3 name=$4
  jq --arg inbound "$inbound" --arg name "$name" '
    .domainTemplates = (.domainTemplates // {templates:[],bindings:[]}) |
    .domainTemplates.bindings = [.domainTemplates.bindings[]? |
      select(.inbound!=$inbound or .template!=$name)]' "$current" >"$candidate"
}

_meta_template_set_outbound() {
  local current=$1 candidate=$2 inbound=$3 name=$4 outbound=$5
  jq --arg inbound "$inbound" --arg name "$name" --arg outbound "$outbound" '
    .domainTemplates = (.domainTemplates // {templates:[],bindings:[]}) |
    if any(.domainTemplates.bindings[]?; .inbound==$inbound and .template==$name) then
      .domainTemplates.bindings |= map(
        if .inbound==$inbound and .template==$name then .outbound=$outbound else . end)
    else error("该入站未应用此模板")
    end' "$current" >"$candidate"
}

list_domain_templates() {
  ensure_meta
  jq -r '.domainTemplates.templates[]? |
    [.name, ((.exact // [])|length), ((.suffix // [])|length)] | @tsv' "$META_FILE"
}

domain_template_exists() {
  ensure_meta
  jq -e --arg name "$1" 'any(.domainTemplates.templates[]?; .name==$name)' "$META_FILE" >/dev/null
}

list_inbound_template_bindings() {
  ensure_meta
  jq -r --arg inbound "$1" '.domainTemplates.bindings[]? |
    select(.inbound==$inbound) | [.template,.outbound] | @tsv' "$META_FILE"
}

_desired_to_additions() {
  local __var=$1 desired_json=$2 inbound=$3
  local count i item match domain template outbound tag rule result='[]'
  count=$(jq 'length' <<<"$desired_json")
  for ((i=0; i<count; i++)); do
    item=$(jq -c ".[$i]" <<<"$desired_json")
    match=$(jq -r '.match' <<<"$item")
    domain=$(jq -r '.domain' <<<"$item")
    template=$(jq -r '.template' <<<"$item")
    outbound=$(jq -r '.outbound' <<<"$item")
    tag="xrayctl-domain:$(random_hex 4)"
    rule=$(jq -n --arg inbound "$inbound" --arg outbound "$outbound" \
      --arg match "$match" --arg domain "$domain" --arg tag "$tag" --arg template "$template" '
      {type:"field",inboundTag:[$inbound],
       domain:(if $match=="suffix" then ["domain:"+$domain] else ["full:"+$domain] end),
       outboundTag:$outbound,ruleTag:$tag,template:$template}')
    result=$(jq -c --argjson rule "$rule" --arg inbound "$inbound" \
      --arg match "$match" --arg domain "$domain" \
      '. + [{rule:$rule,inbound:$inbound,match:$match,domain:$domain}]' <<<"$result")
  done
  printf -v "$__var" '%s' "$result"
}

# Later bindings in metadata order override earlier ones for the same domain.
_inbound_desired_entries() {
  local __var=$1 metadata=$2 inbound=$3 result
  result=$(jq -c --arg inbound "$inbound" '
    .domainTemplates as $dt |
    [$dt.bindings[]? | select(.inbound==$inbound)] as $bound |
    reduce (
      $bound[] as $b |
      ($dt.templates[]? | select(.name==$b.template)) as $t |
      (($t.exact[]? | {match:"exact", domain:., key:("full:"+.)}),
       ($t.suffix[]? | {match:"suffix", domain:., key:("domain:"+.)})) |
      {key:.key, match:.match, domain:.domain, template:$b.template, outbound:$b.outbound}
    ) as $entry ({}; .[$entry.key]=$entry) |
    [.[]]
  ' "$metadata")
  printf -v "$__var" '%s' "$result"
}

_template_key_jq() {
  cat <<'JQ'
def template_rule_key:
  if has("domain_suffix") then .domain_suffix[0]
  elif has("domain") then .domain[0]
  else null end;
JQ
}

_reconcile_template_rules_jq() {
  _xrayctl_domain_rule_jq
  _template_key_jq
  cat <<'JQ'
def inbound_template_rule($inbound):
  xrayctl_domain_rule and (.inboundTag // [])==[$inbound] and ((.template // "")!="");
($desired | map({key:.key, value:.}) | from_entries) as $desired_map |
.routing=(.routing // {}) |
.routing.rules=[(.routing.rules // [])[] |
  if inbound_template_rule($inbound) then
    (template_rule_key) as $k |
    if $desired_map[$k] != null then
      .outboundTag=$desired_map[$k].outbound | .template=$desired_map[$k].template
    else empty end
  else . end]
JQ
}

_missing_template_rules_jq() {
  _xrayctl_domain_rule_jq
  _template_key_jq
  cat <<'JQ'
def inbound_managed($inbound):
  xrayctl_domain_rule and (.inboundTag // [])==[$inbound];
([.routing.rules[]? | select(inbound_managed($inbound)) | template_rule_key]) as $present |
[$desired[] | select(((.key) as $k | $present | index($k)) == null)]
JQ
}

_rebuild_inbound_template_config() {
  local __var=$1 base=$2 inbound=$3 metadata=$4
  local desired missing additions tmpA out
  _inbound_desired_entries desired "$metadata" "$inbound"
  tmpA=$(temp_file)
  if ! jq --arg inbound "$inbound" --argjson desired "$desired" \
    "$(_reconcile_template_rules_jq)" "$base" >"$tmpA"; then
    rm -f "$tmpA"
    return 1
  fi
  missing=$(jq -c --arg inbound "$inbound" --argjson desired "$desired" \
    "$(_missing_template_rules_jq)" "$tmpA") || {
    rm -f "$tmpA"
    return 1
  }
  if [[ $missing == '[]' ]]; then
    printf -v "$__var" '%s' "$tmpA"
    return 0
  fi
  _desired_to_additions additions "$missing" "$inbound"
  out=$(temp_file)
  if ! _build_template_config_candidate "$tmpA" "$out" "$additions"; then
    rm -f "$tmpA" "$out"
    return 1
  fi
  rm -f "$tmpA"
  printf -v "$__var" '%s' "$out"
}

_rebuild_template_bound_inbounds_config() {
  local __var=$1 metadata=$2 name=$3
  local current next inbound rc=0
  current=$(temp_file)
  cp "$CONFIG_FILE" "$current"
  while IFS=$'\t' read -r inbound; do
    [[ -n $inbound ]] || continue
    if ! _rebuild_inbound_template_config next "$current" "$inbound" "$metadata"; then
      rc=1
      break
    fi
    rm -f "$current"
    current=$next
  done < <(jq -r --arg name "$name" \
    '.domainTemplates.bindings[]? | select(.template==$name) | .inbound' "$metadata")
  if ((rc)); then
    rm -f "$current"
    return 1
  fi
  printf -v "$__var" '%s' "$current"
}

_build_template_config_candidate() {
  local current=$1 candidate=$2 additions_json=$3
  jq --argjson additions "$additions_json" "$(_template_config_jq)" "$current" >"$candidate"
}

_template_config_jq() {
  _xrayctl_domain_rule_jq
  cat <<'JQ'
def managed_for($rule; $inbound):
  ($rule | xrayctl_domain_rule) and (($rule.inboundTag // []) == [$inbound]);
def same_rule($rule; $new):
  managed_for($rule; $new.inbound) and
  ($rule.domain == [(if $new.match=="suffix" then "domain:" else "full:" end)+$new.domain]);
def insert_rule($rules; $new):
  ([range(0; ($rules|length)) as $i |
    select(
      if $new.match=="exact" then
        ($rules[$i] | managed_for(.; $new.inbound) and (.domain[0] | startswith("domain:")))
      else
        ($rules[$i] | managed_for(.; $new.inbound) and (.domain[0] | startswith("domain:")) and
          ((.domain[0][7:]|split(".")|length) < ($new.domain|split(".")|length) or
           ((.domain[0][7:]|split(".")|length) == ($new.domain|split(".")|length) and
            (.domain[0][7:]|length) < ($new.domain|length))))
      end
    ) | $i] | .[0] // null) as $priority |
  ([range(0; ($rules|length)) as $i |
    select((($rules[$i].ruleTag // "") == ("xrayctl-outbound:"+$new.inbound)) or
      (((($rules[$i].ruleTag // "")|startswith("xrayctl-user-outbound:"))) and (($rules[$i].inboundTag // [])==[$new.inbound]))) | $i] | .[0] // null) as $default |
  ([range(0; ($rules|length)) as $i |
    select($rules[$i] | managed_for(.; $new.inbound)) | $i] | .[-1] // null) as $last |
  (if $priority != null then $priority
   elif $default != null then $default
   elif $last != null then $last + 1
   else ($rules|length) end) as $index |
  [range(0; (($rules|length)+1)) as $i |
    if $i==$index then $new.rule
    elif $i < $index then $rules[$i]
    else $rules[$i-1] end];
.routing=(.routing // {domainStrategy:"IPIfNonMatch",rules:[]}) |
.routing.rules=reduce $additions[] as $new (.routing.rules;
  if any(.[]; same_rule(.; $new)) then
    map(if same_rule(.; $new) and ((.template // "") == ($new.rule.template // ""))
        then .outboundTag=$new.rule.outboundTag else . end)
  else insert_rule(.; $new) end)
JQ
}

create_domain_template() {
  ensure_runtime_dependencies outbound-template-create; ensure_config; ensure_meta
  local name
  prompt_value name "模板名称" || return
  validate_tag "$name" || { warn "模板名称只能包含字母、数字、点、下划线和横线。"; return 1; }
  if domain_template_exists "$name"; then
    warn "模板已存在：${name}"
    return 1
  fi
  state_commit_metadata _meta_template_add "$name" || return
  info "模板 ${name} 已创建。"
}

_commit_template_change() {
  local config_candidate=$1 meta_candidate=$2 message=$3 rc=0
  if cmp -s "$CONFIG_FILE" "$config_candidate"; then
    state_commit_metadata _state_copy_metadata "$meta_candidate"
    rc=$?
    rm -f "$config_candidate" "$meta_candidate"
    ((rc == 0)) || return "$rc"
  else
    state_commit_candidate_with_metadata "$config_candidate" "$meta_candidate" || {
      rm -f "$config_candidate" "$meta_candidate"
      return 1
    }
    rm -f "$config_candidate" "$meta_candidate"
  fi
  info "$message"
}

apply_domain_template() {
  ensure_runtime_dependencies outbound-template-apply; ensure_config; ensure_meta
  local inbound=$1 name=$2 outbound=$3 meta_candidate config_candidate
  inbound_exists "$inbound" || die "找不到入站：$inbound"
  domain_template_exists "$name" || die "找不到模板：$name"
  outbound_exists "$outbound" || [[ $outbound == direct ]] || die "找不到出站：$outbound"
  meta_candidate=$(temp_file)
  _meta_template_bind "$META_FILE" "$meta_candidate" "$inbound" "$name" "$outbound" || {
    rm -f "$meta_candidate"
    return 1
  }
  _rebuild_inbound_template_config config_candidate "$CONFIG_FILE" "$inbound" "$meta_candidate" || {
    rm -f "$meta_candidate"
    return 1
  }
  _commit_template_change "$config_candidate" "$meta_candidate" "模板 ${name} 已应用到入站 ${inbound}（出站：${outbound}）。"
}

add_domain_template_domains() {
  ensure_runtime_dependencies outbound-template-edit; ensure_config; ensure_meta
  local name=$1 match=$2 raw=$3 normalized domains_json meta_candidate config_candidate
  normalized=$(_normalize_domain_list "$raw") || return 1
  domains_json=$(printf '%s\n' "$normalized" | jq -Rsc 'split("\n") | map(select(length>0)) | unique')
  meta_candidate=$(temp_file)
  _meta_template_domains_add "$META_FILE" "$meta_candidate" "$name" "$match" "$domains_json" || {
    rm -f "$meta_candidate"
    return 1
  }
  _rebuild_template_bound_inbounds_config config_candidate "$meta_candidate" "$name" || {
    rm -f "$meta_candidate"
    return 1
  }
  _commit_template_change "$config_candidate" "$meta_candidate" "模板 ${name} 已更新，已同步到已应用的入站。"
}

delete_domain_template_domains() {
  ensure_runtime_dependencies outbound-template-edit; ensure_config; ensure_meta
  local name=$1 match=$2 raw=$3 normalized domains_json meta_candidate config_candidate
  normalized=$(_normalize_domain_list "$raw") || return 1
  domains_json=$(printf '%s\n' "$normalized" | jq -Rsc 'split("\n") | map(select(length>0)) | unique')
  meta_candidate=$(temp_file)
  _meta_template_domains_delete "$META_FILE" "$meta_candidate" "$name" "$match" "$domains_json" || {
    rm -f "$meta_candidate"
    return 1
  }
  _rebuild_template_bound_inbounds_config config_candidate "$meta_candidate" "$name" || {
    rm -f "$meta_candidate"
    return 1
  }
  _commit_template_change "$config_candidate" "$meta_candidate" "模板 ${name} 已更新，已同步删除已应用入站中的规则。"
}

remove_domain_template() {
  ensure_runtime_dependencies outbound-template-remove; ensure_config; ensure_meta
  local inbound=$1 name=$2 meta_candidate config_candidate
  meta_candidate=$(temp_file)
  _meta_template_unbind "$META_FILE" "$meta_candidate" "$inbound" "$name" || {
    rm -f "$meta_candidate"
    return 1
  }
  _rebuild_inbound_template_config config_candidate "$CONFIG_FILE" "$inbound" "$meta_candidate" || {
    rm -f "$meta_candidate"
    return 1
  }
  _commit_template_change "$config_candidate" "$meta_candidate" "已从入站 ${inbound} 移除模板 ${name}。"
}

update_domain_template_outbound() {
  ensure_runtime_dependencies outbound-template-set-outbound; ensure_config; ensure_meta
  local inbound=$1 name=$2 outbound=$3 meta_candidate config_candidate
  inbound_exists "$inbound" || die "找不到入站：$inbound"
  domain_template_exists "$name" || die "找不到模板：$name"
  outbound_exists "$outbound" || [[ $outbound == direct ]] || die "找不到出站：$outbound"
  meta_candidate=$(temp_file)
  _meta_template_set_outbound "$META_FILE" "$meta_candidate" "$inbound" "$name" "$outbound" || {
    rm -f "$meta_candidate"
    return 1
  }
  _rebuild_inbound_template_config config_candidate "$CONFIG_FILE" "$inbound" "$meta_candidate" || {
    rm -f "$meta_candidate"
    return 1
  }
  _commit_template_change "$config_candidate" "$meta_candidate" "模板 ${name} 的出站已更新为 ${outbound}（入站：${inbound}）。"
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

list_inbound_outbound_status() {
  ensure_config
  heading "入站出站状态"
  printf '入站\t默认出站\t公共域名规则\t用户数\n'
  jq -r '
    (.routing.rules // []) as $rules |
    .inbounds[]? | select(.protocol=="vless" or .protocol=="socks" or .protocol=="http") |
    .tag as $tag | .protocol as $protocol |
    [$tag,
     ([$rules[]? | select((.ruleTag // "")==("xrayctl-outbound:"+$tag)) | .outboundTag][0] // "Xray 原生默认"),
     ([$rules[]? | select(((.ruleTag // "")|startswith("xrayctl-domain:")) and (.inboundTag // [])==[$tag])] | length | tostring),
     (if $protocol=="vless" then (.settings.clients // [] | length)
      elif $protocol=="socks" and .settings.auth=="password" then ((.settings.accounts // .settings.users // []) | length)
      elif $protocol=="http" then ((.settings.accounts // .settings.users // []) | length)
      else 0 end | tostring)] | @tsv
  ' "$CONFIG_FILE"
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
  choose choice "选择出站协议" "SOCKS5" "HTTP" || return 1
  if [[ $choice == 1 ]]; then protocol=socks; else protocol=http; fi
  prompt_outbound_tag tag "${protocol}-out-$(random_hex 2)" || return 1
  prompt_validated_value address "代理服务器地址" "" validate_proxy_address "地址不能为空或包含空格，请重新输入。" || return 1
  prompt_validated_value port "代理服务器端口" "" validate_port "端口必须是 1-65535，请重新输入。" || return 1
  choose auth "认证方式" "无认证" "用户名密码" || return 1
  settings=$(jq -n --arg address "$address" --argjson port "$port" '{address:$address,port:$port}')
  if [[ $auth == 2 ]]; then
    prompt_value username "用户名" || return 1
    prompt_secret password "密码" || return 1
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
  local __var=$1 include_direct=${2:-0} include_detected_local=${3:-1} __ipvar=${4-} candidate_tag answer local_tag
  local tags=() local_ips=() local_ip_tags=() local_raw_ips=() proxy_tags=() local_tags=()
  ((include_direct == 0)) || tags+=("direct")
  while IFS= read -r candidate_tag; do [[ -z $candidate_tag ]] || proxy_tags+=("$candidate_tag"); done < <(
    jq -r '.outbounds[]?|select((.protocol=="socks" or .protocol=="http") and .tag!="direct" and .tag!="blocked")|.tag' "$CONFIG_FILE"
  )
  tags+=("${proxy_tags[@]}")
  # 检测本地 IP，始终把本机 IPv4/IPv6 放在自建代理出站之后。
  while ((include_detected_local)) && IFS=$'\t' read -r label ip iface; do
    local_tag=$(_freedom_tag_for_ip "$ip")
    local_ip_tags+=("$local_tag")
    local_tags+=("$local_tag")
    local found=0
    for t in "${tags[@]}"; do [[ $t == "$local_tag" ]] && { found=1; break; }; done
    if ((!found)); then tags+=("$local_tag"); fi
    local_ips+=("$label")
    local_raw_ips+=("$ip")
  done < <(ensure_config 2>/dev/null || true; detect_local_ips 2>/dev/null)
  ((${#tags[@]} > 0)) || { warn "没有可选出站。"; return 1; }
  # 只显示 direct、代理标签和本机 IP，不显示协议/地址括号说明。
  local display_labels=()
  for t in "${tags[@]}"; do
    if [[ $t == direct ]]; then
      display_labels+=("direct")
    elif [[ $t =~ ^local- ]]; then
      # 找到对应的原始 IP 标签
      local dlabel="" found=0 i
      for ((i=0; i<${#local_ip_tags[@]}; i++)); do
        [[ ${local_ip_tags[$i]} == "$t" ]] && { dlabel="${local_ips[$i]}"; found=1; break; }
      done
      if ((found)); then display_labels+=("${dlabel%% *}"); else display_labels+=("$t"); fi
    else
      display_labels+=("$t")
    fi
  done
  choose answer "选择出站" "${display_labels[@]}" || return 1
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
    if [[ -n $__ipvar ]]; then
      printf -v "$__ipvar" '%s' "$ip"
    else
      chosen=$(_ensure_freedom_outbound "$ip") || { error "无法创建本地出口。"; return 1; }
    fi
  fi
  printf -v "$__var" '%s' "$chosen"
}

assign_outbound() {
  ensure_config
  local inbound=${1-} outbound=${2-} selected_local_ip="" rule_tag tmp
  [[ -n $inbound ]] || select_inbound inbound '^(vless|socks|http)$' || return
  inbound_exists "$inbound" || die "找不到入站：$inbound"
  inbound_require_supported_configuration "$inbound"
  [[ -n $outbound ]] || select_outbound outbound 1 1 selected_local_ip || return
  ensure_runtime_dependencies outbound-assign; ensure_config
  inbound_exists "$inbound" || die "找不到入站：$inbound"
  inbound_require_supported_configuration "$inbound"
  if [[ -n $selected_local_ip ]]; then
    outbound=$(_ensure_freedom_outbound "$selected_local_ip") || { error "无法创建本地出口。"; return 1; }
  fi
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

remove_inbound_default_outbound() {
  ensure_runtime_dependencies outbound-inbound-unset; ensure_config
  local inbound=${1-} rule_tag tmp
  [[ -n $inbound ]] || select_inbound inbound '^(vless|socks|http)$' || return 1
  inbound_exists "$inbound" || die "找不到入站：$inbound"
  rule_tag="xrayctl-outbound:${inbound}"
  tmp=$(temp_file) || return 1
  jq --arg ruleTag "$rule_tag" '.routing.rules |= map(select((.ruleTag // "")!=$ruleTag))' "$CONFIG_FILE" >"$tmp" || { rm -f "$tmp"; return 1; }
  state_apply_candidate_file "$tmp" apply_candidate || return 1
  info "已取消入站 ${inbound} 的默认出站；未设置用户默认出站的用户将使用 Xray 原生默认出站。"
}

# User routing is stored in the same Xray routing.rules array as the inbound
# rules. Keep these functions next to the existing domain rule implementation
# so template reconciliation and outbound deletion can recognize the tags.
_outbound_user_identity() {
  local __var=$1 inbound=$2 label=$3 protocol resolved_identity identity_count
  protocol=$(jq -r --arg inbound "$inbound" '.inbounds[]? | select(.tag==$inbound) | .protocol' "$CONFIG_FILE") || return 1
  case $protocol in
    vless)
      resolved_identity=$(jq -r --arg inbound "$inbound" --arg label "$label" \
        '.inbounds[]? | select(.tag==$inbound) | .settings.clients[]? | select((.xrayctlLabel // .email)==$label) | .email // empty' "$CONFIG_FILE") || return 1
      [[ -n $resolved_identity ]] || { warn "该 VLESS 用户没有 Xray email 身份，无法安全添加用户路由。"; return 1; }
      ;;
    socks)
      jq -e --arg inbound "$inbound" '.inbounds[]? | select(.tag==$inbound and .protocol=="socks" and .settings.auth=="password")' "$CONFIG_FILE" >/dev/null || { warn "无认证 SOCKS5 入站不支持用户路由。"; return 1; }
      resolved_identity=$(jq -r --arg inbound "$inbound" --arg label "$label" '.inbounds[]? | select(.tag==$inbound) | (.settings.accounts // .settings.users // [])[]? | select(.user==$label) | .user' "$CONFIG_FILE") || return 1
      ;;
    http)
      resolved_identity=$(jq -r --arg inbound "$inbound" --arg label "$label" '.inbounds[]? | select(.tag==$inbound) | (.settings.accounts // .settings.users // [])[]? | select(.user==$label) | .user' "$CONFIG_FILE") || return 1
      ;;
    *) warn "${protocol:-该协议} 入站不支持用户级出站规则。"; return 1;;
  esac
  [[ -n $resolved_identity ]] || { warn "找不到入站 ${inbound} 的用户 ${label}。"; return 1; }
  identity_count=$(jq -r --arg inbound "$inbound" --arg identity "$resolved_identity" '
    [.inbounds[]? | select(.tag==$inbound) |
      if .protocol=="vless" then [.settings.clients[]? | select(.email==$identity)]
      else [(.settings.accounts // .settings.users // [])[]? | select(.user==$identity)] end] | flatten | length
  ' "$CONFIG_FILE") || return 1
  [[ $identity_count == 1 ]] || { warn "该入站中的用户身份不唯一，拒绝创建可能同时匹配多个用户的规则。"; return 1; }
  printf -v "$__var" '%s' "$resolved_identity"
}

_outbound_user_rules_safe() {
  local inbound=$1
  # Xray routing is first-match. Refuse to guess what an unowned rule means,
  # and refuse managed rules whose current order would make user rules bypass
  # quota/security rules or put the inbound fallback before public domains.
  jq -e --arg inbound "$inbound" '
    def tag: (.ruleTag // "");
    def scoped:
      ((.inboundTag|type)!="array" or ((.inboundTag|index($inbound))!=null));
    def known_managed:
      (((tag|startswith("xrayctl-user-limit:")) or (tag|startswith("xrayctl-user-outbound:")) or
        (tag|startswith("xrayctl-user-domain:")) or (tag|startswith("xrayctl-domain:")) or
        (tag==("xrayctl-outbound:"+$inbound))) and .inboundTag==[$inbound]) or
      (tag|startswith("xrayctl-security:")) or
      (.outboundTag=="blocked" and ((.ip // [])==["geoip:private"] or (.protocol // [])==["bittorrent"]));
    def public_rule:
      (tag|startswith("xrayctl-domain:")) and .inboundTag==[$inbound];
    def inbound_fallback:
      tag==("xrayctl-outbound:"+$inbound) and .inboundTag==[$inbound];
    def protected_rule:
      (((tag|startswith("xrayctl-user-limit:")) and .inboundTag==[$inbound]) or
       (tag|startswith("xrayctl-security:")) or
       (.outboundTag=="blocked" and ((.ip // [])==["geoip:private"] or (.protocol // [])==["bittorrent"])));
    (.routing.rules // []) as $rules |
    ([ $rules[] | select((known_managed|not) and scoped)]) as $unknown |
    ([range(0;($rules|length)) as $i | select($rules[$i]|public_rule) | $i]) as $public |
    ([range(0;($rules|length)) as $i | select($rules[$i]|inbound_fallback) | $i]) as $fallback |
    ([range(0;($rules|length)) as $i | select($rules[$i]|protected_rule) | $i]) as $protected |
    ([($public[0] // ($rules|length)),($fallback[0] // ($rules|length))] | min) as $boundary |
    (($unknown|length)==0) and
    (($public|length)==0 or ($fallback|length)==0 or all($public[]; . < $fallback[0])) and
    all($protected[]; . < $boundary)
  ' "$CONFIG_FILE" >/dev/null || {
    warn "该入站存在无法安全调整的自定义路由或托管规则顺序；为保留现有语义，拒绝修改用户路由。"
    return 1
  }
}

_outbound_user_rebuild_rules() {
  local input=$1 output=$2 inbound=$3
  jq --arg inbound "$inbound" '
    def xrayctl_domain_rule:
      type=="object" and ((.ruleTag // "")|type)=="string" and ((.ruleTag // "")|startswith("xrayctl-domain:"));
    def xrayctl_user_outbound_rule:
      ((.ruleTag // "")|type)=="string" and ((.ruleTag // "")|startswith("xrayctl-user-outbound:"));
    def xrayctl_user_domain_rule:
      ((.ruleTag // "")|type)=="string" and ((.ruleTag // "")|startswith("xrayctl-user-domain:"));
    def is_personal:
      xrayctl_user_domain_rule and ((.inboundTag // [])==[$inbound]);
    def is_managed_default:
      xrayctl_user_outbound_rule and ((.inboundTag // [])==[$inbound]);
    def is_public:
      xrayctl_domain_rule and ((.inboundTag // [])==[$inbound]);
    def is_inbound_default:
      ((.ruleTag // "")==("xrayctl-outbound:"+$inbound));
    def specificity:
      (.domain[0] // "") as $d |
      (if ($d|startswith("full:")) then $d[5:] elif ($d|startswith("domain:")) then $d[7:] else "" end) as $name |
      [-(($name|split(".")|length)), (if ($d|startswith("full:")) then 0 else 1 end), $name];
    .routing=(.routing // {domainStrategy:"IPIfNonMatch",rules:[]}) |
    (.routing.rules // []) as $rules |
    ([$rules[] | select(is_personal)] | sort_by(specificity)) as $personal |
    ([$rules[] | select(is_managed_default)]) as $user_defaults |
    [$rules[] | select((is_personal or is_managed_default)|not)] as $base |
    # Keep the established public rules and inbound fallback in place. Put
    # personal domains before public domains and user defaults after them.
    ([$base[]] as $b |
      ([range(0;($b|length)) as $i | select(($b[$i]|is_public) or ($b[$i]|is_inbound_default)) | $i] | .[0] // ($b|length)) as $public_at |
      ([range(0;($b|length)) as $i | select($b[$i]|is_inbound_default) | $i] | .[0] // ($b|length)) as $default_at |
      [$b[0:$public_at][]] + $personal + [$b[$public_at:$default_at][]] + $user_defaults + [$b[$default_at:][]]
    ) as $ordered |
    .routing.rules=$ordered
  ' "$input" >"$output"
}

_outbound_user_commit_if_changed() {
  local candidate=$1 message=$2 current_json candidate_json
  current_json=$(jq -cS . "$CONFIG_FILE") || { rm -f "$candidate"; return 1; }
  candidate_json=$(jq -cS . "$candidate") || { rm -f "$candidate"; return 1; }
  if [[ $current_json == "$candidate_json" ]]; then
    rm -f "$candidate"
    info "$message"
    return 0
  fi
  state_apply_candidate_file "$candidate" apply_candidate
}

outbound_user_default_set() {
  ensure_runtime_dependencies outbound-user-set; ensure_config
  local inbound=${1-} label=${2-} outbound=${3-} identity id existing_count current_outbound candidate tmp
  [[ -n $inbound && -n $label ]] || die "用法：xrayctl outbound user set <入站> <用户> <出站>"
  inbound_exists "$inbound" || die "找不到入站：$inbound"
  inbound_require_supported_configuration "$inbound"
  client_label_exists "$inbound" "$label" || die "找不到入站 ${inbound} 的用户 ${label}。"
  _outbound_user_identity identity "$inbound" "$label" || return 1
  [[ -n $outbound ]] || select_outbound outbound 1 1 || return 1
  outbound_exists "$outbound" || [[ $outbound == direct ]] || die "找不到出站：$outbound"
  id=$(jq -r --arg inbound "$inbound" --arg identity "$identity" '
    [.routing.rules[]? | select(((.ruleTag // "")|startswith("xrayctl-user-outbound:")) and .inboundTag==[$inbound] and .user==[$identity]) | .ruleTag[22:]] | .[0] // empty
  ' "$CONFIG_FILE")
  existing_count=$(jq -r --arg inbound "$inbound" --arg identity "$identity" '
    [.routing.rules[]? | select(((.ruleTag // "")|startswith("xrayctl-user-outbound:")) and .inboundTag==[$inbound] and .user==[$identity])] | length
  ' "$CONFIG_FILE")
  current_outbound=$(jq -r --arg inbound "$inbound" --arg identity "$identity" '
      [.routing.rules[]? | select(((.ruleTag // "")|startswith("xrayctl-user-outbound:")) and .inboundTag==[$inbound] and .user==[$identity]) | .outboundTag][0] // empty
    ' "$CONFIG_FILE")
  if [[ -n $id && $existing_count == 1 && $current_outbound == "$outbound" ]]; then
    info "${inbound} / ${label} 的默认出站已是 ${outbound}。"
    return 0
  fi
  _outbound_user_rules_safe "$inbound" || return 1
  [[ -n $id ]] || id=$(random_hex 12)
  candidate=$(temp_file) || return 1
  jq --arg inbound "$inbound" --arg identity "$identity" --arg outbound "$outbound" \
    --arg ruleTag "xrayctl-user-outbound:${id}" '
    .routing=(.routing // {domainStrategy:"IPIfNonMatch",rules:[]}) |
    .routing.rules=([.routing.rules[]? | select((((.ruleTag // "")|startswith("xrayctl-user-outbound:")) and .inboundTag==[$inbound] and .user==[$identity])|not)] +
      [{type:"field",inboundTag:[$inbound],user:[$identity],outboundTag:$outbound,ruleTag:$ruleTag}])
  ' "$CONFIG_FILE" >"$candidate" || { rm -f "$candidate"; return 1; }
  tmp=$(temp_file) || { rm -f "$candidate"; return 1; }
  _outbound_user_rebuild_rules "$candidate" "$tmp" "$inbound" || { rm -f "$candidate" "$tmp"; return 1; }
  rm -f "$candidate"
  _outbound_user_commit_if_changed "$tmp" "${inbound} / ${label} 的默认出站已是 ${outbound}。" || return 1
  info "已设置 ${inbound} / ${label} 的默认出站为 ${outbound}。"
}

outbound_user_list() {
  ensure_config
  local inbound=${1-} label identity default
  [[ -n $inbound ]] || die "用法：xrayctl outbound user list <入站>"
  inbound_exists "$inbound" || die "找不到入站：$inbound"
  printf '入站：%s | 入站默认：%s\n' "$inbound" "$(jq -r --arg tag "$inbound" '[.routing.rules[]?|select(.ruleTag==("xrayctl-outbound:"+$tag))|.outboundTag][0] // "Xray 原生默认"' "$CONFIG_FILE")"
  while IFS= read -r label; do
    [[ -n $label ]] || continue
    _outbound_user_identity identity "$inbound" "$label" || continue
    default=$(jq -r --arg inbound "$inbound" --arg identity "$identity" '
      [.routing.rules[]? | select(((.ruleTag // "")|startswith("xrayctl-user-outbound:")) and .inboundTag==[$inbound] and .user==[$identity]) | .outboundTag][0] // empty
    ' "$CONFIG_FILE")
    printf '%s\t%s\t%s\t%s\n' "$label" "${default:-继承入站}" "$([[ -z $default ]] && printf 是 || printf 否)" \
      "$(jq -r --arg inbound "$inbound" --arg identity "$identity" '
        [.routing.rules[]? | select(((.ruleTag // "")|startswith("xrayctl-user-domain:")) and .inboundTag==[$inbound] and .user==[$identity])] | length
      ' "$CONFIG_FILE")"
  done < <(jq -r --arg inbound "$inbound" '
    .inbounds[]? | select(.tag==$inbound) |
    if .protocol=="vless" then .settings.clients[]? | (.xrayctlLabel // .email // empty)
    elif .protocol=="socks" and .settings.auth=="password" then (.settings.accounts // .settings.users // [])[]? | .user
    elif .protocol=="http" then (.settings.accounts // .settings.users // [])[]? | .user else empty end
  ' "$CONFIG_FILE")
}

outbound_user_default_unset() {
  ensure_runtime_dependencies outbound-user-unset; ensure_config
  local inbound=${1-} label=${2-} identity tmp
  [[ -n $inbound && -n $label ]] || die "用法：xrayctl outbound user unset <入站> <用户>"
  inbound_exists "$inbound" || die "找不到入站：$inbound"
  client_label_exists "$inbound" "$label" || die "找不到入站 ${inbound} 的用户 ${label}。"
  _outbound_user_identity identity "$inbound" "$label" || return 1
  tmp=$(temp_file) || return 1
  jq --arg inbound "$inbound" --arg identity "$identity" '
    .routing.rules |= map(select(((((.ruleTag // "")|startswith("xrayctl-user-outbound:")) and .inboundTag==[$inbound] and .user==[$identity])|not)))
  ' "$CONFIG_FILE" >"$tmp" || { rm -f "$tmp"; return 1; }
  _outbound_user_commit_if_changed "$tmp" "${inbound} / ${label} 没有独立默认出站。" || return 1
  info "已取消 ${inbound} / ${label} 的独立默认出站。"
}

outbound_user_domain_add() {
  ensure_runtime_dependencies outbound-user-rule-add; ensure_config
  local inbound=${1-} label=${2-} match=${3-} domains_input=${4-} outbound=${5-}
  local identity normalized domain domains_json existing rule_tag rule rules_json='[]' candidate tmp
  local -a domains=()
  [[ -n $inbound && -n $label && -n $match && -n $domains_input && -n $outbound ]] || die "用法：xrayctl outbound user rule add <入站> <用户> <suffix|exact> <域名[,域名...]> <出站>"
  case $match in suffix|exact) ;; *) die "匹配方式只能是 suffix 或 exact。";; esac
  inbound_exists "$inbound" || die "找不到入站：$inbound"
  inbound_require_supported_configuration "$inbound"
  client_label_exists "$inbound" "$label" || die "找不到入站 ${inbound} 的用户 ${label}。"
  _outbound_user_identity identity "$inbound" "$label" || return 1
  outbound_exists "$outbound" || [[ $outbound == direct || $outbound == blocked ]] || die "找不到出站：$outbound"
  normalized=$(_normalize_domain_list "$domains_input") || die "域名格式无效。"
  while IFS= read -r domain; do [[ -n $domain ]] && domains+=("$domain"); done <<<"$normalized"
  domains_json=$(printf '%s\n' "${domains[@]}" | jq -Rsc 'split("\n")|map(select(length>0))|unique') || return 1
  existing=$(jq -r --arg inbound "$inbound" --arg identity "$identity" --arg match "$match" --argjson domains "$domains_json" '
    [.routing.rules[]? | select(((.ruleTag // "")|startswith("xrayctl-user-domain:")) and .inboundTag==[$inbound] and .user==[$identity]) | .domain[0] as $d |
      select(any($domains[]; $d==((if $match=="suffix" then "domain:" else "full:" end)+.))) |
      if $match=="suffix" then $d[7:] else $d[5:] end] | unique | join(",")
  ' "$CONFIG_FILE") || return 1
  [[ -z $existing ]] || { warn "已跳过该用户已有规则：${existing}"; }
  for domain in "${domains[@]}"; do
    [[ ,$existing, != *,${domain},* ]] || continue
    while :; do
      rule_tag="xrayctl-user-domain:$(random_hex 12)"
      if ! jq -e --arg ruleTag "$rule_tag" --argjson rules "$rules_json" \
        '([.routing.rules[]?, $rules[]] | any(.[]?; .ruleTag==$ruleTag))' "$CONFIG_FILE" >/dev/null 2>&1; then break; fi
    done
    rule=$(jq -n --arg inbound "$inbound" --arg identity "$identity" --arg match "$match" \
      --arg domain "$domain" --arg outbound "$outbound" --arg ruleTag "$rule_tag" '
      {type:"field",inboundTag:[$inbound],user:[$identity],
       domain:(if $match=="suffix" then ["domain:"+$domain] else ["full:"+$domain] end),
       outboundTag:$outbound,ruleTag:$ruleTag}') || return 1
    rules_json=$(jq -n -c --argjson rules "$rules_json" --argjson rule "$rule" '$rules+[$rule]') || return 1
  done
  [[ $rules_json != '[]' ]] || { info "没有需要添加的新域名规则。"; return 0; }
  _outbound_user_rules_safe "$inbound" || return 1
  candidate=$(temp_file) || return 1
  jq --argjson rules "$rules_json" '.routing=(.routing // {rules:[]}) | .routing.rules += $rules' \
    "$CONFIG_FILE" >"$candidate" || { rm -f "$candidate"; return 1; }
  tmp=$(temp_file) || { rm -f "$candidate"; return 1; }
  _outbound_user_rebuild_rules "$candidate" "$tmp" "$inbound" || { rm -f "$candidate" "$tmp"; return 1; }
  rm -f "$candidate"
  _outbound_user_commit_if_changed "$tmp" "${inbound} / ${label} 的域名规则没有变化。" >/dev/null || return 1
  info "已更新 ${inbound} / ${label} 的专属域名分流。"
}

outbound_user_domain_list() {
  local inbound=${1-} label=${2-} identity
  ensure_config
  [[ -n $inbound && -n $label ]] || die "用法：xrayctl outbound user rule list <入站> <用户>"
  _outbound_user_identity identity "$inbound" "$label" || return 1
  jq -r --arg inbound "$inbound" --arg identity "$identity" '
    [.routing.rules[]? | select(((.ruleTag // "")|startswith("xrayctl-user-domain:")) and .inboundTag==[$inbound] and .user==[$identity]) |
      [(.domain[0] // ""),(.outboundTag // ""),(.ruleTag // "")]][] | @tsv
  ' "$CONFIG_FILE" \
    | while IFS=$'\t' read -r domain outbound rule_tag; do
        case $domain in full:*) domain=${domain#full:}; printf '精确域名 %s → %s [%s]\n' "$domain" "$outbound" "$rule_tag";;
          domain:*) domain=${domain#domain:}; printf '域名及子域名 %s → %s [%s]\n' "$domain" "$outbound" "$rule_tag";; esac
      done
}

outbound_user_domain_delete() {
  ensure_runtime_dependencies outbound-user-rule-delete; ensure_config
  local inbound=${1-} label=${2-} match=${3-} domains_input=${4-} identity normalized domain domains_json tmp
  [[ -n $inbound && -n $label && -n $match && -n $domains_input ]] || die "用法：xrayctl outbound user rule delete <入站> <用户> <suffix|exact> <域名[,域名...]>"
  case $match in suffix|exact) ;; *) die "匹配方式只能是 suffix 或 exact。";; esac
  _outbound_user_identity identity "$inbound" "$label" || return 1
  normalized=$(_normalize_domain_list "$domains_input") || die "域名格式无效。"
  domains_json=$(printf '%s\n' "$normalized" | jq -Rsc 'split("\n")|map(select(length>0))|unique') || return 1
  tmp=$(temp_file) || return 1
  jq --arg inbound "$inbound" --arg identity "$identity" --arg match "$match" --argjson domains "$domains_json" '
    .routing.rules |= map(. as $rule | select((
      ((.ruleTag // "")|startswith("xrayctl-user-domain:")) and .inboundTag==[$inbound] and .user==[$identity] and
      any($domains[]; . as $domain | $rule.domain[0]==((if $match=="suffix" then "domain:" else "full:" end)+$domain))
    )|not))
  ' "$CONFIG_FILE" >"$tmp" || { rm -f "$tmp"; return 1; }
  _outbound_user_commit_if_changed "$tmp" "${inbound} / ${label} 的域名规则已更新。" || return 1
  info "已删除 ${inbound} / ${label} 指定类型的匹配域名规则。"
}

outbound_user_restore() {
  ensure_runtime_dependencies outbound-user-restore; ensure_config
  local inbound=${1-} label=${2-} identity count defaults rules tmp
  [[ -n $inbound && -n $label ]] || die "用法：xrayctl outbound user restore <入站> <用户>"
  client_label_exists "$inbound" "$label" || die "找不到入站 ${inbound} 的用户 ${label}。"
  _outbound_user_identity identity "$inbound" "$label" || return 1
  defaults=$(jq -r --arg inbound "$inbound" --arg identity "$identity" '
    [.routing.rules[]? | select(((.ruleTag // "")|startswith("xrayctl-user-outbound:")) and .inboundTag==[$inbound] and .user==[$identity]) | .outboundTag] | unique | join(",")
  ' "$CONFIG_FILE")
  rules=$(jq -r --arg inbound "$inbound" --arg identity "$identity" '
    [.routing.rules[]? | select(((.ruleTag // "")|startswith("xrayctl-user-domain:")) and .inboundTag==[$inbound] and .user==[$identity]) |
      if (.domain[0]|startswith("full:")) then .domain[0][5:] else .domain[0][7:] end] | unique | join(",")
  ' "$CONFIG_FILE")
  printf '即将删除用户 %s 的独立默认出站：%s\n' "$label" "${defaults:-无}"
  printf '即将删除用户 %s 的专属域名规则：%s\n' "$label" "${rules:-无}"
  confirm "恢复继承入站规则？" N || return 0
  tmp=$(temp_file) || return 1
  jq --arg inbound "$inbound" --arg identity "$identity" '
    .routing.rules |= map(select((((((.ruleTag // "")|startswith("xrayctl-user-outbound:")) or ((.ruleTag // "")|startswith("xrayctl-user-domain:"))) and .inboundTag==[$inbound] and .user==[$identity])|not)))
  ' "$CONFIG_FILE" >"$tmp" || { rm -f "$tmp"; return 1; }
  _outbound_user_commit_if_changed "$tmp" "${inbound} / ${label} 已继承入站规则。" || return 1
  info "${inbound} / ${label} 已恢复继承入站路由。"
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
  local config=${1:-$CONFIG_FILE} id
  while true; do
    id=$(random_hex 4)
    if ! jq -e --arg ruleTag "xrayctl-domain:${id}" \
      '[.routing.rules[]?|select(.ruleTag==$ruleTag)]|length>0' "$config" >/dev/null 2>&1; then
      printf '%s' "$id"
      return 0
    fi
  done
}

list_domain_rules() {
  ensure_config
  local inbound=${1-} context=${2-} rows group_inbound="" number=0 match domain outbound group_start display display_match hide_templates=0
  [[ -z $inbound ]] || inbound_exists "$inbound" || die "找不到入站：$inbound"
  [[ $context == --menu ]] && hide_templates=1
  rows=$(jq -r --arg inbound "$inbound" --arg hideTemplates "$hide_templates" "$(_xrayctl_domain_rule_jq)
    ([.routing.rules[]? |
       select(xrayctl_domain_rule and (\$hideTemplates!=\"1\" or (.template // \"\")==\"\")) |
      (if (.inboundTag|type)==\"array\" then (.inboundTag[0] // \"?\") else \"?\" end) as \$rule_inbound |
      (if (.domain|type)==\"array\" then (.domain[0] // \"\") else \"\" end) as \$domain_value |
      (if (\$domain_value|startswith(\"full:\")) then \"exact\" elif (\$domain_value|startswith(\"domain:\")) then \"suffix\" else \"?\" end) as \$match |
      (if \$match==\"exact\" then \$domain_value[5:] elif \$match==\"suffix\" then \$domain_value[7:] else \$domain_value end) as \$domain |
      [\$rule_inbound,\$match,\$domain,(.outboundTag // \"?\")]] ) as \$rows |
    [.inbounds[].tag] as \$inbound_order |
    \$inbound_order[] as \$group |
    select(\$inbound==\"\" or \$group==\$inbound) |
    (\$rows |
      map(select(.[0]==\$group)) |
      sort_by([(if .[1]==\"suffix\" then 0 else 1 end), .[3]]) |
      group_by([.[1], .[3]])[] |
      sort_by([(.[2] | ascii_downcase), .[2]]) |
      to_entries[] |
      .value + [(if .key==0 then \"first\" else \"\" end)]
    ) | @tsv" "$CONFIG_FILE")
  heading "域名分流规则"
  [[ -n $rows ]] || { info "还没有直接域名规则。"; return 0; }
  while IFS=$'\t' read -r inbound match domain outbound group_start; do
    [[ -n $inbound ]] || continue
    if [[ $inbound != "$group_inbound" ]]; then
      group_inbound=$inbound
      number=0
      [[ $context == --menu ]] || printf '\n%s入站：%s%s\n' "$C_BOLD$C_CYAN" "$group_inbound" "$C_RESET"
    fi
    if [[ $group_start == first ]]; then
      [[ $match == suffix ]] && display_match="子域名" || display_match="精确"
      display=$(_outbound_display_name "$outbound")
      printf '\n%s%s%s → %s%s%s\n' \
        "$C_BOLD$C_CYAN" "$display_match" "$C_RESET" \
        "$C_BOLD$C_GREEN" "$display" "$C_RESET"
    fi
    ((number+=1))
    print_table_cell "$number" 4; printf '  '
    print_table_cell "$domain" 24; printf '\n'
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
  local inbound=${1-} match=${2-} domain=${3-} outbound=${4-} prompt_details=${5-}
  local choice normalized_domains rule_tag new_rule tmp candidate existing_domains existing_domains_json domains_json
  local -a domains=()
  local cli=0
  if [[ $prompt_details == --prompt ]]; then
    [[ -n $inbound && -z $match && -z $domain && -z $outbound ]] || die "内部调用参数无效。"
    inbound_exists "$inbound" || die "找不到入站：$inbound"
    inbound_require_supported_configuration "$inbound"
  elif [[ -n $inbound || -n $match || -n $domain || -n $outbound ]]; then
    cli=1
    [[ -n $inbound && -n $match && -n $domain && -n $outbound ]] || \
      die "用法：xrayctl outbound rule add <入站> <suffix|exact> <域名[,域名...]> <出站>"
    inbound_exists "$inbound" || die "找不到入站：$inbound"
    inbound_require_supported_configuration "$inbound"
    case $match in suffix|exact) ;; *) die "匹配方式只能是 suffix 或 exact。";; esac
    normalized_domains=$(_normalize_domain_list "$domain") || die "域名格式无效。"
    outbound_exists "$outbound" || [[ $outbound == direct ]] || die "找不到出站：$outbound"
  else
    select_inbound inbound '^(vless|socks|http)$' || return
  fi
  if ((cli == 0)); then
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

  domains_json=$(printf '%s\n' "${domains[@]}" | jq -Rsc '
    split("\n") | map(select(length > 0)) |
    reduce .[] as $domain ([]; if index($domain) then . else . + [$domain] end)')
  existing_domains_json=$(jq -c --arg inbound "$inbound" --arg match "$match" --argjson domains "$domains_json" "$(_xrayctl_domain_rule_jq)
    [.routing.rules[]? |
      select(xrayctl_domain_rule and ((.inboundTag // []) == [\$inbound])) |
      .domain[0] as \$rule_domain |
      select(any(\$domains[]; \$rule_domain == ((if \$match==\"suffix\" then \"domain:\" else \"full:\" end) + .))) |
      if \$match==\"suffix\" then \$rule_domain[7:] else \$rule_domain[5:] end] |
      unique" "$CONFIG_FILE")
  existing_domains=$(jq -r 'join(",")' <<<"$existing_domains_json")
  if [[ -n $existing_domains ]]; then
    warn "已跳过已有域名规则：${inbound} ${match} ${existing_domains}。"
  fi

  domains=()
  while IFS= read -r domain; do
    [[ -n $domain ]] && domains+=("$domain")
  done < <(jq -r --argjson existing "$existing_domains_json" '
    .[] as $domain | select(($existing | index($domain)) == null) | $domain' <<<"$domains_json")
  if ((${#domains[@]} == 0)); then
    info "没有需要添加的新域名规则。"
    return 0
  fi

  candidate=$(temp_file)
  cp "$CONFIG_FILE" "$candidate"
  for domain in "${domains[@]}"; do
    rule_tag="xrayctl-domain:$(generate_domain_rule_id "$candidate")"
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
      select(((\$rules[\$i].ruleTag // \"\") == (\"xrayctl-outbound:\"+\$inbound)) or
        (((\$rules[\$i].ruleTag // \"\")|startswith(\"xrayctl-user-outbound:\")) and ((\$rules[\$i].inboundTag // [])==[\$inbound]))) |
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
      end]" "$candidate" >"$tmp"
    rm -f "$candidate"
    candidate=$tmp
  done
  state_apply_candidate_file "$candidate" apply_candidate >/dev/null || return
  info "已添加域名规则：${inbound} ${match}（${#domains[@]} 条） -> ${outbound}。"
}

delete_domain_rule() {
  ensure_runtime_dependencies outbound-rule-delete; ensure_config
  local inbound=${1-} match=${2-} domain=${3-} scope=${4-} rows choice selected_inbound tmp selection token idx
  local row_inbound row_match row_domain row_outbound template_owned
  [[ -n $scope ]] || scope=--direct-only
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

  rows=$(jq -r --arg inbound "${selected_inbound:-$inbound}" --arg scope "$scope" "$(_xrayctl_domain_rule_jq)
    [.routing.rules[]? |
       select(xrayctl_domain_rule and (\$scope!=\"--direct-only\" or (.template // \"\")==\"\")) |
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
    if ((matching_count == 0)); then
      template_owned=$(jq -r --arg inbound "$selected_inbound" --arg match "$match" --arg domain "$domain" "$(_xrayctl_domain_rule_jq)
        [.routing.rules[]? |
          select(xrayctl_domain_rule and (.inboundTag // [])==[\$inbound] and ((.template // \"\") != \"\")) |
          select(.domain == [(if \$match==\"suffix\" then \"domain:\" else \"full:\" end) + \$domain])] | length" "$CONFIG_FILE")
      if ((template_owned > 0)); then
        die '该域名规则由模板管理，请在“管理模板”中调整模板或移除模板。'
      fi
      die "找不到域名规则：${selected_inbound} ${match} ${domain}"
    fi
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
      rows=$(jq -r --arg inbound "$selected_inbound" --arg scope "$scope" "$(_xrayctl_domain_rule_jq)
        [.routing.rules[]? | select(xrayctl_domain_rule and (.inboundTag // [])==[\$inbound]) |
         select(\$scope!=\"--direct-only\" or (.template // \"\")==\"\") |
         (if .domain[0]|startswith(\"full:\") then \"exact\" else \"suffix\" end) as \$match |
         (if \$match==\"exact\" then .domain[0][5:] else .domain[0][7:] end) as \$domain |
         [\$match,\$domain,(.outboundTag // \"?\")]] as \$rules |
        (\$rules |
          sort_by([(if .[0]==\"suffix\" then 0 else 1 end), .[2]]) |
          group_by([.[0], .[2]])[] |
          sort_by([(.[1] | ascii_downcase), .[1]])[]
        ) | @tsv" "$CONFIG_FILE")
    else
      rows=$(jq -r --arg inbound "$selected_inbound" --arg scope "$scope" "$(_xrayctl_domain_rule_jq)
        [.routing.rules[]? | select(xrayctl_domain_rule and (.inboundTag // [])==[\$inbound]) |
         select(\$scope!=\"--direct-only\" or (.template // \"\")==\"\") |
         (if .domain[0]|startswith(\"full:\") then \"exact\" else \"suffix\" end) as \$match |
         (if \$match==\"exact\" then .domain[0][5:] else .domain[0][7:] end) as \$domain |
         [\$match,\$domain,(.outboundTag // \"?\")]] as \$rules |
        (\$rules |
          sort_by([(if .[0]==\"suffix\" then 0 else 1 end), .[2]]) |
          group_by([.[0], .[2]])[] |
          sort_by([(.[1] | ascii_downcase), .[1]])[]
        ) | @tsv" "$CONFIG_FILE")
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
      read -r -p '请选择要删除的规则（支持 1,3,2）: ' selection || { cancel_input; return 1; }
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

_meta_template_remove_outbound_bindings() {
  local current=$1 candidate=$2 outbound=$3
  jq --arg tag "$outbound" '
    .domainTemplates = (.domainTemplates // {templates:[],bindings:[]}) |
    .domainTemplates.bindings = [.domainTemplates.bindings[]? | select(.outbound != $tag)]' \
    "$current" >"$candidate"
}

delete_outbound() {
  ensure_runtime_dependencies outbound-delete; ensure_config; ensure_meta
  local tag=${1-} tmp default_refs domain_refs user_default_refs user_domain_refs custom_refs binding_refs meta_candidate=""
  [[ -n $tag ]] || select_outbound tag 0 0 || return
  outbound_exists "$tag" || die "找不到出站：$tag"
  [[ $tag != direct && $tag != blocked ]] || { warn "${tag} 出站不能删除。"; return 0; }

  default_refs=$(jq -r --arg tag "$tag" '
    [.routing.rules[]? |
      select(.outboundTag==$tag and (.ruleTag|type)=="string" and (.ruleTag|startswith("xrayctl-outbound:")))] | length' "$CONFIG_FILE")
  domain_refs=$(jq -r --arg tag "$tag" '
    [.routing.rules[]? |
      select(.outboundTag==$tag and (.ruleTag|type)=="string" and (.ruleTag|startswith("xrayctl-domain:")))] | length' "$CONFIG_FILE")
  user_default_refs=$(jq -r --arg tag "$tag" '[.routing.rules[]? | select(.outboundTag==$tag and ((.ruleTag // "")|startswith("xrayctl-user-outbound:")))] | length' "$CONFIG_FILE")
  user_domain_refs=$(jq -r --arg tag "$tag" '[.routing.rules[]? | select(.outboundTag==$tag and ((.ruleTag // "")|startswith("xrayctl-user-domain:")))] | length' "$CONFIG_FILE")
  custom_refs=$(jq -r --arg tag "$tag" '
    [.routing.rules[]? |
      select(.outboundTag==$tag) |
      select(
        ((.ruleTag|type)!="string") or
        (((.ruleTag|startswith("xrayctl-outbound:"))|not) and
         ((.ruleTag|startswith("xrayctl-domain:"))|not) and
         ((.ruleTag|startswith("xrayctl-user-outbound:"))|not) and
         ((.ruleTag|startswith("xrayctl-user-domain:"))|not))
      )] | length' "$CONFIG_FILE")
  binding_refs=$(jq -r --arg tag "$tag" '
    [.domainTemplates.bindings[]? | select(.outbound==$tag)] | length' "$META_FILE")
  if ((custom_refs > 0)); then
    die "该出站仍被自定义路由规则引用，请先在完整配置中处理。"
  fi
  if ((default_refs > 0 || domain_refs > 0 || user_default_refs > 0 || user_domain_refs > 0 || binding_refs > 0)); then
    warn "出站 ${tag} 仍被引用：入站默认 ${default_refs}，入站域名 ${domain_refs}，用户默认 ${user_default_refs}，用户域名 ${user_domain_refs}，模板绑定 ${binding_refs}。"
    confirm "继续删除出站 ${tag}？" N || return 0
  else
    confirm "删除出站 ${tag}？" N || return 0
  fi
  tmp=$(temp_file)
  jq --arg tag "$tag" '
    .outbounds |= map(select(.tag!=$tag)) |
    .routing.rules=((.routing.rules // []) | map(select(.outboundTag!=$tag)))' "$CONFIG_FILE" >"$tmp"
  if ((binding_refs > 0)); then
    meta_candidate=$(temp_file)
    _meta_template_remove_outbound_bindings "$META_FILE" "$meta_candidate" "$tag" || {
      rm -f "$tmp" "$meta_candidate"
      return 1
    }
    state_commit_candidate_with_metadata "$tmp" "$meta_candidate" || return
    rm -f "$meta_candidate"
  else
    state_apply_candidate_file "$tmp" apply_candidate || return
  fi
  info "出站 ${tag} 已删除。"
}
