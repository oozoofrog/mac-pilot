"""One fixed UIKit fixture session. No boot, user-app termination, PGID signals or command runner."""
import argparse
import datetime
import errno
import fcntl
import hashlib
import importlib.util
import json
import math
import os
from pathlib import Path
import plistlib
import re
import signal
import shutil
import subprocess
import tempfile
import sys
import time
import uuid

sys.dont_write_bytecode = True
HERE = Path(__file__).resolve().parent
TESTS = HERE.parent
RESOURCE = TESTS.parent / 'skills/mac-computer-use/scripts/view-capture'
sys.path[:0] = [str(TESTS), str(TESTS / 'view-hierarchy-prototype')]
import native_check_support as native
import remote_watchdog as watchdog
import ui_tool_contract
spec = importlib.util.spec_from_file_location('production_capture', RESOURCE / 'capture.py')
capture = importlib.util.module_from_spec(spec)
spec.loader.exec_module(capture)
BUNDLE = capture.FIXTURE_BUNDLE
APP_NAME = 'HierarchyFixture.app'
EXECUTABLE = 'HierarchyFixture'
TOTAL = 360
WORK = 120  # Stop request leaves 118s maximum capture remainder plus 117s session cleanup.
GRACE = 235
PROBE_BUDGET = 25
CLEANUP_BUDGET = 117
CAPTURE_ADMISSION = 75
RECEIPT = 5
CAPTURE = 163
CLAIMS = Path.home() / 'Library/Application Support/sim-pilot/claims.json'


class InputGuard:
    """Observe only event counts, never keys, coordinates or event contents."""
    def __init__(self, read=None):
        if read is None:
            import ctypes
            core = ctypes.CDLL('/System/Library/Frameworks/ApplicationServices.framework/ApplicationServices')
            counter = core.CGEventSourceCounterForEventType
            counter.argtypes = [ctypes.c_int32, ctypes.c_uint32]
            counter.restype = ctypes.c_uint32
            # Combined session: buttons, motion/drag, keys/modifiers and scroll.
            read = lambda: tuple(counter(0, kind) for kind in (1, 2, 3, 4, 5, 6, 7, 10, 11, 12, 22, 25, 26, 27))
        self.read = read
        self.baseline = read()

    def check(self):
        if self.read() != self.baseline:
            raise InterruptedError('desktop input observed; stop interaction, no forced foreground restoration')


def save(path, value):
    capture.write_json(path, value)


def verify_prepared(build):
    ready = json.loads((build / 'prepared.json').read_text())
    if not ready['dispatchPassed']:
        raise RuntimeError('dispatch guards not proved')
    for name, digest in ready['hashes'].items():
        if hashlib.sha256(Path(name).read_bytes()).hexdigest() != digest:
            raise RuntimeError('prepared source or executable changed: ' + name)


def booted(device):
    raw = subprocess.check_output(['xcrun', 'simctl', 'list', 'devices', 'booted', '-j'], text=True, timeout=5)
    matches = [d for group in json.loads(raw)['devices'].values() for d in group if d['udid'] == device and d['state'] == 'Booted']
    if len(matches) != 1:
        raise RuntimeError('selected device is not uniquely booted; no automatic boot')
    return matches[0]


class Claim:
    def __init__(self, device, token, path=CLAIMS):
        self.device, self.token, self.path, self.lock = device, token, path, None
        self.owner = {'by': token, 'note': 'bounded UIKit fixture validation', 'pid': os.getpid(),
                      'since': datetime.datetime.now(datetime.timezone.utc).isoformat()}

    def acquire(self):
        self.path.parent.mkdir(parents=True, exist_ok=True)
        self.lock = (self.path.parent / ('fixture-session-' + self.device + '.lock')).open('a')
        fcntl.flock(self.lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        raw = json.loads(self.path.read_text()) if self.path.exists() else {}
        if self.device in raw:
            raise RuntimeError('existing claim refused, including stale claims; no force/pruning')
        raw[self.device] = self.owner
        save(self.path, raw)
        self.check()

    def check(self):
        if json.loads(self.path.read_text()).get(self.device) != self.owner:
            raise RuntimeError('claim ownership changed; stop interaction')

    def release(self):
        self.check()
        raw = json.loads(self.path.read_text())
        del raw[self.device]
        save(self.path, raw)
        if json.loads(self.path.read_text()) != raw:
            raise RuntimeError('claim release readback differs')
        if self.lock:
            self.lock.close()


class ProbeCleanupUnknown(RuntimeError):
    pass


def monotonic():
    return capture.monotonic()


def received_deadline(value, total=TOTAL):
    # One wall/monotonic pair at CLI receipt; subsequent clock changes cannot extend the run.
    if not re.fullmatch(r'\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z', value):
        raise ValueError('deadline must be UTC YYYY-MM-DDTHH:MM:SSZ')
    end = datetime.datetime.strptime(value, '%Y-%m-%dT%H:%M:%SZ').replace(tzinfo=datetime.timezone.utc).timestamp()
    wall, sample = time.time(), monotonic()
    remaining = min(total, end - wall)
    if remaining <= 0:
        raise ValueError('deadline has already expired')
    return sample + remaining, {'requestedDeadlineUTC': value, 'receivedUnixSeconds': wall,
                                   'receivedMonotonic': sample, 'clock': 'CLOCK_MONOTONIC', 'receivedRemainingSeconds': remaining}


def session_budget(deadline, edit_qualification=False):
    if edit_qualification:
        import edit_qualification as edit
        if not math.isfinite(deadline) or deadline - monotonic() > edit.TOTAL:
            raise ValueError('invalid edit qualification parent deadline')
        return {'deadlineMonotonic': deadline, 'usableDeadlineMonotonic': deadline - RECEIPT,
                'captureAdmissionMonotonic': deadline - edit.MINIMUM,
                'parentStopMonotonic': deadline - RECEIPT - edit.GRACE}
    if not math.isfinite(deadline) or deadline - monotonic() > TOTAL:
        raise ValueError('invalid parent deadline')
    return {'deadlineMonotonic': deadline, 'usableDeadlineMonotonic': deadline - RECEIPT,
            'captureAdmissionMonotonic': deadline - RECEIPT - CLEANUP_BUDGET - CAPTURE,
            'parentStopMonotonic': deadline - RECEIPT - GRACE}


def read_startup(path):
    with path.open('rb') as stream:
        raw = stream.read(16385)
    if len(raw) > 16384:
        raise watchdog.IdentityChanged('worker startup metadata exceeds bound')
    return json.loads(raw)


def startup_check(deadline, check):
    check()
    if monotonic() >= deadline:
        raise TimeoutError('worker startup cutoff exhausted')


def worker_startup(out, token, parent, deadline, check=lambda: None):
    """No claim/install/launch until exact parent acknowledges this runtime."""
    context = json.loads(os.environ['MAC_CU_FIXTURE_STARTUP'])
    if set(context) != {'owner', 'parent', 'cutoff'} or context['owner'] != token:
        raise watchdog.IdentityChanged('worker startup owner/schema mismatch')
    cutoff = min(deadline, context['cutoff'])
    expected_parent = context['parent']
    if os.getppid() != parent or expected_parent['pid'] != parent or os.environ.get('MAC_CU_FIXTURE_WORKER') != token:
        raise watchdog.IdentityChanged('worker startup parent/token mismatch')
    def current(pid):
        startup_check(cutoff, check)
        value = watchdog.lifetime(watchdog.process_identity(pid))
        startup_check(cutoff, check)
        return value
    actual = current(os.getpid())
    if (actual['parent'] != parent or actual['group'] != actual['pid']
            or actual['path'] != expected_parent['path'] or current(parent) != expected_parent):
        raise watchdog.IdentityChanged('worker startup runtime/parent mismatch')
    ready = dict(version=1, owner=token, parent=expected_parent, worker=actual)
    save(out / 'worker-ready.json', ready)
    while True:
        if current(parent) != expected_parent or current(os.getpid()) != actual:
            raise watchdog.IdentityChanged('worker changed before startup acknowledgement')
        try:
            ack = read_startup(out / 'worker-ack.json')
        except FileNotFoundError:
            time.sleep(.01)
            continue
        if ack != ready:
            raise watchdog.IdentityChanged('worker startup acknowledgement mismatch')
        if current(parent) != expected_parent or current(os.getpid()) != actual:
            raise watchdog.IdentityChanged('worker changed after startup acknowledgement')
        return ready


def await_worker_ready(child, out, token, parent_identity, deadline, check, details):
    """One bounded launch phase; only the parent's own runtime image can be ready.

    Launch evidence is retained independently. It is never target authority.
    The unreaped direct Popen handle binds PID custody throughout this boundary.
    """
    cutoff = min(deadline, monotonic() + watchdog.PROCESS_READ_TIMEOUT_SECONDS)
    def current(pid):
        startup_check(cutoff, check)
        value = watchdog.lifetime(watchdog.process_identity(pid))
        startup_check(cutoff, check)
        return value
    initial = current(child.pid)
    details['workerLaunch'] = initial
    expected = dict(initial, path=parent_identity['path'])
    if (initial['pid'] != child.pid or initial['parent'] != parent_identity['pid'] or initial['group'] != child.pid
            or initial['path'] not in (str(Path(sys.executable).resolve()), expected['path'])):
        raise watchdog.IdentityChanged('unexpected worker launch identity')
    reached_runtime = initial['path'] == expected['path']
    ready = dict(version=1, owner=token, parent=parent_identity, worker=expected)
    while True:
        startup_check(cutoff, check)
        if child.poll() is not None:
            raise RuntimeError('worker exited before startup acknowledgement')
        if current(parent_identity['pid']) != parent_identity:
            raise watchdog.IdentityChanged('startup parent lifetime changed')
        actual = current(child.pid)
        if actual != (expected if reached_runtime else initial) and actual != expected:
            raise watchdog.IdentityChanged('worker startup lifetime/image changed')
        reached_runtime = reached_runtime or actual == expected
        try:
            published = read_startup(out / 'worker-ready.json')
        except FileNotFoundError:
            time.sleep(.01)
            continue
        if published != ready or actual != expected or current(child.pid) != expected:
            raise watchdog.IdentityChanged('worker runtime readiness mismatch')
        startup_check(cutoff, check)
        details['workerReady'] = ready
        details['worker'] = dict(expected)
        save(out / 'worker-ack.json', ready)
        return


def guard_worker(out, deadline, token, parent, edit_qualification=False):
    if os.getppid() != parent or os.environ.get('MAC_CU_FIXTURE_WORKER') != token:
        raise RuntimeError('guard worker requires exact parent/token')
    received = monotonic()
    report = dict(session_budget(deadline, edit_qualification), guard=True, mutationCount=0, parentPID=parent, workerPID=os.getpid(),
                  workerReceivedMonotonic=received, workerRemainingAtReceiptSeconds=deadline-received, clock='CLOCK_MONOTONIC')
    try:
        reserve(report['captureAdmissionMonotonic'], 0, 'guard admission including all cleanup reserves')
        worker_startup(out, token, parent, report['captureAdmissionMonotonic'])
        report['passed'] = True
    except Exception as error:
        report.update(passed=False, error=str(error))
    save(out / 'session.json', report)
    return 0 if report['passed'] else 1


def reserve(deadline, seconds, label):
    if deadline - monotonic() < seconds:
        raise TimeoutError('insufficient session deadline for ' + label + '; incomplete, preserve claim')


class ProbeFamilyReadback:
    """Over-approximate discovered descendants for cleanup, never admission/signaling."""
    def __init__(self, child, executable):
        self.child, self.executable = child, str(executable.resolve())
        self.pids, self.groups = {child.pid}, {child.pid}
        self.report = {'signalAuthority': False, 'samples': [], 'directPID': child.pid}

    def sample(self, cutoff=None):
        cutoff = cutoff if cutoff is not None else monotonic() + watchdog.PROCESS_READ_TIMEOUT_SECONDS
        rows = watchdog.rows(timeout=max(.001, cutoff - monotonic()))
        while True:
            found = {r[0] for r in rows if r[1] in self.pids or r[2] in self.groups}
            if found <= self.pids:
                break
            self.pids |= found
        selected = [r for r in rows if r[0] in self.pids]
        self.groups |= {r[2] for r in selected}
        self.report['samples'].append({'rows': selected, 'identities': []})
        for row in selected:
            unreaped_direct = row[0] == self.child.pid and self.child.returncode is None
            value = watchdog.identify_live_server(row[0])
            entry = {'pid': row[0], 'status': 'unknown' if value is watchdog.UNVERIFIED else 'terminal' if value is None else 'live',
                     'identity': value if isinstance(value, dict) else None}
            self.report['samples'][-1]['identities'].append(entry)
            if value is watchdog.UNVERIFIED:
                # An exiting direct child can lose its executable path before
                # waitpid reports completion. Its unreaped Popen handle binds
                # that lifetime; this grants no descendant or signal authority.
                if not unreaped_direct or self.child.poll() != 0:
                    raise ProbeCleanupUnknown('probe family identity unavailable')
                entry.update(status='directReaped', returncode=0, basis='previously unreaped direct Popen child')
            if monotonic() >= cutoff:
                raise ProbeCleanupUnknown('probe family readback acceptance cutoff exhausted')
        if sum(r[3] == self.executable for r in rows) > 1:
            raise ProbeCleanupUnknown('read-only probe executable budget exceeded')
        if monotonic() >= cutoff:
            raise ProbeCleanupUnknown('probe family readback acceptance cutoff exhausted')
        return selected

    def finish(self, normal_exit):
        cutoff = monotonic() + watchdog.PROCESS_READ_TIMEOUT_SECONDS
        remaining = self.sample(cutoff)
        normal_exit = normal_exit and self.child.returncode == 0
        self.report.update(groups=sorted(self.groups), discoveredPIDs=sorted(self.pids),
                           directReaped=self.child.returncode is not None, remaining=remaining,
                           normalExit=normal_exit, unobservedDescendantsPossible=not normal_exit)
        # A killed/failed probe may have spawned an unsampled child in its own group.
        # Empty sampled groups cannot repair that lost custody evidence.
        if remaining or not normal_exit:
            raise ProbeCleanupUnknown('probe family cleanup unproved; no descendant signal authority')
        self.report['terminalReads'] = []
        for pid in self.pids:
            try:
                os.kill(pid, 0)
            except ProcessLookupError:
                self.report['terminalReads'].append({'pid': pid, 'read': 'kill0', 'status': 'ESRCH'})
                if monotonic() >= cutoff:
                    raise ProbeCleanupUnknown('probe family terminal read acceptance cutoff exhausted')
                continue
            except OSError as error:
                raise ProbeCleanupUnknown('discovered probe family PID state unknown') from error
            raise ProbeCleanupUnknown('discovered probe family PID still live/zombie')
        self.report['observedFamilyEmpty'] = True


def probe(build, out, name, device, result=None):
    env = {k: v for k, v in os.environ.items() if not k.startswith(('MAC_CU_', 'DYLD_', 'PYTHON', 'FIXTURE_'))}
    env['FIXTURE_DEVICE'] = device
    if result:
        env['FIXTURE_CAPTURE_RESULT'] = str(result)
    # Fixed CLI-only read/conversion route. Its children cannot attach or start UIKit.
    # Reuse direct-child watchdog operations; never native_check_support's PGID cleanup.
    executable = build / 'session-probe'
    started = monotonic()
    if native.instances(executable):
        raise ProbeCleanupUnknown('exact read-only probe executable already runs')
    child = None
    family = None
    failure = None
    with (out / (name + '.json')).open('w') as log:
        try:
            if monotonic() - started >= 12:
                raise TimeoutError('read-only probe deadline exceeded before launch')
            child = subprocess.Popen([str(executable), '--native-check'], env=env, stdin=subprocess.DEVNULL,
                                     stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
            family = ProbeFamilyReadback(child, executable)
            family.sample()
            while child.poll() is None:
                family.sample()
                # Sampling ends by 15s; reserve 2+2+3+3 for direct cleanup and
                # root/family readbacks inside the unchanged complete 25s budget.
                if monotonic() - started >= 12:
                    raise TimeoutError('read-only probe deadline exceeded')
                time.sleep(.05)
            if child.returncode != 0:
                raise RuntimeError('read-only canonical probe failed: ' + name)
        except BaseException as error:
            failure = error
        finally:
            if child:
                try:
                    family.report['operationError'] = repr(failure) if failure else None
                    grace, finish = {}, {}
                    family.report.update(grace=grace, directFinish=finish)
                    watchdog.graceful_stop(child, grace, timeout=2)
                    watchdog.finish_direct_worker(child, finish, timeout=2)
                    group = watchdog.wait_group_readback(child.pid, timeout=0)
                    family.report['rootGroupReadback'] = group
                    if not group['groupEmpty']:
                        raise ProbeCleanupUnknown('probe helper live/zombie/unknown residual; no descendant signal authority')
                    family.finish(failure is None and child.returncode == 0)
                except Exception as error:
                    raise ProbeCleanupUnknown('probe direct-child cleanup incomplete: ' + repr(error)) from error
                finally:
                    if family:
                        save(out / (name + '-processes.json'), family.report)
    if monotonic() - started > PROBE_BUDGET:
        raise ProbeCleanupUnknown('probe exceeded complete 25s budget')
    if failure:
        raise failure
    value = capture.read_json(out / (name + '.json'))
    if 'hostPID' in value:
        host = capture.ProcessProbe().identity(value['hostPID'])
        value.update(hostStart=host['start'], hostPath=host['path'])
        save(out / (name + '.json'), value)
    return value


def display_state(state):
    return [{k: d.get(k) for k in ('displayId', 'currentOrientation', 'active', 'primary', 'size', 'type')}
            for d in state['displays']]


def require_static_portrait(state):
    displays = [d for d in state['displays'] if 'integrated' in d.get('type', {})]
    if len(displays) != 1 or not displays[0].get('active') or displays[0].get('currentOrientation') != 'rot0':
        raise RuntimeError('this one-shot validation supports one already-active portrait screen only')
    if not state['desktopUnlocked']:
        raise RuntimeError('desktop is locked')


def restore_foreground(build, out, device, before, process_probe, deadline, input_guard=None, stopped=False):
    reserve(deadline, 2 * PROBE_BUDGET + 8, "foreground restore and confirmation")
    current = probe(build, out, 'pre-restore', device)
    if (current['hostPID'] != before['hostPID'] or current.get('hostStart') != before.get('hostStart')
            or current.get('hostPath') != before.get('hostPath')):
        raise RuntimeError('host focus changed; no foreground restoration input')
    if current['frontPID'] != before['frontPID']:
        if stopped:
            raise InterruptedError('cancelled; no foreground restoration launch')
        if input_guard:
            input_guard.check()
        original = process_probe.identity(before['frontPID'], device=True)
        if (original['start'] != before['frontStart'] or original['path'] != before['frontPath']
                or original['deviceID'] != device or original['state'] not in (2, 3) or original['traced']):
            raise RuntimeError('original foreground lifetime unavailable; no relaunch')
        # Restore an already-running original app; never terminate or create a replacement lifetime.
        text = subprocess.check_output(['xcrun', 'simctl', 'launch', device, before['frontBundle']], text=True, timeout=8)
        if text.strip() != before['frontBundle'] + ': ' + str(before['frontPID']):
            raise RuntimeError('foreground restoration returned a different lifetime')
        return probe(build, out, 'restored', device)
    return current


def fixture_inventory(device):
    raw = subprocess.check_output(['xcrun', 'simctl', 'listapps', device], timeout=8)
    converted = subprocess.run(['/usr/bin/plutil', '-convert', 'json', '-o', '-', '-'], input=raw,
                               stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=True, timeout=3)
    apps = json.loads(converted.stdout)
    # Data containers are checked separately: orphan fixture data is also preserved.
    return apps.get(BUNDLE)


def fixture_data(device, deadline=None):
    device_root = Path(booted(device)['dataPath'])
    found = []
    for p in (device_root / 'Containers/Data/Application').glob('*/.com.apple.mobile_container_manager.metadata.plist'):
        if deadline is not None:
            reserve(deadline, 0, 'fixture data scan')
        if plistlib.loads(p.read_bytes()).get('MCMMetadataIdentifier') == BUNDLE:
            found.append(str(p.parent))
    return found


def residual(probe_, target):
    try:
        current = probe_.status(target['pid'])
    except Exception as error:
        try:
            os.kill(target['pid'], 0)
        except ProcessLookupError:
            return {'state': 'gone'}
        return {'state': 'unknown', 'error': str(error)}
    if current['start'] != target['start']:
        return {'state': 'identityChanged', 'current': current}
    if current['state'] == 5:
        return {'state': 'zombie', 'current': current, 'reapOwner': current['parent']}
    try:
        current = probe_.identity(target['pid'], device=True)
        if not capture.same_target(current, target):
            return {'state': 'identityChanged', 'current': current}
        return {'state': 'live', 'current': current}
    except Exception as error:
        return {'state': 'unknown', 'error': str(error)}


def finish_capture(child, folder, interrupted, check=lambda: None, deadline=None):
    deadline = deadline if deadline is not None else monotonic() + CAPTURE
    while child.poll() is None:
        if interrupted() or monotonic() >= deadline - 18:
            (folder / 'cancel').touch(mode=0o600, exist_ok=True)
        try:
            check()
        except Exception:
            (folder / 'cancel').touch(mode=0o600, exist_ok=True)
            child.wait(timeout=max(0.1, deadline - monotonic()))
            raise
        if monotonic() >= deadline:
            # Never kill the reaper while it could own a debugger. Preserve evidence/claim instead.
            raise TimeoutError('production supervisor exceeded full 163s; reaper not killed, recovery unknown')
        time.sleep(.1)
    child.wait(timeout=1)
    return child.returncode


def fixture_launch_arguments(device, token):
    return ['xcrun', 'simctl', 'launch', device, BUNDLE, '--fixture-session', token]


def preserve_fixture_evidence(data, out, stage):
    evidence = {}
    for name, destination, limit in (('geometry-oracle.json', 'oracle-' + stage + '.json', capture.MAX_BYTES),
                                     ('edit-oracle.json', 'edit-oracle-' + stage + '.json', 262144),
                                     ('fault-events.json', 'fault-events-' + stage + '.json', 262144),
                                     ('fault-control.json', 'fault-control-' + stage + '.json', 4096),
                                     ('restart-control.json', 'restart-control-' + stage + '.json', 8192),
                                     ('fixture-lifecycle.log', 'fixture-lifecycle-' + stage + '.log', 1024 * 1024)):
        source = Path(data) / 'Documents' / name
        if source.is_file():
            if source.is_symlink() or source.stat().st_size > limit:
                raise RuntimeError('owned fixture evidence exceeds its safe file boundary')
            shutil.copyfile(source, out / destination)
            evidence[name] = {'preservedAs': destination, 'bytes': (out / destination).stat().st_size}
        else:
            evidence[name] = {'available': False}
    entry = Path(data) / '.recording-entry-v1'
    if entry.exists():
        import ui_capture_contract as artifacts
        for name in ('bootstrap.json','arm.claim','restart.pending.json','restart.consumed.json','restart.spent'):
            try: raw, pin = artifacts.read_file(entry / name, limit=8192)
            except artifacts.ContractError as error:
                if isinstance(error.__cause__, FileNotFoundError): continue
                raise
            destination = 'recording-' + stage + '-' + name
            (out / destination).write_bytes(raw)
            evidence[name] = dict(preservedAs=destination, bytes=len(raw), sha256=pin.sha256)
    return evidence


def wait_for_oracle(oracle, probe_, target, stopping):
    deadline = monotonic() + 8
    while not oracle.is_file():
        observed = residual(probe_, target)
        if observed['state'] != 'live':
            raise RuntimeError('fixture oracle unavailable; exact target residual: ' + json.dumps(observed))
        if stopping() or monotonic() >= deadline:
            raise TimeoutError('fixture oracle not ready')
        time.sleep(.1)


def worker(build, out, device, token, parent, absolute_deadline, texture_probe=False, edit_qualification=False, failure_case=None, experiment=None):
    received = monotonic()
    import edit_qualification as edit
    total, work, grace = (edit.TOTAL, edit.WORK, edit.GRACE) if edit_qualification else (TOTAL, WORK, GRACE)
    budget = session_budget(absolute_deadline, edit_qualification)
    started = absolute_deadline - total
    deadline = budget['usableDeadlineMonotonic']
    if os.getppid() != parent or os.environ.get('MAC_CU_FIXTURE_WORKER') != token:
        raise RuntimeError('worker requires exact parent/token')
    stopping = False
    def stop(*_):
        nonlocal stopping
        stopping = True
    for sig in (signal.SIGTERM, signal.SIGINT):
        signal.signal(sig, stop)
    report = {'passed': False, 'budget': {'total': total, 'work': work, 'cleanup': grace, 'capture': CAPTURE},
              'captureAdmissionSeconds': CAPTURE_ADMISSION, 'cleanupBudgetSeconds': CLEANUP_BUDGET,
              'absoluteDeadlineMonotonic': deadline, 'workerReceivedMonotonic': received,
              'workerRemainingAtReceiptSeconds': absolute_deadline-received, 'deadlineMonotonic': absolute_deadline,
              'clock': 'CLOCK_MONOTONIC', 'fixtureWaitAuthority': False, 'fixtureBudget': 1, 'errors': []}
    if edit_qualification:
        report.update(mode='schema2-edit-qualification', setupBudgetSeconds=edit.SETUP,
                      fullSequenceAdmissionSeconds=edit.MINIMUM, operationCount=edit.COUNT)
        report.pop('captureAdmissionSeconds')
        if failure_case:
            report.update(mode='schema2-failure-qualification', failureCase=failure_case, operationCount=2)
    claim = Claim(device, token)
    owned_claim = installed = False
    target = before = data = app = child = target_binding = None
    input_guard = None
    cleanup_unknown = False
    pp = capture.ProcessProbe()
    try:
        verify_prepared(build)
        if edit_qualification:
            edit.require_full_preparation(build)
        reserve(budget['captureAdmissionMonotonic'], 0, 'worker admission before claim or fixture mutation')
        input_guard = InputGuard()
        report['inputGuard'] = 'combined session event counters; no event contents'
        def startup_input():
            input_guard.check()
            if stopping:
                raise InterruptedError('cancelled before worker startup admission')
        worker_startup(out, token, parent, budget['captureAdmissionMonotonic'], startup_input)
        report['inventory'] = booted(device)
        claim.acquire(); owned_claim = True
        before = probe(build, out, 'before', device)
        require_static_portrait(before)
        report['before'] = before
        if edit_qualification or experiment is not None:
            input_guard = edit.DesktopGuard(input_guard, before['hostPID'])
        if fixture_inventory(device) or fixture_data(device):
            raise RuntimeError('existing fixture app/data preserved; refusing install')
        input_guard.check()
        if stopping:
            raise InterruptedError('cancelled before install')
        claim.check()
        reserve(budget['captureAdmissionMonotonic'], 0, 'fixture install admission')
        # This identity cannot exist before installation; no --terminate-running-process.
        installed = True  # A partial install is also inspected in finally; never silently abandoned.
        subprocess.run(['xcrun', 'simctl', 'install', device, str(build / APP_NAME)], check=True, timeout=12)
        info = fixture_inventory(device)
        app = Path(info['Path']).resolve()
        if plistlib.loads((app / 'Info.plist').read_bytes())['CFBundleIdentifier'] != BUNDLE:
            raise RuntimeError('installed fixture identity mismatch')
        data = fixture_data(device)
        if len(data) != 1:
            raise RuntimeError('fixture data container identity ambiguous')
        report.update(installedApp=str(app), ownedData=data)
        claim.check()
        input_guard.check()
        if stopping:
            raise InterruptedError('cancelled before launch')
        reserve(budget['captureAdmissionMonotonic'], 0, 'fixture launch admission')
        env = {k: v for k, v in os.environ.items() if not k.startswith(('SIMCTL_CHILD_', 'MAC_CU_', 'DYLD_', 'PYTHON'))}
        env['SIMCTL_CHILD_MAC_CU_FIXTURE_SESSION'] = token
        launch_at = time.time()
        launch_arguments = fixture_launch_arguments(device, token)
        report['fixtureDiagnostics'] = 'owned app Documents/fixture-lifecycle.log; host copy before uninstall'
        report['orientationContract'] = {'fixtureSupported': 'portrait only', 'physicalPose': 'unobserved, no pose input sent',
                                         'displayReadback': 'guest framebuffer orientation, not physical pose'}
        text = subprocess.check_output(launch_arguments,
                                       env=env, text=True, timeout=10)
        match = re.fullmatch(re.escape(BUNDLE) + r': (\d+)\s*', text)
        if not match:
            raise RuntimeError('ambiguous fixture launch PID; no signal authority')
        pid = int(match[1])
        identity = pp.identity(pid, device=True)
        target = {k: identity[k] for k in ('pid', 'start', 'path', 'deviceID')}
        if (target['path'] != str(app / EXECUTABLE) or target['deviceID'] != device
                or target['start'][0] + target['start'][1] / 1e6 < launch_at - 1):
            target = None
            raise RuntimeError('fixture start/path/device ownership not proved')
        capture.verify_target(pp, target)
        report['target'] = target
        target_binding = publish_target_binding(out, target, pp, token, budget['captureAdmissionMonotonic'], input_guard)
        # Launchd owns fixture wait/reap. The session only observes exact identity and asks simctl to terminate.
        oracle = Path(data[0]) / 'Documents/geometry-oracle.json'
        wait_for_oracle(oracle, pp, target, lambda: stopping)
        report['readyEvidence'] = preserve_fixture_evidence(data[0], out, 'before')
        observed = probe(build, out, 'fixture-state', device)
        if (observed['frontPID'] != pid or observed['frontStart'] != target['start'] or observed['frontPath'] != target['path']
                or observed['deviceID'] != device or observed['hostPID'] != before['hostPID']
                or observed.get('hostStart') != before.get('hostStart') or observed.get('hostPath') != before.get('hostPath')):
            raise RuntimeError('foreground guard changed; no further input')
        require_static_portrait(observed)
        if experiment is not None:
            # A fixed sibling harness may reuse protected fixture ownership and
            # restoration without forking this lifecycle or production schemas.
            wait_for_oracle(Path(data[0]) / 'Documents/edit-oracle.json', pp, target, lambda: stopping)
            report['experiment'] = experiment(sys.modules[__name__], build, out, device, target, before,
                                               data[0], claim, input_guard, lambda: stopping, deadline)
            report['qualificationPassed'] = report['experiment']['passed']
        elif edit_qualification:
            wait_for_oracle(Path(data[0]) / 'Documents/edit-oracle.json', pp, target, lambda: stopping)
            if failure_case:
                import failure_qualification as faults
            runtime_type = faults.Runtime if failure_case else edit.Runtime
            runtime = runtime_type(sys.modules[__name__], build, out, device, target, before, data[0],
                                   claim, input_guard, lambda: stopping, deadline)
            try:
                if failure_case:
                    qualification = faults.run(runtime, failure_case)
                    report['qualificationPassed'] = qualification['qualified']
                    report['failureEvidence'] = 'failure-case.json'
                else:
                    edit.Sequence(runtime).run()
                report['editQualification'] = {'operationCount': len(runtime.records),
                    'sequenceEvidence': 'edit-sequence.json', 'captureTTLSeconds': 120,
                    'generalAppQualified': False, 'renderedUIQualified': False}
            finally:
                child = runtime.child
                runtime.persist()
        else:
            folder = out / 'capture'; folder.mkdir(mode=0o700)
            request = {'schemaVersion': 1, 'target': target, 'query': '', 'validationOnly': True}
            if texture_probe:
                request['validationTextureProbe'] = True
            save(folder / 'request.json', request)
            claim.check()
            input_guard.check()
            if stopping:
                raise InterruptedError('cancelled before capture')
            reserve(started + CAPTURE_ADMISSION, 0, 'capture admission')
            reserve(deadline, CAPTURE + CLEANUP_BUDGET, 'full capture and subsequent session cleanup')
            capture_deadline = monotonic() + CAPTURE
            report['captureStartedOffsetSeconds'] = monotonic() - started
            with (out / 'capture-result.json').open('w') as log:
                child = subprocess.Popen([sys.executable, '-I', str(RESOURCE / 'capture.py'), '--capture', str(folder / 'request.json')],
                                         stdin=subprocess.DEVNULL, stdout=log, stderr=log)
                def capture_check():
                    claim.check()
                    input_guard.check()
                finish_capture(child, folder, lambda: stopping, check=capture_check, deadline=capture_deadline)
            result = json.loads((out / 'capture-result.json').read_text())
            report['captureStatus'] = result.get('status')
            if result.get('status') != 'success':
                raise RuntimeError('production capture: ' + result.get('status', 'missing'))
            if stopping:
                raise InterruptedError('session cancelled; capture cleanup completed')
            input_guard.check()
            capture.verify_target(pp, target)
            claim.check()
            reserve(deadline, CLEANUP_BUDGET + 2 * PROBE_BUDGET + 8 + 12, 'post-capture reads and cleanup')
            after_capture = probe(build, out, 'after-capture', device)
            if after_capture['frontPID'] != pid or after_capture['hostPID'] != before['hostPID']:
                raise RuntimeError('foreground changed during capture; no screenshot')
            save(out / 'oracle-after.json', json.loads(oracle.read_text()))
            subprocess.run(['xcrun', 'simctl', 'io', device, 'screenshot', str(out / 'device.png')], check=True, timeout=8)
            snapshot = probe(build, out, 'snapshot', device, out / 'capture-result.json')
            import compare
            diagnostic = compare.diagnose(result, snapshot, json.loads(oracle.read_text()), out / 'device.png')
            save(out / 'geometry-diagnostics.json', diagnostic)
            report['geometryDiagnostics'] = 'geometry-diagnostics.json'
            report['comparison'] = compare.check(result, snapshot, json.loads(oracle.read_text()), out / 'device.png')
        report['passed'] = report.get('qualificationPassed', True)
    except BaseException as error:
        cleanup_unknown = isinstance(error, ProbeCleanupUnknown)
        report['errors'].append(repr(error))
    finally:
        # Ignore further interrupt requests while the capture's own finally/reaper completes.
        for sig in (signal.SIGTERM, signal.SIGINT):
            signal.signal(sig, signal.SIG_IGN)
        recording_worker = getattr(claim, 'recording', None)
        if recording_worker is not None:
            try:
                target_binding = recording_worker.cleanup_binding()
                target = target_binding['target']
                report['targetHistories'] = [recording_worker.binding, target_binding]
                report['currentCleanupTarget'] = target
            except Exception as error:
                cleanup_unknown = True
                report['errors'].append('recording custody unresolved; preserve both lifetimes: ' + repr(error))
        safe = not cleanup_unknown and (child is None or child.poll() is not None)
        report['cleanupStartedOffsetSeconds'] = monotonic() - started
        if not safe:
            report['errors'].append('capture/probe cleanup unverified; claim and fixture preserved; no force termination')
            if data:
                try:
                    report['preservedFailureEvidence'] = preserve_fixture_evidence(data[0], out, 'preserved')
                except Exception as error:
                    report['errors'].append('failure evidence readback: ' + repr(error))
        if safe and installed:
            try:
                reserve(deadline, CLEANUP_BUDGET, 'complete fixture cleanup and restore')
                claim.check()
                if target:
                    if target_binding is not None:
                        # This phase permits exit observation, never termination
                        # authority. residual() below still guards the actual stop.
                        publish_target_cleanup(out, target_binding)
                    seen = residual(pp, target)
                    report['fixtureBeforeStop'] = seen
                    if seen['state'] == 'live':
                        if seen['current']['traced'] or seen['current']['state'] not in (2, 3):
                            raise RuntimeError('fixture stopped/traced; preserve it for recovery review')
                        subprocess.run(['xcrun', 'simctl', 'terminate', device, BUNDLE], check=True, timeout=8)
                        until = monotonic() + 4
                        while residual(pp, target)['state'] == 'live' and monotonic() < until:
                            time.sleep(.1)
                    report['fixtureResidual'] = residual(pp, target)
                    if report['fixtureResidual']['state'] != 'gone':
                        raise RuntimeError('fixture live/zombie/unknown; launchd owns reap, no signal/reap attempt')
                elif app:
                    # Failed launch identity is not authority to terminate an unknown process.
                    exact = native.instances(app / EXECUTABLE)
                    if exact:
                        raise RuntimeError('fixture PID ownership ambiguous; preserve app/data')
                if data:
                    report['cleanupEvidence'] = preserve_fixture_evidence(data[0], out, 'cleanup')
                reserve(deadline, 11 + 8 + 11 + 5 + 58, 'uninstall/readback and restore')
                if app is None or Path(fixture_inventory(device)['Path']).resolve() != app:
                    raise RuntimeError('fixture installation identity changed; preserve data')
                subprocess.run(['xcrun', 'simctl', 'uninstall', device, BUNDLE], check=True, timeout=8)
                report['fixtureRemoved'] = fixture_inventory(device) is None and not fixture_data(device, deadline)
                if not report['fixtureRemoved']:
                    raise RuntimeError('fixture removal not confirmed')
            except Exception as error:
                safe = False
                report['errors'].append('fixture cleanup: ' + repr(error))
        if safe and before:
            try:
                # Bring back only the original, still-running lifetime when termination exposes SpringBoard.
                restored = restore_foreground(build, out, device, before, pp, deadline, input_guard, stopping)
                report['restored'] = restored
                if (restored['frontPID'] != before['frontPID'] or restored['frontStart'] != before['frontStart']
                        or restored['frontBundle'] != before['frontBundle'] or display_state(restored) != display_state(before)
                        or restored['hostPID'] != before['hostPID'] or restored['hostWindows'] != before['hostWindows']
                        or restored.get('hostStart') != before.get('hostStart') or restored.get('hostPath') != before.get('hostPath')):
                    raise RuntimeError('original foreground/pose/layout differs; preserved for review')
                report['restorationVerified'] = True
            except Exception as error:
                safe = False
                report['errors'].append('restoration: ' + repr(error))
        if safe and owned_claim:
            try:
                reserve(deadline, 0, 'claim release')
                claim.release(); report['claimReleased'] = True
            except Exception as error:
                report['errors'].append('claim: ' + repr(error))
        report['passed'] = report['passed'] and not report['errors']
        report['elapsedSeconds'] = monotonic() - started
        report['deadlineRemainingSeconds'] = deadline - monotonic()
        if report['deadlineRemainingSeconds'] < 0:
            report['passed'] = False
            report['errors'].append('absolute session cleanup deadline exceeded; incomplete')
        save(out / 'session.json', report)
    return 0 if report['passed'] else 1


def observe_servers(snapshot, group, server_path, report):
    count = 0
    for pid, parent, pgid, path, stat in snapshot:
        if pgid != group or path != str(server_path):
            continue
        observed = watchdog.identify_live_server(pid)
        entry = {'pid': pid, 'parent': parent, 'group': pgid, 'sampleState': stat,
                 'signalAuthority': False, 'monotonicNs': int(monotonic() * 1000000000)}
        if observed is None:
            entry['status'] = 'goneOrZombie'
        elif observed is watchdog.UNVERIFIED:
            entry['status'] = 'unknown'
            count += 1
        else:
            entry.update(status='live', identity=observed)
            # Readback never confers ownership/signal rights on this observer.
            if observed['path'] != str(server_path):
                entry['status'] = 'identityChangedUnknown'
            count += 1
        report['serverObservations'].append(entry)
    if len(report['serverObservations']) > 512:
        del report['serverObservations'][:-512]
    return count


def probe_tool_paths(server_path):
    paths = {'/usr/bin/env', '/usr/bin/xcrun', '/usr/bin/xcode-select', '/usr/bin/xcodebuild',
             '/usr/bin/codesign', '/usr/bin/plutil', '/bin/ps',
             '/Library/Developer/PrivateFrameworks/CoreSimulator.framework/Versions/A/Resources/bin/simctl',
             '/Library/Developer/PrivateFrameworks/CoreDevice.framework/Versions/A/Resources/bin/devicectl'}
    if server_path is not None:
        contents = next((p for p in Path(server_path).parents if p.name == 'Contents'), None)
        if contents:
            paths.update(str(contents / 'Developer/usr/bin' / name) for name in ('simctl', 'xcodebuild'))
    return paths


UI_PROCESS_CONTRACT = None

def bind_ui_process_contract(ui_build, build, device, output):
    """Parent and worker bind only freshly verified manifests before children."""
    global UI_PROCESS_CONTRACT
    verify_prepared(build); verify_prepared(ui_build)
    manifest = json.loads((ui_build / "prepared.json").read_text())
    binary = (ui_build / "InspectorProductCheck.app/Contents/MacOS/check").resolve()
    resource = (binary.parent.parent / "Resources/view-capture/capture.py").resolve()
    if manifest["product"] != str(build.resolve()) or manifest["binary"] != str(binary):
        raise RuntimeError("UI/product manifest binding differs")
    if any(str(p) not in manifest["hashes"] for p in (binary, resource)):
        raise RuntimeError("UI executable/resource is not pinned")
    tool_hashes = manifest.get('uiToolHashes')
    if not isinstance(tool_hashes, dict) or any(
            manifest['hashes'].get(str(Path(path).resolve())) != digest
            for path, digest in tool_hashes.items()):
        raise RuntimeError('UI selected tool inputs are not prepared pins')
    ui_tool_contract.Configuration.read(ui_tool_contract.DEVELOPER, tool_hashes)
    resources = resource.parent
    resource_pins = {p.name: manifest['hashes'].get(str(p.resolve()))
                     for p in resources.iterdir() if p.is_file()}
    if any(value is None for value in resource_pins.values()):
        raise RuntimeError('UI capture resource is outside prepared pins')
    UI_PROCESS_CONTRACT = dict(binary=str(binary), capture=str(resource), device=device,
        output=str(output.resolve()), temporary=str(Path(tempfile.gettempdir()).resolve()),
        toolHashes=tool_hashes, resourcePins=resource_pins, binarySHA256=manifest['hashes'][str(binary)])
    return dict(UI_PROCESS_CONTRACT)

def probe_family_options(build, server_path):
    """Selected Xcode aliases, not arbitrary interpreters or the host's PATH Python."""
    contents = next((p for p in Path(server_path).parents if p.name == 'Contents'), None) if server_path else None
    developer = contents / 'Developer' if contents else None
    python = (developer / 'usr/bin/python3').resolve() if developer else None
    aliases = (str(python), str((python.parent.parent / 'Resources/Python.app/Contents/MacOS/Python').resolve())) if python else ()
    return dict(isolated_probe=str((build / 'session-probe').resolve()) if server_path is not None else None,
                probe_tools=probe_tool_paths(server_path), probe_python=aliases,
                probe_developer=str(developer) if developer else None, ui_contract=UI_PROCESS_CONTRACT if server_path else None)


def without_read_probe_helpers(members, details):
    """Shared observer has checked these roles; preserve them in the diagnostic sample."""
    observation = watchdog._observation.get()
    if observation is None:
        return members
    helpers = [r for r in members if r[0] in observation.probe_members]
    # Only the candidate row is deferred during partial checks. Its descendants
    # remain members. Final acceptance additionally requires target_valid.
    members = [r for r in members if not observation.target_candidate(r[0])]
    details['readProbeHelpers'] = helpers
    return [r for r in members if r[0] not in observation.probe_members]


def publish_target_binding(out, target, process_probe, token, deadline, input_guard):
    observation = watchdog.ProcessObservation(monotonic, deadline, input_guard.check)
    def read(pid):
        observation.check()
        value = watchdog.process_identity(pid)
        observation.check()
        return value
    first = read(target['pid'])
    if any(first[k] != target[k] for k in ('pid', 'start', 'path')):
        raise RuntimeError('prepublication target kernel mismatch')
    observation.check()
    actual = process_probe.identity(target['pid'], device=True)
    observation.check()
    if (any(actual.get(k) != v for k, v in target.items()) or actual.get('traced') is not False
            or actual.get('state') not in (2, 3) or actual.get('parent') != first['parent']):
        raise RuntimeError('prepublication target identity not untraced/bound')
    parent_identity = read(first['parent'])
    worker_identity = read(os.getpid())
    if worker_identity['group'] != worker_identity['pid']:
        raise RuntimeError('publication worker is not session group leader')
    again = process_probe.identity(target['pid'], device=True)
    observation.check()
    if (watchdog.lifetime(read(target['pid'])) != watchdog.lifetime(first)
            or any(again.get(k) != actual.get(k) for k in ('pid', 'start', 'path', 'deviceID', 'parent', 'traced'))
            or again.get('state') not in (2, 3)
            or watchdog.lifetime(read(parent_identity['pid'])) != watchdog.lifetime(parent_identity)
            or watchdog.lifetime(read(worker_identity['pid'])) != watchdog.lifetime(worker_identity)):
        raise RuntimeError('prepublication lifetime changed')
    binding = dict(version=1, owner=token, worker=watchdog.lifetime(worker_identity), target=target,
                   group=first['group'], originalParent=watchdog.lifetime(parent_identity))
    watchdog.validate_target_binding(binding, target)
    observation.check()
    save(out / 'target-observation.json', binding)
    observation.check()
    save(out / 'target.json', target)
    return binding


def read_target_binding(out, target, worker, owner):
    # Bounded read, exact schema, separate from the closed resident target wire.
    with (out / 'target-observation.json').open('rb') as stream:
        raw = stream.read(16385)
    if len(raw) > 16384:
        raise RuntimeError('target observation metadata exceeds bound')
    return watchdog.validate_target_binding(json.loads(raw), target, worker, owner)


def publish_target_cleanup(out, binding):
    save(out / 'target-cleanup.json', {'phase': 'cleanup', 'binding': binding})


def read_target_cleanup(path, binding):
    try:
        with Path(path).open('rb') as stream:
            raw = stream.read(16385)
    except FileNotFoundError:
        return False
    if len(raw) > 16384:
        raise RuntimeError('target cleanup metadata exceeds bound')
    value = json.loads(raw)
    if (not isinstance(value, dict) or set(value) != {'phase', 'binding'}
            or value['phase'] != 'cleanup' or value['binding'] != binding):
        raise watchdog.IdentityChanged('target cleanup binding mismatch')
    watchdog.validate_target_binding(value['binding'], binding['target'], binding['worker'], binding['owner'])
    return True


def legacy_target_observation(snapshot, group, target, build, server_path, details, callback):
    active = watchdog._observation.get()
    if target is None:
        return False
    if active is not None:
        if active.target != target:
            raise watchdog.IdentityChanged('callback target differs from shared observation')
        return False
    # Supplied ps has no acceptance provenance. Re-read in the shared cutoff.
    observe_processes(group, target, build, server_path, details, None, process_check=callback,
                      target_binding=details.get('targetObservationBinding'))
    return True


def observe_processes(group, target, build, server_path, details, deadline,
                      input_guard=None, process_check=None, edit_check=None, target_binding=None, recording_owner=None):
    binding = target_binding if target_binding is not None else details.get('targetObservationBinding')
    process_probe = capture.ProcessProbe() if target is not None else None
    def read_target(pid, device=False):
        try:
            return process_probe.identity(pid, device=device)
        except capture.CaptureError as error:
            if error.status != 'identityUnknown':
                raise
            # An unavailable device read is not exit proof. The shared observer
            # can reconcile only with a bound cleanup phase and fresh ESRCH.
            raise watchdog.IdentityReadError(str(error), None, 'device identity', 0, 0) from error
    cleanup_path = details.get('targetObservationCleanupFile')
    observation = watchdog.ProcessObservation(monotonic, deadline,
        input_guard.check if input_guard else lambda: None,
        details.setdefault('residentExecutableObservations', []),
        **probe_family_options(build, server_path), target=target,
        target_binding=binding, target_reader=read_target if target is not None else None, server_path=server_path,
        target_cleanup_reader=(lambda: read_target_cleanup(cleanup_path, observation.target_binding)) if cleanup_path and target is not None else None,
        recording_owner=recording_owner)
    def validate(snapshot):
        if target is not None:
            if sum(row[3] == target['path'] for row in snapshot) > 1:
                raise RuntimeError('exact fixture executable budget exceeded')
            if sum(row[2] == group and row[3] == str(server_path) for row in snapshot) > 1:
                raise RuntimeError('exact debugserver budget exceeded')
            if edit_check is not None:
                edit_check(snapshot, group, observation.target, build, server_path, details)
        if process_check is not None:
            process_check(snapshot, group, observation.target, build, server_path, details)
    return observation.complete(group, validate)


def parent(build, out, device, deadline, receipt, guard=False, texture_probe=False, edit_qualification=False, failure_case=None,
           worker_script=None, worker_arguments=(), process_check=None):
    import edit_qualification as edit
    recording_owner = None
    total, work, grace = (edit.TOTAL, edit.WORK, edit.GRACE) if edit_qualification else (TOTAL, WORK, GRACE)
    budget = session_budget(deadline, edit_qualification)
    reserve(budget['captureAdmissionMonotonic'], 0, 'parent admission before any mutation')
    verify_prepared(build)
    if edit_qualification:
        edit.require_full_preparation(build)
    lldb_python = edit.require_lldb_python(capture) if edit_qualification and not guard else None
    if not guard:
        booted(device)
    reserve(budget['captureAdmissionMonotonic'], 0, 'parent preflight admission')
    out.mkdir(mode=0o700, parents=False, exist_ok=False)
    token = str(uuid.uuid4())
    env = {k: v for k, v in os.environ.items() if not k.startswith(('MAC_CU_', 'PYTHON', 'DYLD_'))}
    env['MAC_CU_FIXTURE_WORKER'] = token
    server_path = None if guard else capture.tools_for_xcode()[0]
    input_guard = None if guard else InputGuard()
    details = {**receipt, **budget, 'guard': guard, 'serverObservations': [], 'totalDeadlineSeconds': total, 'workDeadlineSeconds': work, 'workerGraceSeconds': grace,
               'budget': 'parent1 worker1 fixture1 captureSupervisor1 lldbWorker1 debugserver1 probe1; serialized simctl1',
               'groupKill': False}
    if lldb_python:
        details['lldbPythonPreflight'] = lldb_python
    child = None
    start = deadline - total
    def interrupted(*_):
        raise native.NativeCheckInterrupted('parent interrupted; cooperative cleanup follows')
    previous = {sig: signal.signal(sig, interrupted) for sig in (signal.SIGTERM, signal.SIGINT)}
    try:
        details['workerSendMonotonic'] = monotonic()
        details['remainingAtWorkerSendSeconds'] = deadline - details['workerSendMonotonic']
        arguments = [sys.executable, '-B', str(worker_script or HERE / 'session.py'), '--worker-guard' if guard else '--worker', str(build), str(out), device, token, str(os.getpid()), str(deadline)]
        if texture_probe and not guard:
            arguments.append('--texture-probe')
        if failure_case:
            arguments.extend(['--failure-case', failure_case])
        elif edit_qualification:
            arguments.append('--edit-qualification')
        arguments.extend(worker_arguments)
        startup_parent = watchdog.lifetime(watchdog.process_identity(os.getpid()))
        env['MAC_CU_FIXTURE_STARTUP'] = json.dumps(dict(owner=token, parent=startup_parent,
            cutoff=min(budget['captureAdmissionMonotonic'], budget['parentStopMonotonic'],
                       monotonic() + watchdog.PROCESS_READ_TIMEOUT_SECONDS)))
        child = subprocess.Popen(arguments,
                                 env=env, stdin=subprocess.DEVNULL, start_new_session=True)
        await_worker_ready(child, out, token, startup_parent,
                           min(budget['captureAdmissionMonotonic'], budget['parentStopMonotonic']),
                           input_guard.check if input_guard else lambda: None, details)
        while child.poll() is None:
            try:
                current_worker = watchdog.lifetime(watchdog.process_identity(child.pid))
            except watchdog.IdentityReadError as error:
                # Only a kernel ESRCH plus reaping our direct child resolves this
                # poll/read race. Permission errors and a still-live child reject.
                if error.errno == errno.ESRCH and child.poll() is not None:
                    details['workerExitDuringIdentityRead'] = {'returncode': child.returncode}
                    break
                raise
            if current_worker != details['worker']:
                raise watchdog.IdentityChanged('ready worker lifetime/image changed')
            if input_guard:
                input_guard.check()
            if monotonic() >= budget['parentStopMonotonic']:
                raise TimeoutError('work budget exhausted; cooperative cleanup reserved: ' + str(grace))
            target_file = out / 'target.json'
            target = snapshot = None
            if target_file.exists():
                target = json.loads(target_file.read_text())
                details['targetObservationBinding'] = read_target_binding(out, target, details['worker'], token)
                details['targetObservationCleanupFile'] = str(out / 'target-cleanup.json')
                if '--recording-transition' in worker_arguments:
                    import recording_owner as recording_bridge
                    declaration = recording_bridge.read_optional(out / 'recording-session.json')
                    if declaration is not None and recording_owner is None:
                        recording_owner = recording_bridge.Owner(sys.modules[__name__], out, declaration,
                            details['targetObservationBinding'], input_guard.check if input_guard else lambda: None, monotonic)
                if recording_owner is not None:
                    recording_owner.check()
                    target = recording_owner.cursor.binding['target']
                    details['targetObservationBinding'] = recording_owner.cursor.binding
            if target is not None or process_check is not None:
                observe_processes(child.pid, target, build, server_path, details,
                                  budget['parentStopMonotonic'], input_guard, process_check,
                                  edit.check_process_budget if edit_qualification else None,
                                  recording_owner=recording_owner)
            time.sleep(.1)
        details['returncode'] = child.wait(timeout=1)
        worker_report = json.loads((out / 'session.json').read_text())
        received = worker_report['workerReceivedMonotonic']
        details['workerDispatchDelaySeconds'] = received - details['workerSendMonotonic']
        details['workerRemainingAtReceiptSeconds'] = worker_report['workerRemainingAtReceiptSeconds']
        if (worker_report['deadlineMonotonic'] != deadline or details['workerDispatchDelaySeconds'] < -.001
                or details['workerRemainingAtReceiptSeconds'] > details['remainingAtWorkerSendSeconds'] + .001):
            raise RuntimeError('worker clock epoch/deadline transmission mismatch')
        details['workerDeadlineTransmissionVerified'] = True
    except BaseException as error:
        details['error'] = repr(error)
    finally:
        for sig in previous:
            signal.signal(sig, signal.SIG_IGN)
        if child:
            grace = {}; details['grace'] = grace
            try:
                watchdog.graceful_stop(child, grace, timeout=min(details['workerGraceSeconds'], max(0, total - 5 - (monotonic() - start))))
                details['group'] = watchdog.wait_group_readback(child.pid, timeout=0)
                if not details['group']['groupEmpty']:
                    raise RuntimeError('session group has live/zombie/unknown residuals; no signal authority')
            except Exception as error:
                details['cleanupError'] = repr(error)
                # Deliberately do not kill a still-owning reaper. No PGID/descendant fallback.
        details['elapsedSeconds'] = monotonic() - start
        if recording_owner is not None:
            cursor = recording_owner.cursor
            details['recordingCustody'] = dict(phase=cursor.phase, revision=cursor.revision,
                binding=cursor.binding, original=cursor.original, candidate=cursor.candidate,
                helper=cursor.helper, launch=cursor.launch_key, reconciliation=cursor.reconcile_key,
                launchSettled=cursor.launch_settled, helperSettled=cursor.helper_settled,
                uncertain=cursor.uncertain, published=cursor.published, signalAuthority=False)
        save(out / 'parent.json', details)
        for sig, handler in previous.items():
            signal.signal(sig, handler)
    return 0 if child and child.returncode == 0 and not details.get('error') and not details.get('cleanupError') else 1


def main():
    if sys.argv[1:2] in (['--worker'], ['--worker-guard']):
        suffix = sys.argv[8:]
        import failure_qualification as faults
        failure_case = suffix[1] if len(suffix) == 2 and suffix[0] == '--failure-case' and suffix[1] in faults.CASES else None
        if len(sys.argv) not in (8, 9, 10) or (suffix not in ([], ['--texture-probe'], ['--edit-qualification']) and not failure_case):
            return 64
        edit_mode = suffix == ['--edit-qualification'] or failure_case is not None
        if sys.argv[1] == '--worker-guard':
            if suffix == ['--texture-probe']:
                return 64
            if edit_mode:
                return guard_worker(Path(sys.argv[3]), float(sys.argv[7]), sys.argv[5], int(sys.argv[6]), True)
            return guard_worker(Path(sys.argv[3]), float(sys.argv[7]), sys.argv[5], int(sys.argv[6]))
        args = (Path(sys.argv[2]), Path(sys.argv[3]), sys.argv[4], sys.argv[5], int(sys.argv[6]), float(sys.argv[7]), suffix == ['--texture-probe'])
        if failure_case:
            return worker(*args, edit_qualification=True, failure_case=failure_case)
        return worker(*args, edit_qualification=True) if edit_mode else worker(*args)
    parser = argparse.ArgumentParser(allow_abbrev=False)
    parser.add_argument('--build', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--device', required=True)
    parser.add_argument('--deadline', required=True, help='Fresh fixed UTC end YYYY-MM-DDTHH:MM:SSZ, including cleanup')
    parser.add_argument('--guard', action='store_true', help='Same CLI/parent/worker deadline route; no Simulator reads or mutations')
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument('--texture-probe', action='store_true', help='Internal schema-1 snapshotImage experiment')
    mode.add_argument('--edit-qualification', action='store_true', help='Ten serial schema-2 operations; 3300s maximum, unchanged 120s capture TTL')
    mode.add_argument('--failure-case', choices=('throw', 'cancel', 'replace', 'reparent'),
                      help='One bounded owned-fixture failure family in a fresh lifetime; no public fault fields')
    args = parser.parse_args()
    import edit_qualification as edit
    try:
        deadline, receipt = received_deadline(args.deadline, edit.TOTAL if args.edit_qualification or args.failure_case else TOTAL)
    except ValueError as error:
        parser.error(str(error))
    return parent(args.build.resolve(), args.output.resolve(), str(uuid.UUID(args.device)).upper(), deadline, receipt,
                  args.guard, args.texture_probe, args.edit_qualification or bool(args.failure_case), args.failure_case)


if __name__ == '__main__':
    raise SystemExit(main())
