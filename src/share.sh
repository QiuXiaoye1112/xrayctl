share_separator() { printf '%s\n' '------------------------------------------------------------------------'; }

print_share_entry() {
  local label=$1 field=$2 value=$3
  share_separator
  printf '用户: %s\n%s: %s\n' "$label" "$field" "$value"
}

link_query_for_stream() {
  local tag=$1 protocol=$2 stream method security query="" path service sni sid pbk flow
  stream=$(jq --arg tag "$tag" '.inbounds[]|select(.tag==$tag)|.streamSettings // {method:"raw",security:"none"}' "$CONFIG_FILE")
  method=$(jq -r '.method // "raw"' <<<"$stream"); security=$(jq -r '.security // "none"' <<<"$stream")
  case $method in
    raw) query="type=tcp" ;;
    websocket) path=$(jq -r '.wsSettings.path // "/"' <<<"$stream"); query="type=ws&path=$(url_encode "$path")" ;;
    grpc) service=$(jq -r '.grpcSettings.serviceName // ""' <<<"$stream"); query="type=grpc&serviceName=$(url_encode "$service")&mode=gun" ;;
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
      [[ $method == grpc ]] && query+="&authority=$(url_encode "$sni")"
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
  local tag=${1-} filter=${2-} protocol host uri_host port query label id password method vmess_net vmess_sni payload link
  [[ -n $tag ]] || select_inbound tag || return
  inbound_exists "$tag" || die "找不到入站：$tag"
  protocol=$(jq -r --arg tag "$tag" '.inbounds[]|select(.tag==$tag)|.protocol' "$CONFIG_FILE")
  host=$(public_host_for_tag "$tag"); uri_host=$host
  [[ $uri_host == *:* && $uri_host != \[*\] ]] && uri_host="[${uri_host}]"
  port=$(jq -r --arg tag "$tag" '.inbounds[]|select(.tag==$tag)|.port' "$CONFIG_FILE")
  heading "${tag} 分享信息"
  case $protocol in
    vless|trojan)
      query=$(link_query_for_stream "$tag" "$protocol")
      while IFS=$'\t' read -r label id; do
        [[ -z $filter || $label == "$filter" ]] || continue
        [[ $protocol == vless ]] && link="vless://${id}@${uri_host}:${port}?${query}#$(url_encode "${tag}-${label}")" \
          || link="trojan://${id}@${uri_host}:${port}?${query}#$(url_encode "${tag}-${label}")"
        print_share_entry "$label" "链接" "$link"
      done < <(jq -r --arg tag "$tag" --arg protocol "$protocol" '.inbounds[]|select(.tag==$tag)|.settings.clients[]|[.email,(if $protocol=="vless" then .id else .password end)]|@tsv' "$CONFIG_FILE")
      ;;
    vmess)
      method=$(jq -r --arg tag "$tag" '.inbounds[]|select(.tag==$tag)|.streamSettings.method // "raw"' "$CONFIG_FILE")
      case $method in raw) vmess_net=tcp;; websocket) vmess_net=ws;; *) vmess_net=$method;; esac
      vmess_sni=$(jq -r --arg tag "$tag" '.inbounds[]|select(.tag==$tag)|.streamSettings.tlsSettings.serverName // empty' "$CONFIG_FILE")
      [[ -n $vmess_sni ]] || vmess_sni=$host
      while IFS=$'\t' read -r label id; do
        [[ -z $filter || $label == "$filter" ]] || continue
        payload=$(jq -nc --arg ps "${tag}-${label}" --arg add "$host" --arg port "$port" --arg id "$id" --arg net "$vmess_net" \
          --arg type "none" --arg host "$([[ $method == websocket ]] && printf '%s' "$host" || true)" \
          --arg path "$(jq -r --arg tag "$tag" '.inbounds[]|select(.tag==$tag)|(.streamSettings.wsSettings.path // .streamSettings.xhttpSettings.path // .streamSettings.grpcSettings.serviceName // "")' "$CONFIG_FILE")" \
          --arg tls "$(jq -r --arg tag "$tag" '.inbounds[]|select(.tag==$tag)|if .streamSettings.security=="tls" then "tls" elif .streamSettings.security=="reality" then "reality" else "" end' "$CONFIG_FILE")" \
          --arg sni "$vmess_sni" \
          '{v:"2",ps:$ps,add:$add,port:$port,id:$id,aid:"0",scy:"auto",net:$net,type:$type,host:$host,path:$path,tls:$tls,sni:$sni,alpn:""}')
        link="vmess://$(printf '%s' "$payload" | base64_nowrap)"
        print_share_entry "$label" "链接" "$link"
      done < <(jq -r --arg tag "$tag" '.inbounds[]|select(.tag==$tag)|.settings.clients[]|[.email,.id]|@tsv' "$CONFIG_FILE")
      ;;
    shadowsocks) die "Shadowsocks 已停止支持；请迁移或删除入站。" ;;
    socks)
      if [[ $(jq -r --arg tag "$tag" '.inbounds[]|select(.tag==$tag)|.settings.auth' "$CONFIG_FILE") == password ]]; then
        while IFS=$'\t' read -r label password; do
          [[ -z $filter || $label == "$filter" ]] || continue
          link="socks5://$(url_encode "$label"):$(url_encode "$password")@${uri_host}:${port}#$(url_encode "${tag}-${label}")"
          print_share_entry "$label" "链接" "$link"
        done < <(jq -r --arg tag "$tag" '.inbounds[]|select(.tag==$tag)|(.settings.accounts // .settings.users // [])[]|[.user,.pass]|@tsv' "$CONFIG_FILE")
      else
        link="socks5://${uri_host}:${port}#$(url_encode "${tag}")"
        print_share_entry "无认证" "链接" "$link"
      fi
      ;;
    http)
      if http_inbound_has_auth "$tag"; then
        while IFS=$'\t' read -r label password; do
          [[ -z $filter || $label == "$filter" ]] || continue
          link="http://$(url_encode "$label"):$(url_encode "$password")@${uri_host}:${port}#$(url_encode "${tag}-${label}")"
          print_share_entry "$label" "链接" "$link"
        done < <(jq -r --arg tag "$tag" '.inbounds[]|select(.tag==$tag)|(.settings.accounts // .settings.users // [])[]|[.user,.pass]|@tsv' "$CONFIG_FILE")
      else
        link="http://${uri_host}:${port}#$(url_encode "${tag}")"
        print_share_entry "无认证" "链接" "$link"
      fi
      ;;
  esac
  share_separator
}

print_all_share_links() {
  ensure_config; init_meta
  local tag found=0
  while IFS= read -r tag; do
    found=1
    print_links "$tag" ""
  done < <(jq -r '.inbounds[]|select(.protocol|test("^(vless|vmess|trojan|socks|http)$"))|.tag' "$CONFIG_FILE")
  ((found == 1)) || { warn "没有可生成分享链接的入站。"; return 0; }
}


# ============================================================
# Unified Certbot environment — all certbot calls go through
# the isolated venv at /opt/xrayctl/certbot (see certbot_cmd).
# ============================================================

