"""Build/sign and prove dispatch without installing, launching UIKit or touching the desktop."""
import argparse
import hashlib
import importlib.util
import json
import os
import plistlib
from pathlib import Path
import shutil
import subprocess
import sys

sys.dont_write_bytecode = True
HERE = Path(__file__).resolve().parent
TESTS = HERE.parent
SOURCE = TESTS.parent / 'skills/mac-computer-use/scripts/mac-cu-src'
sys.path.insert(0, str(TESTS))
import native_check_support as native
sys.path.insert(0, str(SOURCE.parent))
from native_build import run_swift, native_inputs, build_view_capture_resources


def prepare(out, reuse_probe=None, fixture_only=False):
    inputs = [*HERE.glob('*.py'), *HERE.glob('*.swift'), *HERE.glob('*.m'), *HERE.glob('*.h'), * (TESTS / 'view-resident-product').glob('*.swift'), HERE / 'build.sh', HERE / 'Info.plist',
              *SOURCE.glob('*.swift'), *native_inputs(SOURCE),
              TESTS / 'native_check_support.py', TESTS / 'view-hierarchy-prototype/remote_watchdog.py',
              *(TESTS / 'view-hierarchy-prototype').glob('ui_*contract.py'), HERE / 'canonical-call-audit.json',
              TESTS / 'test_view_capture.py', TESTS / 'test_view_edit_backend.py',
              SOURCE.parent / 'setup.py', *(SOURCE.parent / 'view-capture').glob('*')]
    unbuilt = [p for p in inputs if p.parent == SOURCE] if fixture_only else []
    frozen = {str(p.resolve()): hashlib.sha256(p.read_bytes()).hexdigest() for p in inputs if p.is_file() and p not in unbuilt}
    if fixture_only and reuse_probe:
        raise ValueError('fixture-only cannot reuse a whole-host probe')
    subprocess.run([str(HERE / 'build.sh'), str(out)], check=True, timeout=120)
    resources = SOURCE.parent / 'view-capture'
    build_view_capture_resources(out / 'view-capture')
    reused = None
    if not fixture_only:
        main = out / 'main.swift'
        main.write_text(native.isolated_main((SOURCE / 'main.swift').read_text(), 'fixtureSessionProbe()'))
        probe = out / 'session-probe'
        sources = sorted(p for p in SOURCE.glob('*.swift') if p.name != 'main.swift')
        reused = None
        if reuse_probe:
            previous = json.loads((reuse_probe / 'prepared.json').read_text())
            assert previous['dispatchPassed']
            assert (reuse_probe / 'main.swift').read_bytes() == main.read_bytes(), 'canonical generated probe dispatch changed'
            unchanged = [*sources, *native_inputs(SOURCE), HERE / 'session-probe.swift', HERE / 'capture-converter.swift', TESTS / 'view-resident-product/wrapper.swift', reuse_probe / 'session-probe']
            for source in unchanged:
                assert hashlib.sha256(source.read_bytes()).hexdigest() == previous['hashes'][str(source.resolve())], str(source)
            shutil.copy2(reuse_probe / 'session-probe', probe)
            reused = {'from': str(reuse_probe), 'inputsVerifiedUnchanged': len(unchanged),
                      'manifestSHA256': hashlib.sha256((reuse_probe / 'prepared.json').read_bytes()).hexdigest()}
        else:
            run_swift(['swiftc', *map(str, sources), str(HERE / 'session-probe.swift'), str(HERE / 'capture-converter.swift'), str(TESTS / 'view-resident-product/wrapper.swift'), str(main), '-o', str(probe)], check=True, timeout=180)
            subprocess.run(['codesign', '--force', '--sign', '-', str(probe)], check=True, timeout=15)
        subprocess.run(['codesign', '--verify', '--strict', str(probe)], check=True, timeout=15)
    info = plistlib.loads((out / 'HierarchyFixture.app/Info.plist').read_bytes())
    assert info['UISupportedInterfaceOrientations'] == ['UIInterfaceOrientationPortrait']
    scenes = info['UIApplicationSceneManifest']
    assert scenes['UIApplicationSupportsMultipleScenes'] is False
    delegate = scenes['UISceneConfigurations']['UIWindowSceneSessionRoleApplication'][0]['UISceneDelegateClassName']
    symbols = subprocess.check_output(['xcrun', 'nm', '--defined-only', str(out / 'HierarchyFixture.app/HierarchyFixture')], text=True, timeout=5)
    assert '_OBJC_CLASS_$_' + delegate in symbols, 'bundled scene delegate class is missing'
    with (out / 'dispatch.log').open('w') as log:
        if not fixture_only and not reused:
            native.check_routes(probe, dict(os.environ), log)
        guard = out / 'fixture-dispatch'
        subprocess.run(['swiftc', '-parse-as-library', str(HERE / 'entry.swift'), '-o', str(guard)], check=True, timeout=45)
        native.check_routes(guard, dict(os.environ), log, production_helper=False)
        env = dict(os.environ, MAC_CU_FIXTURE_SESSION='headless-guard')
        for argv, environment, expected in [(['--fixture-session', 'headless-guard'], env, 0),
                (['--fixture-session', 'headless-guard'], dict(env, MAC_CU_FIXTURE_CHILD='1'), 64),
                (['--fixture-session', 'wrong'], env, 64)]:
            assert native.run_owned(guard, argv, environment=environment, log=log, timeout=5, max_instances=1) == expected
    # A build cannot attest to a source snapshot that moved while it was compiling.
    for name, digest in frozen.items():
        if hashlib.sha256(Path(name).read_bytes()).hexdigest() != digest:
            raise RuntimeError('preparation input changed during build: ' + name)
    files = [out / 'HierarchyFixture.app/HierarchyFixture', out / 'HierarchyFixture.app/Info.plist',
             out / 'fixture-dispatch', *(out / 'view-capture').glob('*')]
    if not fixture_only:
        files.extend([main, probe])
    hashes = {**frozen, **{str(p.resolve()): hashlib.sha256(p.read_bytes()).hexdigest() for p in files if p.is_file()}}
    manifest = 'fixture-prepared.json' if fixture_only else 'prepared.json'
    (out / manifest).write_text(json.dumps({'hashes': hashes, 'dispatchPassed': True, 'probeReuse': reused,
        'wholeProbeVerified': not fixture_only, 'editQualificationReady': not fixture_only,
        'unbuiltNativeSourceHashes': {str(p.resolve()): hashlib.sha256(p.read_bytes()).hexdigest() for p in unbuilt},
        'sceneDelegateInManifestAndBinary': delegate, 'supportedOrientationPolicy': 'portrait only',
        'UIKitLifecycleLiveVerified': False}, indent=2))
    print('PASS fixture build/sign and entry guards; ' +
          ('whole probe DEFERRED until AX native freeze: ' if fixture_only else 'canonical whole probe compiled and guarded: ') + str(out))


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__, allow_abbrev=False)
    parser.add_argument('output', type=Path)
    parser.add_argument('--reuse-probe-from', type=Path, help='Reuse only the byte-verified, unchanged canonical CLI probe')
    parser.add_argument('--fixture-only', action='store_true', help='Build/sign fixture and prove its entry; no whole-host compile, not runtime-ready')
    args = parser.parse_args()
    if not args.output.is_absolute() or args.output.exists():
        parser.error('output must be an absolute, nonexistent directory')
    prepare(args.output, args.reuse_probe_from.resolve() if args.reuse_probe_from else None, args.fixture_only)
