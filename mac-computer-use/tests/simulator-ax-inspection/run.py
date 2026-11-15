#!/usr/bin/env python3
"""Compile and run only fake objects, under existing native watchdog semantics."""
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[3]
source = root / 'mac-computer-use/skills/mac-computer-use/scripts/mac-cu-src'
tests = Path(__file__).resolve().parent
out = Path(tempfile.mkdtemp(prefix='mac-pilot-ax-inspection.', dir='/tmp'))
print(out, flush=True)
spec = importlib.util.spec_from_file_location('support', tests.parent / 'native_check_support.py')
support = importlib.util.module_from_spec(spec)
spec.loader.exec_module(support)
inputs = [source/'SimulatorAXAdapter.h', source/'SimulatorAXAdapter.m', source/'SimulatorAccessibility.swift', source/'SimulatorAXInspection.swift', tests/'Fixture.h', tests/'Fixture.m', tests/'Stubs.swift', tests/'main.swift', Path(__file__), root/'docs/design/simulator-ax-integration.md']
(out/'source-hashes.json').write_text(json.dumps({str(p): hashlib.sha256(p.read_bytes()).hexdigest() for p in inputs}, indent=2))
flags = ['xcrun', 'clang', '-fobjc-arc', '-fobjc-exceptions', '-fobjc-arc-exceptions', '-fblocks', '-Wall', '-Wextra', '-Werror', '-I', str(source)]
swift = ['xcrun', 'swiftc', '-D', 'SAX_INSPECTION_TESTING', '-import-objc-header', str(tests/'Fixture.h'), '-I', str(source), str(source/'SimulatorAccessibility.swift'), str(source/'SimulatorAXInspection.swift'), str(tests/'Stubs.swift'), str(tests/'main.swift')]
commands = [flags + ['-c', str(source/'SimulatorAXAdapter.m'), '-o', str(out/'production.o')],
            flags + ['-c', str(tests/'Fixture.m'), '-o', str(out/'fixture.o')],
            ['xcrun', 'swiftc', '-typecheck', '-import-objc-header', str(source/'SimulatorAXAdapter.h'), str(source/'SimulatorAccessibility.swift'), str(source/'SimulatorAXInspection.swift'), str(tests/'Stubs.swift')],
            swift + ['-typecheck'],
            swift + [str(out/'production.o'), str(out/'fixture.o'), '-framework', 'AppKit', '-o', str(out/'adapter-check')]]
(out/'build-commands.json').write_text(json.dumps(commands, indent=2))
with (out/'build.log').open('w') as log:
    for command in commands:
        subprocess.run(command, stdout=log, stderr=subprocess.STDOUT, check=True)
with (out/'native-safety.log').open('w') as log:
    subprocess.run(['python3', '-m', 'unittest', 'discover', '-s', 'scripts/tests', '-p', 'test_native_check_safety.py', '-v'], cwd=root, stdout=log, stderr=subprocess.STDOUT, check=True)
with (out/'watchdog.log').open('w') as log:
    env = dict(os.environ)
    support.check_routes(out/'adapter-check', env, log, production_helper=False)
    rc = support.run_owned(out/'adapter-check', ['--native-check'], environment=env, log=log, timeout=20, max_instances=1)
    if rc: raise RuntimeError(f'Headless check exit {rc}; {out}')
with (out/'distribution.log').open('w') as log:
    subprocess.run(['python3', 'scripts/validate_distribution.py'], cwd=root, stdout=log, stderr=subprocess.STDOUT, check=True)
with (out/'whitespace.log').open('w') as log:
    for p in inputs:
        completed = subprocess.run(['git', 'diff', '--no-index', '--check', '/dev/null', str(p)], cwd=root, stdout=log, stderr=subprocess.STDOUT)
        if completed.returncode not in (0, 1): raise RuntimeError(f'Whitespace check failed: {p}')
(out/'result.json').write_text(json.dumps({'status':'pass', 'remaining_instances':support.instances(out/'adapter-check'), 'deadline_seconds':20, 'instance_budget':1}, indent=2))
(out/'artifact-hashes.json').write_text(json.dumps({p.name: hashlib.sha256(p.read_bytes()).hexdigest() for p in out.iterdir() if p.is_file()}, indent=2))
print((out/'watchdog.log').read_text(), end='')
