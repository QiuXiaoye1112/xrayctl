#!/usr/bin/env bash
set -Eeuo pipefail
cd "$(dirname "$0")/../.."
root=$(mktemp -d)
trap 'rm -rf "$root"' EXIT
export XRAYCTL_TESTING=1 XRAYCTL_CONFIG_DIR="$root/config" XRAYCTL_TRAFFIC_FILE="$root/traffic.json"
export XRAYCTL_CERT_DIR="$root/certs" XRAYCTL_LOG_DIR="$root/log" XRAYCTL_BACKUP_DIR="$root/backups"
export XRAYCTL_LOCK_FILE="$root/lock" XRAYCTL_META_FILE="$root/meta.json"
export XRAYCTL_TRAFFIC_NOW='2026-11-10 12:00:00' XRAYCTL_XRAY_BIN=/nonexistent
source ./xrayctl.sh
trap 'rm -rf "$root"' EXIT
# BusyBox flock only supports the nonblocking/unlock flags used here.
flock() {
  [[ ${1-} == -n || ${1-} == -u ]] || { printf 'unsupported flock flag\n' >&2; return 1; }
  command flock "$@"
}
write_default_config
traffic_init_file
traffic_read_counters() { printf 'a\t%s\n' "$counter"; }
traffic_rules_restore() { printf 'collection must not rebuild rules\n' >&2; return 1; }
counter=100
traffic_collect
counter=150
traffic_collect
traffic_collect
jq -e '.totals.daily["2026-11-10"]==300 and .kernelCounters.a==150' "$TRAFFIC_FILE" >/dev/null
before=$(jq -S . "$TRAFFIC_FILE")
traffic_read_counters() { return 1; }
if traffic_collect; then exit 1; fi
[[ $(jq -S . "$TRAFFIC_FILE") == "$before" ]]
traffic_read_counters() { printf 'a\t%s\n' "$counter"; }
counter=170
traffic_collect
jq -e '.totals.daily["2026-11-10"]==340' "$TRAFFIC_FILE" >/dev/null
# Detect a kernel counter reset rather than subtracting a negative delta.
counter=10
traffic_collect
jq -e '.totals.daily["2026-11-10"]==360' "$TRAFFIC_FILE" >/dev/null
# A failed user sample is externally visible, without rolling back inbound data.
traffic_user_collect_locked() { return 1; }
counter=20
if traffic_collect; then exit 1; fi
jq -e '.totals.daily["2026-11-10"]==380 and .kernelCounters.a==20' "$TRAFFIC_FILE" >/dev/null
traffic_user_collect_locked() { :; }
traffic_collect
jq -e '.totals.daily["2026-11-10"]==380' "$TRAFFIC_FILE" >/dev/null
# A failed atomic write must leave both the baseline and total unchanged.
original_write=$(declare -f traffic_write_file)
traffic_write_file() { return 1; }
counter=30
if traffic_collect; then exit 1; fi
jq -e '.totals.daily["2026-11-10"]==380 and .kernelCounters.a==20' "$TRAFFIC_FILE" >/dev/null
eval "$original_write"
traffic_collect
jq -e '.totals.daily["2026-11-10"]==400 and .kernelCounters.a==30' "$TRAFFIC_FILE" >/dev/null
# Exercise portable lock publication and stale-owner recovery without flock.
original_exists=$(declare -f command_exists)
command_exists() { [[ $1 != flock ]] && command -v "$1" >/dev/null 2>&1; }
traffic_lock_acquire
[[ -L $TRAFFIC_LOCK && -s $TRAFFIC_LOCK/pid ]]
traffic_lock_release
[[ ! -L $TRAFFIC_LOCK ]]
eval "$original_exists"
# IPv4/IPv6 and chain baselines are independent: a reset in one must not
# consume the growth recorded by the other.
traffic_read_counters() { printf 'iptables:in:a\t%s\nip6tables:in:a\t%s\n' "$v4" "$v6"; }
v4=100; v6=100
traffic_collect
v4=150; v6=20
traffic_collect
jq -e '.totals.daily["2026-11-10"]==940' "$TRAFFIC_FILE" >/dev/null
# Actual backend readers must propagate errors, including partial IPv6 reads.
eval "$(sed -n '/^traffic_read_counters() {/,/^}/p' src/traffic.sh)"
traffic_recorded_backend() { printf iptables; }
command_exists() { return 0; }
iptables() { printf 'Chain test (1 references)\n pkts bytes target prot opt in out source destination\n 1 30 RETURN tcp -- * * 0/0 0/0 /* xrayctl-traffic:count:a */\n'; }
ip6tables() { return 1; }
if traffic_read_counters; then exit 1; fi
ip6tables() { iptables "$@"; }
iptables() { printf '1 9999999999 RETURN tcp -- * * 0/0 0/0 /* xrayctl-traffic:count:a */\n'; }
[[ $(traffic_read_counters) == $'a\t39999999996' ]]
traffic_recorded_backend() { printf nft; }
nft() { return 1; }
if traffic_read_counters; then exit 1; fi
printf 'ok - cumulative traffic, retries, reset detection, partial user failure, backend failure\n'
