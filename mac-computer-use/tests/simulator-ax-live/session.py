"""AX-only owned session. Explicit selected device; no debugger, host activation or HID."""
import importlib.util
import json
import os
from pathlib import Path
import plistlib
import re
import signal
import subprocess
import sys
import time
import uuid

sys.dont_write_bytecode = True
HERE = Path(__file__).resolve().parent
# Load the frozen AX-compatible session helper, never a concurrently edited helper.
build_argument = Path(sys.argv[2] if sys.argv[1:2] == ['--worker'] else sys.argv[3]).resolve()
spec = importlib.util.spec_from_file_location('hierarchy_session', build_argument / 'frozen-session.py')
s = importlib.util.module_from_spec(spec)
spec.loader.exec_module(s)
def worker(build, out, token, parent, deadline, DEVICE):
    if os.getppid() != parent or os.environ.get('AX_SESSION_WORKER') != token:
        return 64
    report = dict(errors=[], semanticQualified=False, attemptedDelivery=False)
    claim = s.Claim(DEVICE, token)
    acquired = installed = False
    before = target = app = data = None
    stopped = False
    def stop(*_):
        nonlocal stopped
        stopped = True
    for sig in (signal.SIGTERM, signal.SIGINT):
        signal.signal(sig, stop)
    guard = s.InputGuard()
    pp = s.capture.ProcessProbe()
    try:
        s.verify_prepared(build)
        prepared = json.loads((build / 'prepared.json').read_text())
        s.BUNDLE = prepared['bundle']
        inventory = s.booted(DEVICE)
        report['inventory'] = inventory
        all_devices = json.loads(subprocess.check_output(['xcrun', 'simctl', 'list', 'devices', 'booted', '-j'], text=True, timeout=5))['devices']
        runtimes = [runtime for runtime, devices in all_devices.items() if any(d['udid'] == DEVICE for d in devices)]
        if len(runtimes) != 1: raise RuntimeError('selected runtime ambiguous')
        report['runtime'] = runtimes[0]
        claim.acquire(); acquired = True
        os.environ['AX_BOOT_OUTPUT'] = str(out / 'boot.txt')
        before = s.probe(build, out, 'before', DEVICE)
        s.require_static_portrait(before)
        report['before'] = before
        boot = (out / 'boot.txt').read_text()
        if not boot.startswith(DEVICE + ':'):
            raise RuntimeError('missing current boot lifetime')
        if s.fixture_inventory(DEVICE) or s.fixture_data(DEVICE):
            raise RuntimeError('preexisting unique fixture installation/data refused')
        guard.check(); claim.check()
        if stopped: raise InterruptedError('stopped before install')
        installed = True
        subprocess.run(['xcrun', 'simctl', 'install', DEVICE, str(build / 'AXLiveFixture.app')], check=True, timeout=12)
        app = Path(s.fixture_inventory(DEVICE)['Path']).resolve()
        if plistlib.loads((app / 'Info.plist').read_bytes())['CFBundleIdentifier'] != s.BUNDLE:
            raise RuntimeError('installed bundle changed')
        data = s.fixture_data(DEVICE)
        if len(data) != 1: raise RuntimeError('data ownership ambiguous')
        report.update(bundle=s.BUNDLE, app=str(app), data=data)
        guard.check(); claim.check()
        if stopped: raise InterruptedError('stopped before launch')
        env = {k: v for k, v in os.environ.items() if not k.startswith(('SIMCTL_CHILD_', 'MAC_CU_', 'DYLD_', 'PYTHON'))}
        env['SIMCTL_CHILD_MAC_CU_AX_FIXTURE_SESSION'] = token
        launch_time = time.time()
        launched = subprocess.check_output(['xcrun', 'simctl', 'launch', DEVICE, s.BUNDLE, '--fixture-session', token], env=env, text=True, timeout=10)
        match = re.fullmatch(re.escape(s.BUNDLE) + r': (\d+)\s*', launched)
        if not match: raise RuntimeError('launch PID ambiguous')
        ident = pp.identity(int(match[1]), device=True)
        if ident['path'] != str(app / 'AXLiveFixture') or ident['deviceID'] != DEVICE or ident['start'][0] + ident['start'][1]/1e6 < launch_time-1:
            raise RuntimeError('guest ownership not proved')
        target = {k: ident[k] for k in ('pid', 'path', 'start', 'deviceID')}
        target.update(boot=boot, runtime=runtimes[0], hostPID=before['hostPID'], documents=str(Path(data[0]) / 'Documents'))
        s.save(out / 'target.json', target)
        oracle = Path(target['documents']) / 'ax-oracle.json'
        s.wait_for_oracle(oracle, pp, target, lambda: stopped)
        s.save(out / 'oracle-before.json', json.loads(oracle.read_text()))
        current = s.probe(build, out, 'fixture-front', DEVICE)
        if current['frontPID'] != target['pid'] or current['frontStart'] != target['start'] or current['frontPath'] != target['path'] or current['hostPID'] != before['hostPID']:
            raise RuntimeError('fixture front mismatch')
        if (out / 'boot.txt').read_text() != boot: raise RuntimeError('boot changed')
        guard.check(); claim.check()
        if stopped: raise InterruptedError('stopped before AX read')
        env['AX_LIVE_TARGET'] = str(out / 'target.json')
        env['AX_LIVE_OUTPUT'] = str(out)
        with (out / 'ax-probe.log').open('w') as log:
            rc = s.native.run_owned(build / 'session-probe', ['--native-check'], environment=env, log=log, timeout=35, max_instances=1)
        report['probeExit'] = rc
        s.save(out / 'oracle-after.json', json.loads(oracle.read_text()))
        if rc: raise RuntimeError('actual production AX probe failed; see ax-probe.log')
        report['identityMeasured'] = True
        guard.check(); claim.check()
        env['AX_LCD_PHASE'] = '1'
        with (out / 'lcd-probe.log').open('w') as log:
            lcd_rc = s.native.run_owned(build / 'session-probe', ['--native-check'], environment=env, log=log, timeout=40, max_instances=1)
        report['lcdExit'] = lcd_rc
        if lcd_rc: raise RuntimeError('LCD workflow failed; see lcd-probe.log')
        report['attemptedDelivery'] = (out / 'actions.json').exists()
        report['remainingRequirement'] = 'Per-operation oracle results require review; normal product factory and LCD controls used'
    except BaseException as error:
        report['errors'].append(repr(error))
    finally:
        for sig in (signal.SIGTERM, signal.SIGINT): signal.signal(sig, signal.SIG_IGN)
        clean = True
        try:
            s.reserve(deadline, 70, 'owned cleanup and restoration')
            if installed:
                claim.check()
                if target:
                    status = s.residual(pp, target)
                    if status['state'] == 'live':
                        if status['current']['traced'] or status['current']['state'] not in (2, 3): raise RuntimeError('guest stopped/traced')
                        subprocess.run(['xcrun', 'simctl', 'terminate', DEVICE, s.BUNDLE], check=True, timeout=8)
                        until = time.monotonic()+4
                        while s.residual(pp, target)['state'] == 'live' and time.monotonic()<until: time.sleep(.1)
                    report['guestResidual'] = s.residual(pp, target)
                    if report['guestResidual']['state'] != 'gone': raise RuntimeError('guest residual not gone')
                elif app and s.native.instances(app / 'AXLiveFixture'):
                    raise RuntimeError('ambiguous guest lifetime; preserve installation')
                info = s.fixture_inventory(DEVICE)
                if info:
                    if app and Path(info['Path']).resolve() != app: raise RuntimeError('installation changed')
                    if data:
                        for name in ('ax-oracle.json', 'ax-fixture-lifecycle.log'):
                            p = Path(data[0]) / 'Documents' / name
                            if p.is_file(): (out / ('cleanup-' + name)).write_bytes(p.read_bytes())
                    subprocess.run(['xcrun', 'simctl', 'uninstall', DEVICE, s.BUNDLE], check=True, timeout=8)
                report['fixtureRemoved'] = s.fixture_inventory(DEVICE) is None and not s.fixture_data(DEVICE)
                if not report['fixtureRemoved']: raise RuntimeError('fixture removal unconfirmed')
        except BaseException as error:
            clean = False; report['errors'].append('cleanup: ' + repr(error))
        if clean and before:
            try:
                restored = s.restore_foreground(build, out, DEVICE, before, pp, deadline, guard, stopped)
                report['restorationVerified'] = all(restored[k] == before[k] for k in ('frontPID', 'frontStart', 'frontPath', 'hostPID', 'hostWindows')) and s.display_state(restored) == s.display_state(before)
                if not report['restorationVerified']: raise RuntimeError('restoration readback differs')
            except BaseException as error: report['errors'].append('restoration: ' + repr(error))
        if clean and acquired:
            try: claim.release(); report['claimReleased'] = True
            except BaseException as error: report['errors'].append('claim: ' + repr(error))
        report['attemptedDelivery'] = (out / 'actions.json').exists()
        report['probeLeftovers'] = s.native.instances(build / 'session-probe')
        s.save(out / 'session.json', report)
    return 0 if not report['errors'] else 1


def main():
    if sys.argv[1:2] == ['--worker']:
        if len(sys.argv) != 8: return 64
        return worker(Path(sys.argv[2]), Path(sys.argv[3]), sys.argv[4], int(sys.argv[5]), float(sys.argv[6]), sys.argv[7])
    if len(sys.argv) != 5 or sys.argv[1] not in ('--device', '--udid'): return 64
    try:
        device = str(uuid.UUID(sys.argv[2])).upper()
        if device != sys.argv[2].upper(): return 64
    except ValueError:
        return 64
    build, out = map(lambda p: Path(p).resolve(), sys.argv[3:])
    s.verify_prepared(build)
    out.mkdir(mode=0o700)
    token = str(uuid.uuid4()); deadline = time.monotonic()+200
    env = dict(os.environ, AX_SESSION_WORKER=token)
    guard = s.InputGuard()
    child = subprocess.Popen([sys.executable, '-B', str(HERE / 'session.py'), '--worker', str(build), str(out), token, str(os.getpid()), str(deadline), device], env=env, start_new_session=True)
    report = dict(deadlineSeconds=200, workSeconds=100, budgets='worker1 probe1 fixture1 serializedSimctl1', errors=[])
    def stop(*_): raise InterruptedError('parent interrupted')
    previous = {sig: signal.signal(sig, stop) for sig in (signal.SIGINT, signal.SIGTERM)}
    try:
        while child.poll() is None:
            guard.check()
            if time.monotonic() > deadline-100: raise TimeoutError('work deadline; cooperative cleanup')
            target = out / 'target.json'
            if target.exists() and len(s.native.instances(Path(json.loads(target.read_text())['path']))) > 1: raise RuntimeError('duplicate exact fixture instance')
            time.sleep(.1)
    except BaseException as error:
        report['errors'].append(repr(error)); child.terminate()
    finally:
        for sig in previous: signal.signal(sig, signal.SIG_IGN)
        try: child.wait(timeout=max(1, deadline-time.monotonic()))
        except subprocess.TimeoutExpired: report['errors'].append('worker cleanup deadline exceeded; preserved ownership records, no blind kill')
        report['returncode'] = child.poll()
        report['probeLeftovers'] = s.native.instances(build / 'session-probe')
        s.save(out / 'parent.json', report)
        for sig, handler in previous.items(): signal.signal(sig, handler)
    return 0 if report['returncode'] == 0 and not report['errors'] else 1


if __name__ == '__main__': raise SystemExit(main())
