#!/usr/bin/env bash
set -Eeuo pipefail
if [[ ${XRAYCTL_TEST_SYSTEMD_LIFECYCLE:-0} != 1 ]]; then
  printf 'ok - full systemd lifecycle skipped (requires an explicitly selected empty systemd host)\n'
  exit 0
fi
[[ $(id -u) == 0 && $(cat /proc/1/comm) == systemd ]] || {
  printf 'full lifecycle requires root and real systemd PID 1\n' >&2; exit 1;
}
# This entry exercises fixed production paths, including the real upstream
# installer/remover. Refuse an existing installation or managed data.
for path in /usr/local/bin/xray /usr/local/bin/xray-linux-* \
  /usr/local/etc/xray /usr/local/share/xray /var/log/xray /var/lib/xrayctl \
  /var/backups/xrayctl /opt/xrayctl /etc/xrayctl \
  /usr/local/sbin/xrayctl /usr/local/bin/xrayctl \
  /etc/systemd/system/xray.service /etc/systemd/system/xray@.service \
  /etc/systemd/system/xray.service.d /etc/systemd/system/xray@.service.d \
  /etc/systemd/system/xrayctl-* /etc/sysctl.d/99-xrayctl-bbr.conf \
  /etc/sysctl.d/99-sbctl-bbr.conf; do
  [[ ! -e $path && ! -L $path ]] || {
    printf 'refusing full lifecycle: existing resource %s\n' "$path" >&2; exit 1;
  }
done
if systemctl is-active --quiet xray.service; then
  printf 'refusing full lifecycle: Xray is running\n' >&2; exit 1
fi
REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
source "$REPO_ROOT/xrayctl.sh"
[[ $CONFIG_DIR == /usr/local/etc/xray && $LOG_DIR == /var/log/xray &&
   $XRAY_BIN == /usr/local/bin/xray && $SERVICE_NAME == xray &&
   $TRAFFIC_FILE == /var/lib/xrayctl/traffic.json &&
   $QUICK_COMMAND == /usr/local/sbin/xrayctl && $QUICK_SYMLINK == /usr/local/bin/xrayctl ]] || {
  error 'Full lifecycle requires the default layout, with no test path overrides.'; exit 1;
}
TEST_ROOT=$(mktemp -d /tmp/xrayctl-systemd-lifecycle.XXXXXX)
http_pid=""
cleanup_test() {
  if [[ -n $http_pid ]]; then kill "$http_pid" 2>/dev/null || true; wait "$http_pid" 2>/dev/null || true; fi
  rm -rf "$TEST_ROOT"
}
trap cleanup_test EXIT
# Install this workspace's manager, without fetching a different revision.
install -D -m 755 "$REPO_ROOT/dist/xrayctl" "$QUICK_COMMAND"
install_or_update_xray "${XRAYCTL_TEST_INITIAL_VERSION:-26.6.22}"
service_is_active
platform_service_is_enabled
[[ $(systemctl show xray -p User --value) == xray ]]
[[ $(stat -c %U "$LOG_DIR") == root ]]
printf 'ok - real systemd official install, non-root service, access and enable\n'
service_action stop
if service_is_active; then error 'Stopped test service is still active.'; exit 1; fi
service_action start
service_is_active
service_action restart
service_is_active
printf 'ok - real systemd stop/start/restart\n'
IFS=' ' read -r inbound_port target_port < <(python3 - <<'PY'
import socket
sockets=[socket.socket() for _ in range(2)]
for sock in sockets: sock.bind(('127.0.0.1',0))
print(*(sock.getsockname()[1] for sock in sockets))
PY
)
printf 'systemd-lifecycle-real-traffic\n' >"$TEST_ROOT/payload.txt"
python3 -m http.server "$target_port" --bind 127.0.0.1 --directory "$TEST_ROOT" >"$TEST_ROOT/http.log" 2>&1 9>&- 8>&- &
http_pid=$!
for _ in {1..50}; do
  if curl --silent --fail "http://127.0.0.1:$target_port/payload.txt" >/dev/null; then break; fi
  sleep .1
done
jq --argjson port "$inbound_port" '
  .inbounds=[{tag:"lifecycle",listen:"127.0.0.1",port:$port,protocol:"socks",
    settings:{auth:"password",accounts:[{user:"lifecycle",pass:"local-only"}],udp:false}}] |
  .outbounds[0].settings.finalRules=[{action:"allow",network:"tcp",ip:["127.0.0.1/32"]}] |
  .routing.rules=([{type:"field",inboundTag:["lifecycle"],ip:["127.0.0.1/32"],outboundTag:"direct"}] + .routing.rules)
' "$CONFIG_FILE" >"$TEST_ROOT/inbound.json"
apply_candidate "$TEST_ROOT/inbound.json"
proxy_request() {
  curl --silent --show-error --fail --max-time 10 --noproxy '' \
    --socks5-hostname "127.0.0.1:$inbound_port" --proxy-user lifecycle:local-only \
    "http://127.0.0.1:$target_port/payload.txt" >"$TEST_ROOT/response.txt"
  cmp "$TEST_ROOT/payload.txt" "$TEST_ROOT/response.txt"
}
proxy_request
before=$(sha256sum "$CONFIG_FILE" | cut -d' ' -f1)
version_before=$("$XRAY_BIN" version | sed -n '1p')
exec 9>&-
XRAYCTL_MANAGEMENT_LOCK_HELD=0
install_or_update_xray "$XRAY_CORE_PINNED_VERSION"
[[ $before == "$(sha256sum "$CONFIG_FILE" | cut -d' ' -f1)" ]]
[[ $version_before != "$("$XRAY_BIN" version | sed -n '1p')" ]]
service_is_active
proxy_request
printf 'ok - genuine core version upgrade preserves credentials/configuration and authenticated traffic\n'
exec 9>&-
XRAYCTL_MANAGEMENT_LOCK_HELD=0
uninstall_xray <<<DELETE
[[ ! -e $XRAY_BIN && ! -e $CONFIG_FILE && ! -e /etc/systemd/system/xray.service && ! -e $QUICK_COMMAND ]]
if pgrep -x xray; then error 'Xray test process survived complete uninstall.'; exit 1; fi
printf 'ok - complete real systemd official uninstall with zero reported residuals\n'
