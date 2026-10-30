#!/usr/bin/env bash
# --- Missing function definitions for xrayctl ---
# These functions are called but never defined in the script.

# Convert an IP address to a freedom outbound tag name.
# Replaces dots and colons with hyphens, prefixed with "local-".
_freedom_tag_for_ip() {
  local ip=$1
  printf 'local-%s' "${ip//[.:]/-}"
}

# Check whether an outbound tag exists in the config.
outbound_exists() {
  jq -e --arg tag "$1" '.outbounds[]? | select(.tag==$tag)' "$CONFIG_FILE" >/dev/null 2>&1
}

# List domain templates with exact and suffix counts (TSV).
list_domain_templates() {
  ensure_meta
  jq -r '.domainTemplates.templates[]? | [.name, ((.exact // []) | length), ((.suffix // []) | length)] | @tsv' "$META_FILE"
}

# Check whether a domain template exists in metadata.
domain_template_exists() {
  jq -e --arg name "$1" '.domainTemplates.templates[]? | select(.name==$name)' "$META_FILE" >/dev/null 2>&1
}

# Return a human-readable display name for an outbound tag.
# For local-* tags, show the sendThrough IP; otherwise return the tag as-is.
_outbound_display_name() {
  local tag=$1
  if [[ $tag =~ ^local- ]]; then
    local ip
    ip=$(jq -r --arg tag "$tag" '(.outbounds[]? | select(.tag==$tag) | .sendThrough) // empty' "$CONFIG_FILE" 2>/dev/null)
    if [[ -n $ip ]]; then
      printf '%s' "$ip"
    else
      printf '%s' "$tag"
    fi
  else
    printf '%s' "$tag"
  fi
}

# Return a display name for the outbound overview table.
# Same as _outbound_display_name but may include extra context for the overview.
_outbound_overview_display_name() {
  _outbound_display_name "$1"
}

# Format address:port for display. Wraps IPv6 in brackets.
_outbound_endpoint_display() {
  local address=$1 port=$2
  if [[ $address == *:* ]]; then
    printf '[%s]:%s' "$address" "$port"
  else
    printf '%s:%s' "$address" "$port"
  fi
}

# Stage a local (freedom/sendThrough) outbound into a candidate config file.
# If ip is empty, this is a no-op (the outbound already exists or is not local).
_stage_local_outbound() {
  local candidate=$1 ip=$2
  [[ -n $ip ]] || return 0
  local tag
  tag=$(_freedom_tag_for_ip "$ip")
  # Add or update the freedom outbound with the given sendThrough IP
  local tmp
  tmp=$(temp_file) || return 1
  jq --arg tag "$tag" --arg ip "$ip" '
    if any(.outbounds[]?; .tag==$tag)
    then .outbounds = [.outbounds[] | if .tag==$tag then .sendThrough=$ip else . end]
    else .outbounds += [{tag:$tag, protocol:"freedom", sendThrough:$ip, settings:{domainStrategy:"UseIP"}}]
    end
  ' "$candidate" >"$tmp" || { rm -f "$tmp"; return 1; }
  mv "$tmp" "$candidate"
}

# Add a new domain template to metadata.
# Called as: _meta_template_add "$META_FILE" "$meta_candidate" "$name"
_meta_template_add() {
  local current=$1 candidate=$2 name=$3
  jq --arg name "$name" '
    .domainTemplates.templates += [{name:$name, exact:[], suffix:[]}]
  ' "$current" >"$candidate"
}

# Add domains to a template in metadata.
# Called as: _meta_template_domains_add "$META_FILE" "$meta_candidate" "$name" "$match" "$domains_json"
_meta_template_domains_add() {
  local current=$1 candidate=$2 name=$3 match=$4 domains_json=$5
  jq --arg name "$name" --arg match "$match" --argjson domains "$domains_json" '
    .domainTemplates.templates = [
      .domainTemplates.templates[]? |
      if .name==$name then
        if $match=="exact" then .exact = (.exact + $domains | unique)
        else .suffix = (.suffix + $domains | unique) end
      else . end
    ]
  ' "$current" >"$candidate"
}

# Delete domains from a template in metadata.
# Called as: _meta_template_domains_delete "$META_FILE" "$meta_candidate" "$name" "$match" "$domains_json"
_meta_template_domains_delete() {
  local current=$1 candidate=$2 name=$3 match=$4 domains_json=$5
  jq --arg name "$name" --arg match "$match" --argjson domains "$domains_json" '
    .domainTemplates.templates = [
      .domainTemplates.templates[]? |
      if .name==$name then
        if $match=="exact" then .exact = [.exact[]? | select(. as $d | $domains | index($d) | not)]
        else .suffix = [.suffix[]? | select(. as $d | $domains | index($d) | not)] end
      else . end
    ]
  ' "$current" >"$candidate"
}
_rebuild_user_template_bindings_config() {
  local __var=$1 metadata=$2 candidate
  candidate=$(temp_file) || return 1
  _rebuild_user_template_config "$CONFIG_FILE" "$candidate" "$metadata" || { rm -f "$candidate"; return 1; }
  printf -v "$__var" '%s' "$candidate"
}

create_domain_template() {
  ensure_runtime_dependencies outbound-template-create; ensure_config; ensure_meta
  local name
  while true; do
    prompt_validated_value name "模板名称" "" validate_tag "模板名称只能包含字母、数字、点、下划线和横线。" || return 0
    if domain_template_exists "$name"; then
      warn "模板已存在：${name}，请重新输入。"
      continue
    fi
    break
  done
  state_commit_metadata _meta_template_add "$name" || return 1
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
    XRAYCTL_QUIET_CONFIG_APPLIED=1 state_commit_candidate_with_metadata "$config_candidate" "$meta_candidate" || {
      rm -f "$config_candidate" "$meta_candidate"
      return 1
    }
    rm -f "$config_candidate" "$meta_candidate"
  fi
  info "$message"
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
  _rebuild_user_template_bindings_config config_candidate "$meta_candidate" || {
    rm -f "$meta_candidate"
    return 1
  }
  _commit_template_change "$config_candidate" "$meta_candidate" "模板 ${name} 已更新，已同步到已应用该模板的用户。"
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
  _rebuild_user_template_bindings_config config_candidate "$meta_candidate" || {
    rm -f "$meta_candidate"
    return 1
  }
  _commit_template_change "$config_candidate" "$meta_candidate" "模板 ${name} 已更新，已同步到应用该模板的用户。"
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
      (.routing.rules // []) as $rules | (.outbounds[0].tag // "未设置") as $native |
      .inbounds | to_entries[] |
      (.key+1) as $number | .value.tag as $tag |
      [$number,$tag,([$rules[]? | select((.ruleTag // "")==("xrayctl-outbound:"+$tag)) | .outboundTag][0] // $native)] | @tsv' "$CONFIG_FILE" \
      | while IFS=$'\t' read -r number tag outbound; do
          local display; display=$(_outbound_overview_display_name "$outbound")
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
  printf '入站\t默认出站\t用户数\n'
  jq -r '
    (.routing.rules // []) as $rules | (.outbounds[0].tag // "direct") as $native | (.outbounds // []) as $outbounds |
    .inbounds[]? | select(.protocol=="vless" or .protocol=="socks" or .protocol=="http") |
    .tag as $tag | .protocol as $protocol |
    [$tag,
     (([$rules[]? | select((.ruleTag // "")==("xrayctl-outbound:"+$tag)) | .outboundTag][0] // $native) as $route |
       ([$outbounds[]? | select(.tag==$route) | .sendThrough][0] // $route)),
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
  XRAYCTL_QUIET_CONFIG_APPLIED=1 state_apply_candidate_file "$tmp" apply_candidate || return
  info "出站 ${tag} 已添加。"
}

select_outbound() {
  local __var=$1 include_direct=${2:-0} include_detected_local=${3:-1} __ipvar=${4-} include_blocked=${5:-0} candidate_tag answer local_tag
  local label ip iface t i
  local tags=() local_ips=() local_ip_tags=() local_raw_ips=() proxy_tags=() local_tags=()
  ((include_direct == 0)) || tags+=("direct")
  ((include_blocked == 0)) || tags+=("blocked")
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
  local chosen="${tags[$((answer-1))]}" ip=""
  for ((i=0; i<${#local_ip_tags[@]}; i++)); do
    [[ ${local_ip_tags[$i]} == "$chosen" ]] && { ip="${local_raw_ips[$i]}"; break; }
  done
  if [[ -n $ip ]]; then
    [[ -n $__ipvar ]] || { error "本机出站需要随路由配置一起保存。"; return 1; }
    printf -v "$__ipvar" '%s' "$ip"
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
  [[ -n $selected_local_ip ]] || outbound_exists "$outbound" || [[ $outbound == direct ]] || die "找不到出站：$outbound"
  rule_tag="xrayctl-outbound:${inbound}"
  tmp=$(temp_file)
  jq --arg inbound "$inbound" --arg outbound "$outbound" --arg ruleTag "$rule_tag" '
    .routing=(.routing // {domainStrategy:"IPIfNonMatch",rules:[]}) |
    .routing.rules=(
      (.routing.rules // []) as $rules |
      if any($rules[]; (.ruleTag // "") == $ruleTag) then
        [ $rules[] | if (.ruleTag // "") == $ruleTag then .outboundTag=$outbound else . end ]
      else $rules + [{type:"field",inboundTag:[$inbound],outboundTag:$outbound,ruleTag:$ruleTag}] end
    )' "$CONFIG_FILE" >"$tmp"
  _stage_local_outbound "$tmp" "$selected_local_ip" || { rm -f "$tmp"; return 1; }
  XRAYCTL_QUIET_CONFIG_APPLIED=1 state_apply_candidate_file "$tmp" apply_candidate || return
  info "入站 ${inbound} 已使用出站 $(_outbound_display_name "$outbound")。"
}

remove_inbound_default_outbound() {
  ensure_runtime_dependencies outbound-inbound-unset; ensure_config
  local inbound=${1-} rule_tag tmp
  [[ -n $inbound ]] || select_inbound inbound '^(vless|socks|http)$' || return 1
  inbound_exists "$inbound" || die "找不到入站：$inbound"
  rule_tag="xrayctl-outbound:${inbound}"
  tmp=$(temp_file) || return 1
  jq --arg ruleTag "$rule_tag" '.routing.rules |= map(select((.ruleTag // "")!=$ruleTag))' "$CONFIG_FILE" >"$tmp" || { rm -f "$tmp"; return 1; }
  XRAYCTL_QUIET_CONFIG_APPLIED=1 state_apply_candidate_file "$tmp" apply_candidate || return 1
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
    # Preserve legacy inbound domain rules and the inbound fallback. Place
    # user domain rules before them and user defaults after them.
    ([$base[]] as $b |
      ([range(0;($b|length)) as $i | select(($b[$i]|is_public) or ($b[$i]|is_inbound_default)) | $i] | .[0] // ($b|length)) as $public_at |
      ([range(0;($b|length)) as $i | select($b[$i]|is_inbound_default) | $i] | .[0] // ($b|length)) as $default_at |
      [$b[0:$public_at][]] + $personal + [$b[$public_at:$default_at][]] + $user_defaults + [$b[$default_at:][]]
    ) as $ordered |
    .routing.rules=$ordered
  ' "$input" >"$output"
}

# User template bindings are metadata; generated rules remain scoped to one
# inbound and one Xray identity. Direct user rules take precedence on overlap.
_rebuild_user_template_config() {
  local input=$1 output=$2 metadata=$3 inbound tmp current
  while IFS= read -r inbound; do
    [[ -z $inbound ]] || _outbound_user_rules_safe "$inbound" || return 1
  done < <(jq -r --slurpfile meta "$metadata" '
    ([.routing.rules[]? | select((.template // "")!="" and ((.ruleTag // "")|startswith("xrayctl-user-domain:"))) | .inboundTag[0]] +
     [$meta[0].domainTemplates.userBindings[]?.inbound]) | unique[]' "$input")
  tmp=$(temp_file) || return 1
  jq --slurpfile meta "$metadata" '
    (.routing.rules // []) as $old |
    [$old[] | select((((.ruleTag // "")|startswith("xrayctl-user-domain:")) and (.template // "")!="")|not)] as $base |
    ([ $meta[0].domainTemplates.userBindings[]? as $b |
      ($meta[0].domainTemplates.templates[]? | select(.name==$b.template)) as $t |
      (($t.exact[]? | "full:"+.), ($t.suffix[]? | "domain:"+.)) as $domain |
      {inbound:$b.inbound,user:$b.user,domain:$domain,template:$b.template,outbound:$b.outbound}
    ] | group_by([.inbound,.user,.domain]) | map(.[-1])) as $desired |
    .routing=(.routing // {domainStrategy:"IPIfNonMatch",rules:[]}) |
    .routing.rules=($base + [ $desired[] as $d |
      select(any($base[]; ((.ruleTag // "")|startswith("xrayctl-user-domain:")) and .inboundTag==[$d.inbound] and .user==[$d.user] and .domain==[$d.domain])|not) |
      {type:"field",inboundTag:[$d.inbound],user:[$d.user],domain:[$d.domain],outboundTag:$d.outbound,
       ruleTag:("xrayctl-user-domain:template:"+([$d.inbound,$d.user,$d.domain]|@json|@base64)),template:$d.template}
    ])' "$input" >"$tmp" || { rm -f "$tmp"; return 1; }
  current=$tmp
  while IFS= read -r inbound; do
    [[ -n $inbound ]] || continue
    tmp=$(temp_file) || { rm -f "$current"; return 1; }
    _outbound_user_rebuild_rules "$current" "$tmp" "$inbound" || { rm -f "$current" "$tmp"; return 1; }
    rm -f "$current"
    current=$tmp
  done < <(jq -r --slurpfile meta "$metadata" '
    ([.routing.rules[]? | select((.template // "")!="" and ((.ruleTag // "")|startswith("xrayctl-user-domain:"))) | .inboundTag[0]] +
     [$meta[0].domainTemplates.userBindings[]?.inbound]) | unique[]' "$input")
  cp "$current" "$output"
  rm -f "$current"
}

user_template_apply() {
  ensure_runtime_dependencies outbound-user-template; ensure_config; ensure_meta
  local inbound=$1 label=$2 name=$3 outbound=$4 local_ip=${5-} identity meta_candidate candidate display_outbound
  inbound_require_supported_configuration "$inbound"
  _outbound_user_identity identity "$inbound" "$label" || return 1
  domain_template_exists "$name" || die "找不到模板：$name"
  [[ -n $local_ip ]] || outbound_exists "$outbound" || die "找不到出站：$outbound"
  _outbound_user_rules_safe "$inbound" || return 1
  meta_candidate=$(temp_file); candidate=$(temp_file)
  jq --arg inbound "$inbound" --arg user "$identity" --arg name "$name" --arg outbound "$outbound" '
    .domainTemplates.userBindings = ([.domainTemplates.userBindings[]? |
      select(.inbound!=$inbound or .user!=$user or .template!=$name)] +
      [{inbound:$inbound,user:$user,template:$name,outbound:$outbound}])' "$META_FILE" >"$meta_candidate" || { rm -f "$meta_candidate" "$candidate"; return 1; }
  _rebuild_user_template_config "$CONFIG_FILE" "$candidate" "$meta_candidate" || { rm -f "$meta_candidate" "$candidate"; return 1; }
  _stage_local_outbound "$candidate" "$local_ip" || { rm -f "$meta_candidate" "$candidate"; return 1; }
  display_outbound=${local_ip:-$(_outbound_display_name "$outbound")}
  _commit_template_change "$candidate" "$meta_candidate" "已为用户 ${label} 应用模板 ${name}，出站为 ${display_outbound}。"
}

user_template_remove() {
  ensure_runtime_dependencies outbound-user-template; ensure_config; ensure_meta
  local inbound=$1 label=$2 name=$3 identity meta_candidate candidate
  _outbound_user_identity identity "$inbound" "$label" || return 1
  _outbound_user_rules_safe "$inbound" || return 1
  meta_candidate=$(temp_file); candidate=$(temp_file)
  jq --arg inbound "$inbound" --arg user "$identity" --arg name "$name" '
    .domainTemplates.userBindings = [.domainTemplates.userBindings[]? |
      select(.inbound!=$inbound or .user!=$user or .template!=$name)]' "$META_FILE" >"$meta_candidate" || { rm -f "$meta_candidate" "$candidate"; return 1; }
  _rebuild_user_template_config "$CONFIG_FILE" "$candidate" "$meta_candidate" || { rm -f "$meta_candidate" "$candidate"; return 1; }
  _commit_template_change "$candidate" "$meta_candidate" "已移除用户 ${label} 的模板 ${name}。"
}

_outbound_user_commit_if_changed() {
  local candidate=$1 message=$2 current_json candidate_json
  OUTBOUND_USER_NO_CHANGE=0
  current_json=$(jq -cS . "$CONFIG_FILE") || { rm -f "$candidate"; return 1; }
  candidate_json=$(jq -cS . "$candidate") || { rm -f "$candidate"; return 1; }
  if [[ $current_json == "$candidate_json" ]]; then
    rm -f "$candidate"
    OUTBOUND_USER_NO_CHANGE=1
    info "$message"
    return 0
  fi
  XRAYCTL_QUIET_CONFIG_APPLIED=1 state_apply_candidate_file "$candidate" apply_candidate
}

outbound_user_default_set() {
  ensure_runtime_dependencies outbound-user-set; ensure_config
  local inbound=${1-} label=${2-} outbound=${3-} identity id existing_count current_outbound candidate tmp local_ip='' display_outbound
  [[ -n $inbound && -n $label ]] || die "用法：xrayctl outbound user set <入站> <用户> <出站>"
  inbound_exists "$inbound" || die "找不到入站：$inbound"
  inbound_require_supported_configuration "$inbound"
  client_label_exists "$inbound" "$label" || die "找不到入站 ${inbound} 的用户 ${label}。"
  _outbound_user_identity identity "$inbound" "$label" || return 1
  [[ -n $outbound ]] || select_outbound outbound 1 1 local_ip 0 || return 1
  if [[ $outbound == '@inherit' ]]; then
    outbound_user_default_unset "$inbound" "$label"
    return $?
  fi
  [[ -n $local_ip ]] || outbound_exists "$outbound" || [[ $outbound == direct ]] || die "找不到出站：$outbound"
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
    info "用户 ${label} 的默认出站已是 $(_outbound_display_name "$outbound")。"
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
  _stage_local_outbound "$candidate" "$local_ip" || { rm -f "$candidate"; return 1; }
  tmp=$(temp_file) || { rm -f "$candidate"; return 1; }
  _outbound_user_rebuild_rules "$candidate" "$tmp" "$inbound" || { rm -f "$candidate" "$tmp"; return 1; }
  rm -f "$candidate"
  display_outbound=${local_ip:-$(_outbound_display_name "$outbound")}
  _outbound_user_commit_if_changed "$tmp" "用户 ${label} 的默认出站已是 ${display_outbound}。" || return 1
  ((OUTBOUND_USER_NO_CHANGE == 0)) || return 0
  info "已设置用户 ${label} 默认出站为 ${display_outbound}。"
}

outbound_user_list() {
  ensure_config
  local inbound=${1-} label identity default inbound_default
  [[ -n $inbound ]] || die "用法：xrayctl outbound user list <入站>"
  inbound_exists "$inbound" || die "找不到入站：$inbound"
  inbound_default=$(jq -r --arg tag "$inbound" '[.routing.rules[]?|select(.ruleTag==("xrayctl-outbound:"+$tag))|.outboundTag][0] // .outbounds[0].tag // "direct"' "$CONFIG_FILE")
  printf '入站：%s | 入站默认：%s\n' "$inbound" "$(_outbound_display_name "$inbound_default")"
  while IFS= read -r label; do
    [[ -n $label ]] || continue
    _outbound_user_identity identity "$inbound" "$label" || continue
    default=$(jq -r --arg inbound "$inbound" --arg identity "$identity" '
      [.routing.rules[]? | select(((.ruleTag // "")|startswith("xrayctl-user-outbound:")) and .inboundTag==[$inbound] and .user==[$identity]) | .outboundTag][0] // empty
    ' "$CONFIG_FILE")
    [[ -z $default ]] || default=$(_outbound_display_name "$default")
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
  ((OUTBOUND_USER_NO_CHANGE == 0)) || return 0
  info "已取消 ${inbound} / ${label} 的独立默认出站。"
}

outbound_user_domain_add() {
  ensure_runtime_dependencies outbound-user-rule-add; ensure_config
  local inbound=${1-} label=${2-} match=${3-} domains_input=${4-} outbound=${5-} local_ip=${6-}
  local identity normalized domain domains_json existing rule_tag rule rules_json='[]' candidate tmp
  local -a domains=()
  [[ -n $inbound && -n $label && -n $match && -n $domains_input && -n $outbound ]] || die "用法：xrayctl outbound user rule add <入站> <用户> <suffix|exact> <域名[,域名...]> <出站>"
  case $match in suffix|exact) ;; *) die "匹配方式只能是 suffix 或 exact。";; esac
  inbound_exists "$inbound" || die "找不到入站：$inbound"
  inbound_require_supported_configuration "$inbound"
  client_label_exists "$inbound" "$label" || die "找不到入站 ${inbound} 的用户 ${label}。"
  _outbound_user_identity identity "$inbound" "$label" || return 1
  [[ -n $local_ip ]] || outbound_exists "$outbound" || [[ $outbound == direct || $outbound == blocked ]] || die "找不到出站：$outbound"
  normalized=$(_normalize_domain_list "$domains_input") || return 1
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
  _stage_local_outbound "$candidate" "$local_ip" || { rm -f "$candidate"; return 1; }
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
  local inbound=${1-} label=${2-} match=${3-} domains_input=${4-} identity normalized domain domains_json tmp rebuilt
  [[ -n $inbound && -n $label && -n $match && -n $domains_input ]] || die "用法：xrayctl outbound user rule delete <入站> <用户> <suffix|exact> <域名[,域名...]>"
  case $match in suffix|exact) ;; *) die "匹配方式只能是 suffix 或 exact。";; esac
  _outbound_user_identity identity "$inbound" "$label" || return 1
  normalized=$(_normalize_domain_list "$domains_input") || return 1
  domains_json=$(printf '%s\n' "$normalized" | jq -Rsc 'split("\n")|map(select(length>0))|unique') || return 1
  if jq -e --arg inbound "$inbound" --arg identity "$identity" --arg match "$match" --argjson domains "$domains_json" '
    any(.routing.rules[]?; . as $rule |
      ((.ruleTag // "")|startswith("xrayctl-user-domain:")) and (.template // "")!="" and .inboundTag==[$inbound] and .user==[$identity] and
      any($domains[]; . as $domain | $rule.domain[0]==((if $match=="suffix" then "domain:" else "full:" end)+$domain)))' "$CONFIG_FILE" >/dev/null; then
    warn "所选域名属于用户模板，请在模板库修改域名；变更会同步到应用该模板的用户。"
    return 1
  fi
  tmp=$(temp_file) || return 1
  jq --arg inbound "$inbound" --arg identity "$identity" --arg match "$match" --argjson domains "$domains_json" '
    .routing.rules |= map(. as $rule | select((
      ((.ruleTag // "")|startswith("xrayctl-user-domain:")) and .inboundTag==[$inbound] and .user==[$identity] and
      any($domains[]; . as $domain | $rule.domain[0]==((if $match=="suffix" then "domain:" else "full:" end)+$domain))
    )|not))
  ' "$CONFIG_FILE" >"$tmp" || { rm -f "$tmp"; return 1; }
  ensure_meta
  rebuilt=$(temp_file) || { rm -f "$tmp"; return 1; }
  _rebuild_user_template_config "$tmp" "$rebuilt" "$META_FILE" || { rm -f "$tmp" "$rebuilt"; return 1; }
  rm -f "$tmp"; tmp=$rebuilt
  _outbound_user_commit_if_changed "$tmp" "${inbound} / ${label} 的域名规则已更新。" || return 1
  ((OUTBOUND_USER_NO_CHANGE == 0)) || return 0
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
  XRAYCTL_QUIET_CONFIG_APPLIED=1 state_apply_candidate_file "$tmp" state_commit_user_template_identity "$inbound" "$identity" "" || return 1
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

prompt_domain_list() {
  local __var=$1 prompt=$2 input_val
  while true; do
    prompt_value input_val "$prompt" || return 1
    if _normalize_domain_list "$input_val" >/dev/null; then
      printf -v "$__var" '%s' "$input_val"
      return 0
    fi
  done
}

_meta_template_remove_user_bindings() {
  local current=$1 candidate=$2 outbound=$3
  jq --arg tag "$outbound" '
    .domainTemplates = (.domainTemplates // {templates:[],userBindings:[]}) |
    .domainTemplates.userBindings = [.domainTemplates.userBindings[]? | select(.outbound != $tag)]' \
    "$current" >"$candidate"
}

delete_outbound() {
  ensure_runtime_dependencies outbound-delete; ensure_config; ensure_meta
  local tag=${1-} tmp rebuilt default_refs legacy_domain_refs user_default_refs user_domain_refs custom_refs template_refs meta_candidate=""
  [[ -n $tag ]] || select_outbound tag 0 0 || return
  outbound_exists "$tag" || die "找不到出站：$tag"
  [[ $tag != direct && $tag != blocked ]] || { warn "${tag} 出站不能删除。"; return 0; }

  default_refs=$(jq -r --arg tag "$tag" '
    [.routing.rules[]? |
      select(.outboundTag==$tag and (.ruleTag|type)=="string" and (.ruleTag|startswith("xrayctl-outbound:")))] | length' "$CONFIG_FILE")
  legacy_domain_refs=$(jq -r --arg tag "$tag" '
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
  template_refs=$(jq -r --arg tag "$tag" '[.domainTemplates.userBindings[]? | select(.outbound==$tag)] | length' "$META_FILE")
  if ((custom_refs > 0)); then
    die "该出站仍被自定义路由规则引用，请先在完整配置中处理。"
  fi
  if ((default_refs > 0 || legacy_domain_refs > 0 || user_default_refs > 0 || user_domain_refs > 0 || template_refs > 0)); then
    warn "出站 ${tag} 仍被引用：入站默认 ${default_refs}，旧入站域名规则 ${legacy_domain_refs}，用户默认 ${user_default_refs}，用户域名 ${user_domain_refs}，用户模板 ${template_refs}。"
    confirm "继续删除出站 ${tag}？" N || return 0
  else
    confirm "删除出站 ${tag}？" N || return 0
  fi
  tmp=$(temp_file)
  jq --arg tag "$tag" '
    .outbounds |= map(select(.tag!=$tag)) |
    .routing.rules=((.routing.rules // []) | map(select(.outboundTag!=$tag)))' "$CONFIG_FILE" >"$tmp"
  if ((template_refs > 0)); then
    meta_candidate=$(temp_file)
    _meta_template_remove_user_bindings "$META_FILE" "$meta_candidate" "$tag" || {
      rm -f "$tmp" "$meta_candidate"
      return 1
    }
    rebuilt=$(temp_file)
    _rebuild_user_template_config "$tmp" "$rebuilt" "$meta_candidate" || { rm -f "$tmp" "$rebuilt" "$meta_candidate"; return 1; }
    rm -f "$tmp"; tmp=$rebuilt
    XRAYCTL_QUIET_CONFIG_APPLIED=1 state_commit_candidate_with_metadata "$tmp" "$meta_candidate" || return
    rm -f "$meta_candidate"
  else
    XRAYCTL_QUIET_CONFIG_APPLIED=1 state_apply_candidate_file "$tmp" apply_candidate || return
  fi
  info "出站 ${tag} 已删除。"
}
