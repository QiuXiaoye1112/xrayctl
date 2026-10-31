#!/usr/bin/env bash
set -Eeuo pipefail
if [[ -z ${XRAYCTL_REAL_XRAY_BIN:-} ]]; then
  printf 'ok - real transport matrix skipped (set XRAYCTL_REAL_XRAY_BIN)\n'
  exit 0
fi
REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
export REPO_ROOT
python3 - <<'PY'
import copy, hashlib, http.server, json, os, pathlib, socket, ssl, subprocess, tempfile, threading, time

binary = os.environ['XRAYCTL_REAL_XRAY_BIN']
repo = os.environ['REPO_ROOT']
builder = r'''
source "$REPO_ROOT/xrayctl.sh"
index=0
choose() {
  index=$((index+1))
  if ((index==1)); then printf -v "$1" '%s' "$SECURITY_CHOICE"
  else printf -v "$1" '%s' "$TRANSPORT_CHOICE"; fi
}
prompt_value() { printf -v "$1" '%s' /matrix; }
prompt_validated_value() {
  if [[ $2 == 'REALITY 目标' ]]; then printf -v "$1" '127.0.0.1:%s' "$DECOY_PORT"
  else printf -v "$1" '%s' matrix.test; fi
}
prompt_tls_certificate() {
  printf -v "$1" '%s' "$MATRIX_ROOT/cert.pem"
  printf -v "$2" '%s' "$MATRIX_ROOT/key.pem"
  printf -v "$3" '%s' matrix.test
}
stream_result=''; public_result=''; inbound_result=''
build_stream_settings vless stream_result public_result
protocol_build_vless inbound_result node 127.0.0.1 "$SERVER_PORT" alice "$stream_result"
jq -n --argjson inbound "$inbound_result" --arg public "$public_result" '{inbound:$inbound,public:$public}'
'''

class Target(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        body = b'matrix-ok'
        self.send_response(200)
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)
    def log_message(self, *args): pass

def port():
    with socket.socket() as sock:
        sock.bind(('127.0.0.1', 0))
        return sock.getsockname()[1]

def wait_listen(process, number):
    for _ in range(80):
        if process.poll() is not None: raise RuntimeError('Xray exited before listening')
        try:
            with socket.create_connection(('127.0.0.1', number), timeout=.1): return
        except OSError: time.sleep(.05)
    raise RuntimeError('Xray listener did not become ready')

with tempfile.TemporaryDirectory(prefix='xrayctl-transport-') as directory:
    root = pathlib.Path(directory)
    subprocess.run(['openssl', 'req', '-x509', '-newkey', 'rsa:2048', '-nodes', '-days', '1',
                    '-subj', '/CN=matrix.test', '-addext', 'subjectAltName=DNS:matrix.test',
                    '-keyout', str(root/'key.pem'), '-out', str(root/'cert.pem')],
                   check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    cert_hash = hashlib.sha256(ssl.PEM_cert_to_DER_cert((root/'cert.pem').read_text())).hexdigest()
    target = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Target)
    decoy = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Target)
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    context.minimum_version = ssl.TLSVersion.TLSv1_3
    context.load_cert_chain(root/'cert.pem', root/'key.pem')
    context.set_alpn_protocols(['h2', 'http/1.1'])
    decoy.socket = context.wrap_socket(decoy.socket, server_side=True)
    for server in (target, decoy):
        threading.Thread(target=server.serve_forever, daemon=True).start()
    subprocess.run(['curl','-fsS','--noproxy','*','--max-time','3', f'http://127.0.0.1:{target.server_port}/'], check=True, stdout=subprocess.DEVNULL)
    try:
        for security, sec_index in [('none', 3), ('tls', 2), ('reality', 1)]:
            for transport, trans_index in [('raw', 1), ('xhttp', 2), ('websocket', 3)]:
                if security == 'reality' and transport == 'websocket': continue
                server_port, client_port = port(), port()
                env = dict(os.environ, MATRIX_ROOT=directory, SERVER_PORT=str(server_port),
                           SECURITY_CHOICE=str(sec_index), TRANSPORT_CHOICE=str(trans_index),
                           DECOY_PORT=str(decoy.server_port), XRAYCTL_XRAY_BIN=binary)
                generated = json.loads(subprocess.check_output(['bash', '-c', builder], env=env, text=True))
                inbound = generated['inbound']
                stream = copy.deepcopy(inbound['streamSettings'])
                if security == 'tls':
                    stream['tlsSettings'] = {'serverName':'matrix.test', 'pinnedPeerCertSha256':cert_hash,
                                             'alpn':stream['tlsSettings']['alpn']}
                elif security == 'reality':
                    reality = stream['realitySettings']
                    stream['realitySettings'] = {'serverName':'matrix.test', 'fingerprint':'chrome',
                        'publicKey':generated['public'], 'shortId':reality['shortIds'][0]}
                user = {k:v for k,v in inbound['settings']['clients'][0].items() if k in ('id','flow')}
                user['encryption'] = 'none'
                configurations = {
                    'server': {'log':{'loglevel':'debug'}, 'inbounds':[inbound],
                               'outbounds':[{'tag':'direct', 'protocol':'freedom',
                                   'settings':{'finalRules':[{'action':'allow','network':'tcp','ip':['127.0.0.1/32']}]}}]},
                    'client': {'log':{'loglevel':'debug'}, 'inbounds':[{'listen':'127.0.0.1',
                               'port':client_port, 'protocol':'socks', 'settings':{'auth':'noauth'}}],
                               'outbounds':[{'protocol':'vless', 'settings':{'vnext':[{
                                   'address':'127.0.0.1','port':server_port,'users':[user]}]},
                                   'streamSettings':stream}]}}
                processes, logs = [], []
                try:
                    for name, config in configurations.items():
                        config_path = root/f'{name}.json'
                        config_path.write_text(json.dumps(config))
                        checked = subprocess.run([binary,'run','-test','-config',str(config_path)], capture_output=True, text=True)
                        if checked.returncode: raise RuntimeError(checked.stdout+checked.stderr)
                        log = open(root/f'{name}.log', 'w'); logs.append(log)
                        processes.append(subprocess.Popen([binary,'run','-config',str(config_path)], stdout=log, stderr=log))
                    wait_listen(processes[0], server_port); wait_listen(processes[1], client_port)
                    body = subprocess.check_output(['curl','-fsS','--noproxy','','--max-time','15',
                         '--socks5-hostname', f'127.0.0.1:{client_port}',
                         f'http://127.0.0.1:{target.server_port}/'], text=True)
                    if body != 'matrix-ok': raise RuntimeError('unexpected proxy response')
                    print(f'ok - real VLESS {transport}/{security} builder and proxy request', flush=True)
                except Exception:
                    print(f'not ok - real VLESS {transport}/{security}', flush=True)
                    for log in logs: log.flush()
                    for name in configurations:
                        path = root/f'{name}.log'
                        if path.exists(): print(path.read_text(), flush=True)
                    raise
                finally:
                    for process in processes:
                        process.terminate()
                        try: process.wait(timeout=5)
                        except subprocess.TimeoutExpired: process.kill(); process.wait()
                    for log in logs: log.close()
    finally:
        for server in (target, decoy): server.shutdown(); server.server_close()
PY
