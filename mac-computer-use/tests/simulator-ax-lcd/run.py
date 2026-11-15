#!/usr/bin/env python3
"""Headless AppKit view/state fixtures: no windows, simulator or AX transport."""
from pathlib import Path
import hashlib
import importlib.util
import json
import os
import subprocess
import tempfile

root = Path(__file__).resolve().parents[3]
tests = root / 'mac-computer-use/tests'
source = root / 'mac-computer-use/skills/mac-computer-use/scripts/mac-cu-src'
out = Path(tempfile.mkdtemp(prefix='mac-cu-ax-lcd-check.', dir='/tmp'))
print(out, flush=True)
spec = importlib.util.spec_from_file_location('support', tests/'native_check_support.py')
support = importlib.util.module_from_spec(spec)
spec.loader.exec_module(support)
names = ['SimulatorAXUIModel', 'SimulatorHostActions', 'SimulatorRotation', 'SimulatorHingeSlider', 'SimulatorDeviceContainer', 'SimulatorLCDContent', 'SimulatorDeviceChrome', 'SimulatorGesturePad', 'SimulatorToolbox', 'SimulatorToolbarDocking']
inputs = [source/(name+'.swift') for name in names] + [tests/'native-selfcheck-entry.swift', Path(__file__).with_name('main.swift')]
command = ['swiftc', '-parse-as-library', *map(str, inputs), '-o', str(out/'check')]
(out/'source-hashes.json').write_text(json.dumps({str(p): hashlib.sha256(p.read_bytes()).hexdigest() for p in inputs}, indent=2))
with (out/'compile.log').open('w') as log:
    subprocess.run(command, stdout=log, stderr=subprocess.STDOUT, check=True, timeout=180)
with (out/'watchdog.log').open('w') as log:
    support.check_routes(out/'check', dict(os.environ), log, production_helper=False)
    rc = support.run_owned(out/'check', ['--native-check'], environment=dict(os.environ), log=log, timeout=30, max_instances=1)
    if rc: raise RuntimeError(f'check failed: {rc}; {out}')
print((out/'watchdog.log').read_text())
(out/'result.json').write_text(json.dumps({'status': 'pass', 'remaining_instances': support.instances(out/'check')}))
(out/'artifact-hashes.json').write_text(json.dumps({p.name: hashlib.sha256(p.read_bytes()).hexdigest() for p in out.iterdir() if p.is_file()}, indent=2))
