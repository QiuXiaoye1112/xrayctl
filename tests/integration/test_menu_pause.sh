#!/usr/bin/env bash
set -Eeuo pipefail
REPO_ROOT=$(cd "$(dirname "$0")/../.." && pwd)
python3 - "$REPO_ROOT/xrayctl.sh" <<'PYTHON'
import os, pty, select, subprocess, sys, time
fixture = '\nset -Eeuo pipefail\ncase_dir=$(mktemp -d /tmp/xrayctl-pause-check.XXXXXXXX)\ntrap \'rm -rf "$case_dir"\' EXIT\nsource "$1"\ntrap - ERR\ntrap \'rm -rf "$case_dir"\' EXIT\nCONFIG_FILE="$case_dir/config.json"\nprintf \'%s\\n\' \'{"inbounds":[],"outbounds":[],"routing":{"rules":[]}}\' > "$CONFIG_FILE"\nensure_runtime_dependencies() { :; }\nrequire_xray_installed() { :; }\nensure_config() { :; }\nclear_screen() { :; }\nlist_outbound_overview() { :; }\ntemp_file() { mktemp "$case_dir/candidate.XXXXXXXX"; }\nstate_apply_candidate_file() { cp "$1" "$CONFIG_FILE"; rm -f "$1"; }\noutbound_menu\nif [[ $2 == success ]]; then\n  jq -e \'.outbounds|length==1\' "$CONFIG_FILE" >/dev/null\nelse\n  jq -e \'.outbounds|length==0\' "$CONFIG_FILE" >/dev/null\nfi\nprintf \'__MENU_TEST_DONE__\\n\'\n'
def check_menu(candidate, scenario):
    master, slave = pty.openpty()
    process = subprocess.Popen(['bash', '-c', fixture, 'pause-check', candidate, scenario],
                               stdin=slave, stdout=slave, stderr=slave,
                               env={**os.environ, 'NO_COLOR':'1', 'TERM':'dumb'}, start_new_session=True)
    os.close(slave)
    output = bytearray()
    cursor = 0
    def until(text):
        nonlocal cursor
        token = text.encode()
        deadline = time.monotonic() + 10
        while True:
            found = output.find(token, cursor)
            if found >= 0:
                cursor = found + len(token)
                return
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise RuntimeError('PTY prompt timeout in ' + scenario + ': ' + text + '\n' + output.decode(errors='replace'))
            readable, _, _ = select.select([master], [], [], min(remaining, .25))
            if readable:
                try:
                    chunk = os.read(master, 65536)
                except OSError:
                    chunk = b''
                if not chunk:
                    raise RuntimeError('PTY exited early in ' + scenario + '\n' + output.decode(errors='replace'))
                output.extend(chunk)
    def send(text):
        os.write(master, text.encode())
    try:
        until('请选择: ')
        send('3\n')
        until('请选择 [1-2]: ')
        if scenario == 'cancel-protocol':
            send('\x04')
        else:
            send('1\n')
            until('出站标签 [')
            until(']: ')
            send('\n')
            until('代理服务器地址: ')
            send('ww.v\n')
            until('代理服务器端口: ')
            send('4434\n')
            until('认证方式')
            until('请选择 [1-2]: ')
            send('1\n' if scenario == 'success' else '\x04')
        until('按回车键继续...')
        send('\n')
        until('请选择: ')
        pauses = output.decode(errors='replace').count('按回车键继续...')
        if pauses != 1:
            raise RuntimeError('Expected exactly one pause, got ' + str(pauses))
        send('0\n')
        until('__MENU_TEST_DONE__')
        if process.wait(timeout=5) != 0:
            raise RuntimeError('Menu test failed: ' + scenario)
        print('PTY passed:', scenario, '(one pause)')
    finally:
        if process.poll() is None:
            process.terminate()
            process.wait(timeout=5)
        os.close(master)
for scenario in ('cancel-auth', 'cancel-protocol', 'success'):
    check_menu(sys.argv[1], scenario)
PYTHON
