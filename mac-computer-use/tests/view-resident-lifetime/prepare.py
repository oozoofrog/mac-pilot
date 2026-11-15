"""Compile/sign/prove headless routes only. No Simulator inventory, load, attach or UI."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys

sys.dont_write_bytecode = True
HERE = Path(__file__).resolve().parent
FIXTURE = HERE.parent / 'view-hierarchy-fixture'
sys.path[:0] = [str(HERE), str(HERE.parent)]
import bounded
import native_check_support as native


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def prepare(out):
    out.mkdir(mode=0o700, parents=False)
    (out / 'logs').mkdir(mode=0o700)
    commands = []
    def command(name, args, seconds=45):
        row = {'name': name, 'command': list(map(str, args)), 'timeoutSeconds': seconds}
        commands.append(row)
        try:
            result = subprocess.run(row['command'], stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, timeout=seconds)
            (out / 'logs' / (name + '.log')).write_text(result.stdout)
            row['returncode'] = result.returncode
            if result.returncode:
                raise RuntimeError('command failed: ' + name + '; see ' + str(out / 'logs' / (name + '.log')))
            return result.stdout.strip()
        finally:
            (out / 'commands.json').write_text(json.dumps(commands, indent=2) + '\n')
    # The explicit dependency boundary excludes every changing whole-host Swift source.
    dependencies = [p for p in HERE.glob('*') if p.is_file()]
    dependencies += [p for p in FIXTURE.glob('*') if p.is_file()]
    dependencies += [HERE.parent / 'native_check_support.py', HERE.parent / 'view-hierarchy-prototype/remote_watchdog.py']
    resource = HERE.parent.parent / 'skills/mac-computer-use/scripts/view-capture'
    dependencies += [p for p in resource.glob('*') if p.is_file()]
    dependencies.append(resource.parent / 'native_build.py')
    frozen = {str(p): sha(p) for p in dependencies}
    clang = command('clang-path', ['/usr/bin/xcrun', '--find', 'clang'])
    lldb = command('lldb-path', ['/usr/bin/xcrun', '--find', 'lldb'])
    python = command('python-path', ['/usr/bin/xcrun', '--find', 'python3'])
    sdk = command('simulator-sdk', ['/usr/bin/xcrun', '--sdk', 'iphonesimulator', '--show-sdk-path'])
    mac = command('host-sdk', ['/usr/bin/xcrun', '--sdk', 'macosx', '--show-sdk-path'])
    command('xcode-version', ['/usr/bin/xcodebuild', '-version'])
    command('clang-version', [clang, '--version'])
    developer = Path(command('developer-path', ['/usr/bin/xcode-select', '-p']))
    lldb_framework = developer.parent / 'SharedFrameworks/LLDB.framework'
    tool_files = [Path(clang).resolve(), Path(lldb).resolve(), Path(python).resolve(),
                  (lldb_framework / 'LLDB').resolve(), (lldb_framework / 'Resources/debugserver').resolve()]
    # The selected Python and simctl launchers exec these observed native images.
    # Freeze both launcher and final executable bytes for the process budget.
    tool_files += [(Path(python).resolve().parent.parent / 'Resources/Python.app/Contents/MacOS/Python').resolve(),
                   developer / 'usr/bin/simctl',
                   Path('/Library/Developer/PrivateFrameworks/CoreSimulator.framework/Versions/A/Resources/bin/simctl')]
    toolchain = {str(file): {'sha256': sha(file), 'bytes': file.stat().st_size} for file in tool_files}
    (out / 'toolchain.json').write_text(json.dumps(toolchain, indent=2) + '\n')
    common = [clang, '-std=c11', '-fno-objc-arc', '-fobjc-exceptions', '-Wall', '-Wextra', '-Werror', '-framework', 'Foundation']
    command('host-helper', common + ['-isysroot', mac, '-DRESIDENT_HOST_CONTROL',
        '-dynamiclib', str(HERE / 'resident.m'), '-install_name', '@rpath/resident-host.dylib', '-o', str(out / 'resident-host.dylib')])
    command('host-console', common + ['-isysroot', mac, '-fobjc-weak', str(HERE / 'console.m'),
        str(out / 'resident-host.dylib'), '-Wl,-rpath,' + str(out), '-o', str(out / 'resident-console')])
    simulator = common + ['-target', 'arm64-apple-ios17.0-simulator', '-isysroot', sdk, '-framework', 'UIKit']
    command('simulator-helper', simulator + ['-dynamiclib', str(HERE / 'resident.m'),
        '-install_name', '@rpath/resident-simulator.dylib', '-o', str(out / 'resident-simulator.dylib')])
    command('simulator-ir', [clang, '-target', 'arm64-apple-ios17.0-simulator', '-isysroot', sdk,
        '-std=c11', '-fno-objc-arc', '-fobjc-exceptions', '-S', '-emit-llvm', str(HERE / 'resident.m'), '-o', str(out / 'resident.ll')])
    for name in ('resident-host.dylib', 'resident-console', 'resident-simulator.dylib'):
        command('sign-' + name, ['/usr/bin/codesign', '--force', '--sign', '-', str(out / name)])
        command('verify-' + name, ['/usr/bin/codesign', '--verify', '--strict', '--verbose=4', str(out / name)])
    commands_text = command('simulator-load-commands', ['/usr/bin/xcrun', 'otool', '-l', str(out / 'resident-simulator.dylib')])
    arch = command('simulator-architecture', ['/usr/bin/xcrun', 'lipo', '-archs', str(out / 'resident-simulator.dylib')])
    identity = command('simulator-uuid', ['/usr/bin/xcrun', 'dwarfdump', '--uuid', str(out / 'resident-simulator.dylib')])
    symbols = command('simulator-symbols', ['/usr/bin/xcrun', 'nm', '-gU', str(out / 'resident-simulator.dylib')])
    assert arch == 'arm64' and re.search(r'platform\s+(7|IOSSIMULATOR)', commands_text)
    assert '_mac_cu_resident_submit' in symbols and '+load' not in symbols
    image_uuid = re.search(r'UUID: ([A-F0-9-]{36})', identity)[1]
    # Fixture-only support avoids compiling/freezing the concurrently changing host.
    command('fixture-only', [python, '-B', str(FIXTURE / 'prepare.py'), str(out / 'fixture'), '--fixture-only'], 180)
    entitlement_text = command('fixture-existing-entitlements', ['/usr/bin/codesign', '-d', '--xml', '--entitlements', '-',
                               str(out / 'fixture/HierarchyFixture.app/HierarchyFixture')])
    assert '<key>com.apple.security.get-task-allow</key><true/>' in entitlement_text
    env = {k: v for k, v in os.environ.items() if not k.startswith(('MAC_CU_', 'DYLD_', 'PYTHON', 'RESIDENT_'))}
    with (out / 'logs' / 'console-guards.log').open('w') as log:
        native.check_routes(out / 'resident-console', env, log, production_helper=False)
    for mode in ('normal', 'throw', 'cancel', 'pre-cancel'):
        folder = out / ('console-' + mode); folder.mkdir(mode=0o700)
        environment = dict(env, RESIDENT_CONSOLE_DIRECTORY=str(folder), RESIDENT_CONSOLE_MODE=mode)
        bounded.run([str(out / 'resident-console'), '--native-check'], out / 'logs', 'console-' + mode, 5, environment)
    environment = dict(env, RESIDENT_PREPARE_OUTPUT=str(out), RESIDENT_SELECTED_SDK=sdk)
    bounded.run([lldb, '--no-lldbinit', '--batch', '-o', 'command script import ' + str(HERE / 'no_target.py')],
                out / 'logs', 'no-target', 45, environment)
    assert json.loads((out / 'no-target.json').read_text())['passed']
    for name, digest in frozen.items():
        assert sha(Path(name)) == digest, 'dependency moved during preparation: ' + name
    artifacts = [out / 'resident-host.dylib', out / 'resident-console', out / 'resident-simulator.dylib',
                 out / 'fixture/HierarchyFixture.app/HierarchyFixture', out / 'fixture/HierarchyFixture.app/Info.plist']
    hashes = {**frozen, **{str(p): sha(p) for p in artifacts}, **{name: row['sha256'] for name, row in toolchain.items()},
              str(Path(sdk) / 'SDKSettings.json'): sha(Path(sdk) / 'SDKSettings.json')}
    (out / 'guard-build').mkdir(mode=0o700)
    (out / 'guard-build/prepared.json').write_text(json.dumps({'dispatchPassed': True, 'wholeProbeVerified': False,
        'editQualificationReady': False, 'guardOnly': True, 'hashes': hashes}, indent=2) + '\n')
    result = {'headlessPassed': True, 'guestExecuted': False, 'runtimeReady': False,
              'prerequisite': 'final canonical whole-probe source freeze/build and authorized runtime owner',
              'helperUUID': image_uuid, 'helperSHA256': sha(out / 'resident-simulator.dylib'),
              'simulatorSDK': str(Path(sdk).resolve()), 'selectedPython': python, 'selectedLLDB': lldb,
              'debugserverPath': str((lldb_framework / 'Resources/debugserver').resolve()), 'hashes': hashes}
    (out / 'prepared.json').write_text(json.dumps(result, indent=2) + '\n')
    print('PASS headless preparation; guest not loaded; final native freeze required: ' + str(out))


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__, allow_abbrev=False)
    parser.add_argument('output', type=Path)
    args = parser.parse_args()
    if not args.output.is_absolute() or args.output.exists():
        parser.error('output must be absolute and nonexistent')
    prepare(args.output)
