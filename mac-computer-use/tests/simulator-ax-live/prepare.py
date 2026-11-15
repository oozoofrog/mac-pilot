#!/usr/bin/env python3
"""Build a disposable fixture and exercise only its non-UIKit entry guard."""
import hashlib
import json
import os
import plistlib
import subprocess
import sys
from pathlib import Path

here = Path(__file__).resolve().parent
sys.path.insert(0, str(here.parent))
import native_check_support as native

if len(sys.argv) != 2 or not Path(sys.argv[1]).is_absolute() or Path(sys.argv[1]).exists():
    raise SystemExit('usage: prepare.py /absolute/nonexistent-output-directory')
out = Path(sys.argv[1])
subprocess.run([str(here / 'build.sh'), str(out)], check=True, timeout=120)
app = out / 'AXLiveFixture.app'
info = plistlib.loads((app / 'Info.plist').read_bytes())
delegate = info['UIApplicationSceneManifest']['UISceneConfigurations']['UIWindowSceneSessionRoleApplication'][0]['UISceneDelegateClassName']
symbols = subprocess.check_output(['xcrun', 'nm', '--defined-only', str(app / 'AXLiveFixture')], text=True, timeout=10)
assert '_OBJC_CLASS_$_' + delegate in symbols
guard = out / 'fixture-dispatch'
subprocess.run(['swiftc', '-parse-as-library', str(here / 'entry.swift'), '-o', str(guard)], check=True, timeout=45)
with (out / 'dispatch.log').open('w') as log:
    native.check_routes(guard, dict(os.environ), log, production_helper=False)
    env = dict(os.environ, MAC_CU_AX_FIXTURE_SESSION='headless-guard')
    for args, environ, expected in [(['--fixture-session', 'headless-guard'], env, 0),
            (['--fixture-session', 'headless-guard'], dict(env, MAC_CU_AX_FIXTURE_CHILD='1'), 64),
            (['--fixture-session', 'wrong'], env, 64)]:
        assert native.run_owned(guard, args, environment=environ, log=log, timeout=5, max_instances=1) == expected
files = [*here.glob('*.swift'), here / 'Info.plist', here / 'build.sh', here / 'prepare.py', here.parent / 'native_check_support.py', app / 'AXLiveFixture', app / 'Info.plist', guard]
hashes = {str(p.resolve()): hashlib.sha256(p.read_bytes()).hexdigest() for p in files}
(out / 'prepared.json').write_text(json.dumps({'sha256': hashes, 'sceneDelegate': delegate, 'guestLaunched': False, 'liveRunnerPrepared': False}, indent=2))
print('PASS fixture build/sign, scene metadata, and headless dispatch guards:', out)

sys.path.insert(0, str(here.parents[1] / 'skills/mac-computer-use/scripts'))
from native_build import run_swift, native_inputs
source = here.parents[1] / 'skills/mac-computer-use/scripts/mac-cu-src'
main = out / 'main.swift'
main.write_text(native.isolated_main((source / 'main.swift').read_text(), 'axLiveProbe()'))
sources = sorted(p for p in source.glob('*.swift') if p.name != 'main.swift')
original_probe = here.parent / 'view-hierarchy-fixture/session-probe.swift'
frozen_session = out / 'frozen-session.py'
shared_session = here.parent / 'view-hierarchy-fixture/session.py'
frozen_session.write_text(shared_session.read_text().replace('HERE = Path(__file__).resolve().parent', 'HERE = Path(' + repr(str(shared_session.parent)) + ')'))
probe_source = out / 'baseline.swift'
baseline = original_probe.read_text()
start = baseline.index('        if let file = env["FIXTURE_CAPTURE_RESULT"]')
end = baseline.index('            guard let id = env["FIXTURE_DEVICE"]', start)
baseline = baseline[:start] + '        if env["FIXTURE_CAPTURE_RESULT"] != nil { throw ToolError("AX baseline cannot convert captures") } else {\n' + baseline[end:]
probe_source.write_text(baseline.replace('simulatorViewCaptureTarget(pid: pid, deviceID: id)', 'axLiveTarget(pid: pid, deviceID: id)'))
compiled_inputs = [*sources, *native_inputs(source), probe_source, frozen_session, here / 'host-probe.swift', here.parent / 'simulator-inspector-live-check.swift', main, source / 'main.swift']
frozen = {str(p.resolve()): hashlib.sha256(p.read_bytes()).hexdigest() for p in compiled_inputs}
(out / 'frozen-compiled-inputs.json').write_text(json.dumps(frozen, indent=2))
with (out / 'host-build.log').open('w') as log:
    command = ['swiftc', '-D', 'SAX_LIVE_VALIDATION', *map(str, sources), str(probe_source), str(here / 'host-probe.swift'), str(here.parent / 'simulator-inspector-live-check.swift'), str(main), '-o', str(out / 'session-probe')]
    (out / 'host-command.json').write_text(json.dumps(command, indent=2))
    run_swift(command, stdout=log, stderr=subprocess.STDOUT, check=True, timeout=180)
for name, digest in frozen.items():
    assert hashlib.sha256(Path(name).read_bytes()).hexdigest() == digest, 'compiled input changed during build: ' + name
subprocess.run(['codesign', '--force', '--sign', '-', str(out / 'session-probe')], check=True, timeout=15)
with (out / 'native-safety.log').open('w') as log:
    subprocess.run(['python3', '-m', 'unittest', 'discover', '-s', 'scripts/tests', '-p', 'test_native_check_safety.py', '-v'], stdout=log, stderr=subprocess.STDOUT, check=True, timeout=90)
with (out / 'host-dispatch.log').open('w') as log:
    native.check_routes(out / 'session-probe', dict(os.environ), log)
# Each build gets a unique guest identity, signed again after plist update.
import uuid
bundle = 'local.mac-pilot.ax-live-fixture.' + uuid.uuid4().hex
info['CFBundleIdentifier'] = bundle
(app / 'Info.plist').write_bytes(plistlib.dumps(info))
subprocess.run(['codesign', '--force', '--sign', '-', '--entitlements', str(out / 'entitlements.plist'), str(app)], check=True, timeout=15)
subprocess.run(['codesign', '--verify', '--strict', str(app)], check=True, timeout=15)
files += [here / 'assess.py', *sources, *native_inputs(source), probe_source, frozen_session, here / 'host-probe.swift', here.parent / 'simulator-inspector-live-check.swift', here / 'session.py', frozen_session, main, out / 'session-probe', source / 'main.swift']
(out / 'prepared.json').write_text(json.dumps({'hashes': {str(p.resolve()): hashlib.sha256(p.read_bytes()).hexdigest() for p in files}, 'bundle': bundle, 'dispatchPassed': True, 'semanticQualified': False}, indent=2))
(out / 'toolchain.txt').write_text(subprocess.check_output(['xcode-select', '-p'], text=True) + subprocess.check_output(['xcodebuild', '-version'], text=True) + subprocess.check_output(['xcrun', '--sdk', 'iphonesimulator', '--show-sdk-version'], text=True))
print('PASS canonical production host build/sign and helper/unknown/inherited dispatch:', out)
