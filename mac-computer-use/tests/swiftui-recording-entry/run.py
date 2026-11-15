#!/usr/bin/env python3
"""Extract actual fixture core, compile console, prove guards, then run exact-owned max1."""
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent))
from native_check_support import check_routes, run_owned
out = Path(sys.argv[1]) if len(sys.argv) == 2 else Path(tempfile.mkdtemp(prefix='mac-cu-recording-entry-complete-', dir='/private/tmp'))
out.mkdir(parents=True, exist_ok=True)
fixture = HERE.parent / 'swiftui-hierarchy-probe/Fixture.swift'
source = fixture.read_text()
core = source.split('// BEGIN RECORDING ENTRY CORE', 1)[1].split('// END RECORDING ENTRY CORE', 1)[0]
core = core[core.index('\n') + 1:]
(out / 'RecordingEntry.swift').write_text(core)
(out / 'main.swift').write_bytes((HERE / 'main.swift').read_bytes())
commands = []
def build(name, command):
    commands.append(command)
    with (out / name).open('w') as log:
        subprocess.run(command, stdout=log, stderr=subprocess.STDOUT, check=True, timeout=120)
build('console-build.log', ['xcrun', 'swiftc', str(out / 'RecordingEntry.swift'), str(out / 'main.swift'), '-o', str(out / 'RecordingEntryTests')])
env = os.environ.copy()
for key in ('MAC_CU_NATIVE_CHECK_CHILD', 'MAC_CU_FIXTURE_CHILD'):
    env.pop(key, None)
with (out / 'headless.log').open('w') as log:
    check_routes(out / 'RecordingEntryTests', env, log, production_helper=False)
    status = run_owned(out / 'RecordingEntryTests', ['--native-check'], environment=dict(env, MAC_CU_FIXTURE_CHILD='1'), log=log, timeout=5, max_instances=1)
    assert status == 64
    status = run_owned(out / 'RecordingEntryTests', ['--native-check'], environment=env, log=log, timeout=30, max_instances=1)
    assert status == 0, f'headless failure: {status}; see {out}/headless.log'
sdk = subprocess.check_output(['xcrun', '--sdk', 'iphonesimulator', '--show-sdk-path'], text=True).strip()
build('ios-typecheck.log', ['xcrun', 'swiftc', '-target', 'arm64-apple-ios17.0-simulator', '-sdk', sdk, '-parse-as-library', '-typecheck', str(fixture)])
(out / 'commands.json').write_text(json.dumps(commands, indent=2) + '\n')
paths = [fixture, HERE / 'main.swift', HERE / 'run.py', out / 'RecordingEntry.swift', out / 'RecordingEntryTests', out / 'headless.log', out / 'ios-typecheck.log']
(out / 'hashes.json').write_text(json.dumps({str(p): hashlib.sha256(p.read_bytes()).hexdigest() for p in paths}, indent=2) + '\n')
print(out)
print((out / 'headless.log').read_text().splitlines()[-1])
