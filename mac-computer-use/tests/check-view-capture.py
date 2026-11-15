#!/usr/bin/env python3
"""Headless production capture contract, UIKit syntax, packaging/build and dispatch guards.

Never launches a GUI or attaches a debugger. All binaries/resources stay in a unique local directory.
"""
import importlib.util
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
import native_check_support
sys.path.insert(0, str(SCRIPTS))
from native_build import run_swift


def module(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    loaded = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(loaded)
    return loaded


def run(argv, **kwargs):
    subprocess.run([str(a) for a in argv], check=True, timeout=180, **kwargs)


run([sys.executable, '-B', '-m', 'unittest', 'discover', '-s', TESTS, '-p', 'test_view_capture.py', '-v'])
capture = module('capture', RESOURCES / 'capture.py')
with tempfile.TemporaryDirectory(prefix='mac-cu-capture-headless-') as temporary:
    out = Path(temporary)
    expression = out / 'expression.mm'
    expression.write_text((RESOURCES / 'imports.h').read_text() + '\nBOOL check(void) { return '
                          + capture.collection_expression(out / 'answer.json') + '; }')
    sdk = subprocess.check_output(['xcrun', '--sdk', 'iphonesimulator', '--show-sdk-path'], text=True).strip()
    run(['xcrun', 'clang', '-fsyntax-only', '-fmodules', '-fcxx-modules', '-fobjc-arc',
         '-target', 'arm64-apple-ios17.0-simulator', '-isysroot', sdk, expression])
    expression.write_text((RESOURCES / 'imports.h').read_text() + '\nBOOL check(void) { return '
                          + capture.collection_expression(out / 'answer.json', True) + '; }')
    run(['xcrun', 'clang', '-fsyntax-only', '-fmodules', '-fcxx-modules', '-fobjc-arc',
         '-target', 'arm64-apple-ios17.0-simulator', '-isysroot', sdk, expression])
    print('PASS actual production UIKit expression syntax (no evaluation)', flush=True)

    texture_check = out / 'texture-contract'
    run(['swiftc', SOURCE / 'SimulatorViewHierarchy.swift', TESTS / 'simulator-view-texture-selfcheck.swift', '-o', texture_check])
    run([texture_check])

    # Invoke the canonical setup builder with only output paths/signing redirected. It never
    # launches the binary, registers sockets or changes installed apps/profiles/permissions.
    setup = module('capture_setup', SCRIPTS / 'setup.py')
    setup.BUNDLE = out / 'ProductionBuild.app'
    setup.SERVER = setup.BUNDLE / 'Contents/MacOS/mac-cu'
    setup.LOCAL = out / 'bare-mac-cu'
    setup.signing_identity = lambda: '-'
    assert setup.build_app()
    run(['/usr/bin/codesign', '--verify', '--strict', setup.BUNDLE])
    bundled = setup.BUNDLE / 'Contents/Resources/view-capture'
    for source in RESOURCES.iterdir():
        if source.is_file():
            assert (bundled / source.name).read_bytes() == source.read_bytes()
    assert not list(bundled.rglob('*.pyc'))
    print('PASS production build/signature and manifest-relative capture resources', flush=True)

    # The Swift API and text/tree path use the packaged resources in an isolated executable.
    shutil.copytree(bundled, out / 'view-capture')
    check = out / 'capture-contract'
    run(['swiftc', SOURCE / 'SimulatorViewHierarchy.swift', SOURCE / 'SimulatorViews.swift', SOURCE / 'SimulatorTargetIdentity.swift',
         TESTS / 'simulator-ax-scope-stub.swift', TESTS / 'simulator-view-hierarchy-selfcheck.swift', '-o', check])
    run([check], env={**os.environ, 'SIMULATOR_UDID': '00000000-0000-0000-0000-000000000001'})

    # Preserve production helper dispatch, reject unknown/inherited routes before AppKit.
    isolated = out / 'guard-source'
    isolated.mkdir()
    main = isolated / 'main.swift'
    main.write_text(native_check_support.isolated_main((SOURCE / 'main.swift').read_text(),
                    'fatalError("GUI entry forbidden in this headless check")'))
    guard = out / 'dispatch-guard'
    sources = [p for p in sorted(SOURCE.glob('*.swift')) if p.name != 'main.swift']
    run_swift(['swiftc', *map(str, sources), str(main), '-o', str(guard)], check=True, timeout=180)
    native_check_support.check_routes(guard, dict(os.environ), sys.stdout)
    assert not native_check_support.instances(guard)
    print('PASS guarded production helper/unknown/inherited routes; no GUI entry', flush=True)
print('PASS headless view capture checks', flush=True)
