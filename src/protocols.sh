protocol_list() {
  printf '%s\n' vless vmess trojan socks http
}

protocol_supports_stream() {
  [[ $1 == vless || $1 == vmess || $1 == trojan ]]
}

protocol_supports_reality() {
  [[ $1 == vless || $1 == trojan ]]
}

protocol_client_credential_field() {
  case $1 in
    vless|vmess) printf '%s\n' id ;;
    trojan) printf '%s\n' password ;;
    socks|http) printf '%s\n' pass ;;
    *) return 1 ;;
  esac
}

protocol_build_vless() {
  local __out=$1 tag=$2 listen=$3 port=$4 email=$5 stream=$6
  local uuid method flow user result
  uuid=$(generate_uuid)
  method=$(jq -r '.method' <<<"$stream")
  if [[ $method == raw && $(jq -r '.security' <<<"$stream") != none ]]; then
    flow=xtls-rprx-vision
  else
    flow=""
  fi
  user=$(jq -n --arg id "$uuid" --arg email "$email" --arg flow "$flow" \
    '{id:$id,email:$email,level:0} + (if $flow!="" then {flow:$flow} else {} end)')
  result=$(jq -n --arg tag "$tag" --arg listen "$listen" --argjson port "$port" \
    --argjson user "$user" --argjson stream "$stream" \
    '{tag:$tag,listen:$listen,port:$port,protocol:"vless",settings:{clients:[$user],decryption:"none"},streamSettings:$stream,sniffing:{enabled:true,destOverride:["http","tls","quic"],routeOnly:true}}')
  printf -v "$__out" '%s' "$result"
}

protocol_build_vmess() {
  local __out=$1 tag=$2 listen=$3 port=$4 email=$5 stream=$6
  local uuid user result
  uuid=$(generate_uuid)
  user=$(jq -n --arg id "$uuid" --arg email "$email" '{id:$id,alterId:0,email:$email,level:0}')
  result=$(jq -n --arg tag "$tag" --arg listen "$listen" --argjson port "$port" \
    --argjson user "$user" --argjson stream "$stream" \
    '{tag:$tag,listen:$listen,port:$port,protocol:"vmess",settings:{clients:[$user]},streamSettings:$stream,sniffing:{enabled:true,destOverride:["http","tls","quic"],routeOnly:true}}')
  printf -v "$__out" '%s' "$result"
}

protocol_build_trojan() {
  local __out=$1 tag=$2 listen=$3 port=$4 email=$5 password=$6 stream=$7
  local user result
  user=$(jq -n --arg password "$password" --arg email "$email" '{password:$password,email:$email,level:0}')
  result=$(jq -n --arg tag "$tag" --arg listen "$listen" --argjson port "$port" \
    --argjson user "$user" --argjson stream "$stream" \
    '{tag:$tag,listen:$listen,port:$port,protocol:"trojan",settings:{clients:[$user]},streamSettings:$stream,sniffing:{enabled:true,destOverride:["http","tls","quic"],routeOnly:true}}')
  printf -v "$__out" '%s' "$result"
}

protocol_build_socks() {
  local __out=$1 tag=$2 listen=$3 port=$4 username=$5 password=$6 result
  if [[ -n $username ]]; then
    result=$(jq -n --arg tag "$tag" --arg listen "$listen" --argjson port "$port" \
      --arg user "$username" --arg pass "$password" \
      '{tag:$tag,listen:$listen,port:$port,protocol:"socks",settings:{
        auth:"password",
        accounts:[{user:$user,pass:$pass}],
        users:[{user:$user,pass:$pass}],
        udp:true,
        ip:"0.0.0.0"
      }}')
  else
    [[ $listen == 127.0.0.1 || $listen == ::1 ]] || warn "公网监听的无认证 SOCKS5 风险极高。"
    result=$(jq -n --arg tag "$tag" --arg listen "$listen" --argjson port "$port" \
      '{tag:$tag,listen:$listen,port:$port,protocol:"socks",settings:{auth:"noauth",udp:true,ip:"0.0.0.0"}}')
  fi
  printf -v "$__out" '%s' "$result"
}

protocol_build_http() {
  local __out=$1 tag=$2 listen=$3 port=$4 username=$5 password=$6 result
  if [[ -n $username ]]; then
    result=$(jq -n --arg tag "$tag" --arg listen "$listen" --argjson port "$port" \
      --arg user "$username" --arg pass "$password" \
      '{tag:$tag,listen:$listen,port:$port,protocol:"http",settings:{
        accounts:[{user:$user,pass:$pass}],
        users:[{user:$user,pass:$pass}],
        allowTransparent:false
      }}')
  else
    [[ $listen == 127.0.0.1 || $listen == ::1 ]] || warn "公网监听的无认证 HTTP 代理风险极高。"
    result=$(jq -n --arg tag "$tag" --arg listen "$listen" --argjson port "$port" \
      '{tag:$tag,listen:$listen,port:$port,protocol:"http",settings:{allowTransparent:false}}')
  fi
  printf -v "$__out" '%s' "$result"
}

protocol_build() {
  local __out=$1 protocol=$2
  shift 2
  case $protocol in
    vless) protocol_build_vless "$__out" "$@" ;;
    vmess) protocol_build_vmess "$__out" "$@" ;;
    trojan) protocol_build_trojan "$__out" "$@" ;;
    socks) protocol_build_socks "$__out" "$@" ;;
    http) protocol_build_http "$__out" "$@" ;;
    *) error "不支持的协议：${protocol}"; return 1 ;;
  esac
}

build_inbound() {
  local __inbound=$1 __host=$2 __public_key=$3
  local choice protocol tag listen port public_host email password="" stream="" inbound_json username="" generated_public_key="" suggested_host="" suggested_port=""
  choose choice "选择入站协议" \
    "VLESS" "VMess" "Trojan" "SOCKS5" "HTTP"
  case $choice in
    1) protocol=vless;; 2) protocol=vmess;; 3) protocol=trojan;;
    4) protocol=socks;; 5) protocol=http;;
  esac

  if protocol_supports_stream "$protocol"; then
    build_stream_settings "$protocol" stream generated_public_key
    suggested_host=$(jq -r '.tlsSettings.serverName // empty' <<<"$stream")
  fi

  prompt_tag tag "${protocol}-$(random_hex 2)"
  prompt_value listen "监听地址" "0.0.0.0"
  suggest_available_port suggested_port || suggested_port=443
  prompt_port port "$suggested_port"
  if [[ -n $suggested_host ]]; then
    public_host=$suggested_host
    info "客户端连接地址：${public_host}"
  else
    prompt_public_host public_host "" "$suggested_host"
  fi

  case $protocol in
    vless|vmess)
      prompt_client_label email "$tag" "首个用户名称/邮箱" "user-$(random_hex 2)" "" "$protocol"
      protocol_build inbound_json "$protocol" "$tag" "$listen" "$port" "$email" "$stream"
      ;;
    trojan)
      prompt_client_label email "$tag" "首个用户名称/邮箱" "user-$(random_hex 2)" "" "$protocol"
      prompt_secret password "Trojan 密码" "$(random_password)"
      protocol_build inbound_json "$protocol" "$tag" "$listen" "$port" "$email" "$password" "$stream"
      ;;
    socks|http)
      prompt_optional_value username "用户名（留空表示无认证）"
      if [[ -n $username ]]; then prompt_secret password "密码" "$(random_password)"; fi
      protocol_build inbound_json "$protocol" "$tag" "$listen" "$port" "$username" "$password"
      ;;
  esac

  printf -v "$__inbound" '%s' "$inbound_json"
  printf -v "$__host" '%s' "$public_host"
  printf -v "$__public_key" '%s' "$generated_public_key"
}
