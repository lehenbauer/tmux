#!/bin/sh
# Whisp protocol 9: the next-cell rendition is independent of painted cells.
set -eu
TEST_TMUX=${TEST_TMUX:-../tmux}
export TEST_TMUX
python3 - <<'PY'
import os, shlex, subprocess, tempfile, time
from pathlib import Path

binary = str(Path(os.environ['TEST_TMUX']).resolve())
with tempfile.TemporaryDirectory(prefix='tmux-replay-regress-') as temporary:
    root = Path(temporary)
    socket = str(root/'socket')
    def tmux(*args):
        return subprocess.check_output([binary, '-S', socket, *args], stderr=subprocess.PIPE, timeout=10)
    started = False
    try:
        for index, (style, expected) in enumerate([
            (b'\x1b[39m', b'\x1b[0m'),
            (b'\x1b[1;2;31;44m', b'\x1b[0m\x1b[1;2m\x1b[31m\x1b[44m'),
            (b'\x1b[38;2;1;2;3;48;5;117m', b'\x1b[0m\x1b[38;2;1;2;3m\x1b[48;5;117m'),
            (b'\x1b[1;2;31m\x1b[0m', b'\x1b[0m'),
        ]):
            data = b'\x1b[0m' + b'x'*100 + b'\r\n\x1b[38;5;246mfooter' + style + b'\x1b]2;ready\a'
            payload = root/f'payload{index}'
            payload.write_bytes(data)
            command = shlex.join(['/bin/sh', '-c', 'cat '+shlex.quote(str(payload))+'; sleep 30'])
            if not started:
                pane = tmux('-f', '/dev/null', 'new-session', '-d', '-x', '80', '-y', '8', '-P', '-F', '#{pane_id}', command).decode().strip()
                started = True
                assert int(tmux('display-message', '-p', '#{whisp_tmux_protocol_version}')) >= 9
            else:
                pane = tmux('new-window', '-d', '-P', '-F', '#{pane_id}', command).decode().strip()
            for _ in range(200):
                if tmux('display-message', '-p', '-t', pane, '#{pane_title}').strip() == b'ready': break
                time.sleep(.01)
            else: raise AssertionError('fixture timeout')
            before = tmux('capture-pane', '-pJ', '-e', '-t', pane)
            captured = tmux('whisp-capture-pane', '-R', '-t', pane)
            header, body = captured.split(b'\n', 1)
            assert header.startswith(b'whisp-replay-v1\t'), header
            assert bytes.fromhex(header.split(b'\t')[1].decode()) == expected, header
            assert body == before
            assert before == tmux('capture-pane', '-pJ', '-e', '-t', pane)
            assert body.splitlines()[0] == b'x'*100
            print(f'PASS rendition case {index}: literal SGR oracle, joined cells, no mutation')
        for ranges in [[], ['-S', '0', '-E', '1'], ['-S', '2', '-E', '0'],
                       ['-S', '-100', '-E', '-'], ['-S', '-', '-E', '-']]:
            captured = tmux('whisp-capture-pane', '-R', '-t', pane, *ranges)
            assert captured.split(b'\n', 1)[1] == tmux('capture-pane', '-pJ', '-e', '-t', pane, *ranges)
        print('PASS default, partial, reversed, and full-history range parity')
        control = subprocess.run([binary, '-S', socket, '-C', 'attach-session'],
                                 input=f'whisp-capture-pane -R -t {pane}\ndetach-client\n'.encode(),
                                 stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=10, check=True)
        lines = control.stdout.split(b'\n')
        start = next(i for i, line in enumerate(lines) if line.startswith(b'whisp-replay-v1\t'))
        end = next(i for i in range(start + 1, len(lines)) if lines[i].startswith(b'%end '))
        assert b'\n'.join(lines[start:end]) + b'\n' == tmux('whisp-capture-pane', '-R', '-t', pane)
        print('PASS real control-mode header and body parity')
        for flags in [['-L'], ['-J'], ['-e'], ['-A', '1'], ['-B', '1'], ['-n', '1']]:
            result = subprocess.run([binary, '-S', socket, 'whisp-capture-pane', '-R', *flags, '-t', pane], capture_output=True)
            assert result.returncode != 0 and b'-R accepts only' in result.stderr
        print('PASS replay rejects incompatible modes')
    finally:
        if started: tmux('kill-server')
PY
