build_inbound() {
  local __inbound=$1 __host=$2 __public_key=$3
  local choice protocol tag listen port public_host email uuid password method stream="" inbound_json user flow username generated_public_key="" suggested_host=""
  choose choice "选择入站协议" \
    "VLESS" "VMess" "Trojan" "SOCKS5" "HTTP"
  case $choice in
    1) protocol=vless;; 2) protocol=vmess;; 3) protocol=trojan;;
    4) protocol=socks;; 5) protocol=http;;
  esac
  if [[ $protocol == vless || $protocol == vmess || $protocol == trojan ]]; then
    build_stream_settings "$protocol" stream generated_public_key
    suggested_host=$(jq -r '.tlsSettings.serverName // empty' <<<"$stream")
  fi
  prompt_tag tag "${protocol}-$(random_hex 2)"
  prompt_value listen "监听地址" "0.0.0.0"
  prompt_port port 443
  if [[ -n $suggested_host ]]; then
    public_host=$suggested_host
    info "客户端连接地址：${public_host}"
  else
    prompt_public_host public_host "" "$suggested_host"
  fi

  case $protocol in
    vless|vmess|trojan)
      prompt_client_label email "$tag" "首个用户名称/邮箱" "user-$(random_hex 2)" "" "$protocol"
      case $protocol in
        vless)
          uuid=$(generate_uuid)
          method=$(jq -r '.method' <<<"$stream")
          if [[ $method == raw && $(jq -r '.security' <<<"$stream") != none ]]; then flow=xtls-rprx-vision; else flow=""; fi
          user=$(jq -n --arg id "$uuid" --arg email "$email" --arg flow "$flow" '{id:$id,email:$email,level:0} + (if $flow!="" then {flow:$flow} else {} end)')
          inbound_json=$(jq -n --arg tag "$tag" --arg listen "$listen" --argjson port "$port" --argjson user "$user" --argjson stream "$stream" \
            '{tag:$tag,listen:$listen,port:$port,protocol:"vless",settings:{clients:[$user],decryption:"none"},streamSettings:$stream,sniffing:{enabled:true,destOverride:["http","tls","quic"],routeOnly:true}}')
          ;;
        vmess)
          uuid=$(generate_uuid)
          user=$(jq -n --arg id "$uuid" --arg email "$email" '{id:$id,alterId:0,email:$email,level:0}')
          inbound_json=$(jq -n --arg tag "$tag" --arg listen "$listen" --argjson port "$port" --argjson user "$user" --argjson stream "$stream" \
            '{tag:$tag,listen:$listen,port:$port,protocol:"vmess",settings:{clients:[$user]},streamSettings:$stream,sniffing:{enabled:true,destOverride:["http","tls","quic"],routeOnly:true}}')
          ;;
        trojan)
          prompt_secret password "Trojan 密码" "$(random_password)"
          user=$(jq -n --arg password "$password" --arg email "$email" '{password:$password,email:$email,level:0}')
          inbound_json=$(jq -n --arg tag "$tag" --arg listen "$listen" --argjson port "$port" --argjson user "$user" --argjson stream "$stream" \
            '{tag:$tag,listen:$listen,port:$port,protocol:"trojan",settings:{clients:[$user]},streamSettings:$stream,sniffing:{enabled:true,destOverride:["http","tls","quic"],routeOnly:true}}')
          ;;
      esac
      ;;
    socks)
      prompt_optional_value username "用户名（留空表示无认证）"
      if [[ -n $username ]]; then
        prompt_secret password "密码" "$(random_password)"
        inbound_json=$(jq -n --arg tag "$tag" --arg listen "$listen" --argjson port "$port" --arg user "$username" --arg pass "$password" \
          '{tag:$tag,listen:$listen,port:$port,protocol:"socks",settings:{
            auth:"password",
            accounts:[{user:$user,pass:$pass}],
            users:[{user:$user,pass:$pass}],
            udp:true,
            ip:"0.0.0.0"
          }}')
      else
        [[ $listen == 127.0.0.1 || $listen == ::1 ]] || warn "公网监听的无认证 SOCKS5 风险极高。"
        inbound_json=$(jq -n --arg tag "$tag" --arg listen "$listen" --argjson port "$port" \
          '{tag:$tag,listen:$listen,port:$port,protocol:"socks",settings:{auth:"noauth",udp:true,ip:"0.0.0.0"}}')
      fi
      ;;
    http)
      prompt_optional_value username "用户名（留空表示无认证）"
      if [[ -n $username ]]; then
        prompt_secret password "密码" "$(random_password)"
        inbound_json=$(jq -n --arg tag "$tag" --arg listen "$listen" --argjson port "$port" --arg user "$username" --arg pass "$password" \
          '{tag:$tag,listen:$listen,port:$port,protocol:"http",settings:{
            accounts:[{user:$user,pass:$pass}],
            users:[{user:$user,pass:$pass}],
            allowTransparent:false
          }}')
      else
        [[ $listen == 127.0.0.1 || $listen == ::1 ]] || warn "公网监听的无认证 HTTP 代理风险极高。"
        inbound_json=$(jq -n --arg tag "$tag" --arg listen "$listen" --argjson port "$port" \
          '{tag:$tag,listen:$listen,port:$port,protocol:"http",settings:{allowTransparent:false}}')
      fi
      ;;
  esac
  printf -v "$__inbound" '%s' "$inbound_json"
  printf -v "$__host" '%s' "$public_host"
  printf -v "$__public_key" '%s' "$generated_public_key"
}

