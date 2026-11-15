"""Freeze canonical whole host/resources plus a distinct SDK-free debug application."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import subprocess
import sys

sys.dont_write_bytecode = True
HERE = Path(__file__).resolve().parent
FIXTURE = HERE.parent / 'view-hierarchy-fixture'
sys.path.insert(0, str(HERE.parent))
import native_check_support as native
BUNDLE = 'local.mac-pilot.resident-product'


def prepare(out, reuse=None, swiftui=False):
    subprocess.run([sys.executable, '-B', str(FIXTURE / 'prepare.py'), str(out), *(['--reuse-probe-from', str(reuse)] if reuse else [])], check=True, timeout=300)
    app = out / 'ResidentProduct.app'; app.mkdir()
    sdk = subprocess.check_output(['xcrun', '--sdk', 'iphonesimulator', '--show-sdk-path'], text=True).strip()
    commands = [
        ['xcrun', 'clang', '-target', 'arm64-apple-ios17.0-simulator', '-isysroot', sdk,
         '-fobjc-exceptions', '-fno-objc-arc', '-c', str(HERE / 'main.m'), '-o', str(out / 'product-main.o')],
        ['xcrun', 'swiftc', '-parse-as-library', '-target', 'arm64-apple-ios17.0-simulator', '-sdk', sdk,
         '-import-objc-header', str(FIXTURE / 'fault-target.h'), str(HERE / 'ProductApp.swift'),
         str(HERE / 'ProductOracle.swift'), str(out / 'fault-target.o'), str(out / 'product-main.o'),
         '-o', str(app / 'ResidentProduct')]]
    if swiftui:
        commands = [commands[1]]
        commands[0].remove(str(out / 'product-main.o'))
        commands[0].insert(-2, str(HERE / 'SwiftUIApp.swift'))
    with (out / 'product-build.log').open('w') as log:
        for command in commands:
            log.write(repr(command) + '\n'); log.flush()
            subprocess.run(command, stdout=log, stderr=subprocess.STDOUT, check=True, timeout=90)
    guard = out / 'product-entry'
    subprocess.run(['xcrun', 'clang', '-DPRODUCT_ENTRY_GUARD', '-framework', 'Foundation', str(HERE / 'main.m'), '-o', str(guard)], check=True)
    with (out / 'product-entry-guards.log').open('w') as log:
        native.check_routes(guard, dict(os.environ), log, production_helper=False)
        environment = dict(os.environ, MAC_CU_FIXTURE_SESSION='headless-entry')
        for args, env, status in [(['--fixture-session', 'headless-entry'], environment, 0),
            (['--fixture-session', 'headless-entry'], dict(environment, MAC_CU_FIXTURE_CHILD='1'), 64),
            (['--fixture-session', 'wrong'], environment, 64)]:
            assert native.run_owned(guard, args, environment=env, log=log, timeout=5, max_instances=1) == status
    info = plistlib.loads((FIXTURE / 'Info.plist').read_bytes())
    info.update(CFBundleIdentifier=BUNDLE, CFBundleExecutable='ResidentProduct', CFBundleName='Resident Notes')
    info['UIApplicationSceneManifest']['UISceneConfigurations']['UIWindowSceneSessionRoleApplication'][0]['UISceneDelegateClassName'] = 'ResidentProductScene'
    if swiftui:
        del info['UIApplicationSceneManifest']
    (app / 'Info.plist').write_bytes(plistlib.dumps(info))
    subprocess.run(['codesign', '--force', '--sign', '-', '--entitlements', str(out / 'entitlements.plist'), str(app)], check=True)
    subprocess.run(['codesign', '--verify', '--strict', str(app)], check=True)
    links = subprocess.check_output(['xcrun', 'otool', '-L', str(app / 'ResidentProduct')], text=True)
    assert all('mac-cu' not in line and 'resident-v2' not in line for line in links.splitlines()[1:])
    (out / 'product-linked-images.txt').write_text(links)
    value = json.loads((out / 'prepared.json').read_text())
    files = [*app.rglob('*'), *HERE.glob('*'), FIXTURE / 'session.py', FIXTURE / 'session-probe.swift']
    value['hashes'].update({str(p.resolve()): hashlib.sha256(p.read_bytes()).hexdigest() for p in files if p.is_file()})
    value['ordinaryProductApp'] = {'bundleID': BUNDLE, 'app': str(app), 'entry': 'SwiftUI.App' if swiftui else 'UIKit C main', 'linksMacCU': False}
    (out / 'prepared.json').write_text(json.dumps(value, indent=2) + '\n')
    print('PASS distinct product app; no launch/install: ' + str(out))

if __name__ == '__main__':
    parser = argparse.ArgumentParser(allow_abbrev=False); parser.add_argument('output', type=Path)
    parser.add_argument('--reuse-probe-from', type=Path)
    parser.add_argument('--swiftui', action='store_true')
    args = parser.parse_args()
    if not args.output.is_absolute() or args.output.exists(): parser.error('unique absolute output required')
    prepare(args.output, args.reuse_probe_from, args.swiftui)
