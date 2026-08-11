certificate_server_names() {
  local cert=$1 san concrete
  san=$(openssl x509 -in "$cert" -noout -text 2>/dev/null \
    | awk '/X509v3 Subject Alternative Name/ {getline; print; exit}' | tr ',' '\n' \
    | sed -n -e 's/^[[:space:]]*DNS://p' -e 's/^[[:space:]]*IP Address://p')
  if [[ -n $san ]]; then
    concrete=$(printf '%s\n' "$san" | awk '$0 !~ /^\*\./ && !seen[$0]++')
    if [[ -n $concrete ]]; then printf '%s\n' "$concrete"; else printf '%s\n' "$san" | awk '!seen[$0]++'; fi
    return 0
  fi
  openssl x509 -in "$cert" -noout -subject -nameopt RFC2253 2>/dev/null \
    | sed -n 's/^subject=.*CN=\([^,]*\).*$/\1/p'
}

prompt_certificate_server_name() {
  local __var=$1 cert=$2 answer selected default_name name
  local names=()
  while IFS= read -r name; do [[ -n $name ]] && names+=("$name"); done < <(certificate_server_names "$cert")
  if ((${#names[@]} == 0)); then
    prompt_validated_value selected "TLS serverName/SNI" "" validate_domain_or_ip "SNI 必须是证书包含的有效域名/IP。"
  elif ((${#names[@]} == 1)); then
    selected=${names[0]}
  else
    choose answer "选择 TLS serverName/SNI" "${names[@]}"
    selected=${names[$((answer-1))]}
  fi
  if [[ $selected == \*.* ]]; then
    default_name="www.${selected#*.}"
    prompt_validated_value selected "TLS serverName/SNI" "$default_name" validate_domain "通配符证书需要填写具体子域名。"
  fi
  printf -v "$__var" '%s' "$selected"
}

validate_certificate_pair_files() {
  local cert=$1 key=$2 cert_pub key_pub
  [[ -r $cert ]] || { warn "证书文件不存在或不可读，请重新输入。"; return 1; }
  [[ -r $key ]] || { warn "私钥文件不存在或不可读，请重新输入。"; return 1; }
  openssl x509 -in "$cert" -noout >/dev/null 2>&1 \
    || { warn "证书格式无效，请重新输入。"; return 1; }
  openssl x509 -in "$cert" -checkend 0 -noout >/dev/null 2>&1 \
    || { warn "证书已经过期，请重新选择。"; return 1; }
  openssl pkey -in "$key" -noout >/dev/null 2>&1 \
    || { warn "私钥格式无效，请重新输入。"; return 1; }
  cert_pub=$(openssl x509 -in "$cert" -pubkey -noout 2>/dev/null | openssl pkey -pubin -outform DER 2>/dev/null | openssl sha256)
  key_pub=$(openssl pkey -in "$key" -pubout -outform DER 2>/dev/null | openssl sha256)
  [[ -n $cert_pub && $cert_pub == "$key_pub" ]] \
    || { warn "证书与私钥不匹配，请重新输入。"; return 1; }
}

prompt_certificate_files() {
  local __cert=$1 __key=$2 default_cert=${3:-} default_key=${4:-} entered_cert entered_key
  while true; do
    prompt_value entered_cert "证书文件路径" "$default_cert"
    prompt_value entered_key "私钥文件路径" "$default_key"
    if validate_certificate_pair_files "$entered_cert" "$entered_key"; then
      printf -v "$__cert" '%s' "$entered_cert"
      printf -v "$__key" '%s' "$entered_key"
      return 0
    fi
  done
}

ensure_certbot_environment() {
  # Idempotent: clean up legacy symlink if it points to our venv
  if [[ -L /usr/local/bin/certbot ]]; then
    local target
    target=$(readlink -f /usr/local/bin/certbot 2>/dev/null || true)
    [[ $target == "${CERTBOT_VENV}/bin/certbot" ]] && rm -f /usr/local/bin/certbot
  fi

  local manager pip_timeout=${XRAYCTL_CERT_PIP_TIMEOUT:-120} apt_timeout=${XRAYCTL_CERT_APT_TIMEOUT:-60}
  local need_install=0

  if [[ ! -x $CERTBOT_BIN ]]; then need_install=1
  elif ! "$CERTBOT_BIN" --help all 2>/dev/null | grep -q -- '--ip-address'; then need_install=1
  elif ! "$CERTBOT_VENV/bin/python" -c 'import certbot_dns_cloudflare' >/dev/null 2>&1; then need_install=1
  elif ! "$CERTBOT_VENV/bin/python" -c 'import certbot_nginx' >/dev/null 2>&1; then need_install=1
  fi

  if ((need_install == 1)); then
    manager=$(pkg_manager) || die "无法准备 Certbot 环境（未知的包管理器）。"
    info "正在准备独立的 Certbot 环境。"

  case $manager in
    apt)
      DEBIAN_FRONTEND=noninteractive XRAYCTL_APT_TIMEOUT="$apt_timeout" \
        apt_get_guarded install -y --no-install-recommends python3 python3-venv \
        || die "Python venv 安装失败或超时。" ;;
    dnf) run_bounded "$apt_timeout" dnf install -y python3 python3-pip || die "Python 环境安装失败或超时。" ;;
    yum) run_bounded "$apt_timeout" yum install -y python3 python3-pip || die "Python 环境安装失败或超时。" ;;
    pacman) run_bounded "$apt_timeout" pacman -Sy --noconfirm python python-pip || die "Python 环境安装失败或超时。" ;;
    zypper) run_bounded "$apt_timeout" zypper --non-interactive install python3 python3-pip || die "Python 环境安装失败或超时。" ;;
  esac

  install -d -m 755 "$(dirname "$CERTBOT_VENV")"
  if [[ ! -x $CERTBOT_VENV/bin/python ]]; then
    python3 -m venv "$CERTBOT_VENV" || {
      python3 -m venv --without-pip "$CERTBOT_VENV" || die "无法创建 Certbot Python 环境。"
      local bootstrap
      bootstrap=$(temp_file)
      if ! curl --fail --location --proto '=https' --tlsv1.2 --retry 2 \
        --connect-timeout 15 --max-time 60 https://bootstrap.pypa.io/get-pip.py -o "$bootstrap"; then
        rm -f "$bootstrap"; die "下载 pip 引导脚本失败。"
      fi
      if ! run_bounded "$pip_timeout" "$CERTBOT_VENV/bin/python" "$bootstrap" --disable-pip-version-check; then
        rm -f "$bootstrap"; die "pip 引导安装失败。"
      fi
      rm -f "$bootstrap"
    }
  fi

  info "正在安装 Certbot 及插件。"
  run_bounded "$pip_timeout" "$CERTBOT_VENV/bin/pip" install --disable-pip-version-check \
    --timeout 15 --retries 2 --upgrade 'certbot>=5.4' certbot-dns-cloudflare certbot-nginx \
    || die "Certbot / 插件安装失败。"

  "$CERTBOT_BIN" --help all 2>/dev/null | grep -q -- '--ip-address' \
    || die "当前安装的 Certbot 不支持 IP 证书。"
  "$CERTBOT_VENV/bin/pip" list 2>/dev/null | grep -q 'certbot-dns-cloudflare' \
    || warn "certbot-dns-cloudflare 插件安装可能失败，Cloudflare DNS 验证不可用。"
  fi  # end of need_install == 1 block

  mkdir -p "$CERTBOT_CONFIG_DIR" "$CERTBOT_WORK_DIR" "$CERTBOT_LOGS_DIR"
  meta_resource_register "certbotVenv" "$CERTBOT_VENV"
  meta_resource_register "certbotConfigDir" "$CERTBOT_CONFIG_DIR"
  meta_resource_register "certbotWorkDir" "$CERTBOT_WORK_DIR"
  meta_resource_register "certbotLogsDir" "$CERTBOT_LOGS_DIR"
}

certbot_cmd() {
  "$CERTBOT_BIN" \
    --config-dir "$CERTBOT_CONFIG_DIR" \
    --work-dir "$CERTBOT_WORK_DIR" \
    --logs-dir "$CERTBOT_LOGS_DIR" \
    "$@"
}

setup_certbot_renewal_timer() {
  local quick_command="${QUICK_COMMAND:-/usr/local/sbin/xrayctl}"
  [[ -x $quick_command ]] || install_quick_command
  if [[ $(platform_init_system) == openrc ]]; then
    install -d -m 755 "$(dirname "$CERT_RENEW_HOOK")"
    cat >"$CERT_RENEW_HOOK" <<EOF
#!/bin/sh
${quick_command} cert renew-auto >/dev/null 2>&1
EOF
    chmod 755 "$CERT_RENEW_HOOK"
    meta_resource_register "renewHook" "$CERT_RENEW_HOOK"
  else
    cat >/etc/systemd/system/xrayctl-certbot-renew.service <<EOF
[Unit]
Description=Renew certificates managed by xrayctl

[Service]
Type=oneshot
ExecStart=${quick_command} cert renew-auto
EOF
  cat >/etc/systemd/system/xrayctl-certbot-renew.timer <<'EOF'
[Unit]
Description=Renew certificates managed by xrayctl

[Timer]
OnCalendar=*-*-* 00,12:00:00
RandomizedDelaySec=1h
Persistent=true

[Install]
WantedBy=timers.target
EOF
    systemctl daemon-reload
    systemctl enable --now xrayctl-certbot-renew.timer >/dev/null
    meta_resource_register "renewTimer" "xrayctl-certbot-renew.timer"
    meta_resource_register "renewService" "xrayctl-certbot-renew.service"
  fi
}

replace_certificate_pair() {
  local source_cert=$1 source_key=$2 cert_target=$3 key_target=$4 __changed_var=${5:-}
  local cert_tmp="${cert_target}.new"   key_tmp="${key_target}.new"
  local cert_bak="${cert_target}.old"   key_bak="${key_target}.old"
  local had_cert=0 had_key=0 need_rollback=0
  local replace_changed=0

  # --- Compute change BEFORE any replacement ---
  if ! cmp -s "$source_cert" "$cert_target" 2>/dev/null ||
     ! cmp -s "$source_key"  "$key_target"  2>/dev/null; then
    replace_changed=1
  fi

  if [[ $replace_changed == 0 ]]; then
    [[ -n $__changed_var ]] && printf -v "$__changed_var" '%s' "0"
    return 0
  fi

  setup_certificate_access

  install -m 640 -o "$RUNTIME_OWNER" -g "$RUNTIME_GROUP" "$source_cert" "$cert_tmp" || return 1
  install -m 640 -o "$RUNTIME_OWNER" -g "$RUNTIME_GROUP" "$source_key"  "$key_tmp"  || { rm -f "$cert_tmp"; return 1; }

  if ! validate_certificate_pair_files "$cert_tmp" "$key_tmp"; then
    rm -f "$cert_tmp" "$key_tmp"
    warn "新证书/私钥验证失败，已放弃替换。"
    return 1
  fi

  if [[ -f $cert_target ]]; then
    had_cert=1
    if ! cp -a "$cert_target" "$cert_bak"; then
      rm -f "$cert_tmp" "$key_tmp"
      warn "备份当前证书失败，已取消替换。"
      return 1
    fi
  fi
  if [[ -f $key_target ]]; then
    had_key=1
    if ! cp -a "$key_target" "$key_bak"; then
      rm -f "$cert_tmp" "$key_tmp" "$cert_bak"
      warn "备份当前私钥失败，已取消替换。"
      return 1
    fi
  fi

  if ! mv -f "$cert_tmp" "$cert_target"; then need_rollback=1; fi
  if ! mv -f "$key_tmp"  "$key_target";  then need_rollback=1; fi

  if ((need_rollback)); then
    rm -f "$cert_tmp" "$key_tmp"
    if ((had_cert)); then mv -f "$cert_bak" "$cert_target" || true; else rm -f "$cert_target"; fi
    if ((had_key));  then mv -f "$key_bak"  "$key_target" || true; else rm -f "$key_target"; fi
    warn "证书替换失败，已恢复原状态。"
    return 1
  fi

  rm -f "$cert_bak" "$key_bak"

  if [[ -n $__changed_var ]]; then
    printf -v "$__changed_var" '%s' "$replace_changed"
  fi
  return 0
}

restart_xray_if_certificate_changed() {
  local changed=$1
  [[ $changed == 1 ]] || return 0
  service_is_active || return 0
  if ! restart_service; then
    warn "证书已更新，但 Xray 重启失败。"
    return 1
  fi
  info "Xray 已重启以加载新证书。"
}

sync_managed_certificate() {
  local identifier=$1 cert_name=${2:-$1} __changed_var=${3:-}
  local source_cert="${CERTBOT_CONFIG_DIR}/live/${cert_name}/fullchain.pem"
  local source_key="${CERTBOT_CONFIG_DIR}/live/${cert_name}/privkey.pem"
  local cert_target="${CERT_DIR}/${identifier}.crt"
  local key_target="${CERT_DIR}/${identifier}.key"

  [[ -r $source_cert ]] || { warn "无法读取证书：${source_cert}"; return 1; }
  [[ -r $source_key ]]  || { warn "无法读取私钥：${source_key}"; return 1; }

  replace_certificate_pair "$source_cert" "$source_key" "$cert_target" "$key_target" "$__changed_var"
}

hash_ipv6_identifier() {
  local ip=$1
  printf 'ip6-%s' "$(printf '%s' "$ip" | sha256sum | cut -c1-8)"
}

hash_ipv4_identifier() {
  local ip=$1
  printf 'ip4-%s' "$(printf '%s' "$ip" | sha256sum | cut -c1-8)"
}

certificate_identifier_for_subject() {
  local subject=$1
  if validate_ip_literal "$subject"; then
    if [[ $subject == *:* ]]; then
      hash_ipv6_identifier "$subject"
    else
      hash_ipv4_identifier "$subject"
    fi
  else
    printf '%s' "$subject"
  fi
}

detect_port80_owner() {
  local pid pname
  pid=$(ss -tlnp 2>/dev/null | awk '/:80 /{print $NF}' | sed -n 's/.*pid=\([0-9]*\).*/\1/p' | head -1)
  if [[ -z $pid ]]; then
    pid=$(netstat -tlnp 2>/dev/null | awk '/:80 /{print $NF}' | sed -n 's/.*\///p' | head -1)
    if [[ -z $pid ]]; then printf 'free'; return 0; fi
    pname="$pid"
  else
    pname=$(ps -p "$pid" -o comm= 2>/dev/null || true)
  fi
  case $pname in
    xray) printf 'xray';;
    nginx) printf 'nginx';;
    httpd|apache2) printf 'apache';;
    "") printf 'free';;
    *) printf 'other';;
  esac
}

update_tls_inbound_certificate() {
  local tag=$1 cert_path=$2 key_path=$3 sni=$4 tmp method
  inbound_exists "$tag" || { warn "入站不存在：${tag}"; return 1; }
  [[ $(jq -r --arg tag "$tag" '.inbounds[]|select(.tag==$tag)|.streamSettings.security // "none"' "$CONFIG_FILE") == tls ]] \
    || { warn "只有使用 TLS 的入站可以更换证书。"; return 1; }
  validate_certificate_pair_files "$cert_path" "$key_path" || return 1
  method=$(jq -r --arg tag "$tag" '.inbounds[]|select(.tag==$tag)|.streamSettings.method // "raw"' "$CONFIG_FILE")
  tmp=$(temp_file)
  jq --arg tag "$tag" --arg cert "$cert_path" --arg key "$key_path" --arg sni "$sni" --arg method "$method" '
    (.inbounds[]|select(.tag==$tag)|.streamSettings) |= (
      .tlsSettings={
        serverName:$sni,
        alpn:(if $method=="websocket" then ["http/1.1"] else ["h2","http/1.1"] end),
        minVersion:"1.2",
        certificates:[{certificateFile:$cert,keyFile:$key}]
      }
    )' "$CONFIG_FILE" >"$tmp"
  state_apply_candidate_file "$tmp" apply_candidate || return
  info "证书已更新：${tag}"
}

# ============================================================
# Cloudflare credentials
# ============================================================

load_cloudflare_credentials() {
  [[ -f $CLOUDFLARE_INI && -r $CLOUDFLARE_INI ]] || return 1
  grep -q 'dns_cloudflare_api_key' "$CLOUDFLARE_INI" 2>/dev/null
}

cloudflare_dependent_certificates() {
  init_meta
  jq -r '.certificates | to_entries[] | select(.value.validation == "dns-cloudflare") | .key' "$META_FILE" 2>/dev/null
}

cf_credentials_summary() {
  local deps dep_count=0
  deps=$(cloudflare_dependent_certificates)
  [[ -n $deps ]] && dep_count=$(printf '%s\n' "$deps" | grep -c .)
  printf '依赖证书: %s\n' "$dep_count"
  if load_cloudflare_credentials; then
    printf '自动续期状态: 可用\n'
  else
    printf '自动续期状态: 阻塞（凭据缺失）\n'
  fi
}

save_cloudflare_credentials() {
  local email="" api_key=""
  while [[ -z $email ]]; do
    prompt_value email "Cloudflare 邮箱"
    if [[ $email == *@*.* && $email != *" "* ]]; then break; fi
    warn "邮箱格式无效，请重新输入。"
    email=""
  done
  while [[ -z $api_key ]]; do
    prompt_hidden_secret api_key "Cloudflare Global API Key"
    [[ -n $api_key ]] && break
    warn "API Key 不能为空。"
  done
  mkdir -p "$(dirname "$CLOUDFLARE_INI")"
  printf '%s\n' "dns_cloudflare_email = ${email}" "dns_cloudflare_api_key = ${api_key}" >"$CLOUDFLARE_INI"
  chmod 600 "$CLOUDFLARE_INI"
  info "Cloudflare 凭据已保存至 ${CLOUDFLARE_INI}"
  meta_resource_register "cloudflareCredentials" "$CLOUDFLARE_INI"
}

cloudflare_credentials_menu() {
  local choice deps
  while true; do
    clear_screen
    heading "Cloudflare 凭据管理"
    if load_cloudflare_credentials; then
      local email
      email=$(grep 'dns_cloudflare_email' "$CLOUDFLARE_INI" 2>/dev/null | sed 's/.*=\s*//')
      printf 'Cloudflare 邮箱: %s\n' "${email:-未知}"
      printf 'Global API Key: 已配置\n'
      cf_credentials_summary
      printf '\n1) 更新 Global API Key\n2) 删除保存的凭据\n0) 返回\n'
    else
      printf 'Cloudflare 凭据: 未配置\n'
      cf_credentials_summary
      printf '\n1) 配置 Cloudflare 凭据\n0) 返回\n'
    fi
    read -r -p "请选择: " choice || { echo; return; }
    case $choice in
      1) save_cloudflare_credentials; pause;;
      2) if load_cloudflare_credentials; then
           deps=$(cloudflare_dependent_certificates)
           if [[ -n $deps ]]; then
             printf '\n依赖证书（%s 张）：\n\n' "$(printf '%s\n' "$deps" | grep -c .)"
             printf '%s\n' "$deps" | sed 's/^/  - /'
             printf '\n删除凭据后这些证书将无法自动续期。\n'
           fi
           confirm "仍然删除 Cloudflare 凭据？" N || { info "已取消。"; pause; continue; }
           rm -f "$CLOUDFLARE_INI"
           meta_resource_remove "cloudflareCredentials"
           info "Cloudflare 凭据已删除。下次自动续期将阻塞。"
         fi
         pause;;
      0) return;; *) warn "无效选项。"; pause;;
    esac
  done
}

# ============================================================
# Certificate issuance sub-functions
# ============================================================

issue_domain_cloudflare() {
  local domain=$1 email=$2 force=${3:-0}
  local certbot_args=(certonly --dns-cloudflare --dns-cloudflare-credentials "$CLOUDFLARE_INI" \
    --non-interactive --agree-tos --cert-name "$domain" -m "$email" -d "$domain")
  [[ $force == 1 ]] && certbot_args+=(--force-renewal)
  certbot_cmd "${certbot_args[@]}"
}

issue_domain_http() {
  local domain=$1 email=$2 force=${3:-0}
  local owner was_active=0
  owner=$(detect_port80_owner)
  local certbot_args=(certonly --standalone --non-interactive --agree-tos \
    --preferred-challenges http --cert-name "$domain" -m "$email" -d "$domain")
  [[ $force == 1 ]] && certbot_args+=(--force-renewal)

  case $owner in
    free)
      certbot_cmd "${certbot_args[@]}"
      ;;
    xray)
      service_is_active && { was_active=1; platform_service_stop; CERT_STOPPED_SERVICE=1; }
      if ! certbot_cmd "${certbot_args[@]}"; then
        ((was_active)) && { platform_service_start || true; CERT_STOPPED_SERVICE=0; }
        return 1
      fi
      if ((was_active)); then
        platform_service_start; CERT_STOPPED_SERVICE=0
      fi
      ;;
    nginx)
      certbot_args=(certonly --nginx --non-interactive --agree-tos \
        --cert-name "$domain" -m "$email" -d "$domain")
      [[ $force == 1 ]] && certbot_args+=(--force-renewal)
      certbot_cmd "${certbot_args[@]}"
      ;;
    apache)
      warn "80 端口被 Apache 占用，暂不支持 certbot --apache 自动验证。"
      warn "建议使用 Cloudflare DNS 自动验证（无需占用端口）。"
      return 1
      ;;
    *)
      warn "80 端口被其他程序占用，无法使用 HTTP 验证。请选择 Cloudflare DNS 自动验证。"
      return 1
      ;;
  esac
}

issue_domain_manual_dns() {
  local domain=$1 email=$2 force=${3:-0}
  local certbot_args=(certonly --manual --agree-tos -m "$email" --preferred-challenges dns --cert-name "$domain" -d "$domain")
  [[ $force == 1 ]] && certbot_args+=(--force-renewal)
  info "Certbot 将提示添加 TXT 记录，请在 DNS 面板添加后回车继续。"
  certbot_cmd "${certbot_args[@]}"
}

issue_ip_certificate() {
  local ip=$1 email=$2 force=${3:-0} identifier owner was_active=0
  identifier=$(certificate_identifier_for_subject "$ip")
  owner=$(detect_port80_owner)
  local certbot_args=(certonly --standalone --non-interactive --agree-tos \
    --preferred-challenges http --cert-name "$identifier" -m "$email" \
    --preferred-profile shortlived --ip-address "$ip")
  [[ $force == 1 ]] && certbot_args+=(--force-renewal)

  case $owner in
    free) certbot_cmd "${certbot_args[@]}";;
    xray)
      service_is_active && { was_active=1; platform_service_stop; CERT_STOPPED_SERVICE=1; }
      if ! certbot_cmd "${certbot_args[@]}"; then
        ((was_active)) && { platform_service_start || true; CERT_STOPPED_SERVICE=0; }
        return 1
      fi
      if ((was_active)); then
        platform_service_start; CERT_STOPPED_SERVICE=0
      fi
      ;;
    *) warn "80 端口被占用，IP 证书只能使用 HTTP 验证。"; return 1;;
  esac
}

# ============================================================
# Main certificate issue entry point
# ============================================================

issue_certificate() {
  ensure_runtime_dependencies cert-issue
  ensure_certbot_environment
  local domain=${1-} email=${2-} force=0 mode=domain verify_method="" identifier="" cert_name=""
  local was_active=0 rc=0

  if [[ -z $domain ]]; then
    local default_domain
    default_domain=$(detect_public_ip || true)
    prompt_validated_value domain "证书域名/IP" "$default_domain" validate_domain_or_ip "域名/IP 无效，请重新输入。"
  fi
  if validate_ip_literal "$domain"; then mode=ip;
  elif ! validate_domain "$domain"; then die "证书域名/IP 无效。"; fi

  # Determine cert_name / identifier
  if [[ $mode == ip ]]; then
    identifier=$(certificate_identifier_for_subject "$domain")
    cert_name="$identifier"
  else
    identifier="$domain"
    cert_name="$domain"
  fi

  # Choose verification method for domains
  if [[ $mode == domain ]]; then
    local cf_label="Cloudflare DNS 自动验证"
    local dns_label="DNS 手动验证（无法自动续期）"
    local http_label="HTTP 自动验证"
    if load_cloudflare_credentials; then
      choose verify_method "选择验证方式" "$cf_label" "$http_label" "$dns_label"
    else
      choose verify_method "选择验证方式" "$http_label" "$dns_label"
      if [[ $verify_method == 1 ]]; then verify_method=http; else verify_method=dns-manual; fi
      # Adjust for CF case
      if load_cloudflare_credentials; then true; fi
    fi
    # Remap after choose with CF
    if load_cloudflare_credentials; then
      case $verify_method in
        1) verify_method=dns-cloudflare;; 2) verify_method=http;; 3) verify_method=dns-manual;;
      esac
    fi
  fi

  [[ -n $email ]] || prompt_validated_value email "Let's Encrypt 联系邮箱" "" validate_email_address "邮箱格式无效，请重新输入。"
  validate_email_address "$email" || die "邮箱格式无效。"

  # Check if cert already exists
  if [[ -f ${CERT_DIR}/${identifier}.crt && -f ${CERT_DIR}/${identifier}.key ]]; then
    local using_inbounds
    using_inbounds=$(jq -r --arg cert "${CERT_DIR}/${identifier}.crt" \
      '.inbounds[]?|select(.streamSettings.tlsSettings.certificates[0].certificateFile==$cert)|.tag' "$CONFIG_FILE" 2>/dev/null | paste -sd ',')
    if [[ -n $using_inbounds ]]; then
      confirm "证书 ${identifier} 正在被 ${using_inbounds} 使用，是否强制重新签发？" N || { info "已取消。"; return 0; }
    else
      confirm "证书 ${identifier} 已存在，是否强制重新签发？" N || { info "已取消。"; return 0; }
    fi
    force=1
  fi

  # Issue
  local validation="" auto_renew="true"
  case $mode:$verify_method in
    domain:dns-cloudflare)
      validation=dns-cloudflare
      issue_domain_cloudflare "$domain" "$email" "$force" || rc=1
      ;;
    domain:http)
      validation=http-standalone
      local owner; owner=$(detect_port80_owner)
      [[ $owner == nginx ]] && validation=http-nginx
      issue_domain_http "$domain" "$email" "$force" || rc=1
      ;;
    domain:dns-manual)
      validation=dns-manual; auto_renew="false"
      issue_domain_manual_dns "$domain" "$email" "$force" || rc=1
      ;;
    ip:*)
      validation=http-standalone
      issue_ip_certificate "$domain" "$email" "$force" || rc=1
      ;;
  esac

  if ((rc != 0)); then
    warn "证书签发失败，请查看上方 Certbot 输出的具体原因。"
    return 1
  fi

  # Sync cert to CERT_DIR and register metadata
  local changed
  if ! sync_managed_certificate "$identifier" "$cert_name" changed; then
    warn "证书已经由 Let's Encrypt 签发，但无法同步到 Xray 证书目录。"
    warn "Certbot 原始证书仍保留在 ${CERTBOT_CONFIG_DIR}，可修复权限后重新同步。"
    return 1
  fi
  register_certificate_metadata "$identifier" "$domain" "$cert_name" "letsencrypt" "$validation" "$auto_renew"
  setup_certbot_renewal_timer
  restart_xray_if_certificate_changed "$changed" || return 1
  info "证书已签发并托管：${identifier}"
}

register_certificate_metadata() {
  local identifier=$1 subject=$2 cert_name=$3 source=$4 validation=$5 auto_renew=$6
  meta_cert_set "$identifier" "$subject" "$cert_name" "$source" "$validation" "$auto_renew"
}

# ============================================================
# Certificate import / list / count / delete
# ============================================================

import_certificate() {
  ensure_runtime_dependencies cert-import
  local domain=${1-} cert=${2-} key=${3-}
  [[ -n $domain ]] || prompt_validated_value domain "证书标识/域名" "" validate_certificate_identifier "证书标识只能包含字母、数字、点和横线。"
  [[ $domain =~ ^[A-Za-z0-9.-]+$ ]] || die "证书标识无效。"
  [[ -n $cert ]] || prompt_validated_value cert "证书文件路径" "" validate_readable_file "证书文件不存在或不可读，请重新输入。"
  [[ -n $key ]] || prompt_validated_value key "私钥文件路径" "" validate_readable_file "私钥文件不存在或不可读，请重新输入。"
  local changed=0
  local cert_target="${CERT_DIR}/${domain}.crt"
  local key_target="${CERT_DIR}/${domain}.key"
  if ! replace_certificate_pair "$cert" "$key" "$cert_target" "$key_target" changed; then
    warn "证书替换失败，导入未完成。"
    return 1
  fi
  meta_cert_set "$domain" "$domain" "$domain" "imported" "dns-manual" "false"
  restart_xray_if_certificate_changed "$changed" || return 1
  info "证书已导入：${cert_target}"
}

list_certificates() {
  ensure_meta
  local id cert found=0 source validation auto_renew subject cert_name
  while IFS= read -r id; do
    [[ -n $id ]] || continue
    cert="${CERT_DIR}/${id}.crt"
    found=1
    subject=$(meta_cert_get_field "$id" subject)
    cert_name=$(meta_cert_get_field "$id" certName)
    source=$(meta_cert_get_field "$id" source)
    validation=$(meta_cert_get_field "$id" validation)
    auto_renew=$(meta_cert_get_field "$id" autoRenew)
    printf '标识: %s\n' "$id"
    [[ -n $subject && $subject != "$id" ]] && printf '域名/IP: %s\n' "$subject"
    [[ -n $cert_name && $cert_name != "$id" ]] && printf 'Certbot名称: %s\n' "$cert_name"
    case $source in
      legacy)   printf '来源: 旧版本迁移\n';;
      imported) printf '来源: 手动导入\n';;
      letsencrypt) printf '来源: Let'"'"'s Encrypt\n';;
      *)        [[ -n $source ]] && printf '来源: %s\n' "$source";;
    esac
    [[ -n $validation && $validation != "legacy" ]] && printf '验证: %s\n' "$validation"
    if [[ $auto_renew == "true" ]]; then
      if [[ $validation == dns-cloudflare ]] && ! load_cloudflare_credentials; then
        printf '自动续期: 是（阻塞：Cloudflare 凭据缺失）\n'
      else
        printf '自动续期: 是\n'
      fi
    else
      printf '自动续期: 否\n'
    fi
    case $source in
      legacy) printf '状态: 需重新签发以恢复自动续期\n';;
    esac
    if [[ -r $cert ]]; then
      openssl x509 -in "$cert" -noout -subject -issuer -dates 2>/dev/null | sed 's/^/  /'
    else
      printf '[证书文件缺失]\n'
    fi
    printf '\n'
  done < <(meta_cert_list)
  ((found)) || info "还没有托管证书。"
}

certificate_count() {
  meta_cert_list | grep -c . 2>/dev/null || printf '0'
}

managed_certificate_count() {
  meta_cert_list | grep -c . 2>/dev/null || printf '0'
}

# ============================================================
# Certificate renewal
# ============================================================

renew_one_certificate() {
  local identifier=$1 __result_var=${2:-}
  local cert_name validation owner
  local renewal_result_internal="failed"
  local lineage_changed=0 sync_changed=0
  local before_serial="" after_serial=""
  local live_cert="${CERTBOT_CONFIG_DIR}/live"

  meta_cert_exists "$identifier" || {
    warn "证书不在托管列表：${identifier}"
    [[ -n $__result_var ]] && printf -v "$__result_var" '%s' "failed"
    return 1
  }
  cert_name=$(meta_cert_get_field "$identifier" certName)
  [[ -n $cert_name ]] || {
    warn "证书缺少 certName：${identifier}"
    [[ -n $__result_var ]] && printf -v "$__result_var" '%s' "failed"
    return 1
  }
  validation=$(meta_cert_get_field "$identifier" validation)

  # --- Dependency / block check ---
  case $validation in
    dns-cloudflare)
      if ! load_cloudflare_credentials; then
        warn "${identifier}: Cloudflare 凭据缺失，续期阻塞。"
        [[ -n $__result_var ]] && printf -v "$__result_var" '%s' "blocked"
        return 0
      fi
      ;;
    http-standalone)
      owner=$(detect_port80_owner)
      case $owner in
        free|xray) ;;
        *)
          warn "${identifier}: 80 端口被 ${owner} 占用，续期阻塞。"
          [[ -n $__result_var ]] && printf -v "$__result_var" '%s' "blocked"
          return 0
          ;;
      esac
      ;;
    dns-manual)
      warn "${identifier}: 手动 DNS 无法自动续期。"
      [[ -n $__result_var ]] && printf -v "$__result_var" '%s' "blocked"
      return 0
      ;;
  esac

  # --- Build certbot args ---
  local certbot_args=(renew --cert-name "$cert_name" --quiet)
  if [[ $validation == http-standalone ]]; then
    owner=$(detect_port80_owner)
    [[ $owner == xray ]] && certbot_args+=(--pre-hook "$(platform_service_hook_command stop)" \
      --post-hook "$(platform_service_hook_command start)")
  fi

  # --- Record fingerprint before ---
  if [[ -r ${live_cert}/${cert_name}/fullchain.pem ]]; then
    before_serial=$(openssl x509 -in "${live_cert}/${cert_name}/fullchain.pem" \
      -noout -serial 2>/dev/null || true)
  fi

  # --- Renew ---
  if ! certbot_cmd "${certbot_args[@]}"; then
    warn "证书续期失败：${identifier}"
    [[ -n $__result_var ]] && printf -v "$__result_var" '%s' "failed"
    return 1
  fi

  # --- Record fingerprint after ---
  if [[ -r ${live_cert}/${cert_name}/fullchain.pem ]]; then
    after_serial=$(openssl x509 -in "${live_cert}/${cert_name}/fullchain.pem" \
      -noout -serial 2>/dev/null || true)
  fi
  if [[ -n $before_serial && -n $after_serial && $before_serial != "$after_serial" ]]; then
    lineage_changed=1
  fi

  # --- Sync to Xray ---
  if ! sync_managed_certificate "$identifier" "$cert_name" sync_changed; then
    warn "Let's Encrypt 已续期，但同步到 Xray 证书目录失败：${identifier}"
    [[ -n $__result_var ]] && printf -v "$__result_var" '%s' "failed"
    return 1
  fi

  # --- Determine result: lineage_changed = renewal happened ---
  if [[ $lineage_changed == 1 ]]; then
    renewal_result_internal="renewed"
  else
    renewal_result_internal="unchanged"
  fi

  # --- Restart Xray IFF CERT_DIR copy changed ---
  if [[ $sync_changed == 1 ]] && service_is_active; then
    if ! restart_service; then
      warn "证书副本已更新，但 Xray 重启失败。"
      [[ -n $__result_var ]] && printf -v "$__result_var" '%s' "failed"
      return 1
    fi
    info "Xray 已重启以加载新证书。"
  fi

  if [[ -n $__result_var ]]; then
    printf -v "$__result_var" '%s' "$renewal_result_internal"
  fi
  return 0
}

renew_managed_certificates() {
  ensure_runtime_dependencies cert-renew
  local renewed=0 unchanged=0 blocked=0 failed=0 id result
  local blocked_list=""
  while IFS= read -r id; do
    [[ -n $id ]] || continue
    result=""

    if ! renew_one_certificate "$id" result; then
      [[ -n $result ]] || result="failed"
    fi

    case $result in
      renewed)   ((renewed+=1));;
      unchanged) ((unchanged+=1));;
      blocked)   ((blocked+=1)); blocked_list+="${id}"$'\n';;
      failed)    ((failed+=1));;
      *)
        warn "证书 ${id} 返回未知续期状态：${result:-empty}"
        ((failed+=1))
        ;;
    esac
  done < <(meta_cert_auto_renew_certs)
  if ((renewed > 0 || unchanged > 0 || blocked > 0 || failed > 0)); then
    printf '\n续期检查完成：\n'
    [[ $renewed   -gt 0 ]] && printf '  已续期: %s\n' "$renewed"
    [[ $unchanged -gt 0 ]] && printf '  无需续期: %s\n' "$unchanged"
    [[ $blocked   -gt 0 ]] && printf '  阻塞: %s\n' "$blocked"
    [[ $failed    -gt 0 ]] && printf '  失败: %s\n' "$failed"
    if [[ -n $blocked_list ]]; then
      printf '\n阻塞详情：\n%s' "$blocked_list"
    fi
  else
    info "没有需要续期的证书。"
  fi
  if ((failed > 0)); then
    return 1
  fi
  return 0
}

renew_certificate_command() {
  local identifier=${1-} result=""
  ensure_runtime_dependencies cert-renew
  [[ -n $identifier ]] || die "请提供证书标识。"
  if ! renew_one_certificate "$identifier" result; then
    return 1
  fi
  case $result in
    renewed)   info "${identifier}: 已续期。";;
    unchanged) info "${identifier}: 无需续期。";;
    blocked)   warn "${identifier}: 自动续期被阻塞。";;
    failed)    return 1;;
  esac
}

# ============================================================
# Certificate selection / inbound check / delete
# ============================================================

select_managed_certificate() {
  local __var=$1 always_choose=${2:-0} answer
  local identifiers=()
  while IFS= read -r id; do
    [[ -n $id ]] || continue
    [[ -r "${CERT_DIR}/${id}.crt" && -r "${CERT_DIR}/${id}.key" ]] && identifiers+=("$id")
  done < <(meta_cert_list)
  ((${#identifiers[@]} > 0)) || { warn "没有可用的托管证书。"; return 1; }
  if ((${#identifiers[@]} == 1)) && [[ $always_choose != 1 ]]; then
    printf -v "$__var" '%s' "${identifiers[0]}"
    return 0
  fi
  choose answer "选择证书" "${identifiers[@]}"
  printf -v "$__var" '%s' "${identifiers[$((answer-1))]}"
}

certificate_inbound_users() {
  local identifier=$1 cert_path key_path
  cert_path="${CERT_DIR}/${identifier}.crt"
  key_path="${CERT_DIR}/${identifier}.key"
  [[ -r $CONFIG_FILE ]] || return 0
  jq -r --arg cert "$cert_path" --arg key "$key_path" '
    .inbounds[]? |
    select(.streamSettings.security=="tls") |
    select([.streamSettings.tlsSettings.certificates[]? |
      select(.certificateFile==$cert or .keyFile==$key)] | length > 0) |
    .tag' "$CONFIG_FILE"
}

delete_managed_certificate() {
  ensure_runtime_dependencies cert-delete
  local identifier=${1-} assume_yes=${2:-0} cert_path key_path renewal users tag
  [[ -n $identifier ]] || select_managed_certificate identifier 1 || return 0
  validate_certificate_identifier "$identifier" || die "证书标识无效。"
  meta_cert_exists "$identifier" || { warn "该证书不在 xrayctl 托管列表中，不予删除。"; return 0; }
  cert_path="${CERT_DIR}/${identifier}.crt"
  key_path="${CERT_DIR}/${identifier}.key"
  [[ -e $cert_path || -e $key_path ]] || warn "证书副本已缺失，将清理 metadata 及 Certbot 记录。"
  users=$(certificate_inbound_users "$identifier")
  if [[ -n $users ]]; then
    warn "证书正在被以下 TLS 入站使用，不能删除："
    while IFS= read -r tag; do [[ -n $tag ]] && printf '  - %s\n' "$tag" >&2; done <<<"$users"
    return 0
  fi
  [[ $assume_yes == 1 ]] || confirm "删除托管证书 ${identifier}？" N || return 0
  local cert_name
  cert_name=$(meta_cert_get_field "$identifier" certName)
  [[ -z $cert_name ]] && cert_name="$identifier"
  renewal="${CERTBOT_CONFIG_DIR}/renewal/${cert_name}.conf"
  if [[ -f $renewal ]]; then
    certbot_cmd delete --cert-name "$cert_name" --non-interactive \
      || { warn "Let's Encrypt 证书删除失败，托管副本未改动。"; return 1; }
  fi
  rm -f "$cert_path" "$key_path"
  meta_cert_delete "$identifier"
  info "托管证书已删除：${identifier}"
}

manage_inbound_certificate_menu() {
  local tag=$1 choice identifier cert key sni current_cert current_key current_sni
  while inbound_exists "$tag"; do
    [[ $(jq -r --arg tag "$tag" '.inbounds[]|select(.tag==$tag)|.streamSettings.security // "none"' "$CONFIG_FILE") == tls ]] || return 0
    current_cert=$(jq -r --arg tag "$tag" '.inbounds[]|select(.tag==$tag)|.streamSettings.tlsSettings.certificates[0].certificateFile // "未设置"' "$CONFIG_FILE")
    current_key=$(jq -r --arg tag "$tag" '.inbounds[]|select(.tag==$tag)|.streamSettings.tlsSettings.certificates[0].keyFile // "未设置"' "$CONFIG_FILE")
    current_sni=$(jq -r --arg tag "$tag" '.inbounds[]|select(.tag==$tag)|.streamSettings.tlsSettings.serverName // "未设置"' "$CONFIG_FILE")
    clear_screen
    heading "证书管理 · ${tag}"
    printf '证书: %s\n私钥: %s\nSNI: %s\n\n' "$current_cert" "$current_key" "$current_sni"
    printf '1) 更换托管证书\n2) 使用证书文件\n0) 返回入站\n'
    read -r -p "请选择: " choice || { echo; return; }
    case $choice in
      1)
        if select_managed_certificate identifier; then
          cert="${CERT_DIR}/${identifier}.crt"; key="${CERT_DIR}/${identifier}.key"
          info "使用托管证书：${identifier}"
          prompt_certificate_server_name sni "$cert"
          run_menu_action update_tls_inbound_certificate "$tag" "$cert" "$key" "$sni"
          pause
        else
          pause
        fi
        ;;
      2)
        prompt_certificate_files cert key "$current_cert" "$current_key"
        prompt_certificate_server_name sni "$cert"
        run_menu_action update_tls_inbound_certificate "$tag" "$cert" "$key" "$sni"
        pause
        ;;
      0) return;; *) warn "无效选项。"; pause;;
    esac
  done
}
