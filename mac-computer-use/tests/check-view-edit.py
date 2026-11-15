#!/usr/bin/env python3
"""Focused headless backend checks. Does NOT build the whole host, launch GUI or attach."""
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

sys.dont_write_bytecode = True
TESTS = Path(__file__).resolve().parent
ROOT = TESTS.parents[1]
SCRIPTS = TESTS.parent / 'skills/mac-computer-use/scripts'
SOURCE = SCRIPTS / 'mac-cu-src'
RESOURCES = SCRIPTS / 'view-capture'
sys.path.insert(0, str(TESTS))
import native_check_support as native
sys.path.insert(0, str(SCRIPTS))
from native_build import build_view_capture_resources
spec = importlib.util.spec_from_file_location('view_capture_check', RESOURCES / 'capture.py')
capture = importlib.util.module_from_spec(spec); spec.loader.exec_module(capture)


def main():
    out = Path(tempfile.mkdtemp(prefix='mac-cu-edit-headless-'))
    print(out, flush=True)
    def run(name, args, **kwargs):
        with (out / (name + '.log')).open('w') as log:
            log.write(repr([str(a) for a in args]) + '\n'); log.flush()
            subprocess.run([str(a) for a in args], stdout=log, stderr=subprocess.STDOUT, check=True, timeout=180, **kwargs)
        print('PASS', name, flush=True)
    run('capture-edit', [sys.executable, '-B', '-m', 'unittest', 'discover', '-s', TESTS, '-p', 'test_view*py', '-v'])
    run('session', [sys.executable, '-B', '-m', 'unittest', 'discover', '-s', TESTS / 'view-hierarchy-fixture', '-p', 'test_session.py', '-v'])
    run('native-safety', [sys.executable, '-B', '-m', 'unittest', 'discover', '-s', ROOT / 'scripts/tests', '-p', 'test_native_check_safety.py', '-v'])
    run('production-expression', [sys.executable, '-B', TESTS / 'view-edit-production/run.py'])
    sdk = subprocess.check_output(['xcrun', '--sdk', 'iphonesimulator', '--show-sdk-path'], text=True).strip()
    developer = subprocess.check_output(['xcode-select', '-p'], text=True).strip()
    (out / 'xcode.json').write_text(json.dumps({'developer': developer, 'simulatorSDK': sdk}))
    flags = ['xcrun', 'clang++', '-fsyntax-only', '-fmodules', '-fcxx-modules', '-std=c++17',
             '-target', 'arm64-apple-ios17.0-simulator', '-isysroot', sdk]
    for name, body, ownership in [('metadata', capture.collection_expression(out / 'answer.json'), '-fobjc-arc'),
            ('texture', capture.collection_expression(out / 'answer.json', True), '-fobjc-arc'),
            ('editable', capture.edit_backend.expression({}, out / 'answer.json'), '-fno-objc-arc')]:
        source = out / (name + '.mm')
        source.write_text((RESOURCES / 'imports.h').read_text() + '\n@import ObjectiveC;\nBOOL check(void) { return ' + body + '; }')
        run('syntax-' + name, [*flags, ownership, source])
    # ARC is explicitly unsupported, rather than silently depending on debugger defaults.
    failed = subprocess.run([*flags, '-fobjc-arc', str(out / 'editable.mm')], stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, timeout=60)
    (out / 'syntax-arc-rejection.log').write_text(failed.stdout)
    assert failed.returncode != 0 and 'MacCU_edit_expression_requires_MRC_for_explicit_local_lifetime' in failed.stdout
    build_view_capture_resources(out / 'view-capture')
    with (out / 'swift-run.log').open('w') as log:
        for label, original, sources in [
                ('hierarchy', TESTS / 'simulator-view-hierarchy-selfcheck.swift', ['SimulatorViewHierarchy.swift', 'SimulatorViews.swift', 'SimulatorTargetIdentity.swift']),
                ('textures', TESTS / 'simulator-view-texture-selfcheck.swift', ['SimulatorViewHierarchy.swift']),
                ('editable', TESTS / 'simulator-view-edit-selfcheck.swift', ['SimulatorViewHierarchy.swift', 'SimulatorViews.swift', 'SimulatorTargetIdentity.swift'])]:
            swift = original
            if label != 'editable':
                # Add only headless argv guards to existing selfchecks. Their actual
                # assertions/conversion/helper implementations remain unchanged.
                text = original.read_text().replace('CommandLine.arguments', 'fixtureArguments')
                entry = 'static func main() throws {'
                assert text.count(entry) == 1
                guard = '''static func main() throws {
        guard CommandLine.arguments.count >= 2, CommandLine.arguments[1] == "--native-check",
              getenv("MAC_CU_NATIVE_CHECK_CHILD") == nil else { exit(64) }
        let fixtureArguments = [CommandLine.arguments[0]] + Array(CommandLine.arguments.dropFirst(2))
        _ = fixtureArguments
'''
                swift = out / (label + '.swift'); swift.write_text(text.replace(entry, guard))
            binary = out / label
            scope = [TESTS / 'simulator-ax-scope-stub.swift'] if 'SimulatorViews.swift' in sources else []
            run('swift-compile-' + label, ['swiftc', *(SOURCE / n for n in sources), *scope, swift, '-o', binary])
            environment = dict(os.environ, SIMULATOR_UDID='00000000-0000-0000-0000-000000000001')
            native.check_routes(binary, environment, log, production_helper=False)
            assert native.run_owned(binary, ['--native-check'], environment=environment, log=log, timeout=30, max_instances=1) == 0
            assert not native.instances(binary)
    run('distribution', [sys.executable, '-B', ROOT / 'scripts/validate_distribution.py'])
    run('scoped-diff', ['git', 'diff', '--check', '--', str(SOURCE / 'SimulatorViews.swift'), str(SOURCE / 'SimulatorViewHierarchy.swift'),
                       str(RESOURCES), str(TESTS / 'check-view-capture.py'), str(TESTS / 'view-hierarchy-fixture/prepare.py')])
    inputs = [SOURCE / 'SimulatorViews.swift', SOURCE / 'SimulatorTargetIdentity.swift', SOURCE / 'SimulatorViewHierarchy.swift', *RESOURCES.glob('*'),
              TESTS / 'test_view_capture.py', TESTS / 'test_view_edit_backend.py', TESTS / 'simulator-view-edit-selfcheck.swift', TESTS / 'simulator-ax-scope-stub.swift', Path(__file__),
              *list((TESTS / 'view-edit-production').glob('*'))]
    (out / 'sha256.json').write_text(json.dumps({str(p): hashlib.sha256(p.read_bytes()).hexdigest() for p in inputs if p.is_file()}, indent=2))
    print('PASS focused backend checks; no full host build, GUI, Simulator or LLDB attachment:', out, flush=True)


if __name__ == '__main__':
    main()
