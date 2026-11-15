#!/usr/bin/env python3
"""Headless preparation verification. Never builds the whole host or runs Simulator."""
import ast
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

sys.dont_write_bytecode = True
HERE = Path(__file__).resolve().parent
TESTS = HERE.parent
ROOT = TESTS.parents[1]
SOURCE = TESTS.parent / 'skills/mac-computer-use/scripts/mac-cu-src'
sys.path.insert(0, str(TESTS))
import native_check_support as native


def main():
    out = Path(tempfile.mkdtemp(prefix='mac-cu-edit-preparation-')).resolve()
    print(out, flush=True)
    records = []
    def run(name, argv, timeout=180):
        log = out / (name + '.log')
        with log.open('w') as stream:
            stream.write(repr([str(a) for a in argv]) + '\n'); stream.flush()
            result = subprocess.run([str(a) for a in argv], stdout=stream, stderr=subprocess.STDOUT, timeout=timeout)
        records.append({'name': name, 'returncode': result.returncode, 'log': str(log)})
        (out / 'checks.json').write_text(json.dumps(records, indent=2))
        if result.returncode:
            raise RuntimeError('FAILED ' + name + ': ' + str(log))
        print('PASS', name, flush=True)
    run('session-regressions', [sys.executable, '-B', '-m', 'unittest', 'discover', '-s', HERE, '-p', 'test_session.py', '-v'])
    run('edit-qualification', [sys.executable, '-B', '-m', 'unittest', 'discover', '-s', HERE, '-p', 'test_edit_qualification.py', '-v'])
    run('native-safety', [sys.executable, '-B', '-m', 'unittest', 'discover', '-s', ROOT / 'scripts/tests', '-p', 'test_native_check_safety.py', '-v'])
    run('fixture-build-sign-guards', [sys.executable, '-B', HERE / 'prepare.py', out / 'fixture', '--fixture-only'])
    # This is the same converter called by session-probe, with the existing
    # canonical wrapper/receipt checks, including the target identity dependency.
    original = (TESTS / 'simulator-view-edit-selfcheck.swift').read_text()
    needle = 'simulatorEditableViewHierarchySnapshot(result: result, target: target.json)'
    assert original.count(needle) >= 4
    text = original.replace(needle, 'fixtureConvertCapture(result)')
    marker = '        let assets = snapshot["assets"] as! [String: [String: Any]]'
    assert text.count(marker) == 1
    text = text.replace(marker, '''        let legacy: [String: Any] = ["schemaVersion": 1, "status": "success", "target": target.json,
            "captureID": capture.uuidString, "captureTime": "2026-11-09T00:00:00Z", "hierarchy": result["hierarchy"]!]
        let legacySnapshot = try fixtureConvertCapture(legacy)
        assert((legacySnapshot["assets"] as! [String: Any]).count == 2)
        for bad in [["schemaVersion": 3], ["schemaVersion": 2, "status": "failed"]] as [[String: Any]] {
            do { _ = try fixtureConvertCapture(bad); fatalError("unsupported conversion accepted") } catch {}
        }
''' + marker)
    source = out / 'converter-and-wrappers.swift'; source.write_text(text)
    binary = out / 'converter-and-wrappers'
    inputs = [SOURCE / 'SimulatorViews.swift', SOURCE / 'SimulatorViewHierarchy.swift', SOURCE / 'SimulatorTargetIdentity.swift', HERE / 'capture-converter.swift',
              TESTS / 'simulator-view-edit-selfcheck.swift']
    before = {str(p): hashlib.sha256(p.read_bytes()).hexdigest() for p in inputs}
    run('focused-swift-compile', ['swiftc', *inputs[:4], source, '-o', binary])
    shutil.copytree(SOURCE.parent / 'view-capture', out / 'view-capture', ignore=shutil.ignore_patterns('__pycache__', '*.pyc'))
    with (out / 'focused-swift-guards.log').open('w') as log:
        env = dict(os.environ, SIMULATOR_UDID='00000000-0000-0000-0000-000000000001')
        native.check_routes(binary, env, log, production_helper=False)
        assert native.run_owned(binary, ['--native-check'], environment=env, log=log, timeout=30, max_instances=1) == 0
        assert not native.instances(binary)
    for path, digest in before.items():
        assert hashlib.sha256(Path(path).read_bytes()).hexdigest() == digest, 'focused input changed during check'
    for file in HERE.glob('*.py'):
        ast.parse(file.read_text(), filename=str(file))
    run('distribution', [sys.executable, '-B', ROOT / 'scripts/validate_distribution.py'])
    run('scoped-diff', ['git', 'diff', '--check', '--', HERE, ROOT / 'docs/design/simulator-view-edit-live-qualification.md'])
    # git diff omits these currently untracked files, so check them explicitly too.
    owned = [*HERE.glob('*'), ROOT / 'docs/design/simulator-view-edit-live-qualification.md']
    for path in owned:
        if path.is_file():
            for line in path.read_text().splitlines():
                assert line.rstrip() == line, 'trailing whitespace: ' + str(path)
    inputs += [*owned, *list((SOURCE.parent / 'view-capture').glob('*')), TESTS / 'native_check_support.py',
               TESTS / 'view-hierarchy-prototype/remote_watchdog.py', TESTS / 'test_view_capture.py',
               TESTS / 'test_view_edit_backend.py', ROOT / 'scripts/tests/test_native_check_safety.py']
    hashes = {str(p.resolve()): hashlib.sha256(p.read_bytes()).hexdigest() for p in inputs if p.is_file()}
    artifacts = {str(p.relative_to(out)): hashlib.sha256(p.read_bytes()).hexdigest() for p in out.rglob('*') if p.is_file()}
    (out / 'source-hashes.json').write_text(json.dumps(hashes, indent=2, sort_keys=True))
    (out / 'artifact-hashes.json').write_text(json.dumps(artifacts, indent=2, sort_keys=True))
    (out / 'qualification.json').write_text(json.dumps({'preparationPassed': True, 'wholeHostBuilt': False,
        'wholeSessionProbeBuilt': False, 'UIKitRuntimeRun': False, 'LLDBAttached': False,
        'globalInstalled': False, 'generalAppQualified': False, 'renderedUIQualified': False,
        'sourceManifest': 'source-hashes.json', 'artifactManifest': 'artifact-hashes.json'}, indent=2))
    print('PASS headless preparation only; root must freeze AX native inputs, rebuild the whole probe, then own runtime:', out)


if __name__ == '__main__':
    main()
