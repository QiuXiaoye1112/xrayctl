#!/usr/bin/env bash
readonly SS2022_METHOD="2022-blake3-aes-256-gcm"
# Xray switches to single-user mode when the client list is empty.
# shellcheck disable=SC2016
readonly SS2022_INBOUND_JQ='
  def ss2022_inbound:
    def key: type=="string" and test("^[A-Za-z0-9+/]{43}=$");
    .settings |
    .method==$ss2022Method and .network=="tcp,udp" and
    (.password | key) and
    (.clients | type=="array" and length>0 and
      all(.[]; .address==null and (.method // "")=="" and (.password | key))) and
    ([.password, .clients[].password] | length == (unique | length));
'

protocol_list() {
  printf '%s\n' vless shadowsocks socks http
}

protocol_is_supported() {
  case $1 in
    vless|shadowsocks|socks|http) return 0 ;;
    *) return 1 ;;
  esac
}

protocol_supports_stream() {
  [[ $1 == vless ]]
}

protocol_supports_reality() {
  [[ $1 == vless ]]
}

protocol_client_credential_field() {
  case $1 in
    vless) printf '%s\n' id ;;
    shadowsocks) printf '%s\n' password ;;
    socks|http) printf '%s\n' pass ;;
    *) return 1 ;;
  esac
}

protocol_build_vless() {
  local __out=$1 tag=$2 listen=$3 port=$4 email=$5 stream=$6
  local uuid method flow user result
  uuid=$(generate_uuid)
  method=$(jq -r '.network // .method // "raw"' <<<"$stream")
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

protocol_generate_ss2022_key() {
  openssl rand -base64 32
}

protocol_build_shadowsocks() {
  local __out=$1 tag=$2 listen=$3 port=$4 email=$5 server_key user_key result
  server_key=$(protocol_generate_ss2022_key) || return 1
  user_key=$(protocol_generate_ss2022_key) || return 1
  result=$(jq -n --arg tag "$tag" --arg listen "$listen" --argjson port "$port" \
    --arg method "$SS2022_METHOD" --arg serverKey "$server_key" --arg userKey "$user_key" --arg email "$email" \
    '{tag:$tag,listen:$listen,port:$port,protocol:"shadowsocks",settings:{
      method:$method,password:$serverKey,network:"tcp,udp",clients:[{email:$email,password:$userKey,level:0}]
    },sniffing:{enabled:true,destOverride:["http","tls","quic"],routeOnly:true}}') || return 1
  printf -v "$__out" '%s' "$result"
}

protocol_build_socks() {
  local __out=$1 tag=$2 listen=$3 port=$4 username=$5 password=$6 result
  [[ -n $username && -n $password ]] || { warn "SOCKS5 入站必须设置用户名和密码。"; return 1; }
  result=$(jq -n --arg tag "$tag" --arg listen "$listen" --argjson port "$port" \
    --arg user "$username" --arg pass "$password" \
    '{tag:$tag,listen:$listen,port:$port,protocol:"socks",settings:{
      auth:"password",
      accounts:[{user:$user,pass:$pass}],
      users:[{user:$user,pass:$pass}],
      udp:true,
      ip:"0.0.0.0"
    }}')
  printf -v "$__out" '%s' "$result"
}

protocol_build_http() {
  local __out=$1 tag=$2 listen=$3 port=$4 username=$5 password=$6 result
  [[ -n $username && -n $password ]] || { warn "HTTP 入站必须设置用户名和密码。"; return 1; }
  result=$(jq -n --arg tag "$tag" --arg listen "$listen" --argjson port "$port" \
    --arg user "$username" --arg pass "$password" \
    '{tag:$tag,listen:$listen,port:$port,protocol:"http",settings:{
      accounts:[{user:$user,pass:$pass}],
      users:[{user:$user,pass:$pass}],
      allowTransparent:false
    }}')
  printf -v "$__out" '%s' "$result"
}

protocol_build() {
  local __out=$1 protocol=$2
  shift 2
  case $protocol in
    vless) protocol_build_vless "$__out" "$@" ;;
    shadowsocks) protocol_build_shadowsocks "$__out" "$@" ;;
    socks) protocol_build_socks "$__out" "$@" ;;
    http) protocol_build_http "$__out" "$@" ;;
    *) error "不支持的协议：${protocol}"; return 1 ;;
  esac
}

build_inbound() {
  local __inbound=$1 __host=$2 __public_key=$3
  local choice protocol tag listen port public_host email password="" stream="" inbound_json username="" generated_public_key="" suggested_host="" suggested_port=""
  local total_steps=3 listen_step=2 user_step=3
  ui_wizard_step 1 "" "选择入站协议"
  choose choice "选择入站协议" "VLESS" "SS2022" "SOCKS5" "HTTP" || return 1
  case $choice in
    1) protocol=vless; total_steps=4; listen_step=3; user_step=4 ;;
    2) protocol=shadowsocks ;;
    3) protocol=socks ;;
    4) protocol=http ;;
  esac

  if protocol_supports_stream "$protocol"; then
    build_stream_settings "$protocol" stream generated_public_key || return 1
    suggested_host=$(jq -r '.tlsSettings.serverName // empty' <<<"$stream")
  fi

  ui_wizard_step "$listen_step" "$total_steps" "监听参数与连接地址"
  prompt_tag tag "${protocol}-$(random_hex 2)" || return 1
  prompt_value listen "监听地址" "0.0.0.0" || return 1
  suggest_available_port suggested_port || suggested_port=443
  prompt_port port "$suggested_port" || return 1
  if [[ -n $suggested_host ]]; then
    public_host=$suggested_host
    info "客户端连接地址：${public_host}"
  else
    prompt_public_host public_host "" "$suggested_host" || return 1
  fi

  ui_wizard_step "$user_step" "$total_steps" "创建初始访问用户"
  case $protocol in
    vless)
      prompt_client_label email "$tag" "首个用户名称/邮箱" "user-$(random_hex 2)" "" "$protocol" || return 1
      protocol_build inbound_json "$protocol" "$tag" "$listen" "$port" "$email" "$stream"
      ;;
    shadowsocks)
      prompt_client_label email "$tag" "首个用户名称/邮箱" "user-$(random_hex 2)" "" "$protocol" || return 1
      protocol_build inbound_json "$protocol" "$tag" "$listen" "$port" "$email" || return 1
      ;;
    socks|http)
      while true; do
        prompt_validated_value username "用户名" "" validate_email_label "用户名无效，请重新输入。" || return 1
        if ! client_account_identity_exists_globally "$username"; then break; fi
        warn "此用户名已存在"
      done
      prompt_secret password "密码" || return 1
      protocol_build inbound_json "$protocol" "$tag" "$listen" "$port" "$username" "$password"
      ;;
  esac

  printf -v "$__inbound" '%s' "$inbound_json"
  printf -v "$__host" '%s' "$public_host"
  printf -v "$__public_key" '%s' "$generated_public_key"
}
