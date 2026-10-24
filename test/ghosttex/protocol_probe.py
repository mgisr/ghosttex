#!/usr/bin/env python3
"""Exercise native VT replies from inside a real terminal, without UI automation."""
import json
import os
from pathlib import Path
import select
import sys
import termios
import time
import tty

result_path = Path(sys.argv[1] if len(sys.argv) > 1 else '.zig-cache/ghosttex/protocol.json')
result_path.parent.mkdir(parents=True, exist_ok=True)
result_path.unlink(missing_ok=True)
previous = termios.tcgetattr(0)
tty.setraw(0)
results = []
try:
    rows = os.get_terminal_size().lines
    for alternate in (False, True):
        if alternate:
            os.write(1, b'\x1b[?1049h')
        os.write(1, b'\x1b[2J\x1b[H\x1b[?1003h\x1b[?1006h\x1b[?2004h')
        os.write(1, b'Native terminal protocol probe\r\n\\[\r\n\\frac{a+b}{c+d}\r\n\\]\r\n')
        os.write(1, f'\x1b[6;{rows-5}r\x1b[6;1H'.encode())
        for i in range(rows):
            os.write(1, f'scrolling region {i}\r\n'.encode())
        os.write(1, b'\x1b[r')
        os.write(1, b'\x1b[2;1Hplain \\(\\begin{pmatrix}1&2\\\\3&4\\end{pmatrix}\\) after\x1b[K')
        os.write(1, f'\x1b[{rows-3};1H\x1b[48;2;30;30;30m \x1b[K\r\n> input\x1b[K\r\n \x1b[K\x1b[0m\r\nstatus\x1b[{rows-2};5H'.encode())
        expected = [f'\x1b[{rows-2};5R'.encode(), b'\x1b[?1003;1$y', b'\x1b[?2004;1$y',
                    b'\x1b[?1049;1$y' if alternate else b'\x1b[?1049;2$y']
        for stage in ('render', 'partial-erase'):
            if stage == 'partial-erase':
                os.write(1, f'\x1b[2;1H\x1b[K\x1b[{rows-2};5H'.encode())
            os.write(1, b'\x1b[6n\x1b[?1003$p\x1b[?2004$p\x1b[?1049$p')
            response = b''
            deadline = time.monotonic() + 5
            while time.monotonic() < deadline and not all(item in response for item in expected):
                if select.select([0], [], [], .1)[0]:
                    response += os.read(0, 65536)
            assert all(item in response for item in expected), (alternate, stage, response, expected)
            results.append({'alternate': alternate, 'stage': stage, 'replies': response.hex()})
            time.sleep(1)
        os.write(1, b'\x1b[?1003l\x1b[?1006l\x1b[?2004l')
        if alternate:
            os.write(1, b'\x1b[?1049l')
    result_path.write_text(json.dumps({'passed': True, 'rows': rows, 'checks': results}, indent=2))
finally:
    termios.tcsetattr(0, termios.TCSANOW, previous)
