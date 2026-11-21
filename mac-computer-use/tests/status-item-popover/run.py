"""Run the MacPilot AX tools against a disposable AppKit menu-bar application."""
import argparse
import hashlib
import json
import multiprocessing
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import tempfile
import time

here = Path(__file__).resolve().parent
tests = here.parent
scripts = tests.parent / 'skills/mac-computer-use/scripts'
sys.path[:0] = [str(tests), str(scripts)]
from native_build import run_swift
from native_check_support import check_routes, isolated_main, run_owned


def run_fixture(executable, env):
    sys.exit(run_owned(executable, ['--native-check'], environment=env, log=sys.stdout, timeout=100, max_instances=1))


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--output-parent', type=Path, default=None)
    args = parser.parse_args()
    out = Path(tempfile.mkdtemp(prefix='macpilot-status-check-', dir=args.output_parent)).resolve()
    print(out, flush=True)
    bundle = out / 'Fixture.app/Contents'
    name = 'MenuProbe' + out.name.split('-')[-1].replace('_', 'x')
    fixture = bundle / 'MacOS' / name
    fixture.parent.mkdir(parents=True)
    identifier = 'local.macpilot.' + name.lower()
    (bundle / 'Info.plist').write_bytes(plistlib.dumps(dict(
        CFBundleIdentifier=identifier, CFBundleExecutable=name, CFBundleName='Status Fixture',
        CFBundlePackageType='APPL', LSUIElement=True)))
    subprocess.run(['swiftc', '-parse-as-library', here / 'fixture.swift', tests / 'native-selfcheck-entry.swift',
                    '-o', fixture], check=True)
    subprocess.run(['codesign', '-fs', '-', bundle.parent], check=True)
    source = out / 'mac-cu-src'
    shutil.copytree(scripts / 'mac-cu-src', source)
    inputs = sorted(p for p in source.rglob('*') if p.is_file())
    (out / 'source-hashes.json').write_text(json.dumps({
        str(p.relative_to(source)): hashlib.sha256(p.read_bytes()).hexdigest() for p in inputs
    }, indent=2))

    entry = out / 'main.swift'
    entry.write_text(isolated_main((source / 'main.swift').read_text(), 'checkStatusPopover()'))
    probe_bundle = out / 'Probe.app/Contents'
    probe = probe_bundle / 'MacOS/DesktopProbe'
    probe.parent.mkdir(parents=True)
    (probe_bundle / 'Info.plist').write_bytes(plistlib.dumps(dict(
        CFBundleIdentifier=identifier + '.probe', CFBundleExecutable=probe.name,
        CFBundleName='Desktop Check Origin', CFBundlePackageType='APPL', LSUIElement=True)))

    with (out / 'build.log').open('w') as log:
        run_swift(['swiftc', *sorted(p for p in source.glob('*.swift') if p.name != 'main.swift'),
                   entry, here / 'check.swift', here / 'chain.swift', here / 'connection.swift', '-o', probe], source=source, stdout=log, stderr=subprocess.STDOUT, check=True)
    subprocess.run(['codesign', '-fs', '-', probe_bundle.parent], check=True)
    support = out / 'Library/Application Support/mac-cu'
    support.mkdir(parents=True)
    (support / 'always-allow.txt').write_text(identifier + '\n')
    (support / 'modes.json').write_text('{"input":"auto","show":"off"}')
    env = dict(os.environ, MAC_CU_STATUS_CHECK=str(out), MAC_CU_STATUS_EXECUTABLE=name)
    probe_env = dict(env, CFFIXED_USER_HOME=str(out))
    check_routes(fixture, env, sys.stdout, production_helper=False)
    check_routes(probe, probe_env, sys.stdout)
    owner = multiprocessing.Process(target=run_fixture, args=(fixture, env))
    owner.start()
    try:
        deadline = time.monotonic() + 10
        while not (out / 'ready').exists():
            if not owner.is_alive() or time.monotonic() > deadline:
                raise RuntimeError('The status item fixture did not start.')
            time.sleep(0.1)
        if run_owned(probe, ['--native-check'], environment=probe_env, log=sys.stdout, timeout=80, max_instances=1):
            raise RuntimeError('The status item check failed.')
    finally:
        (out / 'done').touch()
        owner.join()
    if owner.exitcode:
        raise RuntimeError('The status item fixture failed.')


if __name__ == '__main__':
    main()
