#!/usr/bin/env bash

set -Eeuo pipefail
XRAY_BIN=${XRAYCTL_REAL_XRAY_BIN:-}
if [[ -z $XRAY_BIN ]]; then
  printf 'ok - real user outbound routing skipped (set XRAYCTL_REAL_XRAY_BIN)\n'
  exit 0
fi
for command_name in jq curl python3; do
  command -v "$command_name" >/dev/null 2>&1 || { printf 'not ok - missing %s\n' "$command_name" >&2; exit 1; }
done
[[ -x $XRAY_BIN ]] || { printf 'not ok - Xray binary is not executable: %s\n' "$XRAY_BIN" >&2; exit 1; }

TEST_ROOT=$(mktemp -d /tmp/xrayctl-user-outbound-real.XXXXXX)
XRAY_PID=
SERVER_PID=
CLIENT_PID=
cleanup() {
  [[ -z $XRAY_PID ]] || { kill "$XRAY_PID" 2>/dev/null || true; wait "$XRAY_PID" 2>/dev/null || true; }
  [[ -z $SERVER_PID ]] || { kill "$SERVER_PID" 2>/dev/null || true; wait "$SERVER_PID" 2>/dev/null || true; }
  [[ -z $CLIENT_PID ]] || { kill "$CLIENT_PID" 2>/dev/null || true; wait "$CLIENT_PID" 2>/dev/null || true; }
  [[ ${XRAYCTL_TEST_KEEP:-0} == 1 ]] || rm -rf "$TEST_ROOT"
}
trap cleanup EXIT

readarray -t PORTS < <(python3 - <<'PY'
import socket
ports=[]
held=[]
for _ in range(8):
    s=socket.socket(); s.bind(("127.0.0.1",0)); ports.append(s.getsockname()[1]); held.append(s)
print("\n".join(map(str,ports)))
for s in held: s.close()
PY
)
SOCKS_PORT=${PORTS[0]}
HTTP_IN_PORT=${PORTS[1]}
TARGET_PORT=${PORTS[2]}
PROXY_US_PORT=${PORTS[3]}
PROXY_JP_PORT=${PORTS[4]}
UDP_PORT=${PORTS[5]}
VLESS_PORT=${PORTS[6]}
VLESS_CLIENT_PORT=${PORTS[7]}
SEEN_FILE="$TEST_ROOT/udp-seen"

python3 - "$TARGET_PORT" "$PROXY_US_PORT" "$PROXY_JP_PORT" "$UDP_PORT" "$SEEN_FILE" <<'PY' >"$TEST_ROOT/servers.log" 2>&1 &
import socketserver, threading, sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
target, us, jp, udp = map(int,sys.argv[1:5]); seen=sys.argv[5]
class Target(BaseHTTPRequestHandler):
    def do_GET(self):
        print("target", self.client_address, self.path, flush=True)
        b=b"direct"; self.send_response(200); self.send_header("Content-Length",str(len(b))); self.end_headers(); self.wfile.write(b)
    def log_message(self,*args): pass
class Proxy(socketserver.BaseRequestHandler):
    def handle(self):
        c=self.request; c.settimeout(4); buf=b""
        try:
            while b"\r\n\r\n" not in buf: buf+=c.recv(4096)
            if buf.startswith(b"CONNECT "):
                c.sendall(b"HTTP/1.1 200 Connection Established\r\n\r\n"); buf=b""
                while b"\r\n\r\n" not in buf: buf+=c.recv(4096)
            b=self.server.marker
            c.sendall(b"HTTP/1.1 200 OK\r\nContent-Length: "+str(len(b)).encode()+b"\r\nConnection: close\r\n\r\n"+b)
        except Exception: pass
class TCP(socketserver.ThreadingTCPServer):
    allow_reuse_address=True; daemon_threads=True
class Echo(socketserver.BaseRequestHandler):
    def handle(self):
        data,sock=self.request
        with open(seen,"ab") as f: f.write(data+b"\n")
        sock.sendto(data,self.client_address)
class UDP(socketserver.ThreadingUDPServer):
    allow_reuse_address=True; daemon_threads=True
def proxy(port,marker):
    s=TCP(("127.0.0.1",port),Proxy); s.marker=marker; s.serve_forever()
threading.Thread(target=lambda:ThreadingHTTPServer(("127.0.0.1",target),Target).serve_forever(),daemon=True).start()
threading.Thread(target=proxy,args=(us,b"proxy-us"),daemon=True).start()
threading.Thread(target=proxy,args=(jp,b"proxy-jp"),daemon=True).start()
UDP(("127.0.0.1",udp),Echo).serve_forever()
PY
SERVER_PID=$!
sleep .2

write_config() {
  local path=$1 quota=${2:-false}
  jq -n --argjson socks "$SOCKS_PORT" --argjson http "$HTTP_IN_PORT" --argjson vless "$VLESS_PORT" --argjson target "$TARGET_PORT" \
    --argjson us "$PROXY_US_PORT" --argjson jp "$PROXY_JP_PORT" --argjson quota "$quota" '
    {
      log:{loglevel:"debug"},
      inbounds:[
        {tag:"socks-in",listen:"127.0.0.1",port:$socks,protocol:"socks",settings:{auth:"password",udp:true,accounts:[
          {user:"alice",pass:"alice-pass"},{user:"bob",pass:"bob-pass"},{user:"charlie",pass:"charlie-pass"}]}},
        {tag:"http-in",listen:"127.0.0.1",port:$http,protocol:"http",settings:{accounts:[{user:"http-user",pass:"http-pass"}]}},
        {tag:"vless-in",listen:"127.0.0.1",port:$vless,protocol:"vless",settings:{decryption:"none",clients:[
          {id:"33333333-3333-4333-8333-333333333333",email:"vless-alice",level:0}]}}
      ],
      outbounds:[
        {tag:"direct",protocol:"freedom",settings:{redirect:"127.0.0.1:\($target)"}},
        {tag:"udp-direct",protocol:"freedom"},
        {tag:"blocked",protocol:"blackhole"},
        {tag:"proxy-us",protocol:"http",settings:{address:"127.0.0.1",port:$us}},
        {tag:"proxy-jp",protocol:"http",settings:{address:"127.0.0.1",port:$jp}}
      ],
      routing:{domainStrategy:"IPIfNonMatch",rules:
        (if $quota then [{type:"field",ruleTag:"xrayctl-user-limit:bob",inboundTag:["socks-in"],user:["bob"],outboundTag:"blocked"}] else [] end) +
        [
          {type:"field",ruleTag:"xrayctl-user-domain:alice-google",inboundTag:["socks-in"],user:["alice"],domain:["full:google.test"],outboundTag:"proxy-jp"},
          {type:"field",ruleTag:"xrayctl-domain:public-google",inboundTag:["socks-in"],domain:["full:google.test"],outboundTag:"direct"},
          {type:"field",ruleTag:"xrayctl-user-outbound:alice",inboundTag:["socks-in"],user:["alice"],outboundTag:"proxy-us"},
          {type:"field",ruleTag:"xrayctl-user-outbound:bob",inboundTag:["socks-in"],user:["bob"],outboundTag:"proxy-jp"},
          {type:"field",ruleTag:"xrayctl-user-outbound:http",inboundTag:["http-in"],user:["http-user"],outboundTag:"proxy-us"},
          {type:"field",ruleTag:"xrayctl-user-domain:vless-google",inboundTag:["vless-in"],user:["vless-alice"],domain:["full:google.test"],outboundTag:"proxy-jp"},
          {type:"field",ruleTag:"xrayctl-user-outbound:vless",inboundTag:["vless-in"],user:["vless-alice"],outboundTag:"proxy-us"},
          {type:"field",ruleTag:"xrayctl-outbound:socks-in-tcp",inboundTag:["socks-in"],network:["tcp"],outboundTag:"direct"},
          {type:"field",ruleTag:"xrayctl-outbound:socks-in-udp",inboundTag:["socks-in"],network:["udp"],outboundTag:"udp-direct"},
          {type:"field",ruleTag:"xrayctl-outbound:http-in",inboundTag:["http-in"],outboundTag:"direct"},
          {type:"field",ruleTag:"xrayctl-outbound:vless-in",inboundTag:["vless-in"],outboundTag:"direct"}
        ]}
    }
  ' >"$path"
}
write_vless_client_config() {
  jq -n --argjson socks "$VLESS_CLIENT_PORT" --argjson server "$VLESS_PORT" '
    {
      log:{loglevel:"warning"},
      inbounds:[{tag:"client-socks",listen:"127.0.0.1",port:$socks,protocol:"socks",settings:{auth:"noauth"}}],
      outbounds:[
        {tag:"to-vless",protocol:"vless",settings:{vnext:[{address:"127.0.0.1",port:$server,users:[
          {id:"33333333-3333-4333-8333-333333333333",encryption:"none"}]}]},streamSettings:{network:"raw",security:"none"}},
        {tag:"direct",protocol:"freedom"}
      ],
      routing:{rules:[{type:"field",inboundTag:["client-socks"],outboundTag:"to-vless"}]}
    }
  ' >"$TEST_ROOT/vless-client.json"
}
validate_config() {
  "$XRAY_BIN" run -test -format json -config "$1" >"$TEST_ROOT/validate.log" 2>&1 || { cat "$TEST_ROOT/validate.log" >&2; return 1; }
}
start_xray() {
  local config=$1
  "$XRAY_BIN" run -config "$config" >>"$TEST_ROOT/xray.log" 2>&1 & XRAY_PID=$!
  for _ in $(seq 1 80); do
    if python3 - "$SOCKS_PORT" "$HTTP_IN_PORT" "$VLESS_PORT" <<'PY'
import socket,sys
for p in map(int,sys.argv[1:]):
    s=socket.socket()
    try: s.connect(("127.0.0.1",p))
    except OSError: sys.exit(1)
    finally: s.close()
PY
    then return 0; fi
    kill -0 "$XRAY_PID" 2>/dev/null || { cat "$TEST_ROOT/xray.log" >&2; return 1; }
    sleep .1
  done
  return 1
}
start_vless_client() {
  "$XRAY_BIN" run -config "$TEST_ROOT/vless-client.json" >>"$TEST_ROOT/client-xray.log" 2>&1 & CLIENT_PID=$!
  for _ in $(seq 1 80); do
    if python3 - "$VLESS_CLIENT_PORT" <<'PY'
import socket,sys
s=socket.socket()
try: s.connect(("127.0.0.1",int(sys.argv[1])))
except OSError: sys.exit(1)
finally: s.close()
PY
    then return 0; fi
    kill -0 "$CLIENT_PID" 2>/dev/null || { cat "$TEST_ROOT/client-xray.log" >&2; return 1; }
    sleep .1
  done
  return 1
}
stop_vless_client() {
  [[ -z $CLIENT_PID ]] || { kill "$CLIENT_PID"; wait "$CLIENT_PID" || true; }
  CLIENT_PID=
}
stop_xray() {
  [[ -z $XRAY_PID ]] || { kill "$XRAY_PID"; wait "$XRAY_PID" || true; }
  XRAY_PID=
}
fetch_socks() {
  curl -fsS --noproxy '' --max-time 4 --proxy-user "$1" --socks5-hostname "127.0.0.1:$SOCKS_PORT" "http://$2.test:$TARGET_PORT/"
}
fetch_http() {
  curl -fsS --noproxy '' --max-time 4 --proxy "http://127.0.0.1:$HTTP_IN_PORT" --proxy-user "$1" "http://other.test:$TARGET_PORT/"
}
assert_eq() {
  [[ $1 == "$2" ]] || { printf 'not ok - %s (expected %s, got %s)\n' "$3" "$1" "$2" >&2; cat "$TEST_ROOT/xray.log" "$TEST_ROOT/servers.log" >&2; exit 1; }
}

CONFIG="$TEST_ROOT/config.json"
write_config "$CONFIG" false
write_vless_client_config
validate_config "$CONFIG"
validate_config "$TEST_ROOT/vless-client.json"
start_xray "$CONFIG"
assert_eq proxy-jp "$(fetch_socks alice:alice-pass google)" 'personal domain rule selected its actual proxy'
assert_eq direct "$(fetch_socks bob:bob-pass google)" 'public domain rule outranked user default'
assert_eq proxy-us "$(fetch_socks alice:alice-pass other)" 'alice default selected its actual proxy'
assert_eq proxy-jp "$(fetch_socks bob:bob-pass other)" 'bob default selected its actual proxy'
assert_eq direct "$(fetch_socks charlie:charlie-pass other)" 'unset user default inherited inbound default'
assert_eq proxy-us "$(fetch_http http-user:http-pass)" 'HTTP authenticated user identity selected its route'
start_vless_client
assert_eq proxy-us "$(curl -fsS --noproxy '' --max-time 4 --socks5-hostname "127.0.0.1:$VLESS_CLIENT_PORT" "http://other.test:$TARGET_PORT/")" 'VLESS email identity selected its actual user default'
assert_eq proxy-jp "$(curl -fsS --noproxy '' --max-time 4 --socks5-hostname "127.0.0.1:$VLESS_CLIENT_PORT" "http://google.test:$TARGET_PORT/")" 'VLESS email identity selected its actual personal domain rule'
grep -Fq 'Hit route rule: [xrayctl-user-outbound:vless] so taking detour [proxy-us]' "$TEST_ROOT/xray.log"
grep -Fq 'Hit route rule: [xrayctl-user-domain:vless-google] so taking detour [proxy-jp]' "$TEST_ROOT/xray.log"
stop_vless_client
stop_xray

# First prove authenticated SOCKS UDP can reach the direct echo server.
write_config "$CONFIG" false
jq '.routing.rules |= map(select((.ruleTag // "")!="xrayctl-user-outbound:bob"))' "$CONFIG" >"$CONFIG.baseline"
mv "$CONFIG.baseline" "$CONFIG"
validate_config "$CONFIG"
start_xray "$CONFIG"
python3 - "$SOCKS_PORT" "$UDP_PORT" bob bob-pass <<'PY'
import socket,sys,struct
socks,port=int(sys.argv[1]),int(sys.argv[2]); user,pwd=sys.argv[3],sys.argv[4]
c=socket.create_connection(("127.0.0.1",socks),2)
def exact(sock,n):
    data=b""
    while len(data)<n: data+=sock.recv(n-len(data))
    return data
c.sendall(b"\x05\x01\x02"); assert exact(c,2)==b"\x05\x02"
u=user.encode(); p=pwd.encode(); c.sendall(b"\x01"+bytes([len(u)])+u+bytes([len(p)])+p); assert exact(c,2)==b"\x01\x00"
c.sendall(b"\x05\x03\x00\x01\x00\x00\x00\x00\x00\x00")
h=exact(c,4); atyp=h[3]
if atyp==1: host=socket.inet_ntoa(exact(c,4))
elif atyp==4: host=socket.inet_ntop(socket.AF_INET6,exact(c,16))
else: n=exact(c,1)[0]; host=exact(c,n).decode()
bport=struct.unpack("!H",exact(c,2))[0]
if host in ("0.0.0.0","::"): host="127.0.0.1"
u_sock=socket.socket(socket.AF_INET,socket.SOCK_DGRAM); u_sock.settimeout(2)
target=socket.inet_aton("127.0.0.1")+struct.pack("!H",port)
u_sock.sendto(b"\x00\x00\x00\x01"+target+b"baseline",(host,bport))
data,_=u_sock.recvfrom(4096); assert data.endswith(b"baseline"),data
print("baseline UDP echo reached")
PY
stop_xray
rm -f "$SEEN_FILE"

# Bob's matched HTTP outbound cannot carry UDP. It must fail closed rather
# than falling through to the inbound direct default.
write_config "$CONFIG" false
validate_config "$CONFIG"
start_xray "$CONFIG"
udp_log_start=$(wc -l <"$TEST_ROOT/xray.log")
python3 - "$SOCKS_PORT" "$UDP_PORT" bob bob-pass <<'PY'
import socket,sys,struct
socks,port=int(sys.argv[1]),int(sys.argv[2]); user,pwd=sys.argv[3],sys.argv[4]
c=socket.create_connection(("127.0.0.1",socks),2)
def exact(sock,n):
    data=b""
    while len(data)<n:
        part=sock.recv(n-len(data))
        if not part: raise EOFError
        data+=part
    return data
c.sendall(b"\x05\x01\x02"); assert exact(c,2)==b"\x05\x02"
u=user.encode(); p=pwd.encode(); c.sendall(b"\x01"+bytes([len(u)])+u+bytes([len(p)])+p); assert exact(c,2)==b"\x01\x00"
c.sendall(b"\x05\x03\x00\x01\x00\x00\x00\x00\x00\x00")
h=exact(c,4); atyp=h[3]
if atyp==1: host=socket.inet_ntoa(exact(c,4))
elif atyp==4: host=socket.inet_ntop(socket.AF_INET6,exact(c,16))
else: n=exact(c,1)[0]; host=exact(c,n).decode()
bport=struct.unpack("!H",exact(c,2))[0]
if host in ("0.0.0.0","::"): host="127.0.0.1"
u_sock=socket.socket(socket.AF_INET,socket.SOCK_DGRAM); u_sock.settimeout(1.5)
target=socket.inet_aton("127.0.0.1")+struct.pack("!H",port)
u_sock.sendto(b"\x00\x00\x00\x01"+target+b"should-not-direct",(host,bport))
try:
    data,_=u_sock.recvfrom(4096)
    print("unexpected UDP response:",data); sys.exit(2)
except socket.timeout:
    print("HTTP-routed UDP did not reach direct echo")
PY
udp_route_log=$(tail -n "+$((udp_log_start + 1))" "$TEST_ROOT/xray.log")
[[ $udp_route_log == *'Hit route rule: [xrayctl-user-outbound:bob] so taking detour [proxy-jp]'* && $udp_route_log == *'udp:'* ]] || {
  printf 'not ok - real Xray did not match the authenticated SOCKS UDP user route\n' >&2
  cat "$TEST_ROOT/xray.log" >&2
  exit 1
}
if [[ -s $SEEN_FILE ]]; then
  printf 'not ok - authenticated SOCKS UDP bypassed the user HTTP outbound and reached direct echo\n' >&2
  exit 1
fi
stop_xray

# A quota ban must outrank both personal domain rules and user defaults.
write_config "$CONFIG" true
validate_config "$CONFIG"
start_xray "$CONFIG"
quota_log_start=$(wc -l <"$TEST_ROOT/xray.log")
if fetch_socks bob:bob-pass other >/dev/null 2>&1; then
  printf 'not ok - real quota ban was bypassed by the user default route\n' >&2
  exit 1
fi
quota_route_log=$(tail -n "+$((quota_log_start + 1))" "$TEST_ROOT/xray.log")
[[ $quota_route_log == *'Hit route rule: [xrayctl-user-limit:bob] so taking detour [blocked]'* ]] || {
  printf "not ok - real Xray did not select the user's quota ban rule\n" >&2
  cat "$TEST_ROOT/xray.log" >&2
  exit 1
}
stop_xray
printf 'ok - real Xray matched VLESS email and authenticated SOCKS/HTTP identities, enforced quota priority, and failed closed for HTTP-routed SOCKS UDP\n'
