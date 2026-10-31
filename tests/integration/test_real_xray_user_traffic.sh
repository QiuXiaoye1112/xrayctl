#!/usr/bin/env bash
set -Eeuo pipefail
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
bin=${XRAYCTL_REAL_XRAY_BIN:-}
if [[ -z $bin ]]; then
  printf 'ok - real Xray user traffic test skipped (set XRAYCTL_REAL_XRAY_BIN)\n'
  exit 0
fi
for cmd in jq curl python3; do command -v "$cmd" >/dev/null || { printf 'not ok - missing %s\n' "$cmd" >&2; exit 1; }; done
source "$root/tests/helpers/http.sh"
tmp=$(mktemp -d "${TMPDIR:-/tmp}/xrayctl-user-test.XXXXXX")
server_pid='' client_pid='' listener_pid=''
cleanup() {
  for pid in "$server_pid" "$client_pid" "$listener_pid"; do [[ -z $pid ]] || kill "$pid" 2>/dev/null || true; done
  wait 2>/dev/null || true
  rm -rf "$tmp"
}
trap cleanup EXIT
# Reserve no public listener: each Xray and target listener is explicitly bound
# to loopback. Random ports reduce collisions with existing local services.
base=$((30000 + RANDOM % 20000))
api=$base; inbound=$((base+1)); alice=$((base+2)); bob=$((base+3))
jq --argjson api "$api" --argjson port "$inbound" '.api.listen="127.0.0.1:\($api)" | .inbounds[0].port=$port' "$root/tests/fixtures/user-traffic/server.json" > "$tmp/server.json"
jq --argjson port "$inbound" --argjson alice "$alice" --argjson bob "$bob" '.inbounds[0].port=$alice | .inbounds[1].port=$bob | .outbounds[].settings.vnext[0].port=$port' "$root/tests/fixtures/user-traffic/client.json" > "$tmp/client.json"
"$bin" run -test -config "$tmp/server.json" >/dev/null
"$bin" run -test -config "$tmp/client.json" >/dev/null
"$bin" run -config "$tmp/server.json" > "$tmp/server.log" 2>&1 & server_pid=$!
"$bin" run -config "$tmp/client.json" > "$tmp/client.log" 2>&1 & client_pid=$!
for _ in {1..30}; do
  if "$bin" api statsquery -s "127.0.0.1:$api" -t 1 -pattern 'user>>>' > /dev/null 2>&1; then break; fi
  if ! kill -0 "$server_pid" || ! kill -0 "$client_pid"; then cat "$tmp/server.log" "$tmp/client.log" >&2; exit 1; fi
  sleep .1
done
test_http_server_start "$tmp/http-port"
listener_pid=$TEST_HTTP_SERVER_PID
target=$TEST_HTTP_SERVER_PORT
fetch() { curl -fsS --noproxy '' --max-time 3 --socks5-hostname "127.0.0.1:$1" "http://127.0.0.1:$target/"; }
if fetch "$alice" >/dev/null 2>&1; then printf 'not ok - blocked user connected\n' >&2; exit 1; fi
[[ $(fetch "$bob") == hello ]]

"$bin" api rmrules -s "127.0.0.1:$api" ban-alice >/dev/null
[[ $(fetch "$alice") == hello ]]

"$bin" api statsquery -s "127.0.0.1:$api" -pattern 'user>>>' > "$tmp/stats.json"
jq -e '[.stat[] | select(.name=="user>>>alice>>>traffic>>>uplink" or .name=="user>>>alice>>>traffic>>>downlink" or .name=="user>>>bob>>>traffic>>>uplink" or .name=="user>>>bob>>>traffic>>>downlink") | select((.value|tonumber)>0)] | length == 4' "$tmp/stats.json" >/dev/null
kill "$server_pid"
wait "$server_pid" || true
server_pid=''
"$bin" run -config "$tmp/server.json" > "$tmp/server.log" 2>&1 & server_pid=$!
for _ in {1..30}; do
  if "$bin" api statsquery -s "127.0.0.1:$api" -t 1 -pattern 'user>>>' > "$tmp/reset.json" 2>/dev/null; then break; fi
  kill -0 "$server_pid" || { cat "$tmp/server.log" >&2; exit 1; }
  sleep .1
done
jq -e '(.stat // [] | length) == 0' "$tmp/reset.json" >/dev/null
if fetch "$alice" >/dev/null 2>&1; then printf 'not ok - persistent rule did not survive restart\n' >&2; exit 1; fi
[[ $(fetch "$bob") == hello ]]

printf 'ok - real Xray user counters, routing block/recovery, and restart\n'
