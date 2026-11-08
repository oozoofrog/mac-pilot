#!/usr/bin/env python3
"""Check the isolated manager; optionally create/start one explicitly named new test device."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import subprocess
import tempfile
from native_check_support import check_routes, isolated_main, run_owned


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', required=True, type=Path)
    parser.add_argument('--create-device', help='Create/start a NEW device named "Mac Pilot Check …". It is retained, never erased/deleted.')
    parser.add_argument('--runtime', help='Exact installed runtime ID for --create-device.')
    parser.add_argument('--device-type', help='Exact compatible device type ID for --create-device.')
    args = parser.parse_args()
    if any([args.create_device, args.runtime, args.device_type]) and not all([args.create_device, args.runtime, args.device_type]):
        parser.error('--create-device, --runtime and --device-type must be supplied together.')
    if args.create_device and not args.create_device.startswith('Mac Pilot Check '):
        parser.error('Use a unique name starting with "Mac Pilot Check " for the new test device.')
    output = args.output.expanduser().resolve()
    output.mkdir(parents=True, exist_ok=False)
    here = Path(__file__).resolve().parent
    source = here.parent / 'skills/mac-computer-use/scripts/mac-cu-src'
    app = output / 'Simulator Preparation Check.app'
    executable = app / 'Contents/MacOS/preparation-check'
    executable.parent.mkdir(parents=True)
    info = {'CFBundleIdentifier': 'org.oozoofrog.mac-cu.preparation-check',
            'CFBundleName': 'Simulator Preparation Check', 'CFBundleExecutable': executable.name,
            'CFBundlePackageType': 'APPL', 'NSHighResolutionCapable': True}
    (app / 'Contents/Info.plist').write_bytes(plistlib.dumps(info))
    sources = sorted(source.glob('*.swift'))
    (output / 'source-hashes.json').write_text(json.dumps({p.name: hashlib.sha256(p.read_bytes()).hexdigest() for p in sources}, indent=2))
    with tempfile.TemporaryDirectory(prefix='mac-cu-preparation-build-') as build:
        entry = Path(build) / 'main.swift'
        text = (source / 'main.swift').read_text()
        entry.write_text(isolated_main(text, 'runSimulatorPreparationLiveCheck()'))
        command = ['swiftc', '-g', *[str(p) for p in sources if p.name != 'main.swift'],
                   str(entry), str(here / 'simulator-preparation-live-check.swift'), '-o', str(executable)]
        with (output / 'build.log').open('w') as log:
            subprocess.run(command, stdout=log, stderr=subprocess.STDOUT, check=True)
    subprocess.run(['codesign', '--force', '--sign', '-', str(app)], check=True)
    subprocess.run(['codesign', '--verify', '--deep', '--strict', str(app)], check=True)
    environment = dict(os.environ, PREPARATION_CHECK_OUTPUT=str(output))
    environment.pop('PREPARATION_CHECK_CREATE', None)
    if args.create_device:
        environment['PREPARATION_CHECK_CREATE'] = json.dumps({'name': args.create_device, 'runtime': args.runtime, 'type': args.device_type})
    before = json.loads(subprocess.check_output(['/usr/bin/xcrun', 'simctl', 'list', '--json'], text=True, timeout=30))
    (output / 'before.json').write_text(json.dumps(before, indent=2))
    before_devices = {d['udid']: d for rows in before['devices'].values() for d in rows}
    if args.create_device and any(d['name'] == args.create_device for d in before_devices.values()):
        parser.error('The test name already exists. Use a new unique name; this runner does not reuse existing devices.')
    with (output / 'live.log').open('w') as log:
        check_routes(executable, environment, log)
        try:
            result = run_owned(executable, ['--native-check'], environment=environment, log=log, timeout=300 if args.create_device else 60)
        finally:
            after = json.loads(subprocess.check_output(['/usr/bin/xcrun', 'simctl', 'list', '--json'], text=True, timeout=30))
            (output / 'after.json').write_text(json.dumps(after, indent=2))
            after_devices = {d['udid']: d for rows in after['devices'].values() for d in rows}
            created = [d for udid, d in after_devices.items() if udid not in before_devices]
            (output / 'retained-devices.json').write_text(json.dumps(created, indent=2))
            for device in created:
                print(f'Retained new device: {device["name"]} · {device["udid"]} · {device["state"]}')
            for udid, device in before_devices.items():
                if udid not in after_devices or after_devices[udid]['state'] != device['state']:
                    raise RuntimeError(f'A pre-existing device changed state during the check: {udid}. Inspect the retained evidence.')
    print((output / 'live.log').read_text())
    print(f'Evidence: {output}')
    raise SystemExit(result)


if __name__ == '__main__':
    main()
