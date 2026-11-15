"""Explicit inspector restart. No attach, global environment, or dispatch retry."""
import ctypes
import datetime
import math
import stat
import uuid
import hashlib
import json
import os
from pathlib import Path
import re
import signal
import subprocess
import time
import capture
import edit_backend
import resident_support


def _integer(value, low, high):
    if type(value) is not int or not low <= value <= high:
        raise ValueError('Invalid bounded integer identity')


def _path(value):
    if (type(value) is not str or not value.startswith('/') or '\0' in value
            or len(value.encode()) > 4096 or os.path.realpath(value) != value):
        raise ValueError('Expected canonical absolute executable path')


def _lifetime(pid, start, path):
    _integer(pid, 1, 2147483647)
    if type(start) is not list or len(start) != 2:
        raise ValueError('Invalid process start')
    _integer(start[0], 1, 2**64 - 1)
    _integer(start[1], 0, 999999)
    _path(path)


def _boot_target(scope):
    parts = scope['bootIdentity'].split(':', 4)
    if len(parts) != 5 or any(not re.fullmatch(r'[1-9][0-9]*|0', v) for v in parts[1:4]):
        raise ValueError('Invalid boot identity')
    device, pid, seconds, micros, path = parts
    boot = dict(deviceID=device, pid=int(pid), start=[int(seconds), int(micros)], path=path)
    _lifetime(boot['pid'], boot['start'], path)
    if device != scope['deviceID'] or Path(path).name != 'launchd_sim':
        raise ValueError('Invalid boot identity')
    return boot


def validate_request(request):
    # Recording wire intentionally differs from the capture scope (no displayID).
    if type(request) is not dict or set(request) != {'explicitClick', 'target', 'scope'} or request['explicitClick'] is not True:
        raise ValueError('Explicit click and exact preparation fields required')
    target, scope = request['target'], request['scope']
    if type(target) is not dict or set(target) != {'pid', 'start', 'path', 'deviceID'}:
        raise ValueError('Invalid target fields')
    _lifetime(target['pid'], target['start'], target['path'])
    device = target['deviceID']
    if type(device) is not str or str(uuid.UUID(device)).upper() != device:
        raise ValueError('Expected canonical device UUID')
    fields = {'deviceID', 'bootIdentity', 'presentation', 'generation', 'runtime'}
    if type(scope) is not dict or set(scope) != fields:
        raise ValueError('Invalid preparation scope fields')
    if any(type(scope[k]) is not str or not 0 < len(scope[k].encode()) <= 1024 or '\0' in scope[k] for k in fields - {'generation'}):
        raise ValueError('Invalid scope identity')
    _integer(scope['generation'], 0, 2**64 - 1)
    if scope['deviceID'] != device:
        raise ValueError('Target/scope device mismatch')
    _boot_target(scope)


def _unique(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError('Duplicate claim JSON key')
        result[key] = value
    return result


def _selected_claim(path, device):
    try:
        fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    except FileNotFoundError:
        return None
    with os.fdopen(fd, 'rb') as stream:
        before = os.fstat(stream.fileno())
        if not stat.S_ISREG(before.st_mode) or before.st_uid != os.getuid() or before.st_mode & 0o022:
            raise ValueError('Invalid claim file ownership/type/mode')
        if before.st_size > 1024 * 1024:
            raise ValueError('Claim file exceeds capacity')
        data = stream.read(1024 * 1024 + 1)
        after = os.fstat(stream.fileno())
        current = os.stat(path, follow_symlinks=False)
        fingerprint = lambda v: (v.st_dev, v.st_ino, v.st_size, v.st_mtime_ns, v.st_ctime_ns)
        if len(data) > 1024 * 1024 or fingerprint(before) != fingerprint(after) or fingerprint(after) != fingerprint(current):
            raise ValueError('Claim file changed during read')
    claims = json.loads(data, object_pairs_hook=_unique,
                        parse_constant=lambda _: (_ for _ in ()).throw(ValueError('Nonfinite claim JSON')))
    if type(claims) is not dict:
        raise ValueError('Invalid claims object')
    selected = [v for k, v in claims.items() if k.upper() == device.upper()]
    if len(selected) > 1:
        raise ValueError('Duplicate selected device claim')
    if not selected:
        return None
    claim = selected[0]
    if type(claim) is not dict or set(claim) != {'pid', 'by', 'note', 'since'}:
        raise ValueError('Invalid selected claimed-device fields')
    _integer(claim['pid'], 2, 2147483647)
    if any(type(claim[k]) is not str for k in ('by', 'note', 'since')) or not claim['by']:
        raise ValueError('Invalid selected claim text')
    _since(claim)
    return claim


def _since(claim):
    value = datetime.datetime.fromisoformat(claim['since'].replace('Z', '+00:00'))
    if value.tzinfo is None or value.utcoffset() is None or not math.isfinite(value.timestamp()):
        raise ValueError('Claim since requires a finite timezone-aware date')
    return value


def _dead(pid):
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return True
    return False  # PermissionError propagates; denied is never dead.


def _native(probe, pid):
    # identity() alone checks birth, but does not pin parent/path around its read.
    before = probe.status(pid)
    first = probe.identity(pid)
    second = probe.identity(pid)
    after = probe.status(pid)
    # Scheduler transitions between runnable and sleeping do not change identity.
    fields = ('pid', 'start', 'parent')
    if (any(before[k] != after[k] or first[k] != after[k] or second[k] != after[k] for k in fields)
            or first['path'] != second['path']
            or any(sample['state'] not in (2, 3) for sample in (before, first, second, after))):
        raise ValueError('Native ancestry changed or is not runnable/sleeping')
    _lifetime(pid, after['start'], first['path'])
    return dict(pid=pid, start=after['start'], parent=after['parent'], path=first['path'])


class ClaimAdmission:
    """Pinned advisory coordination only; never conversation authentication."""
    def __init__(self, device, probe, *, _path_override=None, _wall=time.time, _dead_probe=_dead):
        self.device, self.probe = device, probe
        self.path = _path_override or Path.home() / 'Library/Application Support/sim-pilot/claims.json'
        self.wall, self.dead = _wall, _dead_probe
        self.selected = _selected_claim(self.path, device)
        self.chain = None
        if self.selected is not None:
            self._time_check()
            if not self.dead(self.selected['pid']):
                self.chain = self._chain()
        self.recheck()

    def _time_check(self):
        now = self.wall()
        if not math.isfinite(now) or _since(self.selected).timestamp() > now:
            raise ValueError('Claim since is later than observation')

    def _chain(self):
        pid, seen, chain = os.getpid(), set(), []
        for _ in range(32):
            if pid <= 1 or pid in seen:
                raise ValueError('Unrelated or cyclic claimant ancestry')
            seen.add(pid)
            native = _native(self.probe, pid)
            chain.append(native)
            if pid == self.selected['pid']:
                born = datetime.datetime.fromtimestamp(native['start'][0], datetime.timezone.utc) + datetime.timedelta(microseconds=native['start'][1])
                if born > _since(self.selected):
                    raise ValueError('Claimant birth exceeds since lower bound')
                # Re-read the entire pinned chain after walking all edges.
                if any(_native(self.probe, item['pid']) != item for item in chain):
                    raise ValueError('Claimant ancestry changed')
                return chain
            pid = native['parent']
        raise ValueError('Claimant ancestry exceeds bound')

    def recheck(self):
        if _selected_claim(self.path, self.device) != self.selected:
            raise ValueError('Selected claim changed')
        if self.selected is not None:
            self._time_check()
            if self.chain is None:
                if not self.dead(self.selected['pid']):
                    raise ValueError('Previously dead claim is now live')
            elif self._chain() != self.chain:
                raise ValueError('Pinned claimant ancestry changed')


def check_boot(scope, probe):
    capture.verify_target(probe, _boot_target(scope))


def recording_enabled(probe, pid):
    # Inspect only this key, and never return or persist other environment/argv data.
    mib = (ctypes.c_int * 3)(1, 49, pid)
    data = ctypes.create_string_buffer(1024 * 1024)
    size = ctypes.c_size_t(len(data))
    if probe.libc.sysctl(mib, 3, data, ctypes.byref(size), None, 0):
        return False
    raw = data.raw[:size.value]
    argc = int.from_bytes(raw[:4], 'little', signed=True)
    pos = raw.find(b'\0', 4) + 1
    if not 0 < argc < 65536 or pos <= 4:
        return False
    while pos < len(raw) and raw[pos] == 0:
        pos += 1
    for _ in range(argc):
        end = raw.find(b'\0', pos)
        if end < 0:
            return False
        pos = end + 1
    return [v for v in raw[pos:].split(b'\0') if v.startswith(b'SWIFTUI_VIEW_DEBUG=')] == [b'SWIFTUI_VIEW_DEBUG=287']


def validate_setting(admission):
    resource = Path(admission['build']['developer']).parent / 'PlugIns/DebuggerUI.framework/Versions/A/Resources/DebuggerUI.xcplugindata'
    if hashlib.sha256(resource.read_bytes()).hexdigest() != 'fae3c0680c4ce3124c07159a38376d21999317973c34c45d76ff31a71b69cc3e':
        raise ValueError('Selected Xcode recording configuration is not qualified')


def run(request, folder, probe, *, admit=resident_support.admit, _claim_capture=ClaimAdmission,
        boot=check_boot, setting=validate_setting, enabled=recording_enabled, execute=subprocess.run, terminate=os.kill, clock=time.monotonic, sleep=time.sleep):
    ledger = None
    stage = 'notDispatched'
    result = {'status': 'failed', 'stage': stage}
    try:
        validate_request(request)
        target, scope = request['target'], request['scope']
        claim = _claim_capture(target['deviceID'], probe)
        admission = admit({'target': target})
        setting(admission)
        bundle = admission['bundleID']
        ledger = edit_backend.Ledger({'target': target})
        if not ledger.state or ledger.state['authority'] != 'released':
            raise ValueError('Inspector must have a verified released ledger before restart')
        marker = ledger.root / (edit_backend.digest(target) + '.recording')
        if marker.exists():
            raise ValueError('This lifetime already dispatched a restart; reconcile instead of replaying')
        def fresh(require_target=True):
            if (folder / 'cancel').exists():
                raise ValueError('Inspector context was cancelled or changed')
            claim.recheck(); boot(scope, probe)
            if require_target:
                capture.verify_target(probe, target)
        fresh()
        # Durable boundary survives host/helper loss. The ledger lock excludes capture/edit/release.
        edit_backend.atomic_write(marker, {'stage': 'terminationDispatch', 'target': target})
        stage = 'terminationDispatch'
        fresh()
        terminate(target['pid'], signal.SIGTERM)
        deadline = clock() + 8
        while True:
            try:
                state = probe.status(target['pid'])
                gone = state['start'] != target['start'] or state['state'] == 5
            except Exception:
                # An unreadable live PID is not proof of exit.
                try:
                    os.kill(target['pid'], 0)
                except ProcessLookupError:
                    gone = True
                else:
                    gone = False
            if gone:
                break
            if clock() >= deadline:
                raise ValueError('Termination not observed; launch was not dispatched')
            sleep(.05)
        stage = 'terminated'
        fresh(False)
        edit_backend.atomic_write(marker, {'stage': 'launchDispatch', 'target': target})
        stage = 'launchDispatch'
        env = {'PATH': '/usr/bin:/bin:/usr/sbin:/sbin', 'HOME': str(Path.home()),
               'DEVELOPER_DIR': admission['build']['developer'],
               'SIMCTL_CHILD_SWIFTUI_VIEW_DEBUG': '287'}
        fresh(False)
        try:
            launched = execute(['/usr/bin/xcrun', 'simctl', 'launch', target['deviceID'], bundle],
                env=env, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=15, check=False)
            match = re.fullmatch(re.escape(bundle) + r': (\d+)\s*', launched.stdout.decode())
            if launched.returncode or not match:
                raise ValueError('Launch did not return a verified PID')
            pid = int(match[1])
        except (subprocess.TimeoutExpired, ValueError):
            # Read-only reconciliation; never dispatch launch a second time.
            listing = execute(['/usr/bin/xcrun', 'simctl', 'spawn', target['deviceID'], 'launchctl', 'list'],
                env=env, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=5, check=False)
            matches = re.findall(r'(?m)^(\d+)\s+[^\s]+\s+UIKitApplication:' + re.escape(bundle) + r'\[[^\]]+\]\s*$', listing.stdout.decode())
            result['reconciliation'] = 'matchingLifetimeObserved' if len(matches) == 1 else 'unresolved'
            if len(matches) == 1:
                actual = probe.identity(int(matches[0]), device=True)
                if actual['deviceID'] == target['deviceID'] and actual['path'] == target['path'] and actual['start'] != target['start']:
                    result['observedTarget'] = {k: actual[k] for k in target}
            raise ValueError('Launch outcome uncertain; automatic replay is blocked')
        fresh(False)
        actual = probe.identity(pid, device=True)
        new = {k: actual[k] for k in ('pid', 'start', 'path', 'deviceID')}
        if new['path'] != target['path'] or new['deviceID'] != target['deviceID'] or new['start'] == target['start']:
            raise ValueError('Launched application lifetime does not match')
        capture.verify_target(probe, new)
        if not enabled(probe, pid):
            raise ValueError('New lifetime recording environment is not verified')
        capture.verify_target(probe, new)
        fresh(False)
        result.update(status='success', target=new)
        stage = 'newLifetimeBound'
    except Exception as error:
        result.update(status='outcomeUncertain' if stage in ('terminationDispatch', 'launchDispatch') else 'failed', message=str(error))
    finally:
        result['stage'] = stage
        if ledger is not None:
            ledger.close()
    return result
