#!/usr/bin/env bash
# shellcheck shell=bash
# Per-inbound rolling traffic accounting and per-user monthly quotas. Linux
# packet counters provide inbound samples; only the current display period is
# retained while each user's quota cycle keeps its independent local timestamp.

TRAFFIC_NFT_TABLE="xrayctl_traffic"
TRAFFIC_IPTABLES_IN_CHAIN="XRAYCTL_TRAFFIC_IN"
TRAFFIC_IPTABLES_OUT_CHAIN="XRAYCTL_TRAFFIC_OUT"
TRAFFIC_LOCK="${XRAYCTL_TRAFFIC_LOCK:-${LOCK_FILE}.traffic}"
TRAFFIC_COLLECT_INTERVAL="${XRAYCTL_TRAFFIC_COLLECT_INTERVAL:-60}"
TRAFFIC_SYSTEMD_SERVICE="${SYSTEMD_UNIT_DIR}/xrayctl-traffic-collect.service"
TRAFFIC_SYSTEMD_TIMER="${SYSTEMD_UNIT_DIR}/xrayctl-traffic-collect.timer"
TRAFFIC_OPENRC_SERVICE="${OPENRC_INIT_DIR}/xrayctl-traffic-collect"

traffic_user_managed_config() {
  [[ -r $CONFIG_FILE ]] && jq -e '.xrayctlUserStats.enabled==true' "$CONFIG_FILE" >/dev/null 2>&1
}

traffic_user_has_clients() {
  [[ -r $CONFIG_FILE ]] && jq -e '[.inbounds[]? | select(
    (.protocol=="vless" and ((.settings.clients // [])|length)>0) or
    (.protocol=="socks" and .settings.auth=="password" and ((.settings.accounts // .settings.users // [])|length)>0) or
    (.protocol=="http" and ((.settings.accounts // .settings.users // [])|length)>0)
  )] | length>0' "$CONFIG_FILE" >/dev/null 2>&1
}

# Xray StatsService uses the email field for every authenticated inbound user.
# VLESS has a private xrayctl-generated email; HTTP/SOCKS expose their actual
# account username as that email. The same name on two accounts is ambiguous
# because the core aggregates both counters globally.
traffic_user_inventory_json() {
  local file=${1:-$CONFIG_FILE}
  jq -c '
    [ .inbounds[]? as $inbound |
      if $inbound.protocol=="vless" then
        $inbound.settings.clients[]? |
        select(.xrayctlLabel != null and (.email|type)=="string") |
        {tag:$inbound.tag,id:.email,label:.xrayctlLabel,protocol:"vless"}
      elif $inbound.protocol=="socks" and $inbound.settings.auth=="password" then
        ($inbound.settings.accounts // $inbound.settings.users // [])[]? |
        select((.user|type)=="string" and (.user|length)>0 and (.pass|type)=="string" and (.pass|length)>0) |
        {tag:$inbound.tag,id:.user,label:.user,protocol:"socks"}
      elif $inbound.protocol=="http" then
        ($inbound.settings.accounts // $inbound.settings.users // [])[]? |
        select((.user|type)=="string" and (.user|length)>0 and (.pass|type)=="string" and (.pass|length)>0) |
        {tag:$inbound.tag,id:.user,label:.user,protocol:"http"}
      else empty end
    ] as $clients |
    [$clients[] as $client | $client + {
      ambiguous:(([$clients[] | select(.id==$client.id)]|length)>1)
    }]
  ' "$file"
}

# The core aggregates user counters by email across all inbounds. Keep the
# display label in the client object and use a separate, globally unique email
# for accounting. UUIDs and share-link labels are unchanged. This function
# produces a candidate only; the caller must validate and commit it through
# the normal configuration transaction.
traffic_user_prepare_identities() {
  local input=$1 output=$2 working next index client_index label original identity mappings='[]'
  if ! jq -e '
    def valid_label: . == null or (type=="string" and length<=128 and (test("[\\r\\n\\t]")|not) and (contains(">>>")|not));
    [.inbounds[]? | select(.protocol=="vless") | .settings.clients[]? |
      select((.email|valid_label|not) or (.xrayctlLabel|valid_label|not))] | length==0
  ' "$input" >/dev/null; then
    warn "VLESS 用户名称含有无法安全处理的字符，请先修正配置。"
    return 1
  fi
  working=$(temp_file) || return 1
  cp "$input" "$working" || { rm -f "$working"; return 1; }
  while IFS=$'\t' read -r index client_index; do
    [[ $index =~ ^[0-9]+$ && $client_index =~ ^[0-9]+$ ]] || continue
    original=$(jq -r --argjson i "$index" --argjson j "$client_index" '.inbounds[$i].settings.clients[$j].email // ""' "$working") || { rm -f "$working"; return 1; }
    if [[ -n $original ]] && jq -e --arg email "$original" '[.inbounds[]? | select(.protocol=="vless") | .settings.clients[]? | select(.xrayctlLabel != null and .email==$email)] | length>0' "$working" >/dev/null; then
      rm -f "$working"
      warn "用户名称与已有内部统计标识冲突，拒绝改变用户路由。"
      return 1
    fi
    label=$original
    if [[ -z $label ]]; then
      label=$(jq -r --argjson i "$index" --argjson j "$client_index" '"user-" + (.inbounds[$i].settings.clients[$j].id // ($j|tostring))' "$working") || { rm -f "$working"; return 1; }
    fi
    while :; do
      identity="xrayctl-user-$(random_hex 16)" || { rm -f "$working"; return 1; }
      jq -e --arg id "$identity" '[.. | objects | .email? // empty | select(type=="string" and ascii_downcase == ($id|ascii_downcase))] | length == 0' "$working" >/dev/null && break
    done
    next=$(temp_file) || { rm -f "$working"; return 1; }
    jq --argjson i "$index" --argjson j "$client_index" --arg label "$label" --arg identity "$identity" \
      '.inbounds[$i].settings.clients[$j] |= (.xrayctlLabel=$label | .email=$identity)' "$working" >"$next" || { rm -f "$next" "$working"; return 1; }
    mv -f "$next" "$working" || { rm -f "$next" "$working"; return 1; }
    mappings=$(jq -nc --argjson maps "$mappings" --arg old "$original" --arg new "$identity" '$maps + [{old:$old,new:$new}]') || { rm -f "$working"; return 1; }
  done < <(jq -r '.inbounds | to_entries[] | select(.value.protocol=="vless") | .key as $i | (.value.settings.clients // [] | to_entries[]) | select(.value.xrayctlLabel == null) | [$i,.key] | @tsv' "$input")
  # A regexp user rule can match the generated email even when it did not
  # match the original label. Refuse such a migration instead of silently
  # changing routing. Rules that matched an old name gain its new exact ID.
  if ! jq -e '
    [.routing.rules[]?.user[]? | select(type=="string" and startswith("regexp:")) |
      .[7:] | select((test("\\(\\?[=!<]|\\\\[1-9]") or (try (test("") | true) catch false | not)))] | length==0
  ' "$input" >/dev/null; then
    rm -f "$working"
    warn "用户路由包含无法安全迁移的正则表达式。"
    return 1
  fi
  if ! jq -e --argjson mappings "$mappings" '
    def matches($name;$terms): any($terms[]; . as $term |
      if ($term|startswith("regexp:")) then (try ($name|test($term[7:])) catch false) else $name==$term end);
    [.routing.rules[]? | select((.user|type)=="array") | .user as $terms |
      $mappings[] | select(.old != "") | select(matches(.new;$terms) and (matches(.old;$terms)|not))] | length==0
  ' "$input" >/dev/null; then
    rm -f "$working"
    warn "现有用户路由正则可能匹配新的统计标识，拒绝改变路由行为。"
    return 1
  fi
  # Existing user-targeted rules continue to match the migrated users. Keep
  # their old entries because a non-VLESS account may still use that email.
  jq --argjson mappings "$mappings" '
    if (.routing.rules|type)=="array" then
      .routing.rules |= map(if (.user|type)=="array" then
        .user |= (map(. as $rule | [$rule] + [$mappings[] | select(.old != "") |
          select(if ($rule|startswith("regexp:")) then (try (.old|test($rule[7:])) catch false) else .old==$rule end) | .new]) | add // [] | unique)
      else . end)
    else . end
  ' "$working" >"$output" || { rm -f "$working"; return 1; }
  rm -f "$working"
  # Reject ambiguous pre-existing managed identifiers and labels, rather than
  # ever assigning one core counter to two users.
  jq -e '
    [.. | objects | .email? | select(type=="string") | ascii_downcase] as $all |
    ([.inbounds[]? | select(.protocol=="vless") | .settings.clients[]? |
      ((.xrayctlLabel|type)=="string" and (.xrayctlLabel|length)>0 and
       (.email|type)=="string" and (.email|test("^xrayctl-user-[0-9a-f]{32}$")) and
       (.email | ascii_downcase | . as $id | [$all[] | select(.==$id)] | length == 1))] | all) and
    ([.inbounds[]? | select(.protocol=="vless") | [.settings.clients[]? | (.xrayctlLabel // .email)] | length == (unique|length)] | all)
  ' "$output" >/dev/null
}

traffic_user_prepare_config() {
  local input=$1 output=$2 address=$3 identities api_tag
  if [[ ! $address =~ ^127\.0\.0\.1:([0-9]+)$ ]] || ! validate_port "${BASH_REMATCH[1]}"; then
    warn "用户统计 API 必须监听有效的本机 IPv4 地址。"; return 1
  fi
  # Reuse an existing direct loopback API while preserving its services and
  # tag. Refuse other API layouts and routes to the API because they may make
  # the newly added statistics service externally reachable.
  if ! jq -e --arg address "$address" '
    (.api.tag // "xrayctl-user-stats") as $apiTag |
    (.api == null or ((.api.tag|type)=="string" and (.api.tag|length)>0 and .api.listen==$address)) and
    ([.routing.rules[]? | select(.outboundTag == $apiTag)] | length == 0) and
    ([.inbounds[]?, .outbounds[]? | select(.tag == $apiTag)] | length == 0) and
    (if .xrayctlUserStats.enabled != true then
       ([.routing.rules[]? | select((.ruleTag // "") | startswith("xrayctl-user-limit:"))] | length == 0) and
       ([.inbounds[]?, .outbounds[]? | select(.tag == "xrayctl-user-deny")] | length == 0)
     else true end)
  ' "$input" >/dev/null; then
    warn "已有 API 配置或标签冲突，无法安全配置本机用户统计。"
    return 1
  fi
  api_tag=$(jq -r '.api.tag // "xrayctl-user-stats"' "$input") || return 1
  identities=$(temp_file) || return 1
  traffic_user_prepare_identities "$input" "$identities" || { rm -f "$identities"; warn "用户统计标识或用户名称冲突。"; return 1; }
  if ! jq -e '
    [.inbounds[]? | select(.protocol=="socks" or .protocol=="http") |
      .settings.accounts // .settings.users // [] | .[]? | .user] as $users |
    ([$users[] | select(type!="string" or length==0 or length>128 or (test("[\\r\\n\\t]") or contains(">>>")))] | length)==0
  ' "$identities" >/dev/null; then
    rm -f "$identities"
    warn "HTTP/SOCKS 用户名包含 StatsService 无法安全解析的字符；请先重命名账号。"
    return 1
  fi
  jq --arg address "$address" --arg apiTag "$api_tag" '
    .stats=(.stats // {}) |
    .api=(.api // {}) | .api.tag=$apiTag | .api.listen=$address |
    .api.services=((.api.services // []) + ["StatsService"] | unique) |
    .xrayctlUserStats={enabled:true} |
    .policy=(.policy // {}) | .policy.levels=(.policy.levels // {}) |
    reduce ([0] + [.inbounds[]? | select(.protocol=="vless") | .settings.clients[]? | (.level // 0)] | unique[]) as $level
      (. ; .policy.levels[($level|tostring)]=((.policy.levels[($level|tostring)] // {}) + {statsUserUplink:true,statsUserDownlink:true}))
  ' "$identities" >"$output" || { rm -f "$identities"; return 1; }
  rm -f "$identities"
}

# A PID alone can be reused. Combine it with the Linux boot ID and kernel
# process start ticks, and compare before/after every API query. This works
# with both systemd's MainPID and the OpenRC service's pidfile.
traffic_user_core_epoch() {
  local pid boot start stat_line
  case $(platform_init_system) in
    systemd) pid=$(systemctl show "$SERVICE_NAME" -p MainPID --value 2>/dev/null) || return 1 ;;
    openrc) pid=$(cat "/run/${SERVICE_NAME}.pid" 2>/dev/null) || return 1 ;;
    *) return 1 ;;
  esac
  [[ $pid =~ ^[0-9]+$ ]] && ((pid > 0)) || return 1
  [[ -r /proc/$pid/stat && -r /proc/sys/kernel/random/boot_id ]] || return 1
  boot=$(cat /proc/sys/kernel/random/boot_id) || return 1
  stat_line=$(cat "/proc/$pid/stat") || return 1
  stat_line=${stat_line##*) }
  start=$(awk '{print $20}' <<<"$stat_line")
  [[ $start =~ ^[0-9]+$ && $boot =~ ^[0-9a-fA-F-]+$ ]] || return 1
  printf '%s:%s:%s' "$boot" "$pid" "$start"
}

# StatsService is queried without reset. An absent stat is not treated as a
# zero: it can mean a user has not yet produced traffic. Never accept a partial
# or malformed response as a successful sample.
traffic_user_read_samples() {
  local address=$1 payload
  [[ $address =~ ^127\.0\.0\.1:([0-9]+)$ ]] && validate_port "${BASH_REMATCH[1]}" || return 1
  payload=$("$XRAY_BIN" api statsquery -s "$address" -t 3 -pattern 'user>>>' 2>/dev/null) || return 1
  jq -ce '
    if type!="object" or ((.stat // [])|type)!="array" then error("invalid stats response") else . end |
    (.stat // []) as $stats |
    if ([$stats[] | select((.name|type)!="string" or (((.value // 0)|type)!="number" and ((.value // 0)|type)!="string") or (((.value // 0)|tostring)|test("^[0-9]+$")|not))] | length)>0 or
       ([$stats[].name] | length != (unique|length)) then error("invalid stat entry") else . end |
    reduce $stats[] as $item ({};
      if ($item.name | test("^user>>>[^>]+>>>traffic>>>(uplink|downlink)$")) then
        ($item.name | capture("^user>>>(?<id>[^>]+)>>>traffic>>>(?<direction>uplink|downlink)$")) as $parsed |
        .[$parsed.id][$parsed.direction]=(($item.value // 0)|tonumber)
      else . end)
  ' <<<"$payload"
}

traffic_user_rolled_limits_json() {
  local now=$1 tag id anchor_day anchor_time start end used next_boundary
  while IFS=$'\t' read -r tag id anchor_day anchor_time start end used; do
    [[ -n $tag && -n $id ]] || continue
    if ! traffic_validate_timestamp "$start" || ! traffic_validate_timestamp "$end"; then continue; fi
    while traffic_iso_compare "$now" ge "$end"; do
      start=$end
      next_boundary=$(traffic_limit_next_timestamp "$start" "$anchor_day" "$anchor_time") || return 1
      end=$next_boundary; used=0
    done
    jq -nc --arg tag "$tag" --arg id "$id" --arg start "$start" --arg end "$end" --argjson used "$used" \
      '{tag:$tag,id:$id,start:$start,end:$end,used:$used}'
  done < <(jq -r '.inbounds | to_entries[]? | .key as $tag | (.value.users // {} | to_entries[]?) |
    select(.value.limit.enabled==true) | [$tag,.key,((.value.limit.anchorDay // .value.limit.resetDay // 0)|tostring),
      (.value.limit.anchorTime // ""),(.value.limit.cycleStart // ""),(.value.limit.cycleEnd // ""),
      ((.value.limit.usedBytes // 0)|floor|tostring)] | @tsv' "$TRAFFIC_FILE") | jq -s '.'
}

# Caller holds TRAFFIC_LOCK. Xray's dispatcher counts each payload once per
# direction, not once per network leg. Preserve those raw directional totals;
# quota usage explicitly estimates the two network legs, as inbound quotas do.
# This is an estimate: protocol overhead and retransmissions are not present in
# Xray's payload counters. Failed reads never change this data.
traffic_user_update_samples() {
  local samples=$1 epoch=$2 now period_start inventory active_tags rolled tmp
  now=$(traffic_now)
  period_start=$(traffic_period_start "$now") || return 1
  inventory=$(traffic_user_inventory_json "$CONFIG_FILE") || return 1
  active_tags=$(jq -c '[.inbounds[]? | select(.protocol=="vless" or .protocol=="socks" or .protocol=="http") | .tag]' "$CONFIG_FILE") || return 1
  if jq -e --arg now "$now" '
    .userLastCollectedAt as $last |
    any(.inbounds[]?.users[]?; .limit.enabled==true and
      (.limit.cycleEnd // "")!="" and $now>=.limit.cycleEnd and
      $last!=null and $last<.limit.cycleEnd)
  ' "$TRAFFIC_FILE" >/dev/null; then
    warn "用户采集跨越额度周期边界，边界之间的增量只能按本次采集周期估算。"
  fi
  rolled=$(traffic_user_rolled_limits_json "$now") || return 1
  tmp=$(temp_file) || return 1
  jq --argjson samples "$samples" --argjson inventory "$inventory" --argjson activeTags "$active_tags" --argjson rolled "$rolled" --arg epoch "$epoch" --arg now "$now" --arg periodStart "$period_start" '
    reduce $rolled[] as $cycle (. ;
      .userLastCollectedAt as $last |
      .inbounds[$cycle.tag].users[$cycle.id].limit |= (
        if .cycleStart!=$cycle.start and $last!=null then .lastCycleEstimate={from:$last,to:$now} else . end |
        .cycleStart=$cycle.start | .cycleEnd=$cycle.end | .usedBytes=$cycle.used)
    ) |
    # A manually renamed inbound can be recognized by the stable, globally
    # unique identity. Move its user state before calculating deltas.
    reduce $inventory[] as $client (. ;
      if $client.ambiguous or .inbounds[$client.tag].users[$client.id] != null then . else
        [.inbounds | to_entries[] | select(.key != $client.tag and .value.users[$client.id] != null) | .key] as $oldTags |
        if ($oldTags|length)==1 then
          .inbounds[$client.tag].users[$client.id]=.inbounds[$oldTags[0]].users[$client.id] |
          del(.inbounds[$oldTags[0]].users[$client.id])
        else . end
      end
    ) |
    reduce $activeTags[] as $tag (. ;
      if .inbounds[$tag].users != null then
        .inbounds[$tag].users |= with_entries(.key as $id | select(any($inventory[]; .tag==$tag and .id==$id)))
      else . end
    ) |
    reduce $inventory[] as $client (.;
      .inbounds[$client.tag] |= ((. // {}) | .daily=(.daily // {})) |
      .inbounds[$client.tag].users= (.inbounds[$client.tag].users // {}) |
      .inbounds[$client.tag].users[$client.id] = ((.inbounds[$client.tag].users[$client.id] // {}) + {label:$client.label}) |
      .inbounds[$client.tag].users[$client.id] |= (. as $user |
        ($samples[$client.id] // {}) as $sample |
        if $client.ambiguous then
          .samplingBlocked=true |
          if $sample.uplink != null or $sample.downlink != null then
            .last={epoch:$epoch,uplink:($sample.uplink // ($user.last.uplink // 0)),downlink:($sample.downlink // ($user.last.downlink // 0))}
          else . end
        else
        (($user.last.epoch // "") == $epoch) as $same |
        ($user.samplingBlocked == true) as $blocked |
        (if $same then ($user.last.uplink // 0) else 0 end) as $oldUp |
        (if $same then ($user.last.downlink // 0) else 0 end) as $oldDown |
        (if $blocked or $sample.uplink == null then 0 elif $same and $sample.uplink >= $oldUp then $sample.uplink-$oldUp else $sample.uplink end) as $up |
        (if $blocked or $sample.downlink == null then 0 elif $same and $sample.downlink >= $oldDown then $sample.downlink-$oldDown else $sample.downlink end) as $down |
        .uplinkBytes=((.uplinkBytes // 0)+$up) | .downlinkBytes=((.downlinkBytes // 0)+$down) |
        .cycles=((.cycles // {}) | with_entries(select(.key==$periodStart))) |
        .cycles[$periodStart]=((.cycles[$periodStart] // 0)+2*$up+2*$down) |
        if .limit.enabled==true then .limit.usedBytes=((.limit.usedBytes // 0)+2*$up+2*$down) else . end |
        .accountingMultiplier=2 |
        .last={epoch:$epoch,uplink:($sample.uplink // $oldUp),downlink:($sample.downlink // $oldDown)} |
        del(.samplingBlocked)
        end
      )
    ) | .userLastCollectedAt=$now | .userCoreEpoch=$epoch
  ' "$TRAFFIC_FILE" >"$tmp" || { rm -f "$tmp"; return 1; }
  traffic_write_file "$tmp" || { rm -f "$tmp"; return 1; }
  rm -f "$tmp"
}

traffic_user_collect_locked() {
  local address before after samples inventory
  address=$(jq -r 'if .xrayctlUserStats.enabled==true then (.api.listen // "") else "" end' "$CONFIG_FILE") || return 1
  [[ -n $address ]] || return 0
  inventory=$(traffic_user_inventory_json "$CONFIG_FILE") || return 1
  if ! jq -e --slurpfile traffic "$TRAFFIC_FILE" --argjson inventory "$inventory" '
    $traffic[0] as $state |
    [.. | objects | .email? | select(type=="string") | ascii_downcase] as $all |
    [.inbounds[]? | select(.protocol=="vless") | .tag as $tag | .settings.clients[]? | . as $client |
      ((.xrayctlLabel|type)=="string" and (.xrayctlLabel|length)>0 and (.email|type)=="string" and (.email|test("^xrayctl-user-[0-9a-f]{32}$")) and
        (.email | ascii_downcase | . as $id | [$all[] | select(.==$id)] | length==1) and
        ($state.inbounds[$tag].users[($client.email // "" | tostring)] != null or
          ([($state.inbounds[$tag].users // {}) | to_entries[] | select(.value.label==$client.xrayctlLabel)] | length==0)))] | all and
    ([$inventory[] | select(.protocol=="socks" or .protocol=="http") |
      select((.id|type)!="string" or (.id|length)==0 or (.id|length)>128 or (.id|test("[\\r\\n\\t]") or contains(">>>")))] | length)==0
  ' "$CONFIG_FILE" >/dev/null; then
    warn "用户配置包含未登记或无效的统计标识，本次用户采集已跳过。"
    return 1
  fi
  before=$(traffic_user_core_epoch) || { warn "无法确定 Xray 进程身份，用户流量采集已跳过。"; return 1; }
  samples=$(traffic_user_read_samples "$address") || { warn "Xray 用户统计 API 不可用，本次保留已有用户流量及限制。"; return 1; }
  after=$(traffic_user_core_epoch) || { warn "无法确认 Xray 进程身份，用户流量采集已跳过。"; return 1; }
  [[ $before == "$after" ]] || { warn "采集期间 Xray 已重启，本次用户流量采集已跳过。"; return 1; }
  traffic_user_update_samples "$samples" "$before"
}

traffic_user_collect_serialized() {
  local rc=0
  [[ -f $TRAFFIC_FILE && -f $CONFIG_FILE ]] || return 0
  traffic_lock_acquire || return 1
  traffic_user_collect_locked || rc=1
  traffic_lock_release
  return "$rc"
}

traffic_user_forget_inbound() {
  local tag=$1 tmp rc=0
  [[ -f $TRAFFIC_FILE ]] || return 0
  traffic_lock_acquire || return 1
  tmp=$(temp_file)
  jq --arg tag "$tag" 'del(.inbounds[$tag].users)' "$TRAFFIC_FILE" >"$tmp" || rc=1
  if ((rc==0)); then traffic_write_file "$tmp" || rc=1; fi
  rm -f "$tmp"; traffic_lock_release
  return "$rc"
}

traffic_user_forget_client() {
  local tag=$1 id=$2 tmp rc=0
  [[ -f $TRAFFIC_FILE && -n $id ]] || return 0
  traffic_lock_acquire || return 1
  tmp=$(temp_file)
  jq --arg tag "$tag" --arg id "$id" 'del(.inbounds[$tag].users[$id])' "$TRAFFIC_FILE" >"$tmp" || rc=1
  if ((rc==0)); then traffic_write_file "$tmp" || rc=1; fi
  rm -f "$tmp"; traffic_lock_release
  return "$rc"
}

traffic_user_rename_client_record_locked() {
  local tag=$1 old_id=$2 new_id=$3 tmp rc=0
  [[ -f $TRAFFIC_FILE && -n $old_id && -n $new_id ]] || return 0
  [[ $old_id != "$new_id" ]] || return 0
  tmp=$(temp_file) || return 1
  jq --arg tag "$tag" --arg old "$old_id" --arg new "$new_id" '
    if .inbounds[$tag].users[$old] != null then
      .inbounds[$tag].users[$new]=(.inbounds[$tag].users[$old] + {label:$new}) |
      del(.inbounds[$tag].users[$old])
    else . end
  ' "$TRAFFIC_FILE" >"$tmp" || rc=1
  if ((rc==0)); then traffic_write_file "$tmp" || rc=1; fi
  rm -f "$tmp"
  return "$rc"
}

# If an administrator edits a managed client's email directly, recover its
# stable accounting identity from the existing per-inbound record when the
# label identifies exactly one record. Never guess when the match is unclear.
traffic_user_recover_identities() {
  local input=$1 output=$2
  jq --slurpfile state "$TRAFFIC_FILE" '
    $state[0] as $s |
    .inbounds |= map(if .protocol=="vless" then
      .tag as $tag | .settings.clients |= map(. as $client |
        if .xrayctlLabel == null or $s.inbounds[$tag].users[($client.email // "")] != null then .
        else
          [($s.inbounds[$tag].users // {}) | to_entries[] | select(.value.label==$client.xrayctlLabel) | .key] as $matches |
          if ($matches|length)==1 then .email=$matches[0] else . end
        end)
    else . end)
  ' "$input" >"$output"
}

# Must be called with the management lock held. The traffic lock protects the
# quota snapshot until the configuration transaction has committed or rolled
# back. User rules are before all existing routes; inbound firewall rules remain
# independent and are never changed here.
traffic_user_reconcile_locked() {
  local candidate prepared recovered address inventory rc=0 TRAFFIC_USER_RECONCILE_COMMIT=1
  traffic_user_managed_config || return 0
  [[ -f $TRAFFIC_FILE ]] || return 0
  traffic_lock_acquire || return 1
  # Capture the latest counters before deriving the rules. A failed API read
  # leaves the existing user quota state untouched, so it cannot clear a ban.
  traffic_user_collect_locked || true
  candidate=$(temp_file) || { traffic_lock_release; return 1; }
  prepared=$(temp_file) || { rm -f "$candidate"; traffic_lock_release; return 1; }
  recovered=$(temp_file) || { rm -f "$candidate" "$prepared"; traffic_lock_release; return 1; }
  if ! jq -e '[.inbounds[]? | select(.tag=="xrayctl-user-deny")] | length==0' "$CONFIG_FILE" >/dev/null ||
     ! jq -e '[.outbounds[]? | select(.tag=="xrayctl-user-deny" and .protocol!="blackhole")] | length==0' "$CONFIG_FILE" >/dev/null; then
    warn "用户额度的保留出站标签已被占用。"
    rm -f "$candidate" "$prepared" "$recovered"; traffic_lock_release; return 1
  fi
  address=$(jq -r '.api.listen // ""' "$CONFIG_FILE")
  if ! traffic_user_recover_identities "$CONFIG_FILE" "$recovered" || ! traffic_user_prepare_config "$recovered" "$prepared" "$address"; then
    rm -f "$candidate" "$prepared" "$recovered"; traffic_lock_release; return 1
  fi
  inventory=$(traffic_user_inventory_json "$prepared") || { rm -f "$candidate" "$prepared" "$recovered"; traffic_lock_release; return 1; }
  jq --slurpfile state "$TRAFFIC_FILE" --argjson inventory "$inventory" '
    $state[0] as $s |
    [ $inventory[] | select(.ambiguous|not) | .tag as $tag | .id as $id |
      $s.inbounds[$tag].users[$id].limit as $limit |
      select($limit.enabled==true and ($limit.quotaBytes // 0)>0 and ($limit.usedBytes // 0)>=($limit.quotaBytes // 0)) |
      {type:"field",ruleTag:("xrayctl-user-limit:"+$id),inboundTag:[$tag],user:[$id],outboundTag:"xrayctl-user-deny"}
    ] as $rules |
    .routing=(.routing // {rules:[]}) |
    .routing.rules=($rules + [(.routing.rules // [])[] | select((.ruleTag // "" | startswith("xrayctl-user-limit:"))|not)]) |
    if ($rules|length)>0 and ([.outbounds[]? | select(.tag=="xrayctl-user-deny")] | length)==0 then
      .outbounds += [{protocol:"blackhole",tag:"xrayctl-user-deny"}]
    else . end
  ' "$prepared" >"$candidate" || rc=1
  if ((rc==0)) && ! jq -s -e '.[0]==.[1]' "$CONFIG_FILE" "$candidate" >/dev/null; then
    XRAYCTL_QUIET_CONFIG_APPLIED=1 state_commit "$candidate" || rc=1
  fi
  rm -f "$candidate" "$prepared" "$recovered"; traffic_lock_release
  return "$rc"
}

traffic_user_reconcile() {
  traffic_user_managed_config || return 0
  if [[ ${XRAYCTL_MANAGEMENT_LOCK_HELD:-0} == 1 ]]; then
    traffic_user_reconcile_locked
  else
    (
      mkdir -p "$(dirname "$LOCK_FILE")"
      if command_exists flock; then
        exec 8>"$LOCK_FILE"
        flock -n 8 || exit 1
      else
        local lock_dir="${LOCK_FILE}.d"
        mkdir "$lock_dir" 2>/dev/null || exit 1
        trap 'rmdir "$lock_dir" 2>/dev/null || true' EXIT
      fi
      traffic_user_reconcile_locked
    )
  fi
}

traffic_user_require_manager() {
  if [[ ${XRAYCTL_MANAGEMENT_LOCK_HELD:-0} != 1 ]]; then
    ensure_runtime_dependencies user-traffic
  else
    traffic_require_root user-traffic
  fi
}

traffic_user_choose_address() {
  local port hex attempt
  for ((attempt=0; attempt<100; attempt++)); do
    port=$((40000 + RANDOM % 20000))
    if jq -e --argjson port "$port" '[.inbounds[]? | select(.port==$port)] | length>0' "$CONFIG_FILE" >/dev/null 2>&1; then continue; fi
    printf -v hex '%04X' "$port"
    if ! awk -v port=":$hex" 'NR>1 && $4=="0A" && substr($2,length($2)-length(port)+1)==port {found=1} END {exit !found}' /proc/net/tcp /proc/net/tcp6 2>/dev/null; then
      printf '127.0.0.1:%s' "$port"
      return 0
    fi
  done
  return 1
}

traffic_user_enable() {
  traffic_user_require_manager
  ensure_config
  require_xray_installed
  traffic_runtime_ensure || return 1
  local address candidate needs_timer_update=0
  if [[ $(platform_init_system) == systemd ]] &&
     { [[ ! -f $TRAFFIC_SYSTEMD_SERVICE ]] || ! grep -Fq "$(dirname "$CONFIG_FILE")" "$TRAFFIC_SYSTEMD_SERVICE"; }; then
    needs_timer_update=1
  fi
  if jq -e '.api != null and (.api.listen|type)=="string"' "$CONFIG_FILE" >/dev/null; then
    address=$(jq -r '.api.listen // ""' "$CONFIG_FILE")
  else
    address=$(traffic_user_choose_address) || { warn "无法选择本机统计 API 端口。"; return 1; }
  fi
  candidate=$(temp_file) || return 1
  if ! traffic_user_prepare_config "$CONFIG_FILE" "$candidate" "$address"; then rm -f "$candidate"; return 1; fi
  if ! jq -s -e '.[0]==.[1]' "$CONFIG_FILE" "$candidate" >/dev/null; then
    if ! state_apply_candidate_file "$candidate" apply_candidate; then return 1; fi
  else
    rm -f "$candidate"
  fi
  if ((needs_timer_update)) && ! traffic_timer_install; then
    warn "用户统计已配置，但采集服务升级失败，无法自动应用用户额度；请修复后重试。"
    return 1
  fi
  traffic_user_collect_serialized || { warn "用户统计已配置，但当前无法读取 Xray API。"; return 1; }
}

traffic_user_ensure_configured() {
  traffic_user_has_clients || return 0
  traffic_user_managed_config && return 0
  traffic_user_enable
}

traffic_user_select() {
  local __tag=$1 __label=$2 picked_tag=${3-} picked_label=${4-} protocol inventory
  [[ -n $picked_tag ]] || select_inbound picked_tag '^(vless|socks|http)$' || return 1
  protocol=$(jq -r --arg tag "$picked_tag" '.inbounds[]? | select(.tag==$tag) | .protocol' "$CONFIG_FILE") || return 1
  case $protocol in
    vless) ;;
    socks)
      jq -e --arg tag "$picked_tag" '.inbounds[]? | select(.tag==$tag and .protocol=="socks" and .settings.auth=="password" and ((.settings.accounts // .settings.users // [])|length)>0)' "$CONFIG_FILE" >/dev/null || { warn "该 SOCKS5 入站没有已启用的用户名密码账号。"; return 1; }
      ;;
    http)
      jq -e --arg tag "$picked_tag" '.inbounds[]? | select(.tag==$tag and .protocol=="http" and ((.settings.accounts // .settings.users // [])|length)>0)' "$CONFIG_FILE" >/dev/null || { warn "该 HTTP 入站没有已配置的认证账号。"; return 1; }
      ;;
    *) warn "该协议不支持按账号统计。"; return 1 ;;
  esac
  [[ -n $picked_label ]] || select_client picked_label "$picked_tag" || return 1
  client_label_exists "$picked_tag" "$picked_label" || { warn "找不到用户：${picked_label}"; return 1; }
  inventory=$(traffic_user_inventory_json "$CONFIG_FILE") || return 1
  if jq -e --arg tag "$picked_tag" --arg label "$picked_label" 'any(.[]; .tag==$tag and .label==$label and .ambiguous)' <<<"$inventory" >/dev/null; then
    warn "账号名称在多个入站重复，Xray 汇总同名账号流量，无法安全设置独立额度；请先重命名其中一个账号。"
    return 1
  fi
  printf -v "$__tag" '%s' "$picked_tag"
  printf -v "$__label" '%s' "$picked_label"
}

traffic_user_id() {
  jq -r --arg tag "$1" --arg label "$2" '
    .inbounds[]? | select(.tag==$tag) |
    if .protocol=="vless" then
      .settings.clients[]? | select((.xrayctlLabel // .email)==$label) | .email
    elif .protocol=="socks" and .settings.auth=="password" then
      (.settings.accounts // .settings.users // [])[]? | select(.user==$label) | .user
    elif .protocol=="http" then
      (.settings.accounts // .settings.users // [])[]? | select(.user==$label) | .user
    else empty end
  ' "$CONFIG_FILE"
}

traffic_user_limit_set() {
  local tag=${1-} label=${2-} quota_gb=${3-} reset_day=${4-} reset_time=${5-}
  local id quota now existing old_day old_time anchor_time cycle_end tmp rc=0 interactive=0
  traffic_user_require_manager
  XRAYCTL_QUIET_CONFIG_APPLIED=1 traffic_user_enable || return 1
  traffic_user_select tag label "$tag" "$label" || return 0
  id=$(traffic_user_id "$tag" "$label")
  [[ -n $id ]] || return 1
  if [[ -z $quota_gb || -z $reset_day && -t 0 ]]; then interactive=1; fi
  while [[ -z $quota_gb ]]; do
    read -r -p "每月流量额度（GB）: " quota_gb || { cancel_input; return 0; }
    traffic_limit_quota_bytes "$quota_gb" >/dev/null || { warn "请输入大于 0 的数字。"; quota_gb=""; }
  done
  quota=$(traffic_limit_quota_bytes "$quota_gb") || { warn "流量额度无效。"; return 1; }
  traffic_user_collect_serialized || return 1
  now=$(traffic_now)
  existing=$(jq -r --arg tag "$tag" --arg id "$id" '.inbounds[$tag].users[$id].limit.enabled==true' "$TRAFFIC_FILE")
  old_day=$((10#${now:8:2})); old_time="${now:11:5}:00"
  if [[ $existing == true ]]; then
    old_day=$(jq -r --arg tag "$tag" --arg id "$id" '.inbounds[$tag].users[$id].limit.anchorDay' "$TRAFFIC_FILE")
    old_time=$(jq -r --arg tag "$tag" --arg id "$id" '.inbounds[$tag].users[$id].limit.anchorTime' "$TRAFFIC_FILE")
  fi
  if [[ -z $reset_day && $interactive == 1 ]]; then prompt_value reset_day '每月重置日期（1-31）' "$old_day" || return 0; fi
  reset_day=${reset_day:-$old_day}
  if [[ ! $reset_day =~ ^[0-9]+$ ]] || ((10#$reset_day < 1 || 10#$reset_day > 31)); then warn "重置日期无效。"; return 1; fi
  reset_day=$((10#$reset_day))
  if [[ -z $reset_time && $interactive == 1 ]]; then prompt_value reset_time '每月重置时间（HH:MM，服务器本地时间）' "${old_time:0:5}" || return 0; fi
  reset_time=${reset_time:-${old_time:0:5}}
  if [[ ! $reset_time =~ ^[0-9]{2}:[0-9]{2}$ ]] || ! traffic_validate_timestamp "2026-01-01 ${reset_time}:00"; then warn "重置时间无效。"; return 1; fi
  anchor_time=${reset_time}:00
  if [[ $existing == true && $reset_day == "$old_day" && $anchor_time == "$old_time" ]]; then
    cycle_end=$(jq -r --arg tag "$tag" --arg id "$id" '.inbounds[$tag].users[$id].limit.cycleEnd' "$TRAFFIC_FILE")
  else
    cycle_end=$(traffic_limit_first_cycle_end "$now" "$reset_day" "$anchor_time") || return 1
  fi
  traffic_lock_acquire || return 1
  tmp=$(temp_file)
  jq --arg tag "$tag" --arg id "$id" --arg label "$label" --argjson quota "$quota" --argjson day "$reset_day" --arg time "$anchor_time" --arg now "$now" --arg end "$cycle_end" '
    .inbounds[$tag].users[$id]=((.inbounds[$tag].users[$id] // {}) + {label:$label}) |
    .inbounds[$tag].users[$id].limit |= ((. // {enabled:true,cycleStart:$now,usedBytes:0}) + {enabled:true,quotaBytes:$quota,resetDay:$day,anchorDay:$day,anchorTime:$time,cycleEnd:$end})
  ' "$TRAFFIC_FILE" >"$tmp" || rc=1
  if ((rc==0)); then traffic_write_file "$tmp" || rc=1; fi
  rm -f "$tmp"; traffic_lock_release
  ((rc==0)) || return 1
  traffic_user_reconcile || { warn "用户额度已保存，但封禁规则暂未同步。"; return 1; }
  info "已设置 ${tag} / ${label} 的用户额度，已用流量保留。"
}

traffic_user_limit_remove() {
  local tag=${1-} label=${2-} assume_yes=${3:-0} id tmp rc=0
  traffic_user_require_manager; ensure_config
  traffic_user_managed_config || { warn "用户流量统计尚未配置。"; return 1; }
  traffic_user_select tag label "$tag" "$label" || return 0
  id=$(traffic_user_id "$tag" "$label")
  jq -e --arg tag "$tag" --arg id "$id" '.inbounds[$tag].users[$id].limit.enabled==true' "$TRAFFIC_FILE" >/dev/null || { warn "该用户没有流量额度。"; return 1; }
  [[ $assume_yes == 1 ]] || confirm "取消 ${tag} / ${label} 的用户额度？" N || return 0
  traffic_user_collect_serialized || true
  traffic_lock_acquire || return 1
  tmp=$(temp_file)
  jq --arg tag "$tag" --arg id "$id" 'del(.inbounds[$tag].users[$id].limit)' "$TRAFFIC_FILE" >"$tmp" || rc=1
  if ((rc==0)); then traffic_write_file "$tmp" || rc=1; fi
  rm -f "$tmp"; traffic_lock_release
  ((rc==0)) || return 1
  traffic_user_reconcile || { warn "额度已取消，但封禁规则暂未同步。"; return 1; }
  info "已取消 ${tag} / ${label} 的用户额度。"
}

traffic_user_reset() {
  local tag=${1-} label=${2-} assume_yes=${3:-0} id now end day time tmp rc=0
  traffic_user_require_manager; ensure_config
  traffic_user_managed_config || { warn "用户流量统计尚未配置。"; return 1; }
  traffic_user_select tag label "$tag" "$label" || return 0
  id=$(traffic_user_id "$tag" "$label")
  [[ $assume_yes == 1 ]] || confirm "清零 ${tag} / ${label} 的用户流量和当前额度周期？" N || return 0
  # Refuse to reset without a fresh baseline: otherwise later sampling would
  # re-add traffic that was already included in the reset.
  traffic_user_collect_serialized || return 1
  now=$(traffic_now); end=""
  if jq -e --arg tag "$tag" --arg id "$id" '.inbounds[$tag].users[$id].limit.enabled==true' "$TRAFFIC_FILE" >/dev/null; then
    day=$(jq -r --arg tag "$tag" --arg id "$id" '.inbounds[$tag].users[$id].limit.anchorDay' "$TRAFFIC_FILE")
    time=$(jq -r --arg tag "$tag" --arg id "$id" '.inbounds[$tag].users[$id].limit.anchorTime' "$TRAFFIC_FILE")
    end=$(traffic_limit_first_cycle_end "$now" "$day" "$time") || return 1
  fi
  traffic_lock_acquire || return 1
  tmp=$(temp_file)
  jq --arg tag "$tag" --arg id "$id" --arg now "$now" --arg end "$end" '
    .inbounds[$tag].users[$id].uplinkBytes=0 | .inbounds[$tag].users[$id].downlinkBytes=0 | .inbounds[$tag].users[$id].cycles={} |
    if .inbounds[$tag].users[$id].limit.enabled==true then
      .inbounds[$tag].users[$id].limit.usedBytes=0 | .inbounds[$tag].users[$id].limit.cycleStart=$now | .inbounds[$tag].users[$id].limit.cycleEnd=$end
    else . end
  ' "$TRAFFIC_FILE" >"$tmp" || rc=1
  if ((rc==0)); then traffic_write_file "$tmp" || rc=1; fi
  rm -f "$tmp"; traffic_lock_release
  ((rc==0)) || return 1
  traffic_user_reconcile || { warn "流量已清零，但封禁规则暂未同步。"; return 1; }
  info "已清零 ${tag} / ${label} 的用户流量。"
}

traffic_users_show() {
  local filter=${1-} tag protocol id label used quota start end enabled status ambiguous period_start current_bytes current_tag="" user_state inventory status_disp bar pct fill empty raw_used raw_quota
  heading '流量限制'
  if [[ ! -r $CONFIG_FILE || ! -r $TRAFFIC_FILE ]]; then
    info "用户流量统计尚未配置。"
    return 0
  fi
  IFS=$'\t' read -r period_start _ < <(traffic_period_bounds "$(traffic_now)")
  inventory=$(traffic_user_inventory_json "$CONFIG_FILE") || return 1
  traffic_user_managed_config && user_state='已配置' || user_state='未配置'
  while IFS=$'\t' read -r tag protocol id label current_bytes used quota start end enabled ambiguous; do
    [[ -n $tag ]] || continue
    if [[ $tag != "$current_tag" ]]; then
      printf '\n  %s▸ %s%s\n' "$C_BOLD$C_CYAN" "$tag" "$C_RESET"
      printf '  %s' "$C_DIM"
      print_table_cell '用户名称' 12; printf ' │ '
      print_table_cell_right '已用流量' 10; printf ' / '
      print_table_cell '月度额度' 10; printf ' │ '
      print_table_cell '状态' 8; printf ' │ 占用%s\n' "$C_RESET"
      ui_rule 2
      current_tag=$tag
    fi
    if [[ -z $id || $id == '-' ]]; then
      if [[ $protocol == socks || $protocol == http ]]; then printf '  %s○ 此入站没有可统计的认证账号%s\n' "$C_DIM" "$C_RESET"; else printf '  %s○ 此入站暂不支持按用户统计%s\n' "$C_DIM" "$C_RESET"; fi
      continue
    fi
    raw_used=0; raw_quota=0; bar=""
    if [[ $enabled == true && $quota =~ ^[0-9]+$ && $quota -gt 0 ]]; then
      raw_quota=$quota
      if [[ $ambiguous == true ]]; then
        status='冲突'; status_disp=$(ui_badge warn "冲突"); current_bytes='统计冲突'
      elif ((used >= quota)); then
        status='超额'; status_disp=$(ui_badge err "超额"); current_bytes=$used; raw_used=$used
      else
        status='正常'; status_disp=$(ui_badge ok "正常"); current_bytes=$used; raw_used=$used
      fi
      quota=$(traffic_format_bytes "$quota")
      if [[ $ambiguous != true ]]; then
        pct=$((raw_used * 100 / raw_quota))
        ((pct > 100)) && pct=100
        fill=$((pct / 10)); empty=$((10 - fill))
        bar="$(ui_repeat '█' "$fill")$(ui_repeat '░' "$empty") ${pct}%"
      fi
    else
      quota='∞'
      if [[ $ambiguous == true ]]; then status='冲突'; status_disp=$(ui_badge warn "冲突"); current_bytes='统计冲突'
      else status='正常'; status_disp=$(ui_badge ok "正常"); fi
      bar="${C_DIM}不限额度${C_RESET}"
    fi
    if [[ $ambiguous == true ]]; then used='统计冲突'
    elif [[ $user_state == '已配置' ]]; then used=$(traffic_format_bytes "$current_bytes")
    else used='未统计'; fi
    printf '  '; print_table_cell_clipped "$label" 12; printf ' %s│%s ' "$C_DIM" "$C_RESET"
    print_table_cell_right "$used" 10; printf ' / '
    print_table_cell "$quota" 10; printf ' %s│%s ' "$C_DIM" "$C_RESET"
    print_table_cell "$status_disp" 8; printf ' %s│%s %s\n' "$C_DIM" "$C_RESET" "$bar"
  done < <(jq -r --slurpfile state "$TRAFFIC_FILE" --argjson inventory "$inventory" --arg periodStart "$period_start" --arg filter "$filter" '
    $state[0] as $s | .inbounds[]? | select($filter=="" or .tag==$filter) | .tag as $tag | .protocol as $protocol |
    if $protocol=="vless" then
      if ((.settings.clients // [])|length)==0 then [$tag,$protocol,"-","-",0,0,0,"-","-",false,false] | @tsv
      else .settings.clients[] | .email as $id | ($s.inbounds[$tag].users[$id] // {}) as $u |
        [$tag,$protocol,$id,(.xrayctlLabel // .email // ""),($u.cycles[$periodStart] // 0),
          ($u.limit.usedBytes // 0),($u.limit.quotaBytes // 0),($u.limit.cycleStart // "-"),($u.limit.cycleEnd // "-"),($u.limit.enabled // false),
          ([$inventory[] | select(.tag==$tag and .id==$id) | .ambiguous] | any)] | @tsv
      end
    elif $protocol=="socks" and .settings.auth=="password" then
      if ((.settings.accounts // .settings.users // [])|length)==0 then [$tag,$protocol,"-","-",0,0,0,"-","-",false,false] | @tsv
      else [(.settings.accounts // .settings.users // [])[]? | select((.user|type)=="string" and (.pass|type)=="string" and (.pass|length)>0)] | unique_by(.user)[] | .user as $id | ($s.inbounds[$tag].users[$id] // {}) as $u |
        [$tag,$protocol,$id,$id,($u.cycles[$periodStart] // 0),($u.limit.usedBytes // 0),($u.limit.quotaBytes // 0),($u.limit.cycleStart // "-"),($u.limit.cycleEnd // "-"),($u.limit.enabled // false),
          ([$inventory[] | select(.tag==$tag and .id==$id) | .ambiguous] | any)] | @tsv end
    elif $protocol=="http" then
      if ((.settings.accounts // .settings.users // [])|length)==0 then [$tag,$protocol,"-","-",0,0,0,"-","-",false,false] | @tsv
      else [(.settings.accounts // .settings.users // [])[]? | select((.user|type)=="string" and (.pass|type)=="string" and (.pass|length)>0)] | unique_by(.user)[] | .user as $id | ($s.inbounds[$tag].users[$id] // {}) as $u |
        [$tag,$protocol,$id,$id,($u.cycles[$periodStart] // 0),($u.limit.usedBytes // 0),($u.limit.quotaBytes // 0),($u.limit.cycleStart // "-"),($u.limit.cycleEnd // "-"),($u.limit.enabled // false),
          ([$inventory[] | select(.tag==$tag and .id==$id) | .ambiguous] | any)] | @tsv end
    else [$tag,$protocol,"-","-",0,0,0,"-","-",false,false] | @tsv end
  ' "$CONFIG_FILE")
  [[ -n $current_tag ]] || info "没有可显示的入站。"
}

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
  printf '%s\n' '{"schema":1,"accountingMultiplier":2,"enabled":true,"backend":"","lastCollectedAt":"","period":{"day":1,"time":"00:00:00"},"periodsSeeded":false,"inbounds":{}}'
}

# Install a complete JSON file by rename in the same directory so readers
# outside the lock never observe a truncated or partially written document.
traffic_write_file() {
  local source=$1 staging
  mkdir -p "$(dirname "$TRAFFIC_FILE")" || return 1
  staging=$(mktemp "${TRAFFIC_FILE}.tmp.XXXXXX") || return 1
  if ! install -m 600 "$source" "$staging" || ! mv -f "$staging" "$TRAFFIC_FILE"; then
    rm -f "$staging"
    return 1
  fi
}

traffic_init_file() {
  local own_lock=0 rc=0
  if [[ ${TRAFFIC_LOCK_HELD:-0} != 1 ]]; then
    traffic_lock_acquire || return 1
    own_lock=1
  fi
  traffic_init_file_locked || rc=1
  ((own_lock == 0)) || traffic_lock_release
  return "$rc"
}

traffic_init_file_locked() {
  local dir tmp
  dir=$(dirname "$TRAFFIC_FILE")
  mkdir -p "$dir"
  chmod 700 "$dir" 2>/dev/null || true
  if [[ ! -s $TRAFFIC_FILE ]] || ! jq -e 'type=="object" and ((.inbounds // {})|type)=="object"' "$TRAFFIC_FILE" >/dev/null 2>&1; then
    [[ ! -f $TRAFFIC_FILE ]] || cp -a "$TRAFFIC_FILE" "${TRAFFIC_FILE}.broken-$(timestamp)"
    tmp=$(temp_file) || return 1
    traffic_default_json >"$tmp" || { rm -f "$tmp"; return 1; }
    traffic_write_file "$tmp" || { rm -f "$tmp"; return 1; }
    rm -f "$tmp"
  elif ! jq -e '.schema==1 and (.enabled|type)=="boolean" and (.backend|type)=="string" and (.lastCollectedAt|type)=="string" and (.period.day|type)=="number" and (.period.time|type)=="string" and (.periodsSeeded|type)=="boolean"' "$TRAFFIC_FILE" >/dev/null 2>&1; then
    tmp=$(temp_file)
    jq '.schema=1 | .enabled=true | .backend=(.backend // "") | .lastCollectedAt=(.lastCollectedAt // "") | .period=(.period // {day:1,time:"00:00:00"}) | .periodsSeeded=(.periodsSeeded==true) | .inbounds=(if (.inbounds|type)=="object" then .inbounds else {} end) | del(.limitsEnabled) | .inbounds |= with_entries(del(.value.limit))' \
      "$TRAFFIC_FILE" >"$tmp" || { rm -f "$tmp"; return 1; }
    traffic_write_file "$tmp" || { rm -f "$tmp"; return 1; }
    rm -f "$tmp"
  elif jq -e '.enabled!=true or has("limitsEnabled") or any(.inbounds[]?; type=="object" and has("limit"))' "$TRAFFIC_FILE" >/dev/null 2>&1; then
    tmp=$(temp_file)
    jq '.enabled=true | del(.limitsEnabled) | .inbounds |= with_entries(del(.value.limit))' "$TRAFFIC_FILE" >"$tmp" || { rm -f "$tmp"; return 1; }
    traffic_write_file "$tmp" || { rm -f "$tmp"; return 1; }
    rm -f "$tmp"
  fi
}

traffic_is_enabled() {
  [[ -f $TRAFFIC_FILE ]] && jq -e '.enabled==true' "$TRAFFIC_FILE" >/dev/null 2>&1
}

traffic_set_enabled() {
  local enabled=$1 tmp rc=0
  [[ $enabled == true ]] || { warn "流量统计默认开启，不支持关闭。"; return 1; }
  traffic_init_file || return 1
  traffic_is_enabled && return 0
  traffic_lock_acquire || return 1
  tmp=$(temp_file)
  jq --argjson enabled "$enabled" '.enabled=$enabled' "$TRAFFIC_FILE" >"$tmp" || rc=1
  if ((rc == 0)); then traffic_write_file "$tmp" || rc=1; fi
  rm -f "$tmp"; traffic_lock_release
  return "$rc"
}

traffic_recorded_backend() {
  [[ -f $TRAFFIC_FILE ]] || return 0
  jq -r '.backend // empty' "$TRAFFIC_FILE" 2>/dev/null
}

traffic_set_backend() {
  local backend=$1 tmp own_lock=0 rc=0
  traffic_init_file
  if [[ ${TRAFFIC_LOCK_HELD:-0} != 1 ]]; then traffic_lock_acquire || return 1; own_lock=1; fi
  tmp=$(temp_file); jq --arg backend "$backend" '.backend=$backend' "$TRAFFIC_FILE" >"$tmp" || rc=1
  if ((rc==0)); then traffic_write_file "$tmp" || rc=1; fi
  rm -f "$tmp"
  ((own_lock == 0)) || traffic_lock_release
  return "$rc"
}

traffic_inventory_json() {
  if [[ -f $CONFIG_FILE ]]; then
    jq '[.inbounds[]? | {key:.tag,value:{protocol:.protocol,port:.port,disabled:false}}] | from_entries' "$CONFIG_FILE" 2>/dev/null || printf '{}\n'
  else
    printf '{}\n'
  fi
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
  done < <(jq -r '([.inbounds[]?.daily | keys[]?] + [(.totals.daily // {}) | keys[]]) | unique[]' "$TRAFFIC_FILE")
  tmp=$(temp_file)
  jq --argjson mapping "$mapping" '
    .inbounds |= with_entries(
      .value.cycles=(reduce ((.value.daily // {}) | to_entries[]) as $day ({};
        ($mapping[$day.key] // null) as $start |
        if $start == null or $start == "" then . else .[$start]=((.[$start] // 0) + $day.value) end
      ))
    ) |
    if .totals != null then
      .totals.cycles=(reduce ((.totals.daily // {}) | to_entries[]) as $day ({};
        ($mapping[$day.key] // null) as $start |
        if $start == null or $start == "" then . else .[$start]=((.[$start] // 0) + $day.value) end
      ))
    else . end | .periodsSeeded=true
  ' "$TRAFFIC_FILE" >"$tmp" || { rm -f "$tmp"; return 1; }
  traffic_write_file "$tmp" || { rm -f "$tmp"; return 1; }
  rm -f "$tmp"
}

traffic_update_file() {
  local samples=${1:-'{}'} mark_collected=${2:-1} today cutoff now period_start inventory tmp
  traffic_init_file
  traffic_seed_periods || return 1
  today=$(traffic_today); cutoff=$(traffic_retention_start); now=$(traffic_now)
  period_start=$(traffic_period_start "$now") || return 1
  inventory=$(traffic_inventory_json)
  tmp=$(temp_file)
  jq --arg today "$today" --arg cutoff "$cutoff" --arg periodStart "$period_start" --arg now "$now" --argjson markCollected "$mark_collected" \
     --arg counterEpoch "${TRAFFIC_COUNTER_EPOCH:-}" --argjson rawSnapshot "${TRAFFIC_RAW_SNAPSHOT:-null}" --argjson samples "$samples" --argjson inventory "$inventory" '
    .inbounds=(.inbounds // {}) |
    reduce ($inventory|to_entries[]) as $item (.;
      .inbounds[$item.key]=((.inbounds[$item.key] // {daily:{}}) + $item.value + {deleted:false})
    ) |
    .inbounds |= with_entries(.value.deleted = ($inventory[.key] == null) | .value.disabled = ($inventory[.key].disabled // false)) |
    # Legacy totals counted only the client-facing connection. Migrate once so
    # stored inbound history matches the two-leg accounting convention.
    if .accountingMultiplier == 2 then . else
      .inbounds |= with_entries(
        .value.daily=((.value.daily // {}) | with_entries(.value *= 2)) |
        .value.cycles=((.value.cycles // {}) | with_entries(.value *= 2))
      ) |
      .accountingMultiplier=2
    end |
    .inbounds |= with_entries(
      .value.daily=((.value.daily // {}) | with_entries(select(.key >= $cutoff and .key <= $today))) |
      .value.cycles=((.value.cycles // {}) | with_entries(select(.key == $periodStart))) |
      if .value.cycles[$periodStart] == null then .value.daily |= del(.[$today]) else . end
    ) |
    # Seed the independent aggregate once from retained legacy records, after
    # their accounting conversion. Clearing one inbound must never reseed it.
    .totals=(.totals // {
      daily:(reduce (.inbounds[]?.daily | to_entries[]?) as $entry ({};
        .[$entry.key]=((.[$entry.key] // 0) + $entry.value))),
      cycles:(reduce (.inbounds[]?.cycles | to_entries[]?) as $entry ({};
        .[$entry.key]=((.[$entry.key] // 0) + $entry.value)))
    }) |
    .totals.daily |= with_entries(select(.key >= $cutoff and .key <= $today)) |
    .totals.cycles |= with_entries(select(.key == $periodStart)) |
    if .totals.cycles[$periodStart] == null then .totals.daily |= del(.[$today]) else . end |
    reduce ($samples|to_entries[]) as $item (.;
      .totals.daily[$today]=((.totals.daily[$today] // 0) + ($item.value * 2)) |
      .totals.cycles[$periodStart]=((.totals.cycles[$periodStart] // 0) + ($item.value * 2)) |
      .inbounds[$item.key]=(.inbounds[$item.key] // {protocol:"unknown",port:0,deleted:($inventory[$item.key] == null),daily:{}}) |
      .inbounds[$item.key].daily[$today]=((.inbounds[$item.key].daily[$today] // 0) + ($item.value * 2)) |
      .inbounds[$item.key].cycles[$periodStart]=((.inbounds[$item.key].cycles[$periodStart] // 0) + ($item.value * 2))
    ) |
    .inbounds |= with_entries(select((.value.deleted != true) or ((.value.daily|length) > 0) or ((.value.cycles|length) > 0) or ((.value.users // {})|length)>0)) |
    if $markCollected then .lastCollectedAt=$now else . end |
    if $rawSnapshot != null then .kernelCounters=$rawSnapshot | .kernelCounterEpoch=$counterEpoch else . end
  ' "$TRAFFIC_FILE" >"$tmp" || { rm -f "$tmp"; return 1; }
  traffic_write_file "$tmp" || { rm -f "$tmp"; return 1; }
  rm -f "$tmp"
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
  [[ ${TRAFFIC_LOCK_HELD:-0} != 1 ]] || return 1
  if command_exists flock; then
    mkdir -p "$(dirname "$TRAFFIC_LOCK")" || return 1
    exec {TRAFFIC_LOCK_FD}>"${TRAFFIC_LOCK}.flock" || return 1
    while ! flock -n "$TRAFFIC_LOCK_FD"; do
      attempt=$((attempt + 1))
      if ((attempt >= 100)); then
        exec {TRAFFIC_LOCK_FD}>&-
        return 1
      fi
      sleep 0.05
    done
    TRAFFIC_LOCK_HELD=1
    return 0
  fi
  mkdir -p "$(dirname "$TRAFFIC_LOCK")" || return 1
  # Publish a fully initialized owner atomically; a killed initializer cannot
  # leave the shared lock without a PID.
  TRAFFIC_LOCK_OWNER=$(mktemp -d "${TRAFFIC_LOCK}.owner.XXXXXX") || return 1
  printf '%s\n' "${BASHPID:-$$}" >"$TRAFFIC_LOCK_OWNER/pid"
  while ! ln -sT "$TRAFFIC_LOCK_OWNER" "$TRAFFIC_LOCK" 2>/dev/null; do
    owner=$(cat "$TRAFFIC_LOCK/pid" 2>/dev/null || true)
    if [[ $owner =~ ^[0-9]+$ ]] && ! kill -0 "$owner" 2>/dev/null; then
      if [[ -L $TRAFFIC_LOCK ]]; then
        rm -f "$TRAFFIC_LOCK"
      else
        rm -f "$TRAFFIC_LOCK/pid"; rmdir "$TRAFFIC_LOCK" 2>/dev/null || true
      fi
      continue
    fi
    attempt=$((attempt + 1))
    if ((attempt >= 100)); then
      # Recover an empty legacy mkdir lock only after the initialization grace.
      if [[ -z $owner && ! -L $TRAFFIC_LOCK ]] && rmdir "$TRAFFIC_LOCK" 2>/dev/null; then continue; fi
      rm -f "$TRAFFIC_LOCK_OWNER/pid"; rmdir "$TRAFFIC_LOCK_OWNER"
      unset TRAFFIC_LOCK_OWNER
      return 1
    fi
    sleep 0.05
  done
  TRAFFIC_LOCK_HELD=1

}

traffic_lock_release() {
  if [[ -n ${TRAFFIC_LOCK_FD:-} ]]; then
    flock -u "$TRAFFIC_LOCK_FD" || true
    exec {TRAFFIC_LOCK_FD}>&-
    unset TRAFFIC_LOCK_FD
    TRAFFIC_LOCK_HELD=0
    return 0
  fi
  local owner
  owner=$(cat "$TRAFFIC_LOCK/pid" 2>/dev/null || true)
  if [[ $owner == "${BASHPID:-$$}" && -n ${TRAFFIC_LOCK_OWNER:-} ]]; then
    rm -f "$TRAFFIC_LOCK"
    rm -f "$TRAFFIC_LOCK_OWNER/pid"; rmdir "$TRAFFIC_LOCK_OWNER"
    unset TRAFFIC_LOCK_OWNER
  fi
  TRAFFIC_LOCK_HELD=0
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
  [[ $(traffic_backend) != none ]] || { warn "nftables 安装失败，流量统计无法运行。"; return 1; }
}

traffic_read_nft_counters() {
  command_exists nft || return 1
  local payload
  payload=$(nft -j list table inet "$TRAFFIC_NFT_TABLE" 2>/dev/null) || return 1
  jq -er --argjson detailed "${TRAFFIC_DETAILED_COUNTERS:-0}" '
    if (.nftables|type)!="array" then error("invalid nft response") else . end |
    [.nftables[]?.rule |
      (.comment // "") as $comment |
      select(($comment | startswith("xrayctl-traffic:count:")) or ($comment | test("^xrayctl-traffic:[^:]+$"))) |
      {tag:((if $detailed==1 then ((.chain // "") + ":") else "" end) + (if ($comment | startswith("xrayctl-traffic:count:"))
            then ($comment | sub("^xrayctl-traffic:count:";""))
            else ($comment | sub("^xrayctl-traffic:";"")) end)),
       bytes:([.expr[]?.counter.bytes] | add // 0)} |
       if (.bytes|type)!="number" or .bytes<0 or (.bytes|floor)!=.bytes then error("invalid counter") else . end] |
    group_by(.tag)[] | [.[0].tag,(map(.bytes)|add)] | @tsv
  ' <<<"$payload"
}

traffic_read_iptables_counters() {
  local command chain output found=0
  for command in iptables ip6tables; do
    command_exists "$command" || continue
    for chain in "$TRAFFIC_IPTABLES_IN_CHAIN" "$TRAFFIC_IPTABLES_OUT_CHAIN"; do
      output=$("$command" -t filter -L "$chain" -nvx 2>/dev/null) || return 1
      found=1
      local prefix=""
      [[ ${TRAFFIC_DETAILED_COUNTERS:-0} != 1 ]] || prefix="${command}:${chain}:"
      awk -v prefix="$prefix" '
        $1 ~ /^[0-9]+$/ && $2 ~ /^[0-9]+$/ {
          for (i=1;i<=NF;i++) {
            if ($i ~ /^xrayctl-traffic:count:[A-Za-z0-9_.-]+/) {
              tag=$i; sub(/^xrayctl-traffic:count:/,"",tag); gsub(/[^A-Za-z0-9_.-].*$/,"",tag);
              print prefix tag "\t" $2
            } else if ($i ~ /^xrayctl-traffic:[A-Za-z0-9_.-]+$/) {
              tag=$i; sub(/^xrayctl-traffic:/,"",tag); print prefix tag "\t" $2
            }
          }
        }
      ' <<<"$output"
    done
  done
  ((found))
}

traffic_read_backend_counters() {
  case "$(traffic_recorded_backend)" in
    nft) traffic_read_nft_counters;;
    iptables) traffic_read_iptables_counters;;
    *) return 1;;
  esac
}

traffic_read_counters() {
  local rows
  rows=$(traffic_read_backend_counters | awk -F '\t' '
    NF==2 && $2 ~ /^[0-9]+$/ {sum[$1]+=$2}
    END {for (tag in sum) printf "%s\t%.0f\n",tag,sum[tag]}
  ') || return 1
  if [[ ${TRAFFIC_DETAILED_COUNTERS:-0} == 1 && -r $CONFIG_FILE ]]; then
    jq -e --slurpfile state "$TRAFFIC_FILE" --arg rows "$rows" '
      ($rows|split("\n")|map(split("\t")[0]|split(":")|last)) as $tags |
      (($state[0].rulesInventory // null) as $rules |
        if $rules!=null then all($rules|keys[]; . as $tag | any($tags[]; .==$tag))
        else all(.inbounds[]?; .tag as $tag | any($tags[]; .==$tag)) end)
    ' "$CONFIG_FILE" >/dev/null || return 1
  fi
  printf '%s\n' "$rows"
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
  case "$(traffic_recorded_backend)" in
    nft) traffic_clear_nft_rules;;
    iptables) traffic_clear_iptables_rules;;
  esac
}

traffic_protocols_for_inbound() {
  case $1 in socks) printf '%s\n' tcp udp;; *) printf '%s\n' tcp;; esac
}

traffic_restore_nft_rules() {
  local tag inbound_protocol port transport_protocol count_comment count=0
  command_exists nft || return 1
  traffic_clear_nft_rules || return 1
  nft add table inet "$TRAFFIC_NFT_TABLE" || return 1
  nft 'add chain inet xrayctl_traffic input { type filter hook input priority -5; policy accept; }' || return 1
  nft 'add chain inet xrayctl_traffic output { type filter hook output priority -5; policy accept; }' || return 1
  while IFS=$'\t' read -r tag inbound_protocol port; do
    if [[ -z $tag ]] || ! validate_port "$port"; then continue; fi
    count_comment="\"xrayctl-traffic:count:${tag}\""
    while IFS= read -r transport_protocol; do
      nft add rule inet "$TRAFFIC_NFT_TABLE" input "$transport_protocol" dport "$port" counter comment "$count_comment" || return 1
      nft add rule inet "$TRAFFIC_NFT_TABLE" output "$transport_protocol" sport "$port" counter comment "$count_comment" || return 1
      count=$((count + 1))
    done < <(traffic_protocols_for_inbound "$inbound_protocol")
  done < <(jq -r '.inbounds[]? | [.tag,.protocol,(.port|tostring)] | @tsv' "$CONFIG_FILE" 2>/dev/null || true)
  ((count > 0)) || traffic_clear_nft_rules
}

traffic_restore_iptables_rules() {
  local command tag inbound_protocol port transport_protocol count=0
  traffic_clear_iptables_rules || return 1
  for command in iptables ip6tables; do
    command_exists "$command" || continue
    "$command" -t filter -N "$TRAFFIC_IPTABLES_IN_CHAIN" >/dev/null 2>&1 || true
    "$command" -t filter -N "$TRAFFIC_IPTABLES_OUT_CHAIN" >/dev/null 2>&1 || true
    "$command" -t filter -C INPUT -j "$TRAFFIC_IPTABLES_IN_CHAIN" >/dev/null 2>&1 || "$command" -t filter -I INPUT 1 -j "$TRAFFIC_IPTABLES_IN_CHAIN"
    "$command" -t filter -C OUTPUT -j "$TRAFFIC_IPTABLES_OUT_CHAIN" >/dev/null 2>&1 || "$command" -t filter -I OUTPUT 1 -j "$TRAFFIC_IPTABLES_OUT_CHAIN"
    while IFS=$'\t' read -r tag inbound_protocol port; do
      if [[ -z $tag ]] || ! validate_port "$port"; then continue; fi
      while IFS= read -r transport_protocol; do
        "$command" -t filter -A "$TRAFFIC_IPTABLES_IN_CHAIN" -p "$transport_protocol" --dport "$port" -m comment --comment "xrayctl-traffic:count:${tag}" -j RETURN || return 1
        "$command" -t filter -A "$TRAFFIC_IPTABLES_OUT_CHAIN" -p "$transport_protocol" --sport "$port" -m comment --comment "xrayctl-traffic:count:${tag}" -j RETURN || return 1
        count=$((count + 1))
      done < <(traffic_protocols_for_inbound "$inbound_protocol")
    done < <(jq -r '.inbounds[]? | [.tag,.protocol,(.port|tostring)] | @tsv' "$CONFIG_FILE" 2>/dev/null || true)
  done
  ((count > 0)) || traffic_clear_iptables_rules
}

traffic_rules_restore() {
  local selected inventory epoch
  epoch=$(cat /proc/sys/kernel/random/boot_id 2>/dev/null || printf unknown)
  selected=$(traffic_backend)
  inventory=$(traffic_inventory_json) || return 1
  if jq -e --arg epoch "$epoch" --argjson inventory "$inventory" ' .rulesInventory==$inventory and .rulesInventory!=null and .rulesEpoch==$epoch' "$TRAFFIC_FILE" >/dev/null 2>&1; then
    traffic_read_counters >/dev/null
    return $?
  fi
  [[ $selected != none ]] || return 1
  if traffic_backend_conflicts "$selected"; then
    warn "目标防火墙后端存在同名资源，拒绝覆盖；请先检查资源归属。"
    return 1
  fi
  traffic_rules_clear || return 1
  [[ $(traffic_recorded_backend) == "$selected" ]] || traffic_set_backend "$selected"
  [[ -f $CONFIG_FILE ]] || return 0
  case $selected in
    nft) traffic_restore_nft_rules ;;
    iptables) traffic_restore_iptables_rules ;;
    *) return 1 ;;
  esac || return 1
  local tmp
  tmp=$(temp_file) || return 1
  jq --arg epoch "$epoch" --argjson inventory "$inventory" '.rulesInventory=$inventory | .rulesEpoch=$epoch | .kernelCounters={}' "$TRAFFIC_FILE" >"$tmp" && traffic_write_file "$tmp"
  local rc=$?
  rm -f "$tmp"
  return "$rc"
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
  local counters samples rc=0 snapshot="" raw_samples epoch
  epoch=$(cat /proc/sys/kernel/random/boot_id 2>/dev/null || printf unknown)
  snapshot=$(temp_file) || { traffic_lock_release; return 1; }
  cp -p "$TRAFFIC_FILE" "$snapshot" || { rm -f "$snapshot"; traffic_lock_release; return 1; }
  local previous_epoch
  previous_epoch=$(jq -r '.kernelCounterEpoch // empty' "$TRAFFIC_FILE") || rc=1
  if ((rc == 0)) && [[ -n $previous_epoch && $previous_epoch != "$epoch" ]]; then
    warn "系统已重启，正在重新建立内核统计规则；重启前未采集的计数无法恢复。"
    traffic_rules_restore || rc=1
  fi
  if ((rc == 0)); then counters=$(TRAFFIC_DETAILED_COUNTERS=1 traffic_read_counters) || rc=1; fi
  if ((rc == 0)); then
    raw_samples=$(traffic_samples_json <<<"$counters") || rc=1
    if ((rc == 0)); then
      samples=$(jq -nc --arg epoch "$epoch" --argjson raw "$raw_samples" --slurpfile state "$TRAFFIC_FILE" '$raw | with_entries(. as $entry | .value=($entry.value - (if (($state[0].kernelCounterEpoch // $epoch)==$epoch and ($state[0].kernelCounters[$entry.key] // 0) <= $entry.value) then ($state[0].kernelCounters[$entry.key] // 0) else 0 end))) | reduce to_entries[] as $entry ({}; ($entry.key|split(":")|last) as $tag | .[$tag]=((.[$tag] // 0)+$entry.value))') || rc=1
    fi
  fi
  if ((rc == 0)); then TRAFFIC_RAW_SNAPSHOT="$raw_samples" TRAFFIC_COUNTER_EPOCH="$epoch" traffic_update_file "$samples" || rc=1; fi
  # Totals and the cumulative counter baseline are committed atomically.
  # A failed write leaves both unchanged, allowing an idempotent retry.
  if ((rc != 0)); then
    traffic_write_file "$snapshot" || true
  elif ! traffic_user_collect_locked; then
    # User API failures must never prevent the independent inbound accounting
    # and firewall quota rules from being committed.
    warn "用户流量本次未采集；入站流量采集仍已完成。"
    rc=2
  fi
  rm -f "$snapshot"
  local inventory
  inventory=$(traffic_inventory_json) || rc=1
  if ((rc == 0)) && jq -e --argjson inventory "$inventory" '.rulesInventory!=null and .rulesInventory!=$inventory' "$TRAFFIC_FILE" >/dev/null; then
    traffic_rules_restore || rc=1
  fi
  traffic_lock_release
  if ((rc == 0)); then
    traffic_user_reconcile || { warn "用户额度规则暂未同步，将在下次采集时重试。"; rc=2; }
  fi
  ((rc == 0)) || { warn "流量采集未完成，现有累计记录已尽量保留。"; return "$rc"; }
}

traffic_rename_records() {
  local rc=0
  [[ -f $TRAFFIC_FILE ]] || return 0
  traffic_init_file || return 1
  traffic_lock_acquire || return 1
  traffic_rename_records_locked "$1" "$2" || rc=1
  traffic_lock_release
  return "$rc"
}

traffic_rename_records_locked() {
  local old=$1 new=$2 tmp rc=0
  [[ -f $TRAFFIC_FILE ]] || return 0
  tmp=$(temp_file)
  jq --arg old "$old" --arg new "$new" '
    if .inbounds[$old] then
      (.inbounds[$new] // {daily:{}}) as $target |
      (.inbounds[$old]) as $source |
      .inbounds[$new]=($source + {daily:($target.daily // {}),cycles:($target.cycles // {}),users:(($target.users // {}) + ($source.users // {})),deleted:false}) |
      reduce (($source.daily // {})|to_entries[]) as $day (.;
        .inbounds[$new].daily[$day.key]=((.inbounds[$new].daily[$day.key] // 0) + $day.value)
      ) |
      reduce (($source.cycles // {})|to_entries[]) as $cycle (.;
        .inbounds[$new].cycles[$cycle.key]=((.inbounds[$new].cycles[$cycle.key] // 0) + $cycle.value)
      ) |
      del(.inbounds[$old])
    else . end
  ' "$TRAFFIC_FILE" >"$tmp" || rc=1
  if ((rc == 0)); then traffic_write_file "$tmp" || rc=1; fi
  rm -f "$tmp"
  return "$rc"
}

traffic_after_config_change() {
  local old=${1-} new=${2-}
  traffic_systemd_refresh_write_paths || return 1
  [[ -f $TRAFFIC_FILE ]] || return 0
  # Move the stable user identities before sampling the renamed config. If we
  # sampled first, the new tag would get a second baseline for the same user.
  if [[ -n $old && -n $new ]]; then
    traffic_rename_records "$old" "$new" || return 1
  fi
  if traffic_is_enabled && [[ -n $(traffic_recorded_backend) ]]; then traffic_collect || return 1; else traffic_sync_inventory || return 1; fi
  if [[ -n $old && -z $new ]]; then traffic_user_forget_inbound "$old"; fi
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
  jq --arg start "$start" --arg finish "$finish" '[(.totals.daily // {}) | to_entries[] | select(.key >= $start and .key <= $finish) | .value] | add // 0' "$TRAFFIC_FILE"
}

traffic_user_limit_count() {
  [[ -f $TRAFFIC_FILE ]] || { printf '0'; return; }
  jq '[.inbounds[]?.users[]? | select(.limit.enabled==true)] | length' "$TRAFFIC_FILE" 2>/dev/null || printf '0'
}

traffic_limit_quota_bytes() {
  local value=$1 bytes
  [[ $value =~ ^[0-9]+([.][0-9]+)?$ ]] || return 1
  bytes=$(awk -v value="$value" 'BEGIN {printf "%.0f", value * 1073741824}')
  [[ $bytes =~ ^[0-9]+$ ]] && ((bytes > 0)) || return 1
  printf '%s' "$bytes"
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
  if [[ -z $day ]]; then read -r -p '每月起始日期（1-31）: ' day || { cancel_input; return 0; }; fi
  if [[ -z $clock ]]; then read -r -p '起始时间（HH:MM）: ' clock || { cancel_input; return 0; }; fi
  if [[ ! $day =~ ^[0-9]+$ ]] || ((10#$day < 1 || 10#$day > 31)); then
    warn '日期必须是 1 到 31。'
    return 1
  fi
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
  # Preserve the independent aggregate before rebucketing a legacy file.
  traffic_update_file '{}' false || { traffic_lock_release; return 1; }
  tmp=$(temp_file)
  jq --argjson day "$day" --arg clock "$clock" '.period={day:$day,time:$clock} | .periodsSeeded=false' "$TRAFFIC_FILE" >"$tmp" || rc=1
  if ((rc == 0)); then traffic_write_file "$tmp" || rc=1; fi
  rm -f "$tmp"
  if ((rc == 0)); then traffic_update_file '{}' false || rc=1; fi
  traffic_lock_release
  ((rc == 0)) || return 1
  info '月度统计起点已更新；已有每日记录按日期近似归入新周期。'
  traffic_period_show
}

traffic_show() {
  local start=${1-} end=${2-} period=false rows tag protocol port bytes deleted total status last display_order
  if [[ -n $start && -z $end ]]; then end=$(traffic_today); fi
  if [[ -z $start && -z $end ]]; then
    traffic_init_file
    IFS=$'\t' read -r start end < <(traffic_period_bounds "$(traffic_now)")
    period=true
  else
    traffic_validate_range "$start" "$end" || { warn "日期范围无效或超出当前周期。"; return 1; }
  fi
  traffic_init_file; traffic_sync_inventory
  traffic_is_enabled && status=$(ui_badge ok "运行中") || status=$(ui_badge muted "已停止")
  last=$(jq -r '.lastCollectedAt // empty' "$TRAFFIC_FILE")
  heading "流量信息"
  printf '  统计状态：%s  |  统计范围：%s ～ %s\n  最后采集：%s\n\n' "$status" "$start" "$end" "${last:-尚未采集}"
  printf '%s' "$C_DIM"
  print_table_cell_clipped "标签" 20; printf ' │ '
  print_table_cell_clipped "协议" 10; printf ' │ '
  print_table_cell "端口" 7; printf ' │ %14s%s\n' "总流量" "$C_RESET"
  ui_rule 0
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
      print_table_cell_clipped "$tag" 20; printf ' %s│%s ' "$C_DIM" "$C_RESET"
      print_table_cell_clipped "$protocol" 10; printf ' %s│%s ' "$C_DIM" "$C_RESET"
      print_table_cell "$port" 7; printf ' %s│%s %s%14s%s\n' "$C_DIM" "$C_RESET" "$C_BOLD" "$(traffic_format_bytes "$bytes")" "$C_RESET"
    done <<<"$rows"
  fi
  if [[ $period == true ]]; then
    total=$(jq --arg start "$start" '.totals.cycles[$start] // 0' "$TRAFFIC_FILE")
  else
    total=$(traffic_range_total "$start" "$end")
  fi
  ui_rule 0
  printf '全部入站：%s%s%s\n' "$C_BOLD$C_CYAN" "$(traffic_format_bytes "$total")" "$C_RESET"
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
  local tag=${1-} assume_yes=${2:-0} tmp rc=0
  if [[ $tag == --yes ]]; then tag=""; assume_yes=1; fi
  [[ -n $tag ]] || traffic_select_record_tag tag || return 0
  traffic_collect || true; traffic_init_file
  jq -e --arg tag "$tag" '.inbounds[$tag] != null' "$TRAFFIC_FILE" >/dev/null || { warn "没有入站 ${tag} 的流量记录。"; return 1; }
  [[ $assume_yes == 1 ]] || confirm "清空入站 ${tag} 当前周期的流量记录；已删除的入站将移除整条记录（保留全部入站总流量）？" N || return 0
  traffic_lock_acquire || return 1
  # Statistics may be stopped: seed legacy totals before deleting any record.
  traffic_update_file '{}' false || { traffic_lock_release; return 1; }
  tmp=$(temp_file); jq --arg tag "$tag" '
    if .inbounds[$tag] == null then .
    elif .inbounds[$tag].deleted==true then del(.inbounds[$tag])
    else
      .inbounds[$tag].daily={} | .inbounds[$tag].cycles={} |
      .
    end
  ' "$TRAFFIC_FILE" >"$tmp" || rc=1
  if ((rc == 0)); then traffic_write_file "$tmp" || rc=1; fi
  rm -f "$tmp"; traffic_lock_release
  ((rc == 0)) || return 1
  if traffic_is_enabled; then traffic_rules_restore_serialized || true; fi
  info "已清空入站 ${tag} 的流量记录。"
}

traffic_clear_all_records() {
  local assume_yes=${1:-0} answer tmp rc=0
  traffic_collect || true; traffic_init_file
  if [[ $assume_yes != 1 ]]; then
    printf '输入 RESET 确认清空全部入站流量记录（不清空用户流量）：'
    read -r answer || { cancel_input; return 0; }
    [[ $answer == RESET ]] || { info "已取消。"; return 0; }
  fi
  traffic_lock_acquire || return 1
  tmp=$(temp_file); jq '
    .totals={daily:{},cycles:{}} |
    .inbounds |= with_entries(.value.daily={} | .value.cycles={})
  ' "$TRAFFIC_FILE" >"$tmp" || rc=1
  if ((rc == 0)); then traffic_write_file "$tmp" || rc=1; fi
  rm -f "$tmp"; traffic_lock_release
  ((rc == 0)) || return 1
  if traffic_is_enabled; then traffic_rules_restore_serialized || true; fi
  info "已清空全部入站流量记录。"
}

# Xray opens file logs during run -test. Include configured log parents as well
# as managed state paths, without granting write access to the entire root.
traffic_systemd_write_paths() {
  local log_paths="" path
  local -a paths=("$(dirname "$TRAFFIC_FILE")" "$(dirname "$TRAFFIC_LOCK")"
    "$(dirname "$LOCK_FILE")" "$(dirname "$CONFIG_FILE")" "$(dirname "$META_FILE")" "$LOG_DIR" /run/xtables.lock)
  if [[ -r $CONFIG_FILE ]]; then
    log_paths=$(jq -r '
      [.log.access?, .log.error?] | map(select(.!=null and .!="" and .!="none")) |
      if any(.[]; type!="string" or test("[\\x00-\\x1f\\x7f]")) then error("invalid log path") else .[] end
    ' "$CONFIG_FILE") || return 1
    while IFS= read -r path; do
      [[ -n $path ]] || continue
      [[ $path == /dev/* ]] && continue
      [[ $path == /* ]] || { error "采集服务要求日志使用绝对路径：$path"; return 1; }
      paths+=("$(dirname "$path")")
    done <<<"$log_paths"
  fi
  local index
  for index in "${!paths[@]}"; do
    path=${paths[$index]}
    [[ ! -d $path ]] || path=$(cd "$path" && pwd -P) || return 1
    paths[index]=$path
    [[ $path == /* && ! $path =~ ^/+$ && $path != */../* && $path != */.. && $path != */./* && $path != */. && $path != *$'\n'* && $path != *$'\r'* ]] || {
      error "采集服务写入目录无效或范围过大：$path"; return 1;
    }
  done
  # Quote spaces/backslashes and escape systemd specifiers in path values.
  while IFS= read -r path; do
    # A custom file-log configuration may not use the managed default at all.
    if [[ $path == /run/xtables.lock || ( $path == "$LOG_DIR" && ! -e $path ) ]]; then path="-$path"; fi
    path=${path//\\/\\\\}
    path=${path//\"/\\\"}
    path=${path//%/%%}
    printf '"%s" ' "$path"
  done < <(printf '%s\n' "${paths[@]}" | sort -u)
}

# Configuration edits can move file logs after the collector was installed.
# Only refresh units recorded as owned by this manager, and only when changed.
traffic_systemd_refresh_write_paths() {
  [[ -f $TRAFFIC_SYSTEMD_SERVICE && -r $META_FILE ]] || return 0
  jq -e --arg unit "$TRAFFIC_SYSTEMD_SERVICE" '.managedResources.trafficService==$unit' "$META_FILE" >/dev/null 2>&1 || return 0
  [[ $(platform_init_system) == systemd ]] || return 0
  local expected
  expected=$(traffic_systemd_write_paths) || return 1
  grep -Fxq "ReadWritePaths=$expected" "$TRAFFIC_SYSTEMD_SERVICE" && return 0
  traffic_timer_install
}

traffic_timer_install() {
  [[ -x $QUICK_COMMAND ]] || install_quick_command
  case $(platform_init_system) in
    systemd)
      local write_paths
      write_paths=$(traffic_systemd_write_paths) || return 1
      cat >"$TRAFFIC_SYSTEMD_SERVICE" <<EOF_SERVICE
[Unit]
Description=Collect xrayctl per-inbound traffic counters
After=network-online.target

[Service]
Type=oneshot
# Prepare this single runtime file before constructing the read-only namespace.
# The collector itself retains the strict filesystem sandbox.
ExecStartPre=+/usr/bin/touch /run/xtables.lock
ExecStart=${QUICK_COMMAND} internal-traffic-collect
UMask=0077
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true
ReadWritePaths=$write_paths
EOF_SERVICE
      cat >"$TRAFFIC_SYSTEMD_TIMER" <<EOF_TIMER
[Unit]
Description=Collect xrayctl traffic every minute

[Timer]
OnBootSec=2min
OnActiveSec=1min
OnUnitInactiveSec=1min
AccuracySec=1s
RandomizedDelaySec=5s

[Install]
WantedBy=timers.target
EOF_TIMER
      systemctl daemon-reload || return 1
      systemctl enable xrayctl-traffic-collect.timer >/dev/null 2>&1 || return 1
      systemctl restart xrayctl-traffic-collect.timer >/dev/null 2>&1 || return 1
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
      platform_openrc_service xrayctl-traffic-collect restart >/dev/null 2>&1 || return 1
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
      platform_openrc_service xrayctl-traffic-collect stop >/dev/null 2>&1 || true
      rc-update del xrayctl-traffic-collect default >/dev/null 2>&1 || true
      rm -f "$TRAFFIC_OPENRC_SERVICE"
      ;;
  esac
}

traffic_runtime_ensure() {
  traffic_require_root internal-traffic-ensure
  local was_enabled=0
  traffic_is_enabled && was_enabled=1
  traffic_init_file || return 1
  traffic_set_enabled true || return 1
  if ((was_enabled)) && [[ -n $(traffic_recorded_backend) ]]; then
    local collection_rc=0
    traffic_collect || collection_rc=$?
    ((collection_rc == 0 || collection_rc == 2)) || return 1
  fi
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
  traffic_runtime_ensure || return 1
  meta_resource_register trafficFile "$TRAFFIC_FILE"
  info "流量统计已自动开启；每分钟采集一次。"
}

traffic_disable() {
  info "流量统计默认开启，不支持关闭。"
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
