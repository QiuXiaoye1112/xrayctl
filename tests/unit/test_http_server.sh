#!/usr/bin/env bash
set -Eeuo pipefail
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
tmp=$(mktemp -d "${TMPDIR:-/tmp}/xrayctl-http-test.XXXXXX")
listener_pid=''
cleanup() {
  if [[ -n $listener_pid ]]; then
    kill "$listener_pid" 2>/dev/null || true
    wait "$listener_pid" 2>/dev/null || true
  fi
  rm -rf "$tmp"
}
trap cleanup EXIT
source "$root/tests/helpers/http.sh"
test_http_server_start "$tmp/port"
listener_pid=$TEST_HTTP_SERVER_PID
python3 - "$TEST_HTTP_SERVER_PORT" <<'PY'
import errno
import http.client
import socket
import sys

port = int(sys.argv[1])
for _ in range(20):
    connection = http.client.HTTPConnection("127.0.0.1", port, timeout=3)
    connection.request("GET", "/")
    response = connection.getresponse()
    assert response.status == 200 and response.read() == b"hello"
    connection.close()
    # A one-shot nc listener releases its port after responding. In that gap,
    # an outbound socket can take the same local port and break the next bind.
    with socket.socket() as contender:
        contender.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        try:
            contender.bind(("127.0.0.1", port))
        except OSError as error:
            assert error.errno == errno.EADDRINUSE, error
        else:
            raise AssertionError("HTTP target released its port between requests")
PY
kill -0 "$listener_pid"
printf 'ok - HTTP test target serves repeated requests and reserves its port between them\n'
