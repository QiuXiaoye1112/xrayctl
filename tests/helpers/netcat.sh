# shellcheck shell=bash
# Start a loopback listener with either netcat-traditional or OpenBSD netcat.
# Debian 12 may ship the former, whose listen syntax requires -p/-s.
test_nc_listen_loopback() {
  local port=$1
  if nc -h 2>&1 | grep -Eqi 'v1\.10'; then
    exec nc -l -p "$port" -s 127.0.0.1
  else
    exec nc -l 127.0.0.1 "$port"
  fi
}
