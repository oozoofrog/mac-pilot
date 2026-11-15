"""Locally verified build, target signature and selected Simulator tuple admission."""
import hashlib
import json
import os
from pathlib import Path
import plistlib
import subprocess
import time

HERE = Path(__file__).resolve().parent

def run(args):
    return subprocess.check_output(args, stderr=subprocess.PIPE, timeout=8)

def sha(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()

def manifest():
    value = json.loads((HERE / 'resident-build.json').read_text())
    image = HERE / value['image']
    if (value['abi'] != 2 or value['image'] != 'mac-cu-resident-v2.dylib' or value['architecture'] != 'arm64'
            or sha(image) != value['sha256']):
        raise RuntimeError('Resident ABI/image hash mismatch; rebuild canonical resources')
    for name, expected in value['sources'].items():
        if Path(name).name != name or sha(HERE / name) != expected:
            raise RuntimeError('Resident resource changed since selected-SDK build: ' + name)
    run(['/usr/bin/codesign', '--verify', '--strict', str(image)])
    return value

def admit(request):
    """No request switches can override this exact selected Xcode/runtime admission."""
    m = manifest()
    selected = run(['/usr/bin/xcode-select', '-p']).decode().strip()
    developer = Path(selected).resolve()
    sdk = Path(run(['/usr/bin/xcrun', '--sdk', 'iphonesimulator', '--show-sdk-path']).decode().strip()).resolve()
    framework = developer.parent / 'SharedFrameworks/LLDB.framework'
    if (str(developer) != m['developer'] or str(sdk) != m['sdk']
            or run(['/usr/bin/xcodebuild', '-version']).decode().strip() != 'Xcode 27.2\nBuild version 27B48'
            or m['xcodeVersion'] != 'Xcode 27.2\nBuild version 27B48'
            or sha(sdk / 'SDKSettings.json') != m['sdkSHA256']
            or sha((framework / 'LLDB').resolve()) != m['lldbSHA256']
            or sha((framework / 'Resources/debugserver').resolve()) != m['debugserverSHA256']):
        raise RuntimeError('Unsupported selected Xcode/LLDB/SDK tuple; requires verified Xcode 27B48')
    inventory = json.loads(run(['/usr/bin/xcrun', 'simctl', 'list', 'devices', '--json']))['devices']
    selected_device = [(runtime, d) for runtime, devices in inventory.items() for d in devices
                       if d['udid'].upper() == request['target']['deviceID'].upper()]
    if len(selected_device) != 1 or selected_device[0][1]['state'] != 'Booted':
        raise RuntimeError('Selected device must already be Booted')
    runtime_id = selected_device[0][0]
    runtimes = json.loads(run(['/usr/bin/xcrun', 'simctl', 'list', 'runtimes', '--json']))['runtimes']
    found = [r for r in runtimes if r['identifier'] == runtime_id]
    if len(found) != 1 or found[0].get('version') != '27.2' or found[0].get('buildversion') != '24B114' or not found[0].get('isAvailable'):
        raise RuntimeError('Unsupported exact Simulator runtime; requires iOS 27.2 / 24B114')
    executable = Path(request['target']['path']).resolve(); app = executable.parent
    info = plistlib.loads((app / 'Info.plist').read_bytes())
    bundle = info.get('CFBundleIdentifier')
    if (app.suffix != '.app' or info.get('CFBundleExecutable') != executable.name or not isinstance(bundle, str)
            or bundle.startswith('com.apple.') or '/Containers/Bundle/Application/' not in str(app)):
        raise RuntimeError('Only an installed user app bundle executable is supported')
    installed = Path(run(['/usr/bin/xcrun', 'simctl', 'get_app_container', request['target']['deviceID'], bundle, 'app']).decode().strip()).resolve()
    if installed != app:
        raise RuntimeError('Selected device app container does not match target executable')
    run(['/usr/bin/codesign', '--verify', '--strict', str(app)])
    raw = run(['/usr/bin/codesign', '-d', '--xml', '--entitlements', '-', str(executable)])
    if len(raw) > 65536 or plistlib.loads(raw).get('com.apple.security.get-task-allow') is not True:
        raise RuntimeError('Signed Simulator entitlement com.apple.security.get-task-allow is absent')
    data = Path(run(['/usr/bin/xcrun', 'simctl', 'get_app_container', request['target']['deviceID'], bundle, 'data']).decode().strip()).resolve()
    if '/Containers/Data/Application/' not in str(data):
        raise RuntimeError('Selected application data container is not recognized')
    return {'build': m, 'bundleID': bundle, 'data': str(data), 'runtime': found[0],
            'signedDebugEntitlement': 'com.apple.security.get-task-allow', 'targetResigned': False,
            'executableSHA256': sha(executable)}


def stage(wire, admission):
    """One immutable image pin per exact target lifetime, including across host restarts."""
    m = admission['build']
    target_key = hashlib.sha256(json.dumps(wire['target'], sort_keys=True, separators=(',', ':')).encode()).hexdigest()
    base = Path(admission['data']) / 'Library/Caches/org.oozoofrog.mac-cu-resident'
    base.mkdir(mode=0o700, exist_ok=True)
    root = base / target_key
    root.mkdir(mode=0o700, exist_ok=True)
    import resident_protocol as p
    fd = p.directory(root); os.close(fd)
    pin = root / 'pin.json'; image = root / m['image']
    expected = {'target': wire['target'], 'abi': 2, 'sha256': m['sha256'], 'uuid': m['uuid'], 'path': str(image)}
    if pin.exists():
        if pin.is_symlink() or json.loads(pin.read_text()) != expected or image.is_symlink() or sha(image) != m['sha256']:
            raise RuntimeError('Target lifetime has another or damaged resident pin; restart target naturally before capture')
    else:
        # An interrupted stage never replaces a previous image or pin.
        fd = os.open(image, os.O_CREAT | os.O_EXCL | os.O_WRONLY | os.O_NOFOLLOW, 0o700)
        with os.fdopen(fd, 'wb') as f:
            f.write((HERE / m['image']).read_bytes()); f.flush(); os.fsync(f.fileno())
        run(['/usr/bin/codesign', '--verify', '--strict', str(image)])
        fd = os.open(pin, os.O_CREAT | os.O_EXCL | os.O_WRONLY | os.O_NOFOLLOW, 0o600)
        with os.fdopen(fd, 'w') as f:
            json.dump(expected, f); f.flush(); os.fsync(f.fileno())
    channel = root / wire['operationID']; channel.mkdir(mode=0o700)
    return image, channel
