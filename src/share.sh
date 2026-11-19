#!/usr/bin/env bash
share_separator() { ui_rule 2; }

print_share_entry() {
  local label=$1 field=$2 value=$3 index=${4-}
  if [[ -n $index ]]; then
    printf '\n  %s▸ [%s]%s 用户: %s%s%s\n' "$C_BOLD$C_CYAN" "$index" "$C_RESET" "$C_BOLD" "$label" "$C_RESET"
  else
    printf '\n  %s▸%s 用户: %s%s%s\n' "$C_BOLD$C_CYAN" "$C_RESET" "$C_BOLD" "$label" "$C_RESET"
  fi
  printf '%s: %s\n' "$field" "$value"
}

_share_print_params_card() {
  local tag=$1 protocol=$2 uri_host=$3 port=$4
  local stream method security path="" sni="" sid="" pbk="" flow="" auth="" obfs_host=""
  ui_card_open "连接参数 · ${tag}"
  case $protocol in
    vless)
      stream=$(jq --arg tag "$tag" '.inbounds[]|select(.tag==$tag)|.streamSettings // {network:"raw",security:"none"}' "$CONFIG_FILE")
      method=$(jq -r '.network // .method // "raw"' <<<"$stream")
      security=$(jq -r '.security // "none"' <<<"$stream")
      flow=$(jq -r --arg tag "$tag" '.inbounds[]|select(.tag==$tag)|.settings.clients[0].flow // empty' "$CONFIG_FILE")
      ui_card_kv "协议与传输" "VLESS · ${method^^} · ${security^^}${flow:+ (${flow})}" 12
      ui_card_kv "连接地址" "${uri_host}:${port}" 12
      case $method in
        websocket)
          path=$(jq -r '.wsSettings.path // "/"' <<<"$stream")
          ui_card_kv "WS 路径" "$path" 12
          ;;
        xhttp)
          path=$(jq -r '.xhttpSettings.path // "/"' <<<"$stream")
          ui_card_kv "XHTTP 路径" "${path} (mode: auto)" 12
          ;;
      esac
      case $security in
        tls)
          sni=$(jq -r '.tlsSettings.serverName // empty' <<<"$stream")
          [[ -n $sni ]] || sni=$(public_host_for_tag "$tag")
          ui_card_kv "TLS SNI" "$sni" 12
          ui_card_kv "指纹 (fp)" "chrome" 12
          ;;
        reality)
          sni=$(jq -r '.realitySettings.serverNames[0] // empty' <<<"$stream")
          sid=$(jq -r '.realitySettings.shortIds[0] // empty' <<<"$stream")
          pbk=$(reality_public_key "$tag" 2>/dev/null || true)
          ui_card_kv "伪装 SNI" "${sni:--}" 12
          ui_card_kv "公钥 (pbk)" "${pbk:-需安装 Xray 后生成}" 12
          ui_card_kv "Short ID" "${sid:--}" 12
          ui_card_kv "指纹 (fp)" "chrome" 12
          ;;
      esac
      ;;
    shadowsocks)
      if inbound_obfs_enabled "$tag"; then
        obfs_host=$(inbound_obfs_field "$tag" host)
        ui_card_kv "协议与传输" "SS2022 · TCP · HTTP 混淆" 12
        ui_card_kv "加密方式" "$SS2022_METHOD" 12
        ui_card_kv "混淆域名" "$obfs_host" 12
        ui_card_kv "SIP003 插件" "obfs-local;obfs=http;obfs-host=${obfs_host}" 12
        ui_card_kv "连接地址" "${uri_host}:${port}" 12
      else
        ui_card_kv "协议与传输" "SS2022 · TCP/UDP" 12
        ui_card_kv "加密方式" "$SS2022_METHOD" 12
        ui_card_kv "连接地址" "${uri_host}:${port}" 12
      fi
      ;;
    socks)
      auth=$(jq -r --arg tag "$tag" '.inbounds[]|select(.tag==$tag)|.settings.auth // "noauth"' "$CONFIG_FILE")
      ui_card_kv "协议类型" "SOCKS5 ($([[ $auth == password ]] && printf '账号密码认证' || printf '无认证'))" 12
      ui_card_kv "连接地址" "${uri_host}:${port}" 12
      ;;
    http)
      if http_inbound_has_auth "$tag"; then auth='账号密码认证'; else auth='无认证'; fi
      ui_card_kv "协议类型" "HTTP (${auth})" 12
      ui_card_kv "连接地址" "${uri_host}:${port}" 12
      ;;
  esac
  ui_card_close
}

link_query_for_stream() {
  local tag=$1 protocol=$2 stream method security query="" path sni sid pbk flow
  stream=$(jq --arg tag "$tag" '.inbounds[]|select(.tag==$tag)|.streamSettings // {network:"raw",security:"none"}' "$CONFIG_FILE")
  method=$(jq -r '.network // .method // "raw"' <<<"$stream"); security=$(jq -r '.security // "none"' <<<"$stream")
  case $method in
    raw) query="type=tcp" ;;
    websocket) path=$(jq -r '.wsSettings.path // "/"' <<<"$stream"); query="type=ws&path=$(url_encode "$path")" ;;
    xhttp) path=$(jq -r '.xhttpSettings.path // "/"' <<<"$stream"); query="type=xhttp&path=$(url_encode "$path")&mode=auto" ;;
    *) query="type=$(url_encode "$method")" ;;
  esac
  query+="&security=$(url_encode "$security")"
  case $security in
    tls)
      sni=$(jq -r '.tlsSettings.serverName // empty' <<<"$stream")
      [[ -n $sni ]] || sni=$(public_host_for_tag "$tag")
      query+="&sni=$(url_encode "$sni")"
      [[ $method == websocket ]] && query+="&host=$(url_encode "$sni")"
      query+="&fp=chrome"
      ;;
    reality)
      sni=$(jq -r '.realitySettings.serverNames[0]' <<<"$stream")
      sid=$(jq -r '.realitySettings.shortIds[0]' <<<"$stream")
      pbk=$(reality_public_key "$tag") || { warn "无法获得 REALITY 公钥。"; return 0; }
      query+="&sni=$(url_encode "$sni")&fp=chrome&pbk=$(url_encode "$pbk")&sid=$(url_encode "$sid")&spx=%2F"
      ;;
  esac
  if [[ $protocol == vless ]]; then
    flow=$(jq -r --arg tag "$tag" '.inbounds[]|select(.tag==$tag)|.settings.clients[0].flow // empty' "$CONFIG_FILE")
    [[ -n $flow ]] && query+="&flow=$(url_encode "$flow")"
  fi
  printf '%s' "$query"
}

print_links() {
  ensure_config; init_meta
  local tag=${1-} filter=${2-} protocol host uri_host port query label id password link server_key plugin_query="" obfs_host="" idx=0
  [[ -n $tag ]] || select_inbound tag || return
  inbound_exists "$tag" || die "找不到入站：$tag"
  inbound_require_supported_configuration "$tag"
  protocol=$(jq -r --arg tag "$tag" '.inbounds[]|select(.tag==$tag)|.protocol' "$CONFIG_FILE")
  host=$(public_host_for_tag "$tag"); uri_host=$host
  [[ $uri_host == *:* && $uri_host != \[*\] ]] && uri_host="[${uri_host}]"
  port=$(inbound_effective_port "$tag")
  heading "${tag} · 节点交付"
  _share_print_params_card "$tag" "$protocol" "$uri_host" "$port"
  case $protocol in
    vless)
      query=$(link_query_for_stream "$tag" "$protocol")
      while IFS= read -r -d '' label && IFS= read -r -d '' id; do
        [[ -z $filter || $label == "$filter" ]] || continue
        idx=$((idx + 1))
        link="vless://${id}@${uri_host}:${port}?${query}#$(url_encode "${tag}-${label}")"
        print_share_entry "$label" "链接" "$link" "$idx"
      done < <(jq -j --arg tag "$tag" '.inbounds[]|select(.tag==$tag)|.settings.clients[]|(.xrayctlLabel // .email // ""), "\u0000", (.id // ""), "\u0000"' "$CONFIG_FILE")
      ;;
    shadowsocks)
      if inbound_obfs_enabled "$tag"; then
        obfs_host=$(inbound_obfs_field "$tag" host)
        plugin_query="?plugin=$(url_encode "obfs-local;obfs=http;obfs-host=${obfs_host}")"
      fi
      server_key=$(jq -r --arg tag "$tag" '.inbounds[]|select(.tag==$tag)|.settings.password' "$CONFIG_FILE")
      while IFS= read -r -d '' label && IFS= read -r -d '' password; do
        [[ -z $filter || $label == "$filter" ]] || continue
        idx=$((idx + 1))
        link="ss://${SS2022_METHOD}:$(url_encode "${server_key}:${password}")@${uri_host}:${port}${plugin_query}#$(url_encode "${tag}-${label}")"
        print_share_entry "$label" "链接" "$link" "$idx"
      done < <(jq -j --arg tag "$tag" '.inbounds[]|select(.tag==$tag)|.settings.clients[]|(.xrayctlLabel // .email // ""), "\u0000", .password, "\u0000"' "$CONFIG_FILE")
      ;;
    socks)
      if [[ $(jq -r --arg tag "$tag" '.inbounds[]|select(.tag==$tag)|.settings.auth' "$CONFIG_FILE") == password ]]; then
        while IFS= read -r -d '' label && IFS= read -r -d '' password; do
          [[ -z $filter || $label == "$filter" ]] || continue
          idx=$((idx + 1))
          link="socks5://$(url_encode "$label"):$(url_encode "$password")@${uri_host}:${port}#$(url_encode "${tag}-${label}")"
          print_share_entry "$label" "链接" "$link" "$idx"
        done < <(jq -j --arg tag "$tag" '.inbounds[]|select(.tag==$tag)|(.settings.accounts // .settings.users // [])[]|(.user // ""), "\u0000", (.pass // ""), "\u0000"' "$CONFIG_FILE")
      else
        link="socks5://${uri_host}:${port}#$(url_encode "${tag}")"
        print_share_entry "无认证" "链接" "$link"
      fi
      ;;
    http)
      if http_inbound_has_auth "$tag"; then
        while IFS= read -r -d '' label && IFS= read -r -d '' password; do
          [[ -z $filter || $label == "$filter" ]] || continue
          idx=$((idx + 1))
          link="http://$(url_encode "$label"):$(url_encode "$password")@${uri_host}:${port}#$(url_encode "${tag}-${label}")"
          print_share_entry "$label" "链接" "$link" "$idx"
        done < <(jq -j --arg tag "$tag" '.inbounds[]|select(.tag==$tag)|(.settings.accounts // .settings.users // [])[]|(.user // ""), "\u0000", (.pass // ""), "\u0000"' "$CONFIG_FILE")
      else
        link="http://${uri_host}:${port}#$(url_encode "${tag}")"
        print_share_entry "无认证" "链接" "$link"
      fi
      ;;
  esac
  printf '\n'
  share_separator
}

print_subscription() {
  ensure_config; init_meta
  local tag=${1-} links="" current_tag current_links
  if [[ -n $tag ]]; then
    links=$(print_links "$tag" "" | awk '/^链接: (vless|ss|socks5|http):\/\// {sub(/^链接: /, ""); print}')
  else
    while IFS= read -r current_tag; do
      current_links=$(print_links "$current_tag" "" | awk '/^链接: (vless|ss|socks5|http):\/\// {sub(/^链接: /, ""); print}')
      [[ -n $current_links ]] || continue
      [[ -z $links ]] || links+=$'\n'
      links+=$current_links
    done < <(share_inbound_tags)
  fi
  [[ -n $links ]] || die "没有可生成订阅的代理分享链接。"
  printf '%s' "$links" | base64_nowrap
  printf '\n'
}

print_all_share_links() {
  ensure_config; init_meta
  local tag found=0
  while IFS= read -r tag; do
    found=1
    print_links "$tag" ""
  done < <(share_inbound_tags)
  ((found == 1)) || { warn "没有可生成分享链接的入站。"; return 0; }
}

share_inbound_tags() {
  jq -r --arg ss2022Method "$SS2022_METHOD" "$SS2022_INBOUND_JQ"'
    .inbounds[] |
    select(if .protocol=="shadowsocks" then ss2022_inbound else (.protocol|test("^(vless|socks|http)$")) end) |
    .tag
  ' "$CONFIG_FILE"
}


# ============================================================
# Unified Certbot environment — all certbot calls go through
# the isolated venv at /opt/xrayctl/certbot (see certbot_cmd).
# ============================================================
