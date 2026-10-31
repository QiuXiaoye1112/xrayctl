# shellcheck shell=bash
# Keep the target port bound across requests. A one-shot listener leaves gaps
# where an Xray outbound connection can claim that port as its source port.
test_http_server_start() {
  local ready_file=$1
  python3 - "$ready_file" <<'PY' &
import os
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200)
        self.send_header("Content-Length", "5")
        self.send_header("Connection", "close")
        self.end_headers()
        self.wfile.write(b"hello")

    def log_message(self, *args):
        pass


with ThreadingHTTPServer(("127.0.0.1", 0), Handler) as server:
    with open(sys.argv[1] + ".tmp", "w") as ready:
        ready.write(str(server.server_port))
    os.replace(sys.argv[1] + ".tmp", sys.argv[1])
    server.serve_forever()
PY
  TEST_HTTP_SERVER_PID=$!
  for _ in {1..100}; do
    if [[ -s $ready_file ]]; then
      TEST_HTTP_SERVER_PORT=$(<"$ready_file")
      return 0
    fi
    kill -0 "$TEST_HTTP_SERVER_PID" 2>/dev/null || { wait "$TEST_HTTP_SERVER_PID"; return 1; }
    sleep .05
  done
  kill "$TEST_HTTP_SERVER_PID" 2>/dev/null || true
  wait "$TEST_HTTP_SERVER_PID" 2>/dev/null || true
  printf 'not ok - HTTP test server did not become ready\n' >&2
  return 1
}
