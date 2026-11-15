#!/usr/bin/env python3
"""Extend existing fake AX suite with production host lifecycle, without AXP calls."""
from pathlib import Path
import importlib.util
import hashlib
import json
import os
import subprocess
import tempfile
root = Path(__file__).resolve().parents[3]
tests = root/'mac-computer-use/tests'
source = root/'mac-computer-use/skills/mac-computer-use/scripts/mac-cu-src'
fixture = tests/'simulator-ax-inspection'
out = Path(tempfile.mkdtemp(prefix='mac-cu-ax-host.', dir='/tmp'))
print(out, flush=True)
spec = importlib.util.spec_from_file_location('support', tests/'native_check_support.py')
support = importlib.util.module_from_spec(spec); spec.loader.exec_module(support)
main = out/'main.swift'
main.write_text((fixture/'main.swift').read_text() + '\n' + Path(__file__).with_name('lifecycle.swift').read_text())
inputs = [source/(n+'.swift') for n in ['SimulatorAccessibility', 'SimulatorAXInspection', 'SimulatorAXUIModel', 'SimulatorAXHostIntegration']] + [fixture/'Stubs.swift', main]
with (out/'compile.log').open('w') as log:
    for name, path in [('production', source/'SimulatorAXAdapter.m'), ('fixture', fixture/'Fixture.m')]:
        subprocess.run(['clang', '-fobjc-arc', '-fobjc-exceptions', '-fobjc-arc-exceptions', '-fblocks', '-Wall', '-Wextra', '-Werror', '-I', str(source), '-c', str(path), '-o', str(out/(name+'.o'))], stdout=log, stderr=subprocess.STDOUT, check=True, timeout=60)
    subprocess.run(['swiftc', '-D', 'SAX_INSPECTION_TESTING', '-import-objc-header', str(fixture/'Fixture.h'), '-I', str(source), *map(str, inputs), str(out/'production.o'), str(out/'fixture.o'), '-o', str(out/'check')], stdout=log, stderr=subprocess.STDOUT, check=True, timeout=180)
with (out/'watchdog.log').open('w') as log:
    support.check_routes(out/'check', dict(os.environ), log, production_helper=False)
    rc = support.run_owned(out/'check', ['--native-check'], environment=dict(os.environ), log=log, timeout=25, max_instances=1)
    if rc: raise RuntimeError(f'host tests failed {rc}; {out}')
print((out/'watchdog.log').read_text())
inputs += [source/'SimulatorAXAdapter.h', source/'SimulatorAXAdapter.m', fixture/'Fixture.h', fixture/'Fixture.m', Path(__file__), Path(__file__).with_name('lifecycle.swift')]
(out/'source-hashes.json').write_text(json.dumps({str(p): hashlib.sha256(p.read_bytes()).hexdigest() for p in inputs}, indent=2))
(out/'result.json').write_text(json.dumps({'status': 'pass', 'remaining_instances': support.instances(out/'check')}))
(out/'artifact-hashes.json').write_text(json.dumps({p.name: hashlib.sha256(p.read_bytes()).hexdigest() for p in out.iterdir() if p.is_file()}, indent=2))
