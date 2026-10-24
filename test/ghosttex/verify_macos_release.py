#!/usr/bin/env python3
"""Check a local Ghosttex release and its native VT replies without UI automation."""
import json
from pathlib import Path
import plistlib
import re
import subprocess
import sys
import tempfile
import time

app = Path(sys.argv[1]).resolve()
with (app / 'Contents/Info.plist').open('rb') as stream:
    info = plistlib.load(stream)
assert info['CFBundleDisplayName'] == 'Ghosttex', info
assert info['CFBundleExecutable'] == 'ghosttex', info
assert info['CFBundleIdentifier'] == 'org.ghosttex.terminal', info
assert info['GhosttexBuild'] == 'ReleaseFast', info
icon = info['CFBundleIconFile']
if not icon.endswith('.icns'):
    icon += '.icns'
assert (app / 'Contents/Resources' / icon).is_file(), icon
binary = app / 'Contents/MacOS/ghosttex'
subprocess.run(['codesign', '--verify', '--deep', '--strict', str(app)], check=True)
version = subprocess.check_output([str(binary), '+version'], text=True)
assert version.startswith('Ghosttex ' + info['CFBundleShortVersionString']), version
assert re.search(r'build mode\s*:\s*.*fast', version, re.I), version
defaults = subprocess.check_output([str(binary), '+show-config', '--default', '--no-pager'], text=True)
assert re.search(r'^math-rendering\s*=\s*true$', defaults, re.M)

probe = Path(__file__).with_name('protocol_probe.py').resolve()
with tempfile.TemporaryDirectory(prefix='ghosttex-release-') as directory:
    directory = Path(directory)
    result = directory / 'protocol.json'
    with (directory / 'startup.log').open('w') as log:
        process = subprocess.Popen([
            str(binary), '--config-default-files=false', '--shell-integration=none',
            '--quit-after-last-window-closed=true', '-e', sys.executable, str(probe), str(result),
        ], stdout=log, stderr=subprocess.STDOUT)
        saw_worker = False
        deadline = time.monotonic() + 25
        try:
            while process.poll() is None and time.monotonic() < deadline:
                children = subprocess.check_output(['ps', '-axo', 'ppid=,comm='], text=True)
                for child in children.splitlines():
                    fields = child.strip().split(None, 1)
                    if len(fields) == 2 and fields[0] == str(process.pid):
                        saw_worker |= 'ghosttex-math-worker' in fields[1]
                time.sleep(.1)
            if process.poll() is None:
                raise TimeoutError('release startup/protocol probe timed out')
            assert process.returncode == 0, (directory / 'startup.log').read_text()
            assert saw_worker, 'math worker did not start with default configuration'
            report = json.loads(result.read_text())
            assert report['passed'] and len(report['checks']) == 4, report
        finally:
            if process.poll() is None:
                process.terminate()
                process.wait(timeout=10)
print('Ghosttex ReleaseFast: branding, icon, signature, default math, startup, and 4/4 VT checks passed.')
