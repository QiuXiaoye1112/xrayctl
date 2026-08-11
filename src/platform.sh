validate_ipv4() {
  local value=$1 a b c d extra
  IFS=. read -r a b c d extra <<<"$value"
  [[ -z ${extra:-} && $a =~ ^[0-9]{1,3}$ && $b =~ ^[0-9]{1,3}$ && $c =~ ^[0-9]{1,3}$ && $d =~ ^[0-9]{1,3}$ ]] \
    && ((10#$a <= 255 && 10#$b <= 255 && 10#$c <= 255 && 10#$d <= 255))
}

validate_ip_literal() {
  validate_ipv4 "$1" || [[ $1 == *:* && $1 =~ ^[0-9A-Fa-f:]+$ && ${#1} -le 45 ]]
}

detect_public_ipv4() {
  local response raw
  command_exists curl || return 1
  response=$({ curl -4 --fail --silent --show-error --location --proto '=https' --tlsv1.2 \
    --connect-timeout 3 --max-time 5 https://api.ipify.org 2>/dev/null || true; } | tr -d '[:space:]')
  if validate_ipv4 "$response"; then printf '%s' "$response"; return 0; fi

  response=$({ curl -4 --fail --silent --show-error --location --proto '=https' --tlsv1.2 \
    --connect-timeout 3 --max-time 5 https://checkip.amazonaws.com 2>/dev/null || true; } | tr -d '[:space:]')
  if validate_ipv4 "$response"; then printf '%s' "$response"; return 0; fi

  raw=$(curl -4 --fail --silent --show-error --location --proto '=https' --tlsv1.2 \
    --connect-timeout 3 --max-time 5 https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null || true)
  response=$(awk -F= '$1=="ip" {print $2; exit}' <<<"$raw" | tr -d '[:space:]')
  if validate_ipv4 "$response"; then printf '%s' "$response"; return 0; fi
  return 1
}

detect_public_ipv6() {
  local response raw
  command_exists curl || return 1
  response=$({ curl -6 --fail --silent --show-error --location --proto '=https' --tlsv1.2 \
    --connect-timeout 3 --max-time 5 https://api6.ipify.org 2>/dev/null || true; } | tr -d '[:space:]')
  if validate_ip_literal "$response" && ! validate_ipv4 "$response"; then printf '%s' "$response"; return 0; fi

  raw=$(curl -6 --fail --silent --show-error --location --proto '=https' --tlsv1.2 \
    --connect-timeout 3 --max-time 5 https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null || true)
  response=$(awk -F= '$1=="ip" {print $2; exit}' <<<"$raw" | tr -d '[:space:]')
  if validate_ip_literal "$response" && ! validate_ipv4 "$response"; then printf '%s' "$response"; return 0; fi
  return 1
}

detect_public_ip() { detect_public_ipv4 || detect_public_ipv6; }

detect_local_ips() {
  # 输出: display_label\tip\tinterface
  # 排除 loopback、link-local、docker/虚拟网桥
  local iface ip line
  if command_exists ip; then
    # ip -o 单行输出，$2=网卡 $4=地址
    while IFS= read -r line; do
      iface=$(awk '{print $2}' <<<"$line")
      ip=$(awk '{print $4}' <<<"$line"); ip=${ip%/*}
      [[ $iface =~ ^(docker|br-|veth|virbr|lo|lxc|cali|flannel|cilium) ]] && continue
      validate_ipv4 "$ip" || continue
      [[ $ip =~ ^127\. ]] && continue
      printf '%s (IPv4)\t%s\t%s\n' "$ip" "$ip" "$iface"
    done < <(ip -o -4 addr show 2>/dev/null)
    while IFS= read -r line; do
      iface=$(awk '{print $2}' <<<"$line")
      ip=$(awk '{print $4}' <<<"$line"); ip=${ip%/*}
      ip=${ip%%%*}
      [[ $iface =~ ^(docker|br-|veth|virbr|lo|lxc|cali|flannel|cilium) ]] && continue
      [[ -z $ip || $ip == ::1 || $ip == fe80:* ]] && continue
      printf '%s (IPv6)\t%s\t%s\n' "$ip" "$ip" "$iface"
    done < <(ip -o -6 addr show 2>/dev/null)
  elif command_exists ifconfig; then
    while IFS= read -r line; do
      iface=$(awk '{print $1}' <<<"$line" | sed 's/:$//')
      ip=$(awk '{print $2}' <<<"$line")
      validate_ipv4 "$ip" || continue
      [[ $ip =~ ^127\. ]] && continue
      printf '%s (IPv4)\t%s\t%s\n' "$ip" "$ip" "$iface"
    done < <(ifconfig 2>/dev/null | grep 'inet ' | grep -v '127\.')
    while IFS= read -r line; do
      iface=$(awk '{print $1}' <<<"$line" | sed 's/:$//')
      ip=$(awk '{print $2}' <<<"$line")
      ip=${ip%%%*}
      [[ -z $ip || $ip == ::1 || $ip == fe80:* ]] && continue
      printf '%s (IPv6)\t%s\t%s\n' "$ip" "$ip" "$iface"
    done < <(ifconfig 2>/dev/null | grep 'inet6 ' | grep -v '::1\|fe80:')
  fi
}

ensure_linux_systemd() {
  is_linux || die "仅支持 Linux；当前系统是 $(uname -s)。"
  is_systemd || die "需要使用 systemd 的 Linux 发行版。"
}

pkg_manager() {
  if command_exists apt-get; then printf 'apt';
  elif command_exists dnf; then printf 'dnf';
  elif command_exists yum; then printf 'yum';
  elif command_exists pacman; then printf 'pacman';
  elif command_exists zypper; then printf 'zypper';
  else return 1; fi
}

apt_get_guarded() {
  local total_timeout=${XRAYCTL_APT_TIMEOUT:-180}
  local apt_options=(
    -o Acquire::Retries=2
    -o Acquire::http::Timeout=15
    -o Acquire::https::Timeout=15
    -o Dpkg::Use-Pty=0
  )
  case ${XRAYCTL_APT_FORCE_IPV4:-auto} in
    1|true|yes) apt_options+=(-o Acquire::ForceIPv4=true) ;;
    0|false|no) ;;
    *)
      if [[ -z $APT_IPV4_AVAILABLE_CACHE ]]; then
        if detect_public_ipv4 >/dev/null; then APT_IPV4_AVAILABLE_CACHE=1; else APT_IPV4_AVAILABLE_CACHE=0; fi
      fi
      [[ $APT_IPV4_AVAILABLE_CACHE == 0 ]] || apt_options+=(-o Acquire::ForceIPv4=true)
      ;;
  esac
  if command_exists timeout; then
    timeout --foreground "${total_timeout}s" apt-get "${apt_options[@]}" "$@"
  else
    apt-get "${apt_options[@]}" "$@"
  fi
}

apt_package_index_available() {
  [[ -d /var/lib/apt/lists ]] &&
    find /var/lib/apt/lists -maxdepth 1 -type f -size +0c ! -name lock -print -quit 2>/dev/null | grep -q .
}

install_jq_standalone() {
  local machine asset expected_hash download_url temp actual_hash
  machine=$(uname -m)
  case $machine in
    x86_64|amd64) asset=jq-linux-amd64; expected_hash=b1c22172dd303f3be49e935aa56aa48a8b7a46e0bc838b4997d3bb451495870f ;;
    aarch64|arm64) asset=jq-linux-arm64; expected_hash=8b85c817833814ddca00a144c33705546355afccf0cf39b188f3cdb48b852309 ;;
    armv7l|armv7|armhf) asset=jq-linux-armhf; expected_hash=78458244fb546469b4042e9e07cf78714ef6848895eb9515df76b4eb0b1dc992 ;;
    armv5*|armv6*|armel) asset=jq-linux-armel; expected_hash=d88f6bd640ef8909b3deb587f12c03a0ed38fe8bd5e2e882e2b1bf88f5dab8d2 ;;
    i386|i486|i586|i686) asset=jq-linux-i386; expected_hash=ba996e8ce436973e2f39e2639405a37e8c81ba8c722b71c83996278ad0af16dd ;;
    riscv64) asset=jq-linux-riscv64; expected_hash=a96e5a78a7b2c5a0575bc2a10dda4b20d84efd8c02c8806539ee5f5e57603e8d ;;
    s390x) asset=jq-linux-s390x; expected_hash=42b3306c786e3352e3097b8aa03ca0e5631bdc7a6bf133bb8ddd9e4b148d20c8 ;;
    ppc64le) asset=jq-linux-ppc64el; expected_hash=0dba61281e525ced2111bc00c8bd8078100e8822c33bfb35feee95314bbeeea2 ;;
    *) warn "没有适用于 ${machine} 的 jq 静态包。"; return 1 ;;
  esac
  download_url="https://github.com/jqlang/jq/releases/download/jq-${JQ_VERSION}/${asset}"
  temp=$(temp_file)
  info "正在安装 jq ${JQ_VERSION}。"
  if ! curl --fail --location --proto '=https' --tlsv1.2 --retry 3 --connect-timeout 15 --max-time 180 "$download_url" -o "$temp"; then
    rm -f "$temp"; warn "jq 静态包下载失败。"; return 1
  fi
  if command_exists sha256sum; then actual_hash=$(sha256sum "$temp" | awk '{print $1}');
  elif command_exists openssl; then actual_hash=$(openssl dgst -sha256 "$temp" | awk '{print $NF}');
  else rm -f "$temp"; warn "缺少 SHA-256 校验工具。"; return 1; fi
  if [[ $actual_hash != "$expected_hash" ]]; then
    rm -f "$temp"; warn "jq 静态包 SHA-256 校验失败，拒绝安装。"; return 1
  fi
  install -d -m 755 "$(dirname "$JQ_INSTALL_PATH")"
  install -m 755 "$temp" "$JQ_INSTALL_PATH"
  rm -f "$temp"
  if [[ ${XRAYCTL_TESTING:-0} != 1 ]]; then
    "$JQ_INSTALL_PATH" --version >/dev/null || { warn "jq 静态包无法运行。"; return 1; }
  fi
  info "jq 已安装：${JQ_INSTALL_PATH}"
  meta_resource_register "standaloneJqPath" "$JQ_INSTALL_PATH"
  meta_resource_register "standaloneJqSha256" "$expected_hash"
}

install_packages() {
  local missing=() remaining=() item manager
  for item in "$@"; do command_exists "$item" || missing+=("$item"); done
  ((${#missing[@]})) || return 0
  for item in "${missing[@]}"; do
    if [[ $item == jq ]] && install_jq_standalone; then continue; fi
    remaining+=("$item")
  done
  missing=("${remaining[@]}")
  ((${#missing[@]})) || return 0
  manager=$(pkg_manager) || die "未识别包管理器，请手动安装：${missing[*]}"
  info "安装依赖：${missing[*]}"
  case $manager in
    apt)
      if ! DEBIAN_FRONTEND=noninteractive apt_get_guarded update -y; then
        warn "APT 软件索引更新失败或超时，尝试使用现有索引继续安装。"
      fi
      DEBIAN_FRONTEND=noninteractive apt_get_guarded install -y --no-install-recommends "${missing[@]}" \
        || die "APT 依赖安装失败。请检查 /etc/apt/sources.list、DNS 和服务器网络后重试。"
      ;;
    dnf) dnf install -y "${missing[@]}" ;;
    yum) yum install -y "${missing[@]}" ;;
    pacman) pacman -Sy --noconfirm "${missing[@]}" ;;
    zypper) zypper --non-interactive install "${missing[@]}" ;;
  esac
}

acquire_lock() {
  mkdir -p "$(dirname "$LOCK_FILE")"
  if command_exists flock; then
    exec 9>"$LOCK_FILE"
    flock -n 9 || die "另一个 xrayctl 操作正在运行。"
  else
    local lock_dir="${LOCK_FILE}.d"
    mkdir "$lock_dir" 2>/dev/null || die "另一个 xrayctl 操作正在运行。"
    trap 'rmdir "'"$lock_dir"'" 2>/dev/null || true' EXIT HUP INT TERM
  fi
}

ensure_runtime_dependencies() {
  require_root "$@"
  ensure_linux_systemd
  install_packages curl jq openssl
  acquire_lock
}

ensure_system_context() {
  require_root "$@"
  ensure_linux_systemd
  acquire_lock
}

run_bounded() {
  local seconds=$1; shift
  if command_exists timeout; then timeout --foreground "${seconds}s" "$@"; else "$@"; fi
}

has_net_admin() {
  local cap
  [[ -r /proc/self/status ]] || return 0
  cap=$(awk '/^CapEff:/ {print $2; exit}' /proc/self/status)
  [[ -n $cap ]] || return 0
  cap=${cap: -8}
  (( (16#$cap & 0x1000) != 0 ))
}

# ============================================================
# Metadata migrations — versioned, independent of schema
# ============================================================

# ============================================================
# Metadata — three-layer design
#   Layer 1: init_meta_base  — create/upgrade META_FILE, never runs migrations
#   Layer 2: *_raw helpers   — read/write META_FILE directly, never call init_meta
#   Layer 3: ensure_meta     — init_meta_base + run_metadata_migrations
# ============================================================

# ============================================================
# Metadata — three-layer design (P0-1 fix: zero recursion)
#   Layer 1: init_meta_base    — create/upgrade, NEVER runs migrations
#   Layer 2: *_raw helpers     — direct jq on $META_FILE, NEVER call init_meta
#   Layer 3: ensure_meta       — init_meta_base + run_metadata_migrations
# ============================================================

