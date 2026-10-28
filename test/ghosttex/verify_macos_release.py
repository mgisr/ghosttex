#!/usr/bin/env python3
"""Check a local Ghosttex release and its native VT replies without UI automation."""
import json
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import sys
import tempfile
import time
import uuid

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
    # AppKit persists window/defaults state even with config files disabled.
    # Probe the same binaries under an isolated bundle identity so a running
    # installation's preferences and saved sessions cannot be overwritten.
    isolated_app = directory / 'Ghosttex.app'
    shutil.copytree(app, isolated_app, symlinks=True)
    isolated_plist = isolated_app / 'Contents/Info.plist'
    with isolated_plist.open('rb') as stream:
        isolated_info = plistlib.load(stream)
    isolated_info['CFBundleIdentifier'] = 'org.ghosttex.release-probe.' + uuid.uuid4().hex
    with isolated_plist.open('wb') as stream:
        plistlib.dump(isolated_info, stream)
    subprocess.run(['codesign', '--force', '--deep', '--sign', '-', '--timestamp=none',
                    str(isolated_app)], check=True)
    probe_binary = isolated_app / 'Contents/MacOS/ghosttex'
    with (directory / 'startup.log').open('w') as log:
        process = subprocess.Popen([
            str(probe_binary), '--config-default-files=false', '--shell-integration=none',
            '--window-save-state=never',
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
            subprocess.run([
                '/System/Library/Frameworks/CoreServices.framework/Frameworks/'
                'LaunchServices.framework/Support/lsregister', '-u', str(isolated_app),
            ], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            subprocess.run(['defaults', 'delete', isolated_info['CFBundleIdentifier']],
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            shutil.rmtree(Path.home() / 'Library/Saved Application State' /
                          (isolated_info['CFBundleIdentifier'] + '.savedState'), ignore_errors=True)
print('Ghosttex ReleaseFast: branding, icon, signature, default math, startup, and 4/4 VT checks passed.')
