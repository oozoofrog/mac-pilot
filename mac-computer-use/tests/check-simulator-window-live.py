#!/usr/bin/env python3
"""Build/run a separate native LCD test app; never install, boot or erase a device.

Requires an explicit booted UDID already claimed by this session. Evidence and the
app stay in the requested output directory. Run foreground checks serially.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import subprocess
import sys
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "skills/mac-computer-use/scripts"))
from native_build import run_swift, native_inputs
import selectors
import re
import tempfile
from native_check_support import check_routes, isolated_main, run_owned


def installed_simulator(arguments):
    """Bounded production RPC for restoration, without installing or registering anything."""
    server = Path.home() / 'Library/Application Support/mac-cu/mac-cu.app/Contents/MacOS/mac-cu'
    child = subprocess.Popen([str(server)], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True)
    try:
        def request(message):
            child.stdin.write(json.dumps(message)+'\n'); child.stdin.flush()
            with selectors.DefaultSelector() as selector:
                selector.register(child.stdout, selectors.EVENT_READ)
                if not selector.select(45):
                    raise TimeoutError('Installed restoration RPC deadline')
                return json.loads(child.stdout.readline())
        initialized = request({'jsonrpc':'2.0', 'id':1, 'method':'initialize', 'params':{'protocolVersion':'2025-06-18', 'capabilities':{}, 'clientInfo':{'name':'Guarded Duo restoration', 'version':'1'}}})
        if 'result' not in initialized:
            raise RuntimeError('Installed restoration initialization failed')
        response = request({'jsonrpc':'2.0', 'id':2, 'method':'tools/call', 'params':{'name':'simulator', 'arguments':arguments}})
        if response.get('error') or response.get('result', {}).get('isError'):
            raise RuntimeError(str(response))
        return response['result']
    finally:
        child.stdin.close()
        try:
            child.wait(timeout=5)
        except subprocess.TimeoutExpired:
            child.terminate(); child.wait(timeout=5)
        child.stdout.close()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--pilot', type=Path, default=Path.home() / '.local/bin/sim-pilot', help='Claim-aware Simulator Pilot CLI used for this check.')
    parser.add_argument('--udid', required=True)
    parser.add_argument('--output', required=True, type=Path)
    parser.add_argument('--duo-rotation', action='store_true', help='Guarded production toolbar rotations on the claimed foldable device, with pose/hinge restoration.')
    parser.add_argument('--toolbar', action='store_true', help='Validate the production toolbar ownership, editable popovers and four direct rotations on the explicit owned test device.')
    parser.add_argument('--backend-only', action='store_true', help='No foreground activation or Mac input; test the background simulator backend and native presentation separately.')
    parser.add_argument('--preview', action='store_true', help='Open a persistent isolated app with the production menu bar and actual LCD; do not run automatic device actions.')
    parser.add_argument('--preview-timeout', type=float, default=1800, help='Maximum preview lifetime in seconds; keep this parent watchdog running (default: 1800).')
    args = parser.parse_args()
    if args.duo_rotation and (args.preview or args.backend_only or args.toolbar):
        parser.error('--duo-rotation is a separate foreground check')
    if args.preview and args.backend_only:
        parser.error('--preview and --backend-only are mutually exclusive')
    pilot = args.pilot
    devices = json.loads(subprocess.check_output([str(pilot), 'devices'], text=True))
    chosen = next((d for d in devices if d.get('udid') == args.udid), None)
    if not chosen or not chosen.get('mine'):
        parser.error('The explicit UDID must be booted and claimed by this session (sim-pilot claim).')
    output = args.output.expanduser().resolve()
    output.mkdir(parents=True, exist_ok=False)
    here = Path(__file__).resolve().parent
    source = here.parent / 'skills/mac-computer-use/scripts/mac-cu-src'
    app = output / 'LCD Window Check.app'
    executable = app / 'Contents/MacOS/lcd-window-check'
    executable.parent.mkdir(parents=True)
    info = {'CFBundleIdentifier': 'org.oozoofrog.mac-cu.lcd-window-check',
            'CFBundleName': 'LCD Window Check', 'CFBundleExecutable': executable.name,
            'CFBundlePackageType': 'APPL', 'NSHighResolutionCapable': True}
    if args.preview:
        info['CFBundleIdentifier'] = 'org.oozoofrog.mac-cu.device-preview-final'
        info['CFBundleName'] = 'Mac CU Device Preview'
    (app / 'Contents/Info.plist').write_bytes(plistlib.dumps(info))
    sources = sorted(source.glob('*.swift'))
    (output / 'source-hashes.json').write_text(json.dumps({p.name: hashlib.sha256(p.read_bytes()).hexdigest() for p in [*sources, *native_inputs(source), Path(__file__), here / "native_check_support.py"]}, indent=2))
    # Keep all production definitions; replace only executable dispatch in a temporary main.
    # The tested SimulatorWindow, input, backend and lifecycle classes are unmodified.
    with tempfile.TemporaryDirectory(prefix='mac-cu-lcd-build-') as build:
        entry = Path(build) / 'main.swift'
        main_source = (source / 'main.swift').read_text()
        dispatch = (f'runSimulatorWindowPreview(id: {json.dumps(args.udid)}, output: URL(fileURLWithPath: {json.dumps(str(output))}))'
                    if args.preview else 'runSimulatorDuoRotationLiveCheck()' if args.duo_rotation else 'runSimulatorToolbarLiveCheck()' if args.toolbar else 'runSimulatorWindowLiveCheck()')
        entry.write_text(isolated_main(main_source, dispatch))
        command = ['swiftc', '-g', *[str(p) for p in sources if p.name != 'main.swift'],
                   str(entry), str(here / 'simulator-window-live-check.swift'), str(here / 'simulator-toolbar-live-check.swift'), str(here / 'simulator-duo-rotation-live-check.swift'), '-o', str(executable)]
        with (output / 'build.log').open('w') as log:
            run_swift(command, stdout=log, stderr=subprocess.STDOUT, check=True)
    subprocess.run(['codesign', '--force', '--sign', '-', str(app)], check=True)
    subprocess.run(['codesign', '--verify', '--deep', '--strict', str(app)], check=True)
    environment = dict(os.environ, LCD_CHECK_UDID=args.udid, LCD_CHECK_OUTPUT=str(output), LCD_CHECK_BACKEND_ONLY='1' if args.backend_only else '0')
    if args.preview:
        print(f'Preview app (bounded parent watchdog): {app}', flush=True)
        print(f'Readiness: {output / "ready.json"}', flush=True)
    # Dispatch proof precedes any device mutation or GUI. Exact budget: one root
    # plus its short-lived production permission helper, 300 seconds total.
    with (output / 'live.log').open('w') as log:
        check_routes(executable, environment, log)
        original_angle = None
        if args.duo_rotation:
            baseline = installed_simulator({'action':'hinge', 'device':args.udid})
            message = ' '.join(item.get('text', '') for item in baseline.get('content', []))
            match = re.search(r'Hinge at ([0-9.]+)', message)
            if not match:
                raise RuntimeError('Cannot establish original hinge before launch')
            original_angle = float(match.group(1))
            (output / 'inventory-before.json').write_text(json.dumps(devices, indent=2))
        try:
            result = run_owned(executable, ['--native-check'], environment=environment, log=log,
                               timeout=args.preview_timeout if args.preview else 300, max_instances=2)
        finally:
            if args.duo_rotation:
                # The watchdog has cleaned test processes before this fallback. Its
                # restoration uses the already-installed daemon, never the test entry.
                if not (output / 'restored.txt').exists():
                    restoration = output / 'restore.json'
                    if restoration.exists():
                        state = json.loads(restoration.read_text())
                        installed_simulator({'action':'hinge', 'device':args.udid, 'degrees':180})
                        installed_simulator({'action':'rotate', 'device':args.udid, 'orientation':state['orientation']})
                    installed_simulator({'action':'hinge', 'device':args.udid, 'degrees':original_angle})
                    print('RESTORED by parent after native failure', file=log, flush=True)
                after = json.loads(subprocess.check_output([str(pilot), 'devices'], text=True))
                (output / 'inventory-after.json').write_text(json.dumps(after, indent=2))
                before_devices = {d['udid']: (d.get('name'), d.get('runtime')) for d in devices}
                after_devices = {d['udid']: (d.get('name'), d.get('runtime')) for d in after}
                if before_devices != after_devices:
                    raise RuntimeError('Booted simulator inventory changed during rotation check')
    print((output / 'live.log').read_text())
    print(f'Evidence: {output}')
    raise SystemExit(result)


if __name__ == '__main__':
    main()
