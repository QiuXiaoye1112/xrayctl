prompt_tls_certificate() {
  local __cert=$1 __key=$2 __sni=$3 identifier cert_value key_value sni_value
  if (( $(managed_certificate_count) > 0 )) && confirm "使用托管证书？" Y; then
    select_managed_certificate identifier || return 1
    cert_value="${CERT_DIR}/${identifier}.crt"
    key_value="${CERT_DIR}/${identifier}.key"
    validate_certificate_pair_files "$cert_value" "$key_value" || return 1
    info "使用托管证书：${identifier}"
  else
    prompt_certificate_files cert_value key_value
    info "使用证书文件：${cert_value}"
  fi
  prompt_certificate_server_name sni_value "$cert_value"
  info "TLS serverName/SNI：${sni_value}"
  printf -v "$__cert" '%s' "$cert_value"
  printf -v "$__key" '%s' "$key_value"
  printf -v "$__sni" '%s' "$sni_value"
}

generate_reality_keys() {
  local __private=$1 __public=$2 output key_private key_public
  xray_installed || die "生成 REALITY 密钥前请先安装 Xray。"
  output=$("$XRAY_BIN" x25519)
  key_private=$(awk -F': *' 'tolower($1) ~ /private/ {print $2; exit}' <<<"$output")
  key_public=$(awk -F': *' 'tolower($1) ~ /(public|password)/ {print $2; exit}' <<<"$output")
  [[ -n $key_private && -n $key_public ]] || { error "$output"; die "无法解析 Xray 生成的 REALITY 密钥。"; }
  printf -v "$__private" '%s' "$key_private"; printf -v "$__public" '%s' "$key_public"
}

build_stream_settings() {
  local protocol=$1 __json=$2 __public_key=$3
  local transport_choice security_choice method security path service target sni private public short_id cert key alpn json
  case $protocol in
    vless)
      choose security_choice "选择加密方式" "REALITY" "TLS" "无"
      case $security_choice in 1) security=reality;; 2) security=tls;; 3) security=none;; esac
      ;;
    trojan)
      choose security_choice "选择加密方式" "TLS" "REALITY" "无"
      case $security_choice in 1) security=tls;; 2) security=reality;; 3) security=none;; esac
      ;;
    *)
      choose security_choice "选择加密方式" "TLS" "无"
      case $security_choice in 1) security=tls;; 2) security=none;; esac
      ;;
  esac

  if [[ $security == reality || ( $protocol == trojan && $security != tls ) ]]; then
    choose transport_choice "选择传输方式" "RAW" "XHTTP" "gRPC"
    case $transport_choice in 1) method=raw;; 2) method=xhttp;; 3) method=grpc;; esac
  else
    choose transport_choice "选择传输方式" "RAW" "XHTTP" "WebSocket" "gRPC"
    case $transport_choice in 1) method=raw;; 2) method=xhttp;; 3) method=websocket;; 4) method=grpc;; esac
  fi

  json=$(jq -n --arg method "$method" --arg security "$security" '{method:$method,security:$security}')
  case $method in
    raw) json=$(jq '. + {rawSettings:{acceptProxyProtocol:false,header:{type:"none"}}}' <<<"$json") ;;
    xhttp)
      while true; do prompt_value path "XHTTP 路径" "/$(random_hex 6)"; validate_path "$path" && break; warn "路径必须以 / 开头且不含空格。"; done
      json=$(jq --arg path "$path" '. + {xhttpSettings:{path:$path,mode:"auto"}}' <<<"$json") ;;
    websocket)
      while true; do prompt_value path "WebSocket 路径" "/$(random_hex 6)"; validate_path "$path" && break; warn "路径必须以 / 开头且不含空格。"; done
      json=$(jq --arg path "$path" '. + {wsSettings:{path:$path,acceptProxyProtocol:false}}' <<<"$json") ;;
    grpc)
      prompt_value service "gRPC serviceName" "$(random_hex 6)"
      json=$(jq --arg service "$service" '. + {grpcSettings:{serviceName:$service,multiMode:false}}' <<<"$json") ;;
  esac

  case $security in
    reality)
      prompt_validated_value target "REALITY 目标" "www.microsoft.com:443" validate_reality_target "目标格式应为 域名:端口，请重新输入。"
      prompt_validated_value sni "REALITY serverName/SNI" "${target%%:*}" validate_domain "SNI 必须是有效域名，请重新输入。"
      generate_reality_keys private public
      short_id=$(random_hex 8)
      json=$(jq --arg target "$target" --arg sni "$sni" --arg private "$private" --arg short "$short_id" \
        '. + {realitySettings:{show:false,target:$target,xver:0,serverNames:[$sni],privateKey:$private,shortIds:[$short],maxTimeDiff:0}}' <<<"$json")
      printf -v "$__public_key" '%s' "$public"
      ;;
    tls)
      prompt_tls_certificate cert key sni
      if [[ $method == websocket ]]; then alpn='["http/1.1"]'; else alpn='["h2","http/1.1"]'; fi
      json=$(jq --arg cert "$cert" --arg key "$key" --arg sni "$sni" --argjson alpn "$alpn" \
        '. + {tlsSettings:{serverName:$sni,alpn:$alpn,minVersion:"1.2",certificates:[{certificateFile:$cert,keyFile:$key}]}}' <<<"$json")
      ;;
  esac
  printf -v "$__json" '%s' "$json"
}

reality_public_key() {
  local tag=$1 private output public
  private=$(jq -r --arg tag "$tag" '.inbounds[]|select(.tag==$tag)|.streamSettings.realitySettings.privateKey // empty' "$CONFIG_FILE")
  [[ -n $private ]] || return 1
  output=$("$XRAY_BIN" x25519 -i "$private" 2>/dev/null) || return 1
  public=$(awk -F': *' 'tolower($1) ~ /(public|password)/ {print $2; exit}' <<<"$output")
  [[ -n $public ]] || return 1
  printf '%s' "$public"
}

