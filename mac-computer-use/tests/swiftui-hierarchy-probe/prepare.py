"""별도 Swift 모듈, resident callback, 일반 SwiftUI 앱을 빌드하고 진입 경로를 검증한다."""
import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import plistlib
import re
import subprocess
import sys
import uuid

sys.dont_write_bytecode = True
HERE = Path(__file__).resolve().parent
TESTS = HERE.parent
FIXTURE = TESTS / 'view-hierarchy-fixture'
sys.path.insert(0, str(TESTS))
import native_check_support as native
sys.path.insert(0, str(HERE))
import worker_runtime

def sha(p):
    return hashlib.sha256(Path(p).read_bytes()).hexdigest()

def prepare(out, reuse, compile_only=False):
    out.mkdir(mode=0o700)
    logs = out / 'logs'; logs.mkdir(mode=0o700)
    # 빌드 및 fixture 준비 전에 실제 독립 worker를 검증한다.
    runtime_proof = worker_runtime.prove()
    (out / 'worker-runtime.json').write_text(json.dumps(runtime_proof, indent=2) + '\n')
    commands = []
    def run(label, args, timeout=90, env=None):
        commands.append(dict(label=label, args=list(map(str, args)), timeout=timeout))
        with (logs / (label + '.log')).open('w') as log:
            result = subprocess.run(commands[-1]['args'], stdout=log, stderr=subprocess.STDOUT, timeout=timeout, env=env)
        commands[-1]['returncode'] = result.returncode
        (out / 'commands.json').write_text(json.dumps(commands, indent=2))
        if result.returncode: raise RuntimeError('failed: ' + str(logs / (label + '.log')))
        return (logs / (label + '.log')).read_text().strip()

    # Freeze all transitive parser/request/build inputs before compilation.
    parser_source = TESTS.parent / 'skills/mac-computer-use/scripts/view-capture/swiftui_graph.py'
    capture_source = parser_source.with_name('capture.py')
    build_inputs = list(HERE.glob('*')) + list(parser_source.parent.glob('*.py')) + list(FIXTURE.glob('*.py')) + list((TESTS / 'view-resident-lifetime').glob('*.py')) + [parser_source, capture_source,
        parser_source.parent.parent / 'native_build.py',
        TESTS / 'native_check_support.py', FIXTURE / 'prepare.py', FIXTURE / 'Info.plist']
    frozen = {str(p.resolve()): sha(p) for p in build_inputs if p.is_file()}
    root = HERE.parents[2]
    base = out / 'base'
    if compile_only:
        # A build-only result cannot pass session.verify_prepared or runtime admission.
        if reuse: raise ValueError('compile-only cannot reuse a whole host')
        base.mkdir()
        (base / 'entitlements.plist').write_bytes(plistlib.dumps({'com.apple.security.get-task-allow': True}))
    else:
        run('native-safety', [sys.executable, '-B', '-m', 'unittest', 'discover', '-s', str(root / 'scripts/tests'),
                             '-p', 'test_native_check_safety.py', '-v'], 120)
        run('whole-host', [sys.executable, '-B', FIXTURE / 'prepare.py', base,
                          *(['--reuse-probe-from', reuse] if reuse else [])], 300)
        # Reuse proves bytes; current helper/unknown/inherited dispatch is run again under watchdog.
        with (logs / 'current-dispatch.log').open('w') as log:
            native.check_routes(base / 'session-probe', dict(os.environ), log)
    sdk = subprocess.check_output(['xcrun', '--sdk', 'iphonesimulator', '--show-sdk-path'], text=True).strip()
    common = ['-target', 'arm64-apple-ios17.0-simulator', '-sdk', sdk, '-parse-as-library']
    run('bridge-typecheck', ['xcrun', 'swiftc', *common, '-typecheck', HERE / 'Bridge.swift'])
    run('bridge-object', ['xcrun', 'swiftc', *common, '-module-name', 'ProbeBridge', '-emit-object',
        '-emit-objc-header-path', out / 'ProbeBridge-Swift.h', HERE / 'Bridge.swift', '-o', out / 'Bridge.o'])
    resource = TESTS.parent / 'skills/mac-computer-use/scripts/view-capture'
    spec = importlib.util.spec_from_file_location('probe_capture', resource / 'capture.py')
    module = importlib.util.module_from_spec(spec); spec.loader.exec_module(module)
    request = json.dumps(module.hierarchy_request(True), separators=(',', ':'))
    (out / 'texture-request.h').write_text('#define PROBE_TEXTURE_REQUEST ' + json.dumps(request) + '\n')
    run('resident-object', ['xcrun', 'clang', '-target', 'arm64-apple-ios17.0-simulator', '-isysroot', sdk,
        '-std=c11', '-fno-objc-arc', '-fobjc-exceptions', '-Wall', '-Wextra', '-Werror', '-I', out,
        '-include', out / 'texture-request.h', '-c', HERE / 'resident.m', '-o', out / 'resident.o'])
    image = out / 'resident-simulator.dylib'
    run('helper-link', ['xcrun', '--sdk', 'iphonesimulator', 'swiftc', *common, '-emit-library', out / 'Bridge.o', out / 'resident.o',
        '-framework', 'UIKit', '-framework', 'SwiftUI', '-Xlinker', '-install_name', '-Xlinker',
        '@rpath/swiftui-probe-resident.dylib', '-o', image])
    run('helper-sign', ['codesign', '--force', '--sign', '-', image])
    run('helper-verify', ['codesign', '--verify', '--strict', image])
    helper_uuid = re.search(r'UUID: ([A-F0-9-]{36})', run('helper-uuid', ['xcrun', 'dwarfdump', '--uuid', image]))[1]
    assert run('helper-arch', ['xcrun', 'lipo', '-archs', image]) == 'arm64'
    loads = run('helper-load-commands', ['xcrun', 'otool', '-l', image])
    assert re.search(r'platform\s+(7|IOSSIMULATOR)', loads)
    run('helper-symbols', ['xcrun', 'nm', '-gU', image])
    app = base / 'SwiftUIProbe.app'; app.mkdir()
    bundle = 'local.mac-pilot.swiftui-probe.' + uuid.uuid4().hex
    info = plistlib.loads((FIXTURE / 'Info.plist').read_bytes())
    info.update(CFBundleExecutable='SwiftUIProbe', CFBundleIdentifier=bundle, CFBundleName='SwiftUI Probe')
    del info['UIApplicationSceneManifest']
    (app / 'Info.plist').write_bytes(plistlib.dumps(info))
    run('fixture-build', ['xcrun', 'swiftc', *common, '-module-name', 'SwiftUIProbe', HERE / 'Fixture.swift', '-o', app / 'SwiftUIProbe'])
    run('fixture-sign', ['codesign', '--force', '--sign', '-', '--entitlements', base / 'entitlements.plist', app])
    run('fixture-verify', ['codesign', '--verify', '--strict', app])
    links = run('fixture-links', ['xcrun', 'otool', '-L', app / 'SwiftUIProbe'])
    assert all('ProbeBridge' not in line and 'resident' not in line and 'mac-cu' not in line
               for line in links.splitlines()[1:])
    symbols = run('fixture-symbols', ['xcrun', 'nm', '-gU', app / 'SwiftUIProbe'])
    assert 'externalDebugBytes' not in symbols and 'viewDebugData' not in symbols
    env = {k:v for k,v in os.environ.items() if not k.startswith(('MAC_CU_', 'DYLD_', 'PYTHON', 'RESIDENT_'))}
    env.update(RESIDENT_PREPARE_OUTPUT=str(out), RESIDENT_SELECTED_SDK=sdk)
    run('no-target', ['xcrun', 'lldb', '--no-lldbinit', '--batch', '-o',
        'command script import ' + str(HERE / 'no_target.py')], 45, env)
    assert json.loads((out / 'no-target.json').read_text())['passed']
    for name, digest in frozen.items(): assert sha(name) == digest, 'probe input changed: ' + name
    ready = (dict(hashes={}, dispatchPassed=False, wholeProbeVerified=False, editQualificationReady=False)
             if compile_only else json.loads((base / 'prepared.json').read_text()))
    extra = [image, app / 'SwiftUIProbe', app / 'Info.plist', out / 'ProbeBridge-Swift.h', out / 'texture-request.h']
    extra += [p for p in (TESTS / 'view-resident-lifetime').glob('*.py')]
    developer = Path(subprocess.check_output(['xcode-select', '-p'], text=True).strip())
    extra += [(developer.parent / 'SharedFrameworks/LLDB.framework/LLDB').resolve(),
        (developer.parent / 'SharedFrameworks/LLDB.framework/Resources/debugserver').resolve(), Path(sdk) / 'SDKSettings.json']
    ready['hashes'].update(frozen); ready['hashes'].update({str(p.resolve()): sha(p) for p in extra})
    worker_runtime.verify(runtime_proof)
    ready['swiftUIProbe'] = dict(workerRuntime=runtime_proof, bundleID=bundle, helper=str(image), helperUUID=helper_uuid, helperSHA256=sha(image),
        appSHA256=sha(app / 'SwiftUIProbe'), sdk=sdk, separateModule=True, appGraphCalls=0)
    (base / 'prepared.json').write_text(json.dumps(ready, indent=2) + '\n')
    print(('COMPILED ONLY, RUNTIME REFUSED ' if compile_only else 'PREPARED ') + str(base))

if __name__ == '__main__':
    parser = argparse.ArgumentParser(allow_abbrev=False)
    parser.add_argument('output', type=Path); parser.add_argument('--reuse-probe-from', type=Path)
    parser.add_argument('--compile-only', action='store_true', help='No runtime-ready manifest; never skips a live gate')
    args = parser.parse_args()
    if not args.output.is_absolute() or args.output.exists(): parser.error('unique absolute output required')
    prepare(args.output, args.reuse_probe_from, args.compile_only)
