# shellcheck shell=bash
# Per-inbound rolling traffic accounting and optional monthly quotas. Linux
# packet counters provide the samples; only the current display period is
# retained while quota cycles keep their independent local timestamps.

TRAFFIC_NFT_TABLE="xrayctl_traffic"
TRAFFIC_IPTABLES_IN_CHAIN="XRAYCTL_TRAFFIC_IN"
TRAFFIC_IPTABLES_OUT_CHAIN="XRAYCTL_TRAFFIC_OUT"
TRAFFIC_LOCK="${XRAYCTL_TRAFFIC_LOCK:-${LOCK_FILE}.traffic}"
TRAFFIC_COLLECT_INTERVAL="${XRAYCTL_TRAFFIC_COLLECT_INTERVAL:-60}"
TRAFFIC_SYSTEMD_SERVICE="${SYSTEMD_UNIT_DIR}/xrayctl-traffic-collect.service"
TRAFFIC_SYSTEMD_TIMER="${SYSTEMD_UNIT_DIR}/xrayctl-traffic-collect.timer"
TRAFFIC_OPENRC_SERVICE="${OPENRC_INIT_DIR}/xrayctl-traffic-collect"

traffic_require_root() {
  [[ ${XRAYCTL_TESTING:-0} == 1 ]] || require_root "$@"
}

traffic_now() {
  if [[ -n ${XRAYCTL_TRAFFIC_NOW:-} ]]; then printf '%s' "$XRAYCTL_TRAFFIC_NOW"; else date '+%Y-%m-%d %H:%M:%S'; fi
}

traffic_today() {
  if [[ -n ${XRAYCTL_TRAFFIC_TODAY:-} ]]; then printf '%s' "$XRAYCTL_TRAFFIC_TODAY"; else traffic_now | cut -c1-10; fi
}

traffic_validate_date() {
  local value=${1-} year month day max_day
  [[ $value =~ ^([0-9]{4})-([0-9]{2})-([0-9]{2})$ ]] || return 1
  year=$((10#${BASH_REMATCH[1]})); month=$((10#${BASH_REMATCH[2]})); day=$((10#${BASH_REMATCH[3]}))
  ((year >= 1970 && month >= 1 && month <= 12 && day >= 1)) || return 1
  max_day=$(traffic_days_in_month "$year" "$month")
  ((day <= max_day))
}

traffic_validate_timestamp() {
  local value=${1-} date_part hour minute second
  [[ $value =~ ^([0-9]{4}-[0-9]{2}-[0-9]{2})\ ([0-9]{2}):([0-9]{2}):([0-9]{2})$ ]] || return 1
  date_part=${BASH_REMATCH[1]}; hour=$((10#${BASH_REMATCH[2]})); minute=$((10#${BASH_REMATCH[3]})); second=$((10#${BASH_REMATCH[4]}))
  traffic_validate_date "$date_part" && ((hour <= 23 && minute <= 59 && second <= 59))
}

traffic_days_in_month() {
  local year=$((10#$1)) month=$((10#$2))
  case $month in
    1|3|5|7|8|10|12) printf '31' ;;
    4|6|9|11) printf '30' ;;
    2)
      if ((year % 400 == 0 || (year % 4 == 0 && year % 100 != 0))); then printf '29'; else printf '28'; fi
      ;;
  esac
}

traffic_months_ago() {
  local value=$1 months=${2:-3} year month day total max_day
  traffic_validate_date "$value" || return 1
  year=$((10#${value:0:4})); month=$((10#${value:5:2})); day=$((10#${value:8:2}))
  total=$((year * 12 + month - 1 - months))
  year=$((total / 12)); month=$((total % 12 + 1))
  max_day=$(traffic_days_in_month "$year" "$month")
  ((day <= max_day)) || day=$max_day
  printf '%04d-%02d-%02d' "$year" "$month" "$day"
}

# Return the same local wall-clock time in the next calendar month. The
# original anchor day is retained so Jan 31 -> Feb 28 -> Mar 31.
traffic_limit_next_timestamp() {
  local reference=$1 anchor_day=$2 anchor_time=$3 year month total max_day
  traffic_validate_timestamp "$reference" || return 1
  [[ $anchor_day =~ ^[0-9]+$ ]] && ((10#$anchor_day >= 1 && 10#$anchor_day <= 31)) || return 1
  [[ $anchor_time =~ ^([0-9]{2}):([0-9]{2}):([0-9]{2})$ ]] || return 1
  ((10#${BASH_REMATCH[1]} <= 23 && 10#${BASH_REMATCH[2]} <= 59 && 10#${BASH_REMATCH[3]} <= 59)) || return 1
  year=$((10#${reference:0:4})); month=$((10#${reference:5:2}))
  total=$((year * 12 + month))
  year=$((total / 12)); month=$((total % 12 + 1))
  max_day=$(traffic_days_in_month "$year" "$month")
  ((10#$anchor_day <= max_day)) || anchor_day=$max_day
  printf '%04d-%02d-%02d %s' "$year" "$month" "$((10#$anchor_day))" "$anchor_time"
}

traffic_iso_compare() {
  local left=${1//[-: ]/} operator=$2 right=${3//[-: ]/}
  [[ $left =~ ^[0-9]+$ && $right =~ ^[0-9]+$ ]] || return 2
  case $operator in
    lt) ((10#$left < 10#$right)) ;;
    le) ((10#$left <= 10#$right)) ;;
    ge) ((10#$left >= 10#$right)) ;;
    gt) ((10#$left > 10#$right)) ;;
    *) return 2 ;;
  esac
}

traffic_limit_first_cycle_end() {
  local reference=$1 reset_day=$2 reset_time=$3 year month max_day candidate
  traffic_validate_timestamp "$reference" || return 1
  [[ $reset_day =~ ^[0-9]+$ ]] && ((10#$reset_day >= 1 && 10#$reset_day <= 31)) || return 1
  [[ $reset_time =~ ^([0-9]{2}):([0-9]{2}):([0-9]{2})$ ]] || return 1
  ((10#${BASH_REMATCH[1]} <= 23 && 10#${BASH_REMATCH[2]} <= 59 && 10#${BASH_REMATCH[3]} <= 59)) || return 1
  year=$((10#${reference:0:4})); month=$((10#${reference:5:2}))
  max_day=$(traffic_days_in_month "$year" "$month")
  ((10#$reset_day <= max_day)) || reset_day=$max_day
  candidate=$(printf '%04d-%02d-%02d %s' "$year" "$month" "$reset_day" "$reset_time")
  if traffic_iso_compare "$candidate" gt "$reference"; then printf '%s' "$candidate"; else traffic_limit_next_timestamp "$reference" "$2" "$reset_time"; fi
}

traffic_retention_start() {
  traffic_init_file
  local start
  start=$(traffic_period_start "$(traffic_now)") || return 1
  printf '%s' "${start:0:10}"
}

traffic_validate_range() {
  local start=${1-} end=${2-} cutoff today
  traffic_validate_date "$start" && traffic_validate_date "$end" || return 1
  cutoff=$(traffic_retention_start); today=$(traffic_today)
  traffic_iso_compare "$start" le "$end" || return 1
  traffic_iso_compare "$start" ge "$cutoff" || return 1
  traffic_iso_compare "$end" le "$today"
}

traffic_period_anchor() {
  local reference=$1 offset=${2:-0} day=$3 clock=$4 year month total max_day
  traffic_validate_date "$reference" || return 1
  year=$((10#${reference:0:4})); month=$((10#${reference:5:2}))
  total=$((year * 12 + month - 1 + offset))
  year=$((total / 12)); month=$((total % 12 + 1))
  max_day=$(traffic_days_in_month "$year" "$month")
  ((day <= max_day)) || day=$max_day
  printf '%04d-%02d-%02d %s' "$year" "$month" "$day" "$clock"
}

traffic_period_start() {
  local reference=$1 day clock candidate
  day=$(jq -r '.period.day // 1' "$TRAFFIC_FILE")
  clock=$(jq -r '.period.time // "00:00:00"' "$TRAFFIC_FILE")
  candidate=$(traffic_period_anchor "${reference:0:10}" 0 "$day" "$clock") || return 1
  if traffic_iso_compare "$candidate" le "$reference"; then
    printf '%s' "$candidate"
  else
    traffic_period_anchor "${reference:0:10}" -1 "$day" "$clock"
  fi
}

traffic_period_bounds() {
  local reference=$1 start day clock
  start=$(traffic_period_start "$reference") || return 1
  day=$(jq -r '.period.day // 1' "$TRAFFIC_FILE")
  clock=$(jq -r '.period.time // "00:00:00"' "$TRAFFIC_FILE")
  printf '%s\t%s\n' "$start" "$(traffic_period_anchor "${start:0:10}" 1 "$day" "$clock")"
}

traffic_default_json() {
  printf '%s\n' '{"schema":1,"enabled":false,"limitsEnabled":false,"backend":"","lastCollectedAt":"","period":{"day":1,"time":"00:00:00"},"periodsSeeded":false,"inbounds":{}}'
}

traffic_init_file() {
  local dir tmp
  dir=$(dirname "$TRAFFIC_FILE")
  mkdir -p "$dir"
  chmod 700 "$dir" 2>/dev/null || true
  if [[ ! -s $TRAFFIC_FILE ]] || ! jq -e 'type=="object" and ((.inbounds // {})|type)=="object"' "$TRAFFIC_FILE" >/dev/null 2>&1; then
    [[ ! -f $TRAFFIC_FILE ]] || cp -a "$TRAFFIC_FILE" "${TRAFFIC_FILE}.broken-$(timestamp)"
    tmp=$(temp_file); traffic_default_json >"$tmp"; install -m 600 "$tmp" "$TRAFFIC_FILE"; rm -f "$tmp"
  elif ! jq -e '.schema==1 and (.enabled|type)=="boolean" and (.limitsEnabled|type)=="boolean" and (.backend|type)=="string" and (.lastCollectedAt|type)=="string" and (.period.day|type)=="number" and (.period.time|type)=="string" and (.periodsSeeded|type)=="boolean"' "$TRAFFIC_FILE" >/dev/null 2>&1; then
    tmp=$(temp_file)
    jq '.schema=1 | .enabled=(.enabled==true) | .limitsEnabled=(.limitsEnabled==true) | .backend=(.backend // "") | .lastCollectedAt=(.lastCollectedAt // "") | .period=(.period // {day:1,time:"00:00:00"}) | .periodsSeeded=(.periodsSeeded==true) | .inbounds=(if (.inbounds|type)=="object" then .inbounds else {} end)' \
      "$TRAFFIC_FILE" >"$tmp" || { rm -f "$tmp"; return 1; }
    install -m 600 "$tmp" "$TRAFFIC_FILE"; rm -f "$tmp"
  fi
}

traffic_is_enabled() {
  [[ -f $TRAFFIC_FILE ]] && jq -e '.enabled==true' "$TRAFFIC_FILE" >/dev/null 2>&1
}

traffic_set_enabled() {
  local enabled=$1 tmp rc=0
  traffic_init_file
  traffic_lock_acquire || return 1
  tmp=$(temp_file)
  jq --argjson enabled "$enabled" '.enabled=$enabled' "$TRAFFIC_FILE" >"$tmp" || rc=1
  if ((rc == 0)); then install -m 600 "$tmp" "$TRAFFIC_FILE" || rc=1; fi
  rm -f "$tmp"; traffic_lock_release
  return "$rc"
}

traffic_limits_are_enabled() {
  [[ -f $TRAFFIC_FILE ]] && jq -e '.limitsEnabled==true' "$TRAFFIC_FILE" >/dev/null 2>&1
}

traffic_set_limits_enabled() {
  local enabled=$1 tmp rc=0
  traffic_init_file
  traffic_lock_acquire || return 1
  tmp=$(temp_file)
  jq --argjson enabled "$enabled" '.limitsEnabled=$enabled' "$TRAFFIC_FILE" >"$tmp" || rc=1
  if ((rc == 0)); then install -m 600 "$tmp" "$TRAFFIC_FILE" || rc=1; fi
  rm -f "$tmp"; traffic_lock_release
  return "$rc"
}

traffic_recorded_backend() {
  [[ -f $TRAFFIC_FILE ]] || return 0
  jq -r '.backend // empty' "$TRAFFIC_FILE" 2>/dev/null
}

traffic_set_backend() {
  local backend=$1 tmp
  traffic_init_file
  tmp=$(temp_file); jq --arg backend "$backend" '.backend=$backend' "$TRAFFIC_FILE" >"$tmp"
  install -m 600 "$tmp" "$TRAFFIC_FILE"; rm -f "$tmp"
}

traffic_inventory_json() {
  if [[ -f $CONFIG_FILE ]]; then
    jq '[.inbounds[]? | {key:.tag,value:{protocol:.protocol,port:.port,disabled:false}}] | from_entries' "$CONFIG_FILE" 2>/dev/null || printf '{}\n'
  else
    printf '{}\n'
  fi
}

traffic_rolled_limits_json() {
  local now=$1 tag quota reset_day anchor_day anchor_time cycle_start cycle_end used next
  traffic_init_file
  while IFS=$'\t' read -r tag quota anchor_day anchor_time cycle_start cycle_end used; do
    [[ -n $tag ]] || continue
    if ! traffic_validate_timestamp "$cycle_start" || ! traffic_validate_timestamp "$cycle_end"; then continue; fi
    while traffic_iso_compare "$now" ge "$cycle_end"; do
      cycle_start=$cycle_end
      next=$(traffic_limit_next_timestamp "$cycle_start" "$anchor_day" "$anchor_time") || break 2
      cycle_end=$next
      used=0
    done
    reset_day=$anchor_day
    jq -nc --arg key "$tag" --argjson quota "$quota" --argjson resetDay "$reset_day" --argjson anchorDay "$anchor_day" \
      --arg anchorTime "$anchor_time" --arg cycleStart "$cycle_start" --arg cycleEnd "$cycle_end" --argjson used "$used" \
      '{key:$key,value:{enabled:true,quotaBytes:$quota,resetDay:$resetDay,anchorDay:$anchorDay,anchorTime:$anchorTime,cycleStart:$cycleStart,cycleEnd:$cycleEnd,usedBytes:$used}}'
  done < <(jq -r '
    .inbounds | to_entries[]? | select(.value.limit.enabled==true) |
    [.key,((.value.limit.quotaBytes // 0)|floor|tostring),((.value.limit.resetDay // .value.limit.anchorDay // 0)|floor|tostring),
     (.value.limit.anchorTime // ""),(.value.limit.cycleStart // ""),(.value.limit.cycleEnd // ""),
     ((.value.limit.usedBytes // 0)|floor|tostring)] | @tsv
  ' "$TRAFFIC_FILE") | jq -s 'from_entries'
}

# Existing files contain daily totals only. Assign each old boundary day to
# the new period as an approximation; subsequent samples use their collection
# time and are accumulated directly in the matching period.
traffic_seed_periods() {
  local day start mapping='{}' tmp
  [[ $(jq -r '.periodsSeeded // false' "$TRAFFIC_FILE") != true ]] || return 0
  while IFS= read -r day; do
    traffic_validate_date "$day" || continue
    start=$(traffic_period_start "$day 23:59:59") || return 1
    mapping=$(jq -nc --argjson mapping "$mapping" --arg day "$day" --arg start "$start" '$mapping + {($day):$start}') || return 1
  done < <(jq -r '[.inbounds[]?.daily | keys[]?] | unique[]' "$TRAFFIC_FILE")
  tmp=$(temp_file)
  jq --argjson mapping "$mapping" '
    .inbounds |= with_entries(
      .value.cycles=(reduce ((.value.daily // {}) | to_entries[]) as $day ({};
        ($mapping[$day.key] // null) as $start |
        if $start == null or $start == "" then . else .[$start]=((.[$start] // 0) + $day.value) end
      ))
    ) | .periodsSeeded=true
  ' "$TRAFFIC_FILE" >"$tmp" || { rm -f "$tmp"; return 1; }
  install -m 600 "$tmp" "$TRAFFIC_FILE"; rm -f "$tmp"
}

traffic_update_file() {
  local samples=${1:-'{}'} mark_collected=${2:-1} today cutoff now period_start inventory limits tmp
  traffic_init_file
  traffic_seed_periods || return 1
  today=$(traffic_today); cutoff=$(traffic_retention_start); now=$(traffic_now)
  period_start=$(traffic_period_start "$now") || return 1
  inventory=$(traffic_inventory_json)
  limits=$(traffic_rolled_limits_json "$now")
  tmp=$(temp_file)
  jq --arg today "$today" --arg cutoff "$cutoff" --arg periodStart "$period_start" --arg now "$now" --argjson markCollected "$mark_collected" \
     --argjson samples "$samples" --argjson inventory "$inventory" --argjson limits "$limits" '
    .inbounds=(.inbounds // {}) |
    reduce ($inventory|to_entries[]) as $item (.;
      .inbounds[$item.key]=((.inbounds[$item.key] // {daily:{}}) + $item.value + {deleted:false})
    ) |
    .inbounds |= with_entries(.value.deleted = ($inventory[.key] == null) | .value.disabled = ($inventory[.key].disabled // false)) |
    reduce ($limits|to_entries[]) as $item (.;
      if .inbounds[$item.key] then .inbounds[$item.key].limit=$item.value else . end
    ) |
    .inbounds |= with_entries(
      .value.daily=((.value.daily // {}) | with_entries(select(.key >= $cutoff and .key <= $today))) |
      .value.cycles=((.value.cycles // {}) | with_entries(select(.key == $periodStart))) |
      if .value.cycles[$periodStart] == null then .value.daily |= del(.[$today]) else . end
    ) |
    reduce ($samples|to_entries[]) as $item (.;
      .inbounds[$item.key]=(.inbounds[$item.key] // {protocol:"unknown",port:0,deleted:($inventory[$item.key] == null),daily:{}}) |
      .inbounds[$item.key].daily[$today]=((.inbounds[$item.key].daily[$today] // 0) + $item.value) |
      .inbounds[$item.key].cycles[$periodStart]=((.inbounds[$item.key].cycles[$periodStart] // 0) + $item.value) |
      if .inbounds[$item.key].limit.enabled==true then
        .inbounds[$item.key].limit.usedBytes=((.inbounds[$item.key].limit.usedBytes // 0) + $item.value)
      else . end
    ) |
    .inbounds |= with_entries(select((.value.deleted != true) or ((.value.daily|length) > 0) or ((.value.cycles|length) > 0) or (.value.limit.enabled==true))) |
    if $markCollected then .lastCollectedAt=$now else . end
  ' "$TRAFFIC_FILE" >"$tmp" || { rm -f "$tmp"; return 1; }
  install -m 600 "$tmp" "$TRAFFIC_FILE"; rm -f "$tmp"
}

traffic_sync_inventory() {
  local rc=0
  traffic_lock_acquire || return 1
  traffic_update_file '{}' false || rc=1
  traffic_lock_release
  return "$rc"
}

traffic_lock_acquire() {
  local attempt=0 owner=""
  mkdir -p "$(dirname "$TRAFFIC_LOCK")"
  while ! mkdir "$TRAFFIC_LOCK" 2>/dev/null; do
    owner=$(cat "$TRAFFIC_LOCK/pid" 2>/dev/null || true)
    if [[ $owner =~ ^[0-9]+$ ]] && ! kill -0 "$owner" 2>/dev/null; then
      rm -f "$TRAFFIC_LOCK/pid" 2>/dev/null || true
      rmdir "$TRAFFIC_LOCK" 2>/dev/null || true
      continue
    fi
    attempt=$((attempt + 1))
    ((attempt < 100)) || return 1
    sleep 0.05
  done
  printf '%s\n' "$$" >"$TRAFFIC_LOCK/pid"
}

traffic_lock_release() {
  local owner
  owner=$(cat "$TRAFFIC_LOCK/pid" 2>/dev/null || true)
  [[ $owner != "$$" ]] || rm -f "$TRAFFIC_LOCK/pid" 2>/dev/null || true
  rmdir "$TRAFFIC_LOCK" 2>/dev/null || true
}

traffic_backend() {
  local recorded
  if [[ -n ${XRAYCTL_TRAFFIC_BACKEND:-} ]]; then printf '%s' "$XRAYCTL_TRAFFIC_BACKEND"; return; fi
  recorded=$(traffic_recorded_backend)
  if [[ $recorded == nft ]] && command_exists nft; then printf 'nft'
  elif [[ $recorded == iptables ]] && { command_exists iptables || command_exists ip6tables; }; then printf 'iptables'
  elif command_exists nft; then printf 'nft'
  elif command_exists iptables || command_exists ip6tables; then printf 'iptables'
  else printf 'none'; fi
}

traffic_backend_conflicts() {
  local backend=$1 recorded
  recorded=$(traffic_recorded_backend)
  [[ $recorded == "$backend" ]] && return 1
  case $backend in
    nft)
      command_exists nft && nft list table inet "$TRAFFIC_NFT_TABLE" >/dev/null 2>&1
      ;;
    iptables)
      if command_exists iptables && { iptables -t filter -S "$TRAFFIC_IPTABLES_IN_CHAIN" >/dev/null 2>&1 || iptables -t filter -S "$TRAFFIC_IPTABLES_OUT_CHAIN" >/dev/null 2>&1; }; then return 0; fi
      if command_exists ip6tables && { ip6tables -t filter -S "$TRAFFIC_IPTABLES_IN_CHAIN" >/dev/null 2>&1 || ip6tables -t filter -S "$TRAFFIC_IPTABLES_OUT_CHAIN" >/dev/null 2>&1; }; then return 0; fi
      return 1
      ;;
    *) return 1;;
  esac
}

traffic_ensure_backend() {
  [[ $(uname -s) == Linux || ${XRAYCTL_TESTING:-0} == 1 ]] || { warn "流量统计仅支持 Linux。"; return 1; }
  [[ $(traffic_backend) != none ]] && return 0
  info "流量统计需要 nftables，正在安装..."
  install_packages nftables
  [[ $(traffic_backend) != none ]] || { warn "nftables 安装失败，无法开启流量统计。"; return 1; }
}

traffic_read_nft_counters() {
  command_exists nft || return 0
  local payload
  payload=$(nft -j list table inet "$TRAFFIC_NFT_TABLE" 2>/dev/null) || return 0
  jq -r '
    [.nftables[]?.rule |
      (.comment // "") as $comment |
      select(($comment | startswith("xrayctl-traffic:count:")) or ($comment | test("^xrayctl-traffic:[^:]+$"))) |
      {tag:(if ($comment | startswith("xrayctl-traffic:count:"))
            then ($comment | sub("^xrayctl-traffic:count:";""))
            else ($comment | sub("^xrayctl-traffic:";"")) end),
       bytes:([.expr[]?.counter.bytes] | add // 0)}] |
    group_by(.tag)[] | [.[0].tag,(map(.bytes)|add)] | @tsv
  ' <<<"$payload"
}

traffic_read_iptables_counters() {
  local command chain output
  for command in iptables ip6tables; do
    command_exists "$command" || continue
    for chain in "$TRAFFIC_IPTABLES_IN_CHAIN" "$TRAFFIC_IPTABLES_OUT_CHAIN"; do
      output=$("$command" -t filter -L "$chain" -nvx 2>/dev/null) || continue
      awk '
        $1 ~ /^[0-9]+$/ && $2 ~ /^[0-9]+$/ {
          for (i=1;i<=NF;i++) {
            if ($i ~ /^xrayctl-traffic:count:[A-Za-z0-9_.-]+/) {
              tag=$i; sub(/^xrayctl-traffic:count:/,"",tag); gsub(/[^A-Za-z0-9_.-].*$/,"",tag);
              print tag "\t" $2
            } else if ($i ~ /^xrayctl-traffic:[A-Za-z0-9_.-]+$/) {
              tag=$i; sub(/^xrayctl-traffic:/,"",tag); print tag "\t" $2
            }
          }
        }
      ' <<<"$output"
    done
  done
}

traffic_read_counters() {
  {
    case $(traffic_recorded_backend) in
      nft) traffic_read_nft_counters;;
      iptables) traffic_read_iptables_counters;;
    esac
  } | awk -F '\t' '
    NF==2 && $2 ~ /^[0-9]+$/ {sum[$1]+=$2}
    END {for (tag in sum) print tag "\t" sum[tag]}
  '
}

traffic_samples_json() {
  jq -Rn '
    reduce inputs as $line ({};
      ($line | split("\t")) as $fields |
      if (($fields|length)==2 and ($fields[1]|test("^[0-9]+$")))
      then .[$fields[0]]=((.[$fields[0]] // 0) + ($fields[1]|tonumber)) else . end)
  '
}

traffic_clear_nft_rules() {
  command_exists nft || return 0
  local payload
  payload=$(nft -j list table inet "$TRAFFIC_NFT_TABLE" 2>/dev/null) || return 0
  if ! jq -e '
    [.nftables[]?.rule | select(. != null) |
      select(((.comment // "") | startswith("xrayctl-traffic:")) | not)] | length==0
  ' <<<"$payload" >/dev/null; then
    warn "nftables 表 ${TRAFFIC_NFT_TABLE} 含有非 xrayctl 规则，拒绝删除。"
    return 1
  fi
  nft delete table inet "$TRAFFIC_NFT_TABLE" >/dev/null 2>&1 || return 1
}

traffic_clear_iptables_rules() {
  local command parent chain rules rc=0
  for command in iptables ip6tables; do
    command_exists "$command" || continue
    for chain in "$TRAFFIC_IPTABLES_IN_CHAIN" "$TRAFFIC_IPTABLES_OUT_CHAIN"; do
      rules=$("$command" -t filter -S "$chain" 2>/dev/null) || continue
      if awk -v chain="$chain" '$1=="-A" && $2==chain && index($0,"xrayctl-traffic:")==0 {bad=1} END{exit bad}' <<<"$rules"; then :
      else
        warn "${command} 链 ${chain} 含有非 xrayctl 规则，拒绝删除。"
        return 1
      fi
    done
    for parent in INPUT OUTPUT; do
      [[ $parent == INPUT ]] && chain=$TRAFFIC_IPTABLES_IN_CHAIN || chain=$TRAFFIC_IPTABLES_OUT_CHAIN
      while "$command" -t filter -C "$parent" -j "$chain" >/dev/null 2>&1; do
        "$command" -t filter -D "$parent" -j "$chain" >/dev/null 2>&1 || break
      done
      "$command" -t filter -F "$chain" >/dev/null 2>&1 || true
      "$command" -t filter -X "$chain" >/dev/null 2>&1 || true
      "$command" -t filter -S "$chain" >/dev/null 2>&1 && rc=1
    done
  done
  ((rc == 0)) || { warn "iptables 流量统计链仍被其他规则引用，未能安全删除。"; return 1; }
}

traffic_rules_clear() {
  case $(traffic_recorded_backend) in
    nft) traffic_clear_nft_rules;;
    iptables) traffic_clear_iptables_rules;;
  esac
}

traffic_protocols_for_inbound() {
  case $1 in socks) printf '%s\n' tcp udp;; *) printf '%s\n' tcp;; esac
}

traffic_limit_is_blocked() {
  local tag=$1
  traffic_limits_are_enabled || return 1
  jq -e --arg tag "$tag" '
    .inbounds[$tag].limit.enabled==true and
    ((.inbounds[$tag].limit.usedBytes // 0) >= (.inbounds[$tag].limit.quotaBytes // 0))
  ' "$TRAFFIC_FILE" >/dev/null 2>&1
}

traffic_restore_nft_rules() {
  local tag inbound_protocol port transport_protocol count_comment block_comment blocked count=0
  command_exists nft || return 1
  traffic_clear_nft_rules || return 1
  nft add table inet "$TRAFFIC_NFT_TABLE" || return 1
  nft 'add chain inet xrayctl_traffic input { type filter hook input priority -5; policy accept; }' || return 1
  nft 'add chain inet xrayctl_traffic output { type filter hook output priority -5; policy accept; }' || return 1
  while IFS=$'\t' read -r tag inbound_protocol port; do
    if [[ -z $tag ]] || ! validate_port "$port"; then continue; fi
    count_comment="\"xrayctl-traffic:count:${tag}\""
    block_comment="\"xrayctl-traffic:block:${tag}\""
    blocked=0; traffic_limit_is_blocked "$tag" && blocked=1
    while IFS= read -r transport_protocol; do
      if ((blocked)); then
        nft add rule inet "$TRAFFIC_NFT_TABLE" input "$transport_protocol" dport "$port" comment "$block_comment" drop || return 1
        nft add rule inet "$TRAFFIC_NFT_TABLE" output "$transport_protocol" sport "$port" comment "$block_comment" drop || return 1
      fi
      nft add rule inet "$TRAFFIC_NFT_TABLE" input "$transport_protocol" dport "$port" counter comment "$count_comment" || return 1
      nft add rule inet "$TRAFFIC_NFT_TABLE" output "$transport_protocol" sport "$port" counter comment "$count_comment" || return 1
      count=$((count + 1))
    done < <(traffic_protocols_for_inbound "$inbound_protocol")
  done < <(jq -r '.inbounds[]? | [.tag,.protocol,(.port|tostring)] | @tsv' "$CONFIG_FILE" 2>/dev/null || true)
  ((count > 0)) || traffic_clear_nft_rules
}

traffic_restore_iptables_rules() {
  local command tag inbound_protocol port transport_protocol blocked count=0
  traffic_clear_iptables_rules || return 1
  for command in iptables ip6tables; do
    command_exists "$command" || continue
    "$command" -t filter -N "$TRAFFIC_IPTABLES_IN_CHAIN" >/dev/null 2>&1 || true
    "$command" -t filter -N "$TRAFFIC_IPTABLES_OUT_CHAIN" >/dev/null 2>&1 || true
    "$command" -t filter -C INPUT -j "$TRAFFIC_IPTABLES_IN_CHAIN" >/dev/null 2>&1 || "$command" -t filter -I INPUT 1 -j "$TRAFFIC_IPTABLES_IN_CHAIN"
    "$command" -t filter -C OUTPUT -j "$TRAFFIC_IPTABLES_OUT_CHAIN" >/dev/null 2>&1 || "$command" -t filter -I OUTPUT 1 -j "$TRAFFIC_IPTABLES_OUT_CHAIN"
    while IFS=$'\t' read -r tag inbound_protocol port; do
      if [[ -z $tag ]] || ! validate_port "$port"; then continue; fi
      blocked=0; traffic_limit_is_blocked "$tag" && blocked=1
      while IFS= read -r transport_protocol; do
        if ((blocked)); then
          "$command" -t filter -A "$TRAFFIC_IPTABLES_IN_CHAIN" -p "$transport_protocol" --dport "$port" -m comment --comment "xrayctl-traffic:block:${tag}" -j DROP || return 1
          "$command" -t filter -A "$TRAFFIC_IPTABLES_OUT_CHAIN" -p "$transport_protocol" --sport "$port" -m comment --comment "xrayctl-traffic:block:${tag}" -j DROP || return 1
        fi
        "$command" -t filter -A "$TRAFFIC_IPTABLES_IN_CHAIN" -p "$transport_protocol" --dport "$port" -m comment --comment "xrayctl-traffic:count:${tag}" -j RETURN || return 1
        "$command" -t filter -A "$TRAFFIC_IPTABLES_OUT_CHAIN" -p "$transport_protocol" --sport "$port" -m comment --comment "xrayctl-traffic:count:${tag}" -j RETURN || return 1
        count=$((count + 1))
      done < <(traffic_protocols_for_inbound "$inbound_protocol")
    done < <(jq -r '.inbounds[]? | [.tag,.protocol,(.port|tostring)] | @tsv' "$CONFIG_FILE" 2>/dev/null || true)
  done
  ((count > 0)) || traffic_clear_iptables_rules
}

traffic_rules_restore() {
  local selected
  selected=$(traffic_backend)
  [[ $selected != none ]] || return 1
  traffic_rules_clear || return 1
  [[ $(traffic_recorded_backend) == "$selected" ]] || traffic_set_backend "$selected"
  [[ -f $CONFIG_FILE ]] || return 0
  case $selected in
    nft) traffic_restore_nft_rules ;;
    iptables) traffic_restore_iptables_rules ;;
    *) return 1 ;;
  esac
}

traffic_rules_restore_serialized() {
  local rc=0
  traffic_lock_acquire || return 1
  traffic_rules_restore || rc=1
  traffic_lock_release
  return "$rc"
}

traffic_collect() {
  traffic_is_enabled || return 0
  traffic_require_root internal-traffic-collect
  traffic_lock_acquire || { warn "另一个流量采集任务正在运行。"; return 1; }
  local counters samples rc=0 snapshot=""
  snapshot=$(temp_file) || { traffic_lock_release; return 1; }
  cp -p "$TRAFFIC_FILE" "$snapshot" || { rm -f "$snapshot"; traffic_lock_release; return 1; }
  counters=$(traffic_read_counters) || rc=1
  if ((rc == 0)); then
    samples=$(traffic_samples_json <<<"$counters") || rc=1
  fi
  if ((rc == 0)); then traffic_update_file "$samples" || rc=1; fi
  if ((rc == 0)); then traffic_rules_restore || rc=1; fi
  # Rule replacement clears packet counters.  If replacement fails, the
  # counters still represent the same packets and the next retry would add
  # them again.  Restore the pre-collection file so the retry is idempotent.
  if ((rc != 0)); then
    install -m 600 "$snapshot" "$TRAFFIC_FILE" || true
  fi
  rm -f "$snapshot"
  traffic_lock_release
  ((rc == 0)) || { warn "流量采集未完成，现有累计记录已尽量保留。"; return 1; }
}

traffic_rename_records() {
  local old=$1 new=$2 tmp rc=0
  [[ -f $TRAFFIC_FILE ]] || return 0
  traffic_lock_acquire || return 1
  tmp=$(temp_file)
  jq --arg old "$old" --arg new "$new" '
    if .inbounds[$old] then
      (.inbounds[$new] // {daily:{}}) as $target |
      (.inbounds[$old]) as $source |
      .inbounds[$new]=($source + {daily:($target.daily // {}),cycles:($target.cycles // {}),deleted:false}) |
      reduce (($source.daily // {})|to_entries[]) as $day (.;
        .inbounds[$new].daily[$day.key]=((.inbounds[$new].daily[$day.key] // 0) + $day.value)
      ) |
      reduce (($source.cycles // {})|to_entries[]) as $cycle (.;
        .inbounds[$new].cycles[$cycle.key]=((.inbounds[$new].cycles[$cycle.key] // 0) + $cycle.value)
      ) |
      del(.inbounds[$old])
    else . end
  ' "$TRAFFIC_FILE" >"$tmp" || rc=1
  if ((rc == 0)); then install -m 600 "$tmp" "$TRAFFIC_FILE" || rc=1; fi
  rm -f "$tmp"; traffic_lock_release
  return "$rc"
}

traffic_remove_limit_data() {
  local tag=$1 tmp rc=0
  [[ -f $TRAFFIC_FILE ]] || return 0
  traffic_lock_acquire || return 1
  tmp=$(temp_file)
  jq --arg tag "$tag" 'del(.inbounds[$tag].limit)' "$TRAFFIC_FILE" >"$tmp" || rc=1
  if ((rc == 0)); then install -m 600 "$tmp" "$TRAFFIC_FILE" || rc=1; fi
  rm -f "$tmp"; traffic_lock_release
  return "$rc"
}

traffic_after_config_change() {
  local old=${1-} new=${2-}
  [[ -f $TRAFFIC_FILE ]] || return 0
  if traffic_is_enabled; then traffic_collect || return 1; else traffic_sync_inventory || return 1; fi
  if [[ -n $old && -n $new ]]; then
    traffic_rename_records "$old" "$new" || return 1
    traffic_is_enabled && traffic_rules_restore_serialized
  elif [[ -n $old ]]; then
    traffic_remove_limit_data "$old"
  fi
}

traffic_format_bytes() {
  local bytes=${1:-0}
  awk -v bytes="$bytes" 'BEGIN {
    split("B KB MB GB TB PB", units, " "); value=bytes+0; unit=1;
    while (value>=1024 && unit<6) {value/=1024; unit++}
    if (unit==1) printf "%d %s", value, units[unit]; else printf "%.2f %s", value, units[unit]
  }'
}

traffic_range_total() {
  local start=$1 finish=$2
  jq --arg start "$start" --arg finish "$finish" '[.inbounds[]?.daily | to_entries[]? | select(.key >= $start and .key <= $finish) | .value] | add // 0' "$TRAFFIC_FILE"
}

traffic_limit_count() {
  [[ -f $TRAFFIC_FILE ]] || { printf '0'; return; }
  jq '[.inbounds[]? | select(.limit.enabled==true)] | length' "$TRAFFIC_FILE" 2>/dev/null || printf '0'
}

traffic_exhausted_tags() {
  traffic_limits_are_enabled || return 0
  jq -r '
    [.inbounds | to_entries[]? |
      select(.value.deleted!=true and .value.limit.enabled==true and
        ((.value.limit.usedBytes // 0) >= (.value.limit.quotaBytes // 0))) | .key] | join("、")
  ' "$TRAFFIC_FILE" 2>/dev/null
}

traffic_limits_show() {
  local rows tag quota used remaining rate status status_color cycle_start cycle_end cycle feature feature_color configured blocked limits_active=0
  traffic_init_file; traffic_sync_inventory
  if traffic_limits_are_enabled; then
    feature="已启用"; feature_color=$C_GREEN; limits_active=1
  else
    feature="未启用"; feature_color=$C_YELLOW
  fi
  configured=$(traffic_limit_count)
  if ((limits_active)); then
    blocked=$(jq '[.inbounds[]? | select(.deleted!=true and .limit.enabled==true and
      ((.limit.usedBytes // 0) >= (.limit.quotaBytes // 0)))] | length' "$TRAFFIC_FILE")
  else
    blocked=0
  fi
  heading "月度流量限制"
  printf '功能：%s%s%s  ·  已设置：%s  ·  已禁用：%s\n\n' "$feature_color" "$feature" "$C_RESET" "$configured" "$blocked"
  rows=$(jq -r '
    .inbounds | to_entries | sort_by(.key)[] |
    select(.value.deleted!=true and .value.limit.enabled==true) |
    [.key,((.value.limit.quotaBytes // 0)|floor|tostring),
     ((.value.limit.usedBytes // 0)|floor|tostring),
     (.value.limit.cycleStart // ""),(.value.limit.cycleEnd // "")] | @tsv
  ' "$TRAFFIC_FILE")
  if [[ -z $rows ]]; then
    info "还没有为入站设置流量额度。"
    return 0
  fi
  while IFS=$'\t' read -r tag quota used cycle_start cycle_end; do
    remaining=$((quota > used ? quota - used : 0))
    rate=$(traffic_format_percent "$used" "$quota")
    cycle=$(traffic_format_cycle "$cycle_start" "$cycle_end")
    if ((limits_active == 0)); then status="未执行"; status_color=$C_YELLOW
    elif ((used >= quota)); then status="已禁用"; status_color=$C_RED
    else status="正常"; status_color=$C_GREEN; fi
    printf '%s%s%s  [%s%s%s]\n' "$C_BOLD" "$tag" "$C_RESET" "$status_color" "$status" "$C_RESET"
    printf '  流量  %s / %s  (%s)\n' "$(traffic_format_bytes "$used")" "$(traffic_format_bytes "$quota")" "$rate"
    printf '  剩余  %s\n' "$(traffic_format_bytes "$remaining")"
    printf '  周期  %s\n\n' "$cycle"
  done <<<"$rows"
}

traffic_format_percent() {
  local used=${1:-0} quota=${2:-0}
  awk -v used="$used" -v quota="$quota" 'BEGIN {
    if (quota<=0) {printf "-"; exit}
    percent=(used/quota)*100
    if (used>0 && percent<0.01) printf "<0.01%%"; else printf "%.2f%%", percent
  }'
}

traffic_format_cycle() {
  local start=${1-} end=${2-} start_min end_min
  if ! traffic_validate_timestamp "$start" || ! traffic_validate_timestamp "$end"; then
    printf '%s → %s' "$start" "$end"
    return 0
  fi
  start_min=${start:0:16}; end_min=${end:0:16}
  if [[ ${start:0:4} == "${end:0:4}" ]]; then end_min=${end:5:11}; fi
  printf '%s → %s' "$start_min" "$end_min"
}

traffic_limit_quota_bytes() {
  local value=$1 bytes
  [[ $value =~ ^[0-9]+([.][0-9]+)?$ ]] || return 1
  bytes=$(awk -v value="$value" 'BEGIN {printf "%.0f", value * 1073741824}')
  [[ $bytes =~ ^[0-9]+$ ]] && ((bytes > 0)) || return 1
  printf '%s' "$bytes"
}

traffic_limits_enable() {
  traffic_require_root traffic-limits-enable; ensure_config
  traffic_is_enabled || { warn "请先开启流量统计，再启用流量限制。"; return 1; }
  traffic_limits_are_enabled && { info "流量限制已经启用。"; return 0; }
  traffic_collect || return 1
  traffic_set_limits_enabled true || return 1
  if ! traffic_rules_restore_serialized; then
    traffic_set_limits_enabled false || true
    traffic_rules_restore_serialized || true
    warn "流量限制启用失败，已恢复为关闭状态。"
    return 1
  fi
  info "流量限制已启用；未设置额度的入站不会受到限制。"
}

traffic_limits_disable() {
  traffic_require_root traffic-limits-disable
  traffic_limits_are_enabled || { info "流量限制已经关闭。"; return 0; }
  traffic_collect || true
  traffic_set_limits_enabled false || return 1
  if traffic_is_enabled; then
    if ! traffic_rules_restore_serialized; then
      traffic_set_limits_enabled true || true
      traffic_rules_restore_serialized || true
      warn "流量限制关闭失败，已恢复原状态。"
      return 1
    fi
  else
    traffic_rules_clear || return 1
  fi
  info "流量限制已关闭，额度配置和周期累计值已保留。"
}

traffic_limit_set() {
  local tag=${1-} quota_gb=${2-} reset_day=${3-} quota now anchor_day anchor_time cycle_end tmp rc=0 existing
  traffic_require_root traffic-limit-set; ensure_config
  traffic_is_enabled || { warn "请先开启流量统计。"; return 1; }
  traffic_limits_are_enabled || { warn "请先启用流量限制功能。"; return 1; }
  [[ -n $tag ]] || select_inbound tag || return 0
  inbound_exists "$tag" || { warn "找不到入站：${tag}"; return 1; }
  while [[ -z $quota_gb ]]; do
    read -r -p "每月流量额度（GB）: " quota_gb || { echo; return 0; }
    quota=$(traffic_limit_quota_bytes "$quota_gb") || { warn "请输入大于 0 的数字，例如 100 或 100.5。"; quota_gb=""; }
  done
  quota=${quota:-$(traffic_limit_quota_bytes "$quota_gb")} || { warn "流量额度无效。"; return 1; }
  traffic_collect || return 1
  now=$(traffic_now); anchor_time=${now:11:8}
  if [[ -z $reset_day && -t 0 ]]; then
    read -r -p "每月重置日期（1-31）: " reset_day || { echo; return 0; }
  fi
  reset_day=${reset_day:-$((10#${now:8:2}))}
  if ! [[ $reset_day =~ ^[0-9]+$ ]] || ((10#$reset_day < 1 || 10#$reset_day > 31)); then
    warn "重置日期无效，请输入 1 到 31。"; return 1
  fi
  existing=$(jq -r --arg tag "$tag" '.inbounds[$tag].limit.enabled==true' "$TRAFFIC_FILE")
  if [[ $existing == true ]]; then
    anchor_time=$(jq -r --arg tag "$tag" '.inbounds[$tag].limit.anchorTime // empty' "$TRAFFIC_FILE")
  fi
  anchor_day=$reset_day
  cycle_end=$(traffic_limit_first_cycle_end "$now" "$reset_day" "$anchor_time") || return 1
  traffic_lock_acquire || return 1
  tmp=$(temp_file)
  jq --arg tag "$tag" --argjson quota "$quota" --arg now "$now" --argjson resetDay "$reset_day" --argjson anchorDay "$anchor_day" \
    --arg anchorTime "$anchor_time" --arg cycleEnd "$cycle_end" '
      if .inbounds[$tag].limit.enabled==true then
        .inbounds[$tag].limit.quotaBytes=$quota | .inbounds[$tag].limit.resetDay=$resetDay | .inbounds[$tag].limit.anchorDay=$anchorDay | .inbounds[$tag].limit.cycleEnd=$cycleEnd
      else
        .inbounds[$tag].limit={enabled:true,quotaBytes:$quota,resetDay:$resetDay,anchorDay:$anchorDay,anchorTime:$anchorTime,
          cycleStart:$now,cycleEnd:$cycleEnd,usedBytes:0}
      end
    ' "$TRAFFIC_FILE" >"$tmp" || rc=1
  if ((rc == 0)); then install -m 600 "$tmp" "$TRAFFIC_FILE" || rc=1; fi
  rm -f "$tmp"; traffic_lock_release
  ((rc == 0)) || return 1
  traffic_rules_restore_serialized || { warn "额度已保存，但防火墙规则暂未同步，采集任务会自动重试。"; return 1; }
  if [[ $existing == true ]]; then
    info "已修改入站 ${tag} 的月度额度；原周期起止时间和已用流量保持不变。"
  else
    info "已设置入站 ${tag} 的月度额度，当前周期：${now} ～ ${cycle_end}。"
  fi
}

traffic_limit_remove() {
  local tag=${1-}
  traffic_require_root traffic-limit-remove; ensure_config
  [[ -n $tag ]] || select_inbound tag || return 0
  jq -e --arg tag "$tag" '.inbounds[$tag].limit.enabled==true' "$TRAFFIC_FILE" >/dev/null 2>&1 || { warn "入站 ${tag} 没有流量限制。"; return 1; }
  confirm "取消入站 ${tag} 的流量限制并删除当前周期累计值？" N || return 0
  traffic_collect || true
  traffic_remove_limit_data "$tag" || return 1
  if traffic_is_enabled; then traffic_rules_restore_serialized || true; fi
  info "已取消入站 ${tag} 的流量限制。"
}

traffic_period_show() {
  local day clock start end
  traffic_init_file
  day=$(jq -r '.period.day' "$TRAFFIC_FILE")
  clock=$(jq -r '.period.time' "$TRAFFIC_FILE")
  IFS=$'\t' read -r start end < <(traffic_period_bounds "$(traffic_now)")
  printf '月度统计起点：每月 %s 日 %s\n当前周期：%s ～ %s\n' "$day" "${clock:0:5}" "$start" "$end"
}

traffic_period_set() {
  local day=${1-} clock=${2-} tmp rc=0
  traffic_require_root traffic-period-set
  if [[ -z $day ]]; then read -r -p '每月起始日期（1-31）: ' day || return 1; fi
  if [[ -z $clock ]]; then read -r -p '起始时间（HH:MM）: ' clock || return 1; fi
  [[ $day =~ ^[0-9]+$ ]] && ((10#$day >= 1 && 10#$day <= 31)) || { warn '日期必须是 1 到 31。'; return 1; }
  [[ $clock =~ ^[0-9]{2}:[0-9]{2}$ ]] || { warn '时间格式必须是 HH:MM。'; return 1; }
  clock+=:00
  traffic_validate_timestamp "2026-01-01 $clock" || { warn '时间无效。'; return 1; }
  day=$((10#$day))
  traffic_init_file
  if jq -e --argjson day "$day" --arg clock "$clock" '.period.day==$day and .period.time==$clock' "$TRAFFIC_FILE" >/dev/null; then
    info '月度统计起点没有变化。'
    traffic_period_show
    return 0
  fi
  if traffic_is_enabled; then traffic_collect || return 1; fi
  traffic_lock_acquire || return 1
  tmp=$(temp_file)
  jq --argjson day "$day" --arg clock "$clock" '.period={day:$day,time:$clock} | .periodsSeeded=false' "$TRAFFIC_FILE" >"$tmp" || rc=1
  if ((rc == 0)); then install -m 600 "$tmp" "$TRAFFIC_FILE" || rc=1; fi
  rm -f "$tmp"
  if ((rc == 0)); then traffic_update_file '{}' false || rc=1; fi
  traffic_lock_release
  ((rc == 0)) || return 1
  info '月度统计起点已更新；已有每日记录按日期近似归入新周期。'
  traffic_period_show
}

traffic_show() {
  local start=${1-} end=${2-} period=false rows tag protocol port bytes deleted total status last limit_status exhausted display_order
  if [[ -n $start && -z $end ]]; then end=$(traffic_today); fi
  if [[ -z $start && -z $end ]]; then
    traffic_init_file
    IFS=$'\t' read -r start end < <(traffic_period_bounds "$(traffic_now)")
    period=true
  else
    traffic_validate_range "$start" "$end" || { warn "日期范围无效或超出当前周期。"; return 1; }
  fi
  traffic_init_file; traffic_sync_inventory
  traffic_is_enabled && status="运行中" || status="已停止"
  last=$(jq -r '.lastCollectedAt // empty' "$TRAFFIC_FILE")
  heading "流量信息"
  printf '统计状态：%s\n统计范围：%s ～ %s\n最后采集：%s\n\n' "$status" "$start" "$end" "${last:-尚未采集}"
  print_table_cell_clipped "标签" 20; printf '| '
  print_table_cell_clipped "协议" 10; printf '| '
  print_table_cell "端口" 7; printf '| %14s\n' "总流量"
  display_order=$(jq -c '[.inbounds[]?.tag]' "$CONFIG_FILE" 2>/dev/null || printf '[]')
  rows=$(jq -r --arg start "$start" --arg finish "$end" --argjson period "$period" --argjson order "$display_order" '
    ($order | to_entries | map({key:.value,value:.key}) | from_entries) as $positions |
    .inbounds | to_entries |
    sort_by(if $positions[.key] != null then [0,$positions[.key]] else [1,.key] end)[] |
    [.key,(.value.protocol // "unknown"),((.value.port // 0)|tostring),
     (if $period then (.value.cycles[$start] // 0)
      else ([.value.daily | to_entries[]? | select(.key >= $start and .key <= $finish) | .value] | add // 0) end),
     (.value.deleted // false),(.value.disabled // false)] | @tsv
  ' "$TRAFFIC_FILE")
  if [[ -n $rows ]]; then
    while IFS=$'\t' read -r tag protocol port bytes deleted disabled; do
      if [[ $disabled == true ]]; then tag="${tag}(已禁用)"; elif [[ $deleted == true ]]; then tag="${tag}(已删除)"; fi
      print_table_cell_clipped "$tag" 20; printf '| '
      print_table_cell_clipped "$protocol" 10; printf '| '
      print_table_cell "$port" 7; printf '| %14s\n' "$(traffic_format_bytes "$bytes")"
    done <<<"$rows"
  fi
  if [[ $period == true ]]; then
    total=$(jq --arg start "$start" '[.inbounds[]?.cycles[$start] // 0] | add // 0' "$TRAFFIC_FILE")
  else
    total=$(traffic_range_total "$start" "$end")
  fi
  printf '%s\n全部入站：%s\n' '----------------------------------------------------------' "$(traffic_format_bytes "$total")"
  traffic_limits_are_enabled && limit_status="已启用" || limit_status="未启用"
  printf '流量限制：%s' "$limit_status"
  exhausted=$(traffic_exhausted_tags)
  [[ -z $exhausted ]] || printf '  |  已禁用入站：%s' "$exhausted"
  printf '\n'
}

traffic_prompt_range() {
  local __start_var=$1 __end_var=$2 candidate_start candidate_end cutoff today
  cutoff=$(traffic_retention_start); today=$(traffic_today)
  while true; do
    prompt_value candidate_start "开始日期" "$cutoff" || return 1
    traffic_validate_date "$candidate_start" || { warn "开始日期格式无效，请使用 YYYY-MM-DD。"; continue; }
    traffic_iso_compare "$candidate_start" ge "$cutoff" || { warn "只保留当前周期的数据，最早可选 ${cutoff}。"; continue; }
    break
  done
  while true; do
    prompt_value candidate_end "结束日期" "$today" || return 1
    traffic_validate_date "$candidate_end" || { warn "结束日期格式无效，请使用 YYYY-MM-DD。"; continue; }
    traffic_iso_compare "$candidate_end" le "$today" || { warn "结束日期不能晚于今天 ${today}。"; continue; }
    traffic_iso_compare "$candidate_end" ge "$candidate_start" || { warn "结束日期不能早于开始日期。"; continue; }
    break
  done
  printf -v "$__start_var" '%s' "$candidate_start"; printf -v "$__end_var" '%s' "$candidate_end"
}

traffic_select_record_tag() {
  local __var=$1 __item __deleted __disabled __answer __selected
  local tags=() labels=()
  ensure_config
  traffic_init_file
  traffic_sync_inventory || return 1
  while IFS=$'\t' read -r __item __deleted __disabled; do
    [[ -n $__item ]] || continue
    tags+=("$__item")
    if [[ $__disabled == true ]]; then labels+=("${__item}(已禁用)")
    elif [[ $__deleted == true ]]; then labels+=("${__item}(已删除)")
    else labels+=("$__item"); fi
  done < <(
    jq -r --slurpfile traffic "$TRAFFIC_FILE" '
      ([.inbounds[]?.tag | {tag:.,deleted:false,disabled:false}] +
       [($traffic[0].inbounds // {} | to_entries[]? |
         select(.value.deleted==true) | {tag:.key,deleted:true,disabled:false})]) |
      reduce .[] as $item ([];
        if any(.[]; .tag==$item.tag) then . else . + [$item] end) |
      .[] | [.tag,(.deleted|tostring),(.disabled|tostring)] | @tsv
    ' "$CONFIG_FILE"
  )
  ((${#tags[@]})) || { warn "没有可清空的入站流量记录。"; return 1; }
  if ((${#tags[@]} == 1)); then
    __selected=${tags[0]}
  else
    choose __answer "选择入站" "${labels[@]}" || return 1
    __selected=${tags[$((__answer-1))]}
  fi
  printf -v "$__var" '%s' "$__selected"
}

traffic_clear_tag_records() {
  local tag=${1-} tmp rc=0
  [[ -n $tag ]] || traffic_select_record_tag tag || return 0
  traffic_collect || true; traffic_init_file
  jq -e --arg tag "$tag" '.inbounds[$tag] != null' "$TRAFFIC_FILE" >/dev/null || { warn "没有入站 ${tag} 的流量记录。"; return 1; }
  confirm "清空入站 ${tag} 当前周期的流量记录和额度已用量？" N || return 0
  traffic_lock_acquire || return 1
  tmp=$(temp_file); jq --arg tag "$tag" '
    .inbounds[$tag].daily={} | .inbounds[$tag].cycles={} |
    if .inbounds[$tag].limit.enabled==true then .inbounds[$tag].limit.usedBytes=0 else . end
  ' "$TRAFFIC_FILE" >"$tmp" || rc=1
  if ((rc == 0)); then install -m 600 "$tmp" "$TRAFFIC_FILE" || rc=1; fi
  rm -f "$tmp"; traffic_lock_release
  ((rc == 0)) || return 1
  if traffic_is_enabled; then traffic_rules_restore_serialized || true; fi
  info "已清空入站 ${tag} 的流量记录。"
}

traffic_clear_all_records() {
  local answer tmp rc=0
  traffic_collect || true; traffic_init_file
  printf '输入 RESET 确认清空全部流量记录和所有当前周期已用流量：'
  read -r answer || { echo; return 0; }
  [[ $answer == RESET ]] || { info "已取消。"; return 0; }
  traffic_lock_acquire || return 1
  tmp=$(temp_file); jq '
    .inbounds |= with_entries(
      .value.daily={} | .value.cycles={} |
      if .value.limit.enabled==true then .value.limit.usedBytes=0 else . end
    )
  ' "$TRAFFIC_FILE" >"$tmp" || rc=1
  if ((rc == 0)); then install -m 600 "$tmp" "$TRAFFIC_FILE" || rc=1; fi
  rm -f "$tmp"; traffic_lock_release
  ((rc == 0)) || return 1
  if traffic_is_enabled; then traffic_rules_restore_serialized || true; fi
  info "已清空全部流量记录。"
}

traffic_timer_install() {
  [[ -x $QUICK_COMMAND ]] || install_quick_command
  case $(platform_init_system) in
    systemd)
      cat >"$TRAFFIC_SYSTEMD_SERVICE" <<EOF_SERVICE
[Unit]
Description=Collect xrayctl per-inbound traffic counters
After=network-online.target

[Service]
Type=oneshot
ExecStart=${QUICK_COMMAND} internal-traffic-collect
UMask=0077
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true
ReadWritePaths=$(dirname "$TRAFFIC_FILE") $(dirname "$TRAFFIC_LOCK")
EOF_SERVICE
      cat >"$TRAFFIC_SYSTEMD_TIMER" <<EOF_TIMER
[Unit]
Description=Collect xrayctl traffic every minute

[Timer]
OnBootSec=2min
OnUnitActiveSec=1min
RandomizedDelaySec=5s
Persistent=true

[Install]
WantedBy=timers.target
EOF_TIMER
      systemctl daemon-reload
      systemctl enable --now xrayctl-traffic-collect.timer >/dev/null 2>&1 || return 1
      meta_resource_register trafficService "$TRAFFIC_SYSTEMD_SERVICE"
      meta_resource_register trafficTimer "$TRAFFIC_SYSTEMD_TIMER"
      ;;
    openrc)
      cat >"$TRAFFIC_OPENRC_SERVICE" <<EOF_RC
#!/sbin/openrc-run
name="xrayctl traffic collector"
description="Collect xrayctl per-inbound traffic counters"
command="${QUICK_COMMAND}"
command_args="internal-traffic-watch"
command_user="root:root"
supervisor="supervise-daemon"
respawn_delay=3
respawn_max=0
$(printf '%s' 'depend() { need net; after xray; }')
EOF_RC
      chmod 755 "$TRAFFIC_OPENRC_SERVICE"
      rc-update add xrayctl-traffic-collect default >/dev/null 2>&1 || true
      rc-service xrayctl-traffic-collect restart >/dev/null 2>&1 || return 1
      meta_resource_register trafficService "$TRAFFIC_OPENRC_SERVICE"
      ;;
    *) warn "未检测到 systemd 或 OpenRC，无法安装流量采集任务。"; return 1;;
  esac
}

traffic_timer_remove() {
  case $(platform_init_system) in
    systemd)
      systemctl disable --now xrayctl-traffic-collect.timer >/dev/null 2>&1 || true
      systemctl stop xrayctl-traffic-collect.service >/dev/null 2>&1 || true
      rm -f "$TRAFFIC_SYSTEMD_SERVICE" "$TRAFFIC_SYSTEMD_TIMER"
      systemctl daemon-reload >/dev/null 2>&1 || true
      ;;
    openrc)
      rc-service xrayctl-traffic-collect stop >/dev/null 2>&1 || true
      rc-update del xrayctl-traffic-collect default >/dev/null 2>&1 || true
      rm -f "$TRAFFIC_OPENRC_SERVICE"
      ;;
  esac
}

traffic_runtime_ensure() {
  traffic_is_enabled || return 0
  traffic_ensure_backend || return 1
  traffic_sync_inventory || return 1
  traffic_rules_restore_serialized || return 1
  traffic_timer_install
}

traffic_runtime_stop() {
  traffic_timer_remove
  traffic_rules_clear
}

traffic_enable() {
  traffic_require_root traffic-enable; ensure_config
  local selected
  traffic_ensure_backend || return 1
  selected=$(traffic_backend)
  if traffic_backend_conflicts "$selected"; then
    warn "检测到同名 ${selected} 流量规则，但无法确认由 xrayctl 管理；拒绝覆盖。"
    return 1
  fi
  traffic_set_backend "$selected"
  traffic_set_enabled true
  traffic_sync_inventory
  if ! traffic_rules_restore || ! traffic_timer_install; then
    traffic_set_enabled false; traffic_runtime_stop || true
    warn "流量统计启动失败，已撤销运行时规则。"; return 1
  fi
  meta_resource_register trafficFile "$TRAFFIC_FILE"
  info "流量统计已开启；每分钟保存一次，只保留当前月度周期。"
}

traffic_disable() {
  traffic_require_root traffic-disable
  traffic_limits_are_enabled && { warn "请先关闭流量限制功能，再停止流量统计。"; return 1; }
  traffic_collect || true
  if ! traffic_runtime_stop; then
    traffic_timer_install || true
    warn "检测到不属于 xrayctl 的同名规则，流量统计未停止。"
    return 1
  fi
  traffic_set_enabled false
  info "流量统计已停止，已有记录将继续保留。"
}

traffic_remove_all() {
  traffic_runtime_stop || return 1
  rm -f "$TRAFFIC_FILE"
  rmdir "$(dirname "$TRAFFIC_FILE")" 2>/dev/null || true
}

internal_traffic_collect() { traffic_collect; }

internal_traffic_watch() {
  traffic_require_root internal-traffic-watch
  trap 'traffic_collect >/dev/null 2>&1 || true; exit 0' INT TERM
  while traffic_is_enabled; do
    traffic_collect || true
    sleep "$TRAFFIC_COLLECT_INTERVAL" & wait $!
  done
}
