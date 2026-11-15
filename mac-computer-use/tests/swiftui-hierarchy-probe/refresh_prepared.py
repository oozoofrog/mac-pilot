"""Reuse one reviewed successful SwiftUI preparation; never compile or launch LLDB.

Boundary: the seven CONTROLLER_DRIFT paths are not read by either build recipe or
by no_target -> debugger -> protocol/worker_runtime/capture -> edit_backend.
All other historical pins must match. REQUIRED_INPUTS closes the declared local
compile/proof imports; current source inventories close newly added build inputs.
The selected worker verifier binds Python/Xcode/LLDB, and SDKSettings plus the
resident-build compiler pin bind declared SDK/toolchain identities. This is not a
claim that every SDK header is immutable, or that hash-then-exec is atomic.

The reviewed artifact manifest is the trust anchor, not proof of current process
state. Its outer successful preparation exit is required in addition to all 18
command exits. Old no-target bytes stay historical. Only guards run afresh.
Importing this module performs no I/O, subprocess work, or local-module imports.
"""
import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import plistlib
import stat
import struct
import subprocess
import sys
import uuid

PREFIX = 'mac-computer-use/tests/'
CONTROLLER_DRIFT = frozenset(PREFIX + n for n in (
    'view-hierarchy-fixture/test_probe_family.py', 'view-hierarchy-fixture/test_session.py',
    'view-hierarchy-fixture/session.py', 'view-hierarchy-prototype/remote_watchdog.py',
    'swiftui-hierarchy-probe/runner.py', 'view-resident-lifetime/runner.py',
    'view-resident-lifetime/test_runner.py'))
REQUIRED_INPUTS = frozenset(PREFIX + n for n in (
    'swiftui-hierarchy-probe/prepare.py', 'swiftui-hierarchy-probe/Bridge.swift',
    'swiftui-hierarchy-probe/Fixture.swift', 'swiftui-hierarchy-probe/resident.m',
    'swiftui-hierarchy-probe/resident.h', 'swiftui-hierarchy-probe/capture.inc',
    'swiftui-hierarchy-probe/no_target.py', 'swiftui-hierarchy-probe/debugger.py',
    'swiftui-hierarchy-probe/protocol.py', 'swiftui-hierarchy-probe/worker_runtime.py',
    'view-hierarchy-fixture/prepare.py', 'view-hierarchy-fixture/build.sh',
    'view-hierarchy-fixture/Info.plist', 'view-hierarchy-fixture/entry.swift',
    'view-hierarchy-fixture/main.swift', 'view-hierarchy-fixture/edit-oracle.swift',
    'view-hierarchy-fixture/fault-target.m', 'view-hierarchy-fixture/fault-target.h',
    'view-hierarchy-fixture/session-probe.swift', 'view-hierarchy-fixture/capture-converter.swift',
    'view-resident-product/wrapper.swift', 'native_check_support.py')) | frozenset(
    'mac-computer-use/skills/mac-computer-use/scripts/' + n for n in (
        'native_build.py', 'view-capture/capture.py', 'view-capture/edit_backend.py'))
COMMANDS = tuple((n, 120 if n == 'native-safety' else 300 if n == 'whole-host' else
                  45 if n == 'no-target' else 90) for n in (
    'native-safety', 'whole-host', 'bridge-typecheck', 'bridge-object', 'resident-object',
    'helper-link', 'helper-sign', 'helper-verify', 'helper-uuid', 'helper-arch',
    'helper-load-commands', 'helper-symbols', 'fixture-build', 'fixture-sign',
    'fixture-verify', 'fixture-links', 'fixture-symbols', 'no-target'))
REQUIRED_ARTIFACTS = frozenset((
    'base/view-capture/resident-build.json', 'base/view-capture/mac-cu-resident-v2.dylib',
    'resident-simulator.dylib', 'ProbeBridge-Swift.h', 'texture-request.h',
    'base/session-probe', 'base/fixture-dispatch', 'base/main.swift', 'base/entitlements.plist',
    'base/HierarchyFixture.app/HierarchyFixture', 'base/HierarchyFixture.app/Info.plist',
    'base/HierarchyFixture.app/_CodeSignature/CodeResources',
    'base/SwiftUIProbe.app/SwiftUIProbe', 'base/SwiftUIProbe.app/Info.plist',
    'base/SwiftUIProbe.app/_CodeSignature/CodeResources'))
LIMIT = 4 * 1024 * 1024


def require(ok, message):
    if not ok: raise ValueError(message)


def sha(path):
    h = hashlib.sha256()
    with Path(path).open('rb') as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b''): h.update(block)
    return h.hexdigest()


def bounded_bytes(path):
    with Path(path).open('rb') as stream: data = stream.read(LIMIT + 1)
    require(len(data) <= LIMIT, 'oversized metadata: ' + str(path))
    return data


def metadata(path):
    return json.loads(bounded_bytes(path))


def safe_file(path, root):
    """Reject lexical escape and every symlink component inside the custody root."""
    require(path.is_absolute() and '..' not in path.parts, 'unsafe path: ' + str(path))
    require(path.is_relative_to(root), 'path outside source root: ' + str(path))
    for component in (path, *path.parents):
        require(not component.is_symlink(), 'symlink in artifact path: ' + str(path))
        if component == root: break
    require(stat.S_ISREG(path.stat().st_mode), 'not a regular file: ' + str(path))


def macho_uuid(path):
    # The canonical helper is a thin arm64 Mach-O, not an arbitrary architecture cache.
    with path.open('rb') as stream:
        header = stream.read(32)
        require(len(header) == 32, 'short Mach-O header')
        magic, cpu, _, _, count, size, _, _ = struct.unpack('<8I', header)
        require(magic == 0xfeedfacf and cpu == 0x100000c and size <= LIMIT,
                'helper is not thin arm64 Mach-O')
        commands = stream.read(size)
    offset = 0; found = []
    for _ in range(count):
        require(offset + 8 <= len(commands), 'truncated load command')
        kind, length = struct.unpack_from('<II', commands, offset)
        require(length >= 8 and offset + length <= len(commands), 'invalid load command')
        if kind == 0x1b:
            require(length == 24, 'invalid UUID command')
            found.append(str(uuid.UUID(bytes=commands[offset+8:offset+24])).upper())
        offset += length
    require(offset == size and len(found) == 1, 'missing or duplicate helper UUID')
    return found[0]


def declared_inputs(repo):
    result = {repo / n for n in REQUIRED_INPUTS | CONTROLLER_DRIFT}
    tests = repo / 'mac-computer-use/tests'
    scripts = repo / 'mac-computer-use/skills/mac-computer-use/scripts'
    for directory, patterns in (
        (tests/'view-hierarchy-fixture', ('*.py', '*.swift', '*.m', '*.h')),
        (tests/'view-resident-product', ('*.swift',)),
        (tests/'view-resident-lifetime', ('*.py',)),
        (tests/'swiftui-hierarchy-probe', ('*',)),
        (scripts/'mac-cu-src', ('*.swift', '*.h', '*.m')),
        (scripts/'view-capture', ('*',))):
        for pattern in patterns:
            result.update(p for p in directory.glob(pattern) if p.is_file() and
                          p.name not in ('refresh_prepared.py', 'test_preparation_reuse.py'))
    return result


def load_local(path, name):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec); spec.loader.exec_module(module)
    return module


def verify_runtime(proof, repo, sdk):
    # verify(), unlike prove(), never launches a Python LLDB import worker.
    worker = load_local(repo / (PREFIX+'swiftui-hierarchy-probe/worker_runtime.py'), 'refresh_worker')
    worker.verify(proof)
    selected = subprocess.check_output(['/usr/bin/xcrun', '--sdk', 'iphonesimulator', '--show-sdk-path'],
                                       text=True, timeout=3).strip()
    require(Path(selected).resolve(strict=True) == Path(sdk).resolve(strict=True), 'selected SDK changed')


def current_guards(base, repo, logs):
    native = load_local(repo / (PREFIX+'native_check_support.py'), 'refresh_native')
    with (logs/'current-native-safety.log').open('x') as log:
        subprocess.run([sys.executable, '-B', '-m', 'unittest', 'discover', '-s',
                        str(repo/'scripts/tests'), '-p', 'test_native_check_safety.py', '-v'],
                       stdout=log, stderr=subprocess.STDOUT, check=True, timeout=120)
    with (logs/'current-dispatch.log').open('x') as log:
        env = {k:v for k,v in os.environ.items() if not k.startswith(('MAC_CU_', 'DYLD_', 'PYTHON', 'RESIDENT_'))}
        native.check_routes(base/'session-probe', env, log)
        native.check_routes(base/'fixture-dispatch', env, log, production_helper=False)
        environment = dict(env, MAC_CU_FIXTURE_SESSION='headless-guard')
        for argv, child_env, expected in (
            (['--fixture-session', 'headless-guard'], environment, 0),
            (['--fixture-session', 'headless-guard'], dict(environment, MAC_CU_FIXTURE_CHILD='1'), 64),
            (['--fixture-session', 'wrong'], environment, 64)):
            require(native.run_owned(base/'fixture-dispatch', argv, environment=child_env,
                                     log=log, timeout=5, max_instances=1) == expected,
                    'fixture entry guard failed')
    # run_owned raises if its owned cleanup cannot be established. Never catch it.
    return dict(passed=True, cleanupResolved=True, watchdogSeconds=5, maxInstances=1)


def refresh(source, artifact_manifest, expected_sha256, output, *, repo=None):
    repo = Path(repo) if repo else Path(__file__).resolve().parents[3]
    source, artifact_manifest, output = map(Path, (source, artifact_manifest, output))
    require(source.is_absolute() and source == source.resolve(strict=True), 'canonical absolute source required')
    root = source.parent
    require(artifact_manifest == root/'artifact-manifest.json', 'enclosing artifact manifest required')
    safe_file(artifact_manifest, root)
    require(sha(artifact_manifest) == expected_sha256, 'artifact manifest digest mismatch')
    artifacts = metadata(artifact_manifest)
    require(isinstance(artifacts, dict) and 0 < len(artifacts) <= 4096, 'invalid artifact inventory')
    for name, digest in artifacts.items():
        path = Path(name); safe_file(path, root)
        require(sha(path) == digest, 'artifact hash mismatch: ' + name)
    def evidence(path):
        require(str(path) in artifacts, 'missing custody evidence: ' + str(path))
        return metadata(path)
    ready = evidence(source/'base/prepared.json')
    require(all(ready.get(k) is True for k in ('dispatchPassed', 'wholeProbeVerified', 'editQualificationReady')),
            'incomplete whole preparation')
    require('swiftUIProbe' in ready and isinstance(ready.get('hashes'), dict), 'missing SwiftUI completion')
    require(evidence(root/'preparation-exit.json') == {'returncode': 0}, 'outer preparation did not exit successfully')
    invocation = evidence(root/'preparation-command.json')
    require(isinstance(invocation, list) and str(source) in invocation and
            any(str(a).endswith('swiftui-hierarchy-probe/prepare.py') for a in invocation), 'missing preparation custody')
    commands = evidence(source/'commands.json')
    require([(c.get('label'), c.get('timeout')) for c in commands] == list(COMMANDS) and
            all(type(c.get('returncode')) is int and c['returncode'] == 0 for c in commands),
            'incomplete, timed-out, or nonzero preparation commands')
    proof = evidence(source/'no-target.json'); swift = ready['swiftUIProbe']
    require(proof.get('passed') is True and proof.get('processCreated') is False and
            proof.get('guestLoaded') is False and not proof.get('error'), 'invalid no-target proof')
    helper = source/'resident-simulator.dylib'
    require(swift.get('helper') == str(helper) and swift.get('helperSHA256') == sha(helper) and
            swift.get('helperUUID') == proof.get('moduleUUID') == macho_uuid(helper), 'helper identity mismatch')
    require(swift.get('appSHA256') == sha(source/'base/SwiftUIProbe.app/SwiftUIProbe'), 'app hash mismatch')
    info = plistlib.loads(bounded_bytes(source/'base/SwiftUIProbe.app/Info.plist'))
    require(info.get('CFBundleIdentifier') == swift.get('bundleID') and
            str(swift.get('bundleID')).startswith('local.mac-pilot.swiftui-probe.') and
            info.get('CFBundleExecutable') == 'SwiftUIProbe', 'app identity mismatch')
    require(proof.get('compiler', {}).get('executable') == str(helper) and
            Path(proof['compiler']['sdkPath']).resolve(strict=True) == Path(swift['sdk']).resolve(strict=True),
            'proof compiler binding mismatch')
    require(evidence(source/'worker-runtime.json') == swift.get('workerRuntime'), 'worker proof mismatch')
    build = evidence(source/'base/view-capture/resident-build.json')
    require(build.get('abi') == 2 and build.get('architecture') == 'arm64', 'missing resident build provenance')
    require(build.get('developer') == swift['workerRuntime'].get('context', {}).get('developer'),
            'resident developer binding mismatch')
    require(Path(build['sdk']).resolve(strict=True) == Path(swift['sdk']).resolve(strict=True) and
            sha(Path(build['sdk'])/'SDKSettings.json') == build.get('sdkSHA256'), 'resident SDK binding mismatch')
    compiler = Path(build['command'][0])
    require(compiler.is_absolute() and sha(compiler) == build.get('compilerSHA256'), 'resident compiler changed')
    packaged = source/'base/view-capture/mac-cu-resident-v2.dylib'
    require(build.get('image') == packaged.name and build.get('sha256') == sha(packaged) and
            build.get('uuid') == macho_uuid(packaged), 'packaged resident identity mismatch')
    framework = Path(build['developer']).parent/'SharedFrameworks/LLDB.framework'
    toolpins = {str(compiler): build['compilerSHA256']}
    for relative, key in (('LLDB', 'lldbSHA256'), ('Resources/debugserver', 'debugserverSHA256')):
        path = framework/relative
        require(sha(path) == build.get(key), 'resident toolchain changed: ' + relative)
        toolpins[str(path.resolve(strict=True))] = build[key]
    pins = ready['hashes']; current = dict(toolpins); drift = {}
    for name, digest in build.get('sources', {}).items():
        path = repo/'mac-computer-use/skills/mac-computer-use/scripts/view-capture'/name
        require('/' not in name and name not in ('.', '..') and pins.get(str(path.resolve())) == digest,
                'resident source provenance mismatch')
    require(all(str(p.resolve()) in pins for p in declared_inputs(repo)), 'missing declared compile/proof input pin')
    for name, digest in pins.items():
        path = Path(name)
        if path.is_relative_to(source):
            require(name in artifacts and artifacts[name] == digest, 'unpinned source artifact')
        actual = sha(path)
        if actual != digest:
            require(path.is_relative_to(repo) and str(path.relative_to(repo)) in CONTROLLER_DRIFT,
                    'unexpected source/toolchain drift: ' + name)
            drift[name] = dict(previous=digest, current=actual)
        current[name] = actual
    require(str((Path(swift['sdk'])/'SDKSettings.json').resolve()) in
            {str(Path(n).resolve()) for n in pins}, 'missing SDK identity pin')
    required = {source/n for n in REQUIRED_ARTIFACTS}
    required.update(Path(n) for n in pins if Path(n).is_relative_to(source))
    # Signed app resource envelopes and packaged capture resources must be complete.
    for directory in (source/'base/HierarchyFixture.app', source/'base/SwiftUIProbe.app', source/'base/view-capture'):
        required.update(p for p in directory.rglob('*') if not p.is_dir())
    required.update((source/'no-target.json', source/'commands.json', source/'worker-runtime.json'))
    for path in required:
        safe_file(path, root)
        require(str(path) in artifacts, 'required copy lacks custody pin: ' + str(path))
    # Freeze current guards (including their test implementation) and this utility too.
    extra = [Path(__file__).resolve(), * (repo/'scripts/tests').glob('test_native_check_safety.py')]
    current.update({str(p): sha(p) for p in extra})
    require(output.is_absolute() and '..' not in output.parts and not output.exists() and not output.is_symlink(),
            'unique absolute nonexistent output required')
    require(output.parent == output.parent.resolve(strict=True) and not output.is_relative_to(root) and
            not output.is_relative_to(repo), 'output must be a separate private directory')
    verify_runtime(swift['workerRuntime'], repo, swift['sdk'])
    output.mkdir(mode=0o700)
    logs = output/'refresh-logs'; logs.mkdir(mode=0o700)
    for path in sorted(required):
        safe_file(path, root)
        target = output/path.relative_to(source); target.parent.mkdir(parents=True, exist_ok=True)
        with path.open('rb') as src, target.open('xb') as dst:
            for block in iter(lambda: src.read(1024*1024), b''): dst.write(block)
        target.chmod(stat.S_IMODE(path.stat().st_mode) & 0o777)
        require(sha(target) == artifacts[str(path)], 'copy hash mismatch')
    guards = current_guards(output/'base', repo, logs)
    require(guards.get('passed') is True and guards.get('cleanupResolved') is True, 'guard cleanup unresolved')
    verify_runtime(swift['workerRuntime'], repo, swift['sdk'])
    for name, digest in current.items(): require(sha(name) == digest, 'source changed during guards: ' + name)
    require(sha(artifact_manifest) == expected_sha256, 'artifact manifest changed during refresh')
    for name, digest in artifacts.items(): require(sha(name) == digest, 'old evidence changed during refresh')
    newpins = {}
    for name, digest in current.items():
        path = Path(name)
        newpins[str(output/path.relative_to(source)) if path.is_relative_to(source) else name] = digest
    for path in required:
        copied = output/path.relative_to(source)
        require(sha(copied) == artifacts[str(path)], 'copied artifact changed during guards')
        newpins[str(copied)] = artifacts[str(path)]
    ready['hashes'] = newpins
    swift['helper'] = str(output/'resident-simulator.dylib')
    ready['refresh'] = dict(source=str(source), artifactManifest=str(artifact_manifest),
        artifactManifestSHA256=expected_sha256, originalPreparedSHA256=artifacts[str(source/'base/prepared.json')],
        reusedNoTargetProof=True, reusedProofSHA256=artifacts[str(source/'no-target.json')],
        controllerDrift=drift, currentGuards=guards, currentRuntimeAdmission=False)
    # Preserve the original completion bytes separately; publish readiness last.
    provenance = output/'provenance'; provenance.mkdir(mode=0o700)
    for old in (source/'base/prepared.json', artifact_manifest,
                root/'preparation-command.json', root/'preparation-exit.json'):
        destination = provenance/('original-prepared.json' if old.name == 'prepared.json' else old.name)
        destination.write_bytes(bounded_bytes(old))
        expected = expected_sha256 if old == artifact_manifest else artifacts[str(old)]
        require(sha(destination) == expected, 'provenance copy changed')
        newpins[str(destination)] = expected
    for log in logs.iterdir():
        safe_file(log, output)
        newpins[str(log)] = sha(log)
    pending = output/'base/prepared.pending.json'
    with pending.open('x') as stream:
        json.dump(ready, stream, indent=2); stream.write('\n'); stream.flush(); os.fsync(stream.fileno())
    os.link(pending, output/'base/prepared.json')  # Atomic visibility, fail if destination exists.
    pending.unlink()
    return ready


def main():
    parser = argparse.ArgumentParser(description=__doc__, allow_abbrev=False)
    parser.add_argument('--source', type=Path, required=True)
    parser.add_argument('--artifact-manifest', type=Path, required=True)
    parser.add_argument('--expected-sha256', required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    refresh(args.source, args.artifact_manifest, args.expected_sha256, args.output)


if __name__ == '__main__': main()
