init_meta_base() {
  mkdir -p "$CONFIG_DIR"

  if [[ ! -s $META_FILE ]]; then
    printf '%s\n' \
      '{"schema":4,"inbounds":{},"certificates":{},"managedResources":{},"migrations":{}}' \
      >"$META_FILE"
    chmod 600 "$META_FILE"
    return 0
  fi

  local tmp
  tmp=$(temp_file)

  jq '
    .schema = ([.schema // 1, 4] | max) |
    .inbounds = (.inbounds // {}) |
    .certificates = (.certificates // {}) |
    .managedResources = (.managedResources // {}) |
    .migrations = (.migrations // {})
  ' "$META_FILE" >"$tmp" || {
    rm -f "$tmp"
    return 1
  }

  install -m 600 "$tmp" "$META_FILE"
  rm -f "$tmp"
}

# --- Raw helpers — read/write META_FILE directly, MUST NOT call ensure_meta / init_meta_base ---

meta_migration_done_raw() {
  jq -r --arg name "$1" '.migrations[$name] // false' "$META_FILE" 2>/dev/null | grep -qx true
}

meta_mark_migration_raw() {
  local name=$1 tmp
  tmp=$(temp_file)
  jq --arg name "$name" '.migrations[$name] = true' "$META_FILE" >"$tmp" || {
    rm -f "$tmp"
    return 1
  }
  install -m 600 "$tmp" "$META_FILE"
  rm -f "$tmp"
}

meta_cert_exists_raw() {
  jq -e --arg id "$1" '.certificates[$id] != null' "$META_FILE" >/dev/null 2>&1
}

meta_cert_set_raw() {
  local identifier=$1 subject=$2 cert_name=$3 source=$4 validation=$5 auto_renew=${6:-true}
  local tmp
  tmp=$(temp_file)
  jq \
    --arg id "$identifier" \
    --arg subject "$subject" \
    --arg certName "$cert_name" \
    --arg source "$source" \
    --arg validation "$validation" \
    --arg autoRenew "$auto_renew" \
    --arg now "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
    '.certificates[$id] = {
      subject:$subject,
      certName:$certName,
      source:$source,
      validation:$validation,
      autoRenew:($autoRenew=="true"),
      updatedAt:$now
    }' \
    "$META_FILE" >"$tmp" || {
      rm -f "$tmp"
      return 1
    }
  install -m 600 "$tmp" "$META_FILE"
  rm -f "$tmp"
}

# --- Migration functions — use ONLY raw helpers, NEVER call ensure_meta / init_meta ---

meta_mark_migration() {
  init_meta_base
  meta_mark_migration_raw "$1"
}

migration_done() {
  init_meta_base
  meta_migration_done_raw "$1"
}

migrate_legacy_certificates_v1() {
  migration_done "legacyCertScanV1" && return 0

  local crt key identifier subject migrated=0

  if [[ -d $CERT_DIR ]]; then
    for crt in "$CERT_DIR"/*.crt; do
      [[ -e $crt ]] || continue

      identifier=$(basename "$crt" .crt)
      key="${CERT_DIR}/${identifier}.key"

      [[ -r $key ]] || continue
      meta_cert_exists_raw "$identifier" && continue

      subject=$(certificate_server_names "$crt" | head -1)
      [[ -n $subject ]] || subject="$identifier"

      meta_cert_set_raw \
        "$identifier" \
        "$subject" \
        "$identifier" \
        "legacy" \
        "legacy" \
        "false" || return 1

      ((migrated+=1))
    done
  fi

  meta_mark_migration_raw "legacyCertScanV1"
  ((migrated == 0)) || info "已注册 ${migrated} 张旧版证书至 metadata。"
}

cleanup_legacy_certbot_symlink_v1() {
  migration_done "legacyCertbotSymlinkV1" && return 0
  if [[ -L /usr/local/bin/certbot ]]; then
    local target
    target=$(readlink -f /usr/local/bin/certbot 2>/dev/null || true)
    if [[ $target == "${CERTBOT_VENV}/bin/certbot" ]]; then
      rm -f /usr/local/bin/certbot
      hash -r 2>/dev/null || true
      info "已清理旧版 xrayctl Certbot 全局软链接。"
    fi
  fi
  meta_mark_migration_raw "legacyCertbotSymlinkV1"
}

run_metadata_migrations() {
  migrate_legacy_certificates_v1
  cleanup_legacy_certbot_symlink_v1
}

# --- Public entry points ---

ensure_meta() {
  init_meta_base
  run_metadata_migrations
}

init_meta() { ensure_meta; }

meta_cert_exists() {
  ensure_meta
  jq -e --arg id "$1" '.certificates[$id]' "$META_FILE" >/dev/null 2>&1
}

meta_cert_set() {
  local identifier=$1 subject=$2 certName=$3 source=$4 validation=$5 autoRenew=${6:-true} tmp
  ensure_meta; tmp=$(temp_file)
  jq --arg id "$identifier" --arg subject "$subject" --arg certName "$certName" \
     --arg source "$source" --arg validation "$validation" --arg autoRenew "$autoRenew" \
     --arg now "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
    '.certificates[$id] = {subject:$subject, certName:$certName, source:$source,
      validation:$validation, autoRenew: ($autoRenew == "true"), updatedAt:$now}' \
    "$META_FILE" >"$tmp"
  install -m 600 "$tmp" "$META_FILE"; rm -f "$tmp"
}

meta_cert_delete() {
  local identifier=$1 tmp
  ensure_meta; tmp=$(temp_file)
  jq --arg id "$identifier" 'del(.certificates[$id])' "$META_FILE" >"$tmp"
  install -m 600 "$tmp" "$META_FILE"; rm -f "$tmp"
}

meta_cert_get_field() {
  local identifier=$1 field=$2
  ensure_meta
  jq -r --arg id "$identifier" --arg field "$field" \
    '.certificates[$id][$field] // empty' "$META_FILE"
}

meta_cert_list() {
  ensure_meta
  jq -r '.certificates | keys[]' "$META_FILE" 2>/dev/null
}

meta_cert_auto_renew_certs() {
  ensure_meta
  jq -r '.certificates | to_entries[] | select(.value.autoRenew == true) | .key' "$META_FILE" 2>/dev/null
}

meta_resource_register() {
  local key=$1 value=$2 tmp
  ensure_meta; tmp=$(temp_file)
  jq --arg key "$key" --arg value "$value" \
    '.managedResources[$key] = $value' "$META_FILE" >"$tmp"
  install -m 600 "$tmp" "$META_FILE"; rm -f "$tmp"
}

meta_resource_get() {
  ensure_meta
  jq -r --arg key "$1" '.managedResources[$key] // empty' "$META_FILE"
}

meta_resource_remove() {
  local key=$1 tmp
  ensure_meta; tmp=$(temp_file)
  jq --arg key "$key" 'del(.managedResources[$key])' "$META_FILE" >"$tmp"
  install -m 600 "$tmp" "$META_FILE"; rm -f "$tmp"
}

write_default_config() {
  local tmp
  mkdir -p "$CONFIG_DIR" /var/log/xray
  cat >"$CONFIG_FILE" <<'JSON'
{
  "log": {
    "loglevel": "warning",
    "access": "/var/log/xray/access.log",
    "error": "/var/log/xray/error.log"
  },
  "inbounds": [],
  "outbounds": [
    {"protocol": "freedom", "tag": "direct"},
    {"protocol": "blackhole", "tag": "blocked"}
  ],
  "routing": {
    "domainStrategy": "IPIfNonMatch",
    "rules": [
      {"type": "field", "ip": ["geoip:private"], "outboundTag": "blocked"},
      {"type": "field", "protocol": ["bittorrent"], "outboundTag": "blocked"}
    ]
  }
}
JSON
  chmod 640 "$CONFIG_FILE"
  init_meta
}

ensure_config() {
  [[ -f $CONFIG_FILE ]] || write_default_config
  jq -e 'type=="object" and (.inbounds|type=="array")' "$CONFIG_FILE" >/dev/null \
    || die "配置文件不是有效的 Xray JSON：$CONFIG_FILE"
  init_meta
}

xray_installed() { [[ -x $XRAY_BIN ]]; }
require_xray_installed() { xray_installed || die "Xray 尚未安装，请先运行：sudo xrayctl install"; }

validate_candidate() {
  local candidate=$1 validation_output
  if ! validation_output=$(jq -e 'type=="object" and (.inbounds|type=="array") and (.outbounds|type=="array")' "$candidate" 2>&1); then
    error "JSON 结构检查失败。"
    [[ -z $validation_output ]] || printf '%s\n' "$validation_output" >&2
    return 1
  fi
  if xray_installed; then
    if ! validation_output=$("$XRAY_BIN" run -test -format json -config "$candidate" 2>&1); then
      error "Xray 核心拒绝了新配置，原始错误如下："
      [[ -z $validation_output ]] || printf '%s\n' "$validation_output" >&2
      return 1
    fi
  fi
}

timestamp() { date '+%Y%m%d-%H%M%S'; }

backup_config_quiet() {
  [[ -f $CONFIG_FILE ]] || return 0
  mkdir -p "$BACKUP_DIR"
  local target
  target="${BACKUP_DIR}/config-$(timestamp).json"
  cp -a "$CONFIG_FILE" "$target"
  [[ ! -f $META_FILE ]] || cp -a "$META_FILE" "${target%.json}.meta.json"
  printf '%s' "$target"
}

state_validate_metadata_candidate() {
  local candidate=$1 validation_output
  if ! validation_output=$(jq -e '
    type=="object" and
    ((.schema // 1) | type=="number") and
    ((.inbounds // {}) | type=="object") and
    ((.certificates // {}) | type=="object") and
    ((.managedResources // {}) | type=="object") and
    ((.migrations // {}) | type=="object")
  ' "$candidate" 2>&1); then
    error "metadata JSON 结构检查失败。"
    [[ -z $validation_output ]] || printf '%s\n' "$validation_output" >&2
    return 1
  fi
}

_state_restore_snapshot() {
  local config_snapshot=$1 meta_snapshot=$2
  install -m 640 -o "$RUNTIME_OWNER" -g "$RUNTIME_GROUP" "$config_snapshot" "$CONFIG_FILE" || return 1
  install -m 600 "$meta_snapshot" "$META_FILE" || return 1
}

_state_cleanup_transaction_files() {
  local path
  for path in "$@"; do
    [[ -z $path ]] || rm -f "$path"
  done
}

state_commit() {
  local candidate=$1 meta_mutator=${2-} old_active=0
  local config_snapshot meta_snapshot meta_candidate=""
  if [[ -n $meta_mutator ]]; then shift 2; else shift; fi
  ensure_config
  validate_candidate "$candidate" || return 1
  service_is_active && old_active=1
  setup_runtime_access || return 1

  if [[ -n $meta_mutator ]]; then
    meta_candidate=$(temp_file)
    if ! "$meta_mutator" "$META_FILE" "$meta_candidate" "$@"; then
      _state_cleanup_transaction_files "$meta_candidate"
      return 1
    fi
    if ! state_validate_metadata_candidate "$meta_candidate"; then
      _state_cleanup_transaction_files "$meta_candidate"
      return 1
    fi
  fi

  config_snapshot=$(temp_file)
  meta_snapshot=$(temp_file)
  cp -p "$CONFIG_FILE" "$config_snapshot"
  cp -p "$META_FILE" "$meta_snapshot"

  if ! install -m 640 -o "$RUNTIME_OWNER" -g "$RUNTIME_GROUP" "$candidate" "$CONFIG_FILE"; then
    _state_cleanup_transaction_files "$config_snapshot" "$meta_snapshot" "$meta_candidate"
    return 1
  fi

  if [[ -n $meta_candidate ]] && ! install -m 600 "$meta_candidate" "$META_FILE"; then
    error "metadata 提交失败，正在回滚配置和 metadata。"
    _state_restore_snapshot "$config_snapshot" "$meta_snapshot" || true
    _state_cleanup_transaction_files "$config_snapshot" "$meta_snapshot" "$meta_candidate"
    return 1
  fi

  if ((old_active)) && ! restart_service; then
    error "重启失败，正在回滚配置和 metadata。"
    _state_restore_snapshot "$config_snapshot" "$meta_snapshot" || true
    restart_service || true
    _state_cleanup_transaction_files "$config_snapshot" "$meta_snapshot" "$meta_candidate"
    return 1
  fi

  _state_cleanup_transaction_files "$config_snapshot" "$meta_snapshot" "$meta_candidate"
  info "配置已应用。"
}

apply_candidate() { state_commit "$1"; }

temp_file() { mktemp "${TMPDIR:-/tmp}/xrayctl.XXXXXX"; }

_state_build_inbound_meta_set() {
  local current=$1 candidate=$2 tag=$3 host=$4
  jq --arg tag "$tag" --arg host "$host" --arg now "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
    '.inbounds[$tag] = ((.inbounds[$tag] // {}) + {host:$host,managed:true,updatedAt:$now}) |
     del(.inbounds[$tag].realityPublicKey)' \
    "$current" >"$candidate"
}

_state_build_inbound_meta_delete() {
  local current=$1 candidate=$2 tag=$3
  jq --arg tag "$tag" 'del(.inbounds[$tag])' "$current" >"$candidate"
}

_state_build_inbound_meta_rename() {
  local current=$1 candidate=$2 old_tag=$3 new_tag=$4
  jq --arg old "$old_tag" --arg new "$new_tag" --arg now "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" '
    if .inbounds[$old] then
      .inbounds[$new]=(.inbounds[$old] + {updatedAt:$now}) | del(.inbounds[$old])
    else . end' \
    "$current" >"$candidate"
}

state_commit_inbound_set() {
  state_commit "$1" _state_build_inbound_meta_set "$2" "$3"
}

state_commit_inbound_delete() {
  state_commit "$1" _state_build_inbound_meta_delete "$2"
}

state_commit_inbound_rename() {
  state_commit "$1" _state_build_inbound_meta_rename "$2" "$3"
}

edit_config() {
  ensure_runtime_dependencies config-edit; ensure_config
  local editor=${EDITOR:-vi} tmp
  tmp=$(temp_file); cp "$CONFIG_FILE" "$tmp"
  "$editor" "$tmp"
  if cmp -s "$tmp" "$CONFIG_FILE"; then info "配置未更改。"; else apply_candidate "$tmp"; fi
  rm -f "$tmp"
}

check_config() {
  ensure_config
  if validate_candidate "$CONFIG_FILE"; then info "配置检查通过。"; else return 1; fi
}

set_log_level() {
  ensure_runtime_dependencies config-loglevel; ensure_config
  local choice level tmp
  choose choice "日志级别" "warning" "info" "error" "debug" "none"
  case $choice in 1) level=warning;; 2) level=info;; 3) level=error;; 4) level=debug;; 5) level=none;; esac
  tmp=$(temp_file); jq --arg level "$level" '.log.loglevel=$level' "$CONFIG_FILE" >"$tmp"
  apply_candidate "$tmp"; rm -f "$tmp"
}

backup_all() {
  require_root backup; ensure_config
  local target=${1:-${BACKUP_DIR}/xrayctl-$(timestamp).tar.gz}
  local paths=("${CONFIG_FILE#/}")
  mkdir -p "$BACKUP_DIR" "$(dirname "$target")"
  [[ ! -f $META_FILE ]] || paths+=("${META_FILE#/}")
  [[ ! -d $CERT_DIR ]] || paths+=("${CERT_DIR#/}")
  tar -czf "$target" -C / "${paths[@]}" 2>/dev/null || { rm -f "$target"; die "备份失败。"; }
  chmod 600 "$target"
  info "备份已创建：$target"
  meta_resource_register "backupDir" "$BACKUP_DIR"
  info "提示：备份包含 Xray 配置、metadata 和证书副本，不含 Certbot 账户/lineage 数据。"
}

restore_backup() {
  ensure_runtime_dependencies restore; ensure_config
  local archive=${1-} temp extract_config snapshot had_meta=0 had_certs=0
  [[ -n $archive ]] || prompt_value archive "备份文件路径"
  [[ -r $archive ]] || die "无法读取备份：$archive"
  tar -tzf "$archive" >/dev/null || die "不是有效的 tar.gz 备份。"
  if tar -tzf "$archive" | awk 'BEGIN{bad=0} /^\// || /(^|\/)\.\.($|\/)/ {bad=1} END{exit !bad}'; then
    die "备份包含不安全的路径。"
  fi
  extract_config="${CONFIG_FILE#/}"
  tar -tzf "$archive" | grep -Fxq "$extract_config" || die "备份中没有 ${extract_config}。"
  temp=$(mktemp -d "${TMPDIR:-/tmp}/xrayctl-restore.XXXXXX")
  tar -xzf "$archive" -C "$temp"
  if find "$temp" -type l -print -quit | grep -q .; then rm -rf "$temp"; die "备份中不允许包含符号链接。"; fi
  [[ -f "$temp/$extract_config" ]] || { rm -rf "$temp"; die "备份配置不是普通文件。"; }
  jq -e 'type=="object" and (.inbounds|type=="array") and (.outbounds|type=="array")' \
    "$temp/$extract_config" >/dev/null || { rm -rf "$temp"; die "备份配置 JSON 结构无效。"; }
  confirm "恢复会覆盖当前配置和托管证书，继续吗？" N || { rm -rf "$temp"; return; }

  backup_config_quiet >/dev/null || true
  snapshot="$temp/.current"
  mkdir -p "$snapshot"
  cp -a "$CONFIG_FILE" "$snapshot/config.json"
  if [[ -f $META_FILE ]]; then cp -a "$META_FILE" "$snapshot/meta.json"; had_meta=1; fi
  if [[ -d $CERT_DIR ]]; then cp -a "$CERT_DIR" "$snapshot/certs"; had_certs=1; fi

  cp -a "$temp/$extract_config" "$CONFIG_FILE"
  if [[ -f "$temp/${META_FILE#/}" ]]; then cp -a "$temp/${META_FILE#/}" "$META_FILE"; else rm -f "$META_FILE"; fi
  rm -rf "$CERT_DIR"
  setup_certificate_access
  if [[ -d "$temp/${CERT_DIR#/}" ]]; then cp -a "$temp/${CERT_DIR#/}/." "$CERT_DIR/"; fi
  init_meta
  setup_runtime_access

  if ! validate_candidate "$CONFIG_FILE" || ! restart_service; then
    error "恢复后配置验证或服务启动失败，正在回滚配置、元数据和证书。"
    cp -a "$snapshot/config.json" "$CONFIG_FILE"
    if ((had_meta)); then cp -a "$snapshot/meta.json" "$META_FILE"; else rm -f "$META_FILE"; fi
    rm -rf "$CERT_DIR"
    setup_certificate_access
    if ((had_certs)); then cp -a "$snapshot/certs/." "$CERT_DIR/"; fi
    init_meta
    setup_runtime_access
    restart_service || true
    rm -rf "$temp"
    die "恢复失败，已回滚配置、元数据和证书。"
  fi
  rm -rf "$temp"; info "备份已恢复。"

  # Warn if any Let's Encrypt certs lack Certbot lineage after restore
  local id source auto_renew cert_name warned=0
  while IFS= read -r id; do
    [[ -n $id ]] || continue
    source=$(meta_cert_get_field "$id" source)
    [[ $source == letsencrypt ]] || continue
    auto_renew=$(meta_cert_get_field "$id" autoRenew)
    [[ $auto_renew == true ]] || continue
    cert_name=$(meta_cert_get_field "$id" certName)
    if [[ ! -d ${CERTBOT_CONFIG_DIR}/live/${cert_name} ]]; then
      warn "证书 ${id}: 副本已恢复，但 Certbot lineage 缺失，无法自动续期。请重新签发。"
      ((warned+=1))
    fi
  done < <(meta_cert_list)
  if ((warned > 0)); then
    warn "共 ${warned} 张 Let's Encrypt 证书缺少 Certbot 续期数据。"
  fi
  return 0
}
