# shellcheck shell=bash
# Start a loopback listener with either netcat-traditional or OpenBSD netcat.
# Debian 12 may ship the former, whose listen syntax requires -p/-s.
test_port_in_use_any_state() {
  local port=$1 hex
  local -a files=()
  [[ -r /proc/net/tcp ]] && files+=(/proc/net/tcp)
  [[ -r /proc/net/tcp6 ]] && files+=(/proc/net/tcp6)
  ((${#files[@]} > 0)) || return 1
  printf -v hex '%04X' "$port"
  awk -v port=":$hex" 'FNR>1 && substr($2,length($2)-length(port)+1)==port {found=1; exit} END {exit !found}' "${files[@]}"
}

test_port_has_active_socket() {
  local port=$1 hex
  local -a files=()
  [[ -r /proc/net/tcp ]] && files+=(/proc/net/tcp)
  [[ -r /proc/net/tcp6 ]] && files+=(/proc/net/tcp6)
  ((${#files[@]} > 0)) || return 1
  printf -v hex '%04X' "$port"
  awk -v port=":$hex" 'FNR>1 && $4!="06" && substr($2,length($2)-length(port)+1)==port {found=1; exit} END {exit !found}' "${files[@]}"
}

test_port_is_listening() {
  local port=$1 hex
  local -a files=()
  [[ -r /proc/net/tcp ]] && files+=(/proc/net/tcp)
  [[ -r /proc/net/tcp6 ]] && files+=(/proc/net/tcp6)
  ((${#files[@]} > 0)) || return 1
  printf -v hex '%04X' "$port"
  awk -v port=":$hex" 'FNR>1 && $4=="0A" && substr($2,length($2)-length(port)+1)==port {found=1; exit} END {exit !found}' "${files[@]}"
}

test_choose_port_base() {
  local span=${1:-10} attempt base offset busy
  for ((attempt=0; attempt<200; attempt++)); do
    base=$((15000 + RANDOM % 14000))
    busy=0
    for ((offset=0; offset<span; offset++)); do
      if test_port_in_use_any_state $((base + offset)); then
        busy=1
        break
      fi
    done
    if ((busy == 0)); then
      printf '%s\n' "$base"
      return 0
    fi
  done
  return 1
}

test_nc_listen_loopback() {
  local port=$1 attempt
  for ((attempt=0; attempt<50; attempt++)); do
    if ! test_port_has_active_socket "$port"; then
      break
    fi
    sleep 0.05
  done
  if nc -h 2>&1 | grep -Eqi 'v1\.10'; then
    exec nc -l -p "$port" -s 127.0.0.1
  else
    exec nc -l 127.0.0.1 "$port"
  fi
}

test_wait_nc_listen_loopback() {
  local port=$1 pid=${2:-} attempt
  if [[ -r /proc/net/tcp || -r /proc/net/tcp6 ]]; then
    for ((attempt=0; attempt<50; attempt++)); do
      if test_port_is_listening "$port"; then
        return 0
      fi
      if [[ -n $pid ]] && ! kill -0 "$pid" 2>/dev/null; then
        return 1
      fi
      sleep 0.05
    done
    return 1
  fi
  sleep .2
}
