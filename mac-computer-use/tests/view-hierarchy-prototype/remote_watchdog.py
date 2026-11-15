"""Bounded parent for remote_run.py; it never attaches to a target itself."""
import argparse
import contextvars
import ctypes
import errno
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import time
import uuid
import ui_process_contract

HERE = Path(__file__).resolve().parent
DEADLINE_SECONDS = 480
FIXTURE_BUDGET = 2  # One fixture plus at most one short-lived probe.
SERVER_BUDGET = 2   # One collector server plus the traced-case holder.
# Includes a start_server unwind (10), holder release (8), recovery (5+3
# probe), four child TERM/KILL waits (4*10), fixture probe/wait (3+5),
# and 11 seconds scheduling/receipt margin.
WORKER_GRACE_SECONDS = 85
GROUP_READBACK_SECONDS = 5
WORKER_WAIT_SECONDS = 5
PROCESS_READ_TIMEOUT_SECONDS = 3
CLEANUP_BUDGET_SECONDS = WORKER_GRACE_SECONDS + WORKER_WAIT_SECONDS + GROUP_READBACK_SECONDS + 2 * PROCESS_READ_TIMEOUT_SECONDS
UNVERIFIED = object()

class IdentityChanged(RuntimeError):
    pass

class BSDInfo(ctypes.Structure):
    _fields_ = [(name, ctypes.c_uint32) for name in (
        'flags', 'status', 'xstatus', 'pid', 'ppid', 'uid', 'gid', 'ruid', 'rgid', 'svuid', 'svgid', 'reserved')]
    _fields_ += [('comm', ctypes.c_char * 16), ('name', ctypes.c_char * 32)]
    _fields_ += [(name, ctypes.c_uint32) for name in ('nfiles', 'pgid', 'pjobc', 'tdev', 'tpgid')]
    _fields_ += [('nice', ctypes.c_int32), ('start_sec', ctypes.c_uint64), ('start_usec', ctypes.c_uint64)]

class ObservationExpired(TimeoutError):
    pass

class IdentityReadError(RuntimeError):
    def __init__(self, message, identity, syscall, result, error):
        super().__init__(message)
        self.identity, self.syscall, self.result, self.errno = identity, syscall, result, error


_observation = contextvars.ContextVar('process_observation', default=None)


def session_members(snapshot, group, probe=None):
    """Include all worker descendants and exact probe instances across groups."""
    observation = _observation.get()
    ui = observation.ui_contract['binary'] if observation is not None and observation.ui_contract else None
    ids = {group} | {r[0] for r in snapshot if r[2] == group or (probe and r[3] == probe) or (ui and r[3] == ui)}
    observation = _observation.get()
    if observation is not None:
        ids |= observation.validation_members
        if observation.recording_owner:
            cursor = observation.recording_owner.cursor
            ids |= {v['pid'] for v in (cursor.helper, cursor.ui) if v is not None}
            ids |= {v[0] for v in (cursor.launch_key, cursor.reconcile_key) if v is not None}
    while True:
        children = {r[0] for r in snapshot if r[1] in ids}
        if children <= ids:
            return [r for r in snapshot if r[0] in ids and r[0] != group]
        ids |= children


def parent_context_pending(pid, allowed_paths=()):
    """Only partial validation may defer a predicate whose parent is unresolved."""
    current = _observation.get()
    return (current is not None and pid in current.validation_pending
            and (pid not in current.validation_paths or current.validation_paths[pid] in allowed_paths))


def checkpoint():
    current = _observation.get()
    if current is not None:
        current.check()


def record_read(pid, syscall, result, error, identity=None):
    current = _observation.get()
    if current is not None:
        current.record(pid, syscall, result, error, identity)
    checkpoint()


def process_status(pid):
    checkpoint()
    libc = ctypes.CDLL('/usr/lib/libSystem.B.dylib', use_errno=True)
    libc.proc_pidinfo.argtypes = [ctypes.c_int, ctypes.c_int, ctypes.c_uint64, ctypes.c_void_p, ctypes.c_int]
    info = BSDInfo()
    ctypes.set_errno(0)
    size = libc.proc_pidinfo(pid, 3, 0, ctypes.byref(info), ctypes.sizeof(info))
    error = ctypes.get_errno()
    valid = size == ctypes.sizeof(info) and info.pid == pid
    identity = ({'pid': pid, 'parent': int(info.ppid), 'group': int(info.pgid),
                 'start': [int(info.start_sec), int(info.start_usec)], 'state': int(info.status)} if valid else None)
    record_read(pid, 'proc_pidinfo', size, error, identity)
    if not valid:
        raise IdentityReadError('cannot read owned PID status ' + str(pid), None, 'proc_pidinfo', size, error)
    return identity


def process_identity(pid):
    status = process_status(pid)
    checkpoint()
    libc = ctypes.CDLL('/usr/lib/libSystem.B.dylib', use_errno=True)
    libc.proc_pidpath.argtypes = [ctypes.c_int, ctypes.c_void_p, ctypes.c_uint32]
    path = ctypes.create_string_buffer(4096)
    ctypes.set_errno(0)
    result = libc.proc_pidpath(pid, path, len(path))
    error = ctypes.get_errno()
    partial = dict(status)
    if result > 0:
        partial['path'] = os.path.realpath(os.fsdecode(path.value))
    record_read(pid, 'proc_pidpath', result, error, partial)
    if result <= 0:
        raise IdentityReadError('cannot identify owned PID ' + str(pid), partial, 'proc_pidpath', result, error)
    current = process_status(pid)
    if any(current.get(key) != status.get(key) for key in ('start', 'parent', 'group')):
        raise IdentityChanged('owned PID changed while reading identity')
    current['path'] = partial['path']
    return current


def process_arguments(pid):
    """Read argv only, never publish argv/environment or use a ps command string."""
    checkpoint()
    libc = ctypes.CDLL('/usr/lib/libSystem.B.dylib', use_errno=True)
    libc.sysctl.argtypes = [ctypes.c_void_p, ctypes.c_uint, ctypes.c_void_p,
                           ctypes.POINTER(ctypes.c_size_t), ctypes.c_void_p, ctypes.c_size_t]
    mib = (ctypes.c_int * 3)(1, 49, pid)  # KERN_PROCARGS2
    data = ctypes.create_string_buffer(1024 * 1024)
    size = ctypes.c_size_t(len(data))
    ctypes.set_errno(0)
    result = libc.sysctl(mib, 3, data, ctypes.byref(size), None, 0)
    error = ctypes.get_errno()
    record_read(pid, 'sysctl-argv', result, error)
    if result:
        raise IdentityReadError('cannot read helper argv', None, 'sysctl-argv', result, error)
    buf = data.raw[:size.value]
    argc = int.from_bytes(buf[:4], sys.byteorder, signed=True)
    pos = buf.find(b'\0', 4) + 1
    if not 0 < argc < 65536 or pos <= 4:
        raise IdentityReadError('invalid helper argv', None, 'sysctl-argv', result, error)
    while pos < len(buf) and buf[pos] == 0:
        pos += 1
    args = []
    for _ in range(argc):
        end = buf.find(b'\0', pos)
        if end < 0:
            raise IdentityReadError('incomplete helper argv', None, 'sysctl-argv', result, error)
        args.append(os.fsdecode(buf[pos:end])); pos = end + 1
    return args


def gone_or_zombie(pid):
    try:
        return process_status(pid)['state'] == 5
    except IdentityReadError:
        pass
    checkpoint()
    try:
        os.kill(pid, 0)
    except OSError as exc:
        record_read(pid, 'kill0', -1, exc.errno)
        return isinstance(exc, ProcessLookupError)
    record_read(pid, 'kill0', 0, 0)
    return False


def identify_live_server(pid):
    try:
        info = process_identity(pid)
    except (IdentityChanged, ObservationExpired, InterruptedError):
        raise
    except RuntimeError as exc:
        # Only identity read failures are reconcilable in an active observation.
        if _observation.get() is not None and not isinstance(exc, IdentityReadError):
            raise
        if gone_or_zombie(pid):
            return None
        return UNVERIFIED
    return None if info['state'] == 5 else info


def rows(timeout=PROCESS_READ_TIMEOUT_SECONDS):
    checkpoint()
    active = _observation.get()
    if active is not None:
        timeout = min(timeout, active.cutoff - active.clock())
    output = subprocess.check_output(['/bin/ps', '-axo', 'pid=,ppid=,pgid=,stat=,comm='], text=True, timeout=timeout)
    checkpoint()
    result = []
    for line in output.splitlines():
        checkpoint()
        fields = line.strip().split(None, 4)
        if len(fields) != 5:
            raise RuntimeError('incomplete process snapshot')
        result.append((int(fields[0]), int(fields[1]), int(fields[2]), os.path.realpath(fields[4]), fields[3]))
        checkpoint()
    return result


LIFETIME_KEYS = ('pid', 'start', 'path', 'parent', 'group')


def lifetime(info):
    return {k: info[k] for k in LIFETIME_KEYS}


def validate_target_binding(binding, target, worker=None, owner=None):
    """Bounded metadata is expected identity, never current kernel proof."""
    if not isinstance(binding, dict) or set(binding) != {'version', 'owner', 'worker', 'target', 'group', 'originalParent'}:
        raise IdentityChanged('missing or invalid target observation binding')
    if type(binding['version']) is not int or binding['version'] != 1 or not isinstance(binding['owner'], str):
        raise IdentityChanged('invalid observation owner/version')
    try:
        uuid.UUID(binding['owner'])
        if set(target) != {'pid', 'start', 'path', 'deviceID'} or binding['target'] != target:
            raise ValueError('target')
        if (type(target['pid']) is not int or target['pid'] <= 0 or
                not isinstance(target['start'], list) or len(target['start']) != 2 or
                any(type(v) is not int or v < 0 for v in target['start']) or
                not isinstance(target['path'], str) or not os.path.isabs(target['path']) or
                not isinstance(target['deviceID'], str) or not target['deviceID']):
            raise ValueError('target schema')
        if type(binding['group']) is not int or binding['group'] <= 0:
            raise ValueError('group')
        for info in (binding['worker'], binding['originalParent']):
            if not isinstance(info, dict) or set(info) != set(LIFETIME_KEYS):
                raise ValueError('lifetime schema')
            if any(type(info[k]) is not int or info[k] <= 0 for k in ('pid', 'parent', 'group')):
                raise ValueError('pid')
            if (not isinstance(info['start'], list) or len(info['start']) != 2 or
                    any(type(v) is not int or v < 0 for v in info['start']) or
                    not isinstance(info['path'], str) or not os.path.isabs(info['path'])):
                raise ValueError('lifetime')
        if worker is not None and binding['worker'] != lifetime(worker):
            raise ValueError('worker')
        if owner is not None and binding['owner'] != owner:
            raise ValueError('owner')
    except (KeyError, TypeError, ValueError) as exc:
        raise IdentityChanged('target observation binding mismatch') from exc
    return binding


class ProcessObservation:
    """One acceptance cutoff; synchronous reads may return after it. No custody."""
    def __init__(self, clock, deadline=None, check=lambda: None, events=None, isolated_probe=None, probe_tools=(),
                 probe_python=(), probe_developer=None, target=None, target_binding=None,
                 target_reader=None, server_path=None, target_cleanup_reader=None, ui_contract=None, recording_owner=None):
        self.clock, self.input_check = clock, check
        self.recording_owner = recording_owner
        self.ui_contract = ui_contract
        self.ui_process = (ui_process_contract.Contract(ui_contract, probe_python, str(server_path),
                           target, target_binding, self.check,
                           recording_owner.cursor if recording_owner else None) if ui_contract else None)
        self.ui_roles = {}
        self.target = target
        self.target_binding = validate_target_binding(target_binding, target) if target is not None else None
        self.target_reader, self.server_path = target_reader, str(server_path)
        self.target_cleanup_reader = target_cleanup_reader
        self.target_valid = False
        self.isolated_probe, self.probe_tools = isolated_probe, set(probe_tools)
        self.probe_python = tuple(probe_python)
        self.probe_developer = probe_developer
        self.probe_members = set()
        self.probe_monitors = set()
        self.helper_roles = {}
        self.full_identities = {}
        self.exec_candidates = set()
        self.group = None
        self.cutoff = min(clock() + PROCESS_READ_TIMEOUT_SECONDS, deadline if deadline is not None else float('inf'))
        self.events = events if events is not None else []
        self.identities, self.samples, self.pass_identities = {}, {}, {}
        self.validation_members = set()
        self.validation_pending = set()
        self.validation_paths = {}

    def target_candidate(self, pid):
        candidate = self.recording_owner.cursor.candidate if self.recording_owner else None
        return ((self.target is not None and pid == self.target['pid']) or
                (candidate is not None and pid == candidate['target']['pid']))

    def read_bound_identity(self, pid):
        self.check()
        info = process_identity(pid)
        self.check()
        if info['state'] == 5:
            if self.target_candidate(pid):
                raise IdentityReadError('target is a zombie', info, 'identity', 0, 0)
            raise IdentityChanged('target relationship lifetime ended')
        self.record(pid, 'identity', 0, 0, info)
        return info

    def read_ui_identity(self, pid):
        """An exiting helper requires inventory reconciliation, never acceptance."""
        self.check()
        info = process_identity(pid)
        self.check()
        if info['state'] == 5:
            raise IdentityReadError('UI helper exited during semantic read', info, 'identity', 0, 0)
        self.record(pid, 'identity', 0, 0, info)
        return info

    def resolve_target(self, snapshot, group):
        self.target_valid = False
        if self.target is None:
            return True
        if self.recording_owner:
            terminal = self.recording_owner.resolve(self, snapshot, group)
            if terminal is not None: return terminal
        terminal = self.resolve_target_exit(snapshot, group)
        if terminal is not None:
            return terminal
        try:
            return self.resolve_live_target(snapshot, group)
        except IdentityReadError:
            # Cleanup can start after this observation began, including between
            # the kernel and device reads. Re-read the bound phase in this cutoff.
            terminal = self.resolve_target_exit(snapshot, group)
            if terminal is not None:
                return terminal
            raise

    def resolve_target_exit(self, snapshot, group):
        """None: live-role path; False: unresolved; True: freshly confirmed exit."""
        self.check()
        if self.target_cleanup_reader is None or not self.target_cleanup_reader():
            self.check()
            return None
        self.check()
        binding, pid = self.target_binding, self.target['pid']
        if binding['worker']['pid'] != group:
            raise IdentityChanged('cleanup worker group mismatch')
        worker = self.read_bound_identity(group)
        if lifetime(worker) != binding['worker']:
            raise IdentityChanged('cleanup worker lifetime changed')
        def status():
            self.check()
            try:
                value = process_status(pid)
            except IdentityReadError as error:
                self.check()
                return 'absent' if error.errno == errno.ESRCH and error.identity is None else 'unknown'
            self.check()
            if (value['pid'] != pid or value['start'] != self.target['start']
                    or value['group'] != binding['group']):
                raise IdentityChanged('cleanup target lifetime/group changed')
            return 'zombie' if value['state'] == 5 else 'live'
        state = status()
        if state == 'live':
            return None  # Cleanup intent cannot replace live path/device proof.
        if state != 'absent':
            return False  # A zombie is not a confirmed reap; denied reads stay unknown.
        self.check()
        try:
            os.kill(pid, 0)
        except ProcessLookupError:
            self.record(pid, 'kill0', -1, errno.ESRCH)
        except OSError as error:
            self.record(pid, 'kill0', -1, error.errno)
            self.check()
            return False
        else:
            self.record(pid, 'kill0', 0, 0)
            self.check()
            return False
        self.check()
        if status() != 'absent':
            return False
        if lifetime(self.read_bound_identity(group)) != lifetime(worker):
            raise IdentityChanged('cleanup worker changed during exit read')
        if not self.target_cleanup_reader():
            raise IdentityChanged('cleanup phase disappeared during exit read')
        self.check()
        if any(r[0] != pid and r[3] == self.target['path'] for r in snapshot):
            raise IdentityChanged('retired target executable has another instance')
        if any(r[0] == pid for r in snapshot):
            return False  # Reconcile a pre-exit ps row with a fresh full snapshot.
        self.target_valid = True
        self.events.append(dict(status='verifiedTargetExit', target=self.target, signalAuthority=False))
        return True

    def resolve_live_target(self, snapshot, group):
        """Bracket device reader and relationship reads inside the one cutoff."""
        binding, pid = self.target_binding, self.target['pid']
        if binding['worker']['pid'] != group:
            raise IdentityChanged('target worker group mismatch')
        before = self.read_bound_identity(pid)
        for key in ('pid', 'start', 'path'):
            if before[key] != self.target[key]:
                raise IdentityChanged('target ' + key + ' mismatch')
        if before['group'] != binding['group']:
            raise IdentityChanged('target group mismatch')
        self.check()
        actual = self.target_reader(pid, device=True)
        self.check()
        if any(actual.get(k) != v for k, v in self.target.items()):
            raise IdentityChanged('target device/lifetime mismatch')
        if actual.get('parent') != before['parent']:
            raise IdentityChanged('target parent changed across device read')
        worker = self.read_bound_identity(group)
        if lifetime(worker) != binding['worker']:
            raise IdentityChanged('owning worker lifetime changed')
        chain = [worker]
        if actual.get('traced') is False:
            original = self.read_bound_identity(before['parent'])
            if lifetime(original) != binding['originalParent']:
                raise IdentityChanged('original parent lifetime changed')
            chain.append(original)
            if actual.get('state') not in (2, 3):
                raise IdentityChanged('detached target state invalid')
        elif actual.get('traced') is True:
            if actual.get('state') not in (2, 3, 4):
                raise IdentityChanged('attached target state invalid')
            debugger = self.read_bound_identity(before['parent'])
            if debugger['path'] != self.server_path:
                raise IdentityChanged('target parent is not selected debugger')
            chain.append(debugger)
            seen = {pid, debugger['pid']}
            while chain[-1]['parent'] != group:
                parent = chain[-1]['parent']
                if parent in seen or not any(r[0] == parent for r in snapshot):
                    raise IdentityChanged('unrelated debugger ancestor chain')
                seen.add(parent)
                chain.append(self.read_bound_identity(parent))
            # Owning callback checks the exact direct/product topology and counts.
            rows_by_pid = {r[0]: r for r in snapshot}
            for info in chain[1:]:
                row = rows_by_pid.get(info['pid'])
                if row is None or self.row_identity(row) != {k: info[k] for k in ('pid', 'parent', 'group', 'path')}:
                    raise IdentityChanged('debugger chain not in current helper snapshot')
        else:
            raise IdentityChanged('target traced state unresolved')
        self.check()
        again = self.target_reader(pid, device=True)
        self.check()
        for info in reversed(chain):
            if lifetime(self.read_bound_identity(info['pid'])) != lifetime(info):
                raise IdentityChanged('target relationship changed during read')
        after = self.read_bound_identity(pid)
        if again.get('state') not in ((2, 3, 4) if actual['traced'] else (2, 3)):
            raise IdentityChanged('target state changed during observation')
        if lifetime(after) != lifetime(before) or any(again.get(k) != actual.get(k) for k in
                ('pid', 'start', 'path', 'deviceID', 'parent', 'traced')):
            raise IdentityChanged('target changed during observation')
        row = next((r for r in snapshot if r[0] == pid), None)
        if row is None or self.row_identity(row) != {k: after[k] for k in ('pid', 'parent', 'group', 'path')}:
            return False
        self.target_valid = True
        self.events.append(dict(status='verifiedTargetRole', identity=actual, signalAuthority=False))
        return True

    def check(self):
        self.input_check()
        if self.clock() >= self.cutoff:
            raise ObservationExpired('process observation acceptance cutoff exhausted')

    def record(self, pid, syscall, result, error, identity=None):
        self.events.append(dict(order=len(self.events), pid=pid, syscall=syscall,
                                result=result, errno=error, identity=identity, signalAuthority=False))
        if identity and not self.target_candidate(pid):
            self.pass_identities.setdefault(pid, {}).update(identity)
            previous = self.identities.setdefault(pid, {})
            for key in ('pid', 'start', 'parent', 'group', 'path'):
                if key in identity:
                    if key in previous and previous[key] != identity[key]:
                        if key == 'path' and self.allow_probe_exec(pid, previous, identity, syscall):
                            if syscall == 'ps':
                                continue  # Candidate only; a fresh complete identity must confirm it.
                        else:
                            self.reject('process ' + key + ' changed during observation', pid, dict(previous), identity, syscall)
                    previous[key] = identity[key]
            if syscall == 'identity':
                self.full_identities[pid] = dict(identity)

    def helper_role(self, info):
        """Exact canonical read argv, checked between full identity reads by caller."""
        path = info['path']
        args = process_arguments(info['pid'])
        if not args:
            return None
        tail = args[1:]
        if path == '/bin/zsh' and args[0] != '/bin/zsh':
            return None
        if path == '/bin/ps' and info['pid'] in self.probe_monitors:
            return 'probe-monitor' if tail == ['-axo', 'pid=,ppid=,pgid=,stat=,comm='] else None
        if path == '/usr/bin/xcrun':
            if tail[:1] == ['python3']: tail = tail[1:]
            elif tail[:1] == ['devicectl']: tail = tail[1:]
            else: return None
        if path in {'/usr/bin/xcrun', *self.probe_python} and len(tail) == 5:
            capture = str(Path(self.isolated_probe).parent / 'view-capture/capture.py')
            if tail[:3] == ['-I', capture, '--identity'] and tail[3].isdigit() and int(tail[3]) > 0:
                try: uuid.UUID(tail[4])
                except ValueError: return None
                return 'identity'
        if path == '/bin/zsh':
            script = str(Path(self.probe_developer) / 'usr/bin/devicectl') if self.probe_developer else None
            if tail[:1] != [script]: return None
            tail = tail[1:]
        device_binary = '/Library/Developer/PrivateFrameworks/CoreDevice.framework/Versions/A/Resources/bin/devicectl'
        if path in {'/usr/bin/xcrun', '/bin/zsh', device_binary} and len(tail) == 8:
            if tail[:4] == ['device', 'info', 'displays', '--device'] and tail[5:7] == ['--quiet', '--json-output']:
                try: uuid.UUID(tail[4])
                except ValueError: return None
                output = Path(tail[7])
                if output.is_absolute() and output.name.startswith('mac-cu-displays-' + tail[4] + '-') and output.suffix == '.json':
                    return 'display'
        if path == '/usr/libexec/PlistBuddy' and tail == ['-c', 'Print :CFBundleVersion',
                '/Library/Developer/PrivateFrameworks/CoreDevice.framework/Versions/A/Resources/Info.plist']:
            return 'display-version'
        return None

    def allow_probe_exec(self, pid, previous, current, syscall):
        if self.ui_process and pid in self.ui_roles:
            if self.ui_process.allow_exec(pid, previous, current):
                self.exec_candidates.add(pid)
                return True  # Final native/argv/artifact validation remains required.
            return False
        evidence = self.helper_roles.get(pid)
        if not evidence or evidence['identity']['path'] != previous.get('path'):
            return False
        parent = self.full_identities.get(previous.get('parent'), {})
        if (parent.get('path') != self.isolated_probe or parent.get('parent') != self.group
                or parent.get('group') != parent.get('pid') or previous.get('group') != pid):
            return False
        role = evidence['role']
        chains = ([['/usr/bin/xcrun', alias] for alias in self.probe_python] if role in {'identity','capture-supervisor'} else
                  [['/usr/bin/xcrun', '/bin/zsh', '/Library/Developer/PrivateFrameworks/CoreDevice.framework/Versions/A/Resources/bin/devicectl']])
        old, new = previous.get('path'), current.get('path')
        if not any(old in chain and new in chain and chain.index(old) < chain.index(new) for chain in chains):
            return False
        if syscall == 'ps':
            self.exec_candidates.add(pid)
            return True
        if any(current.get(k) != evidence['identity'].get(k) for k in ('pid', 'start', 'parent', 'group')):
            return False
        if self.helper_role(current) != role:
            return False
        self.events.append(dict(status='verifiedExecTransition', previous=dict(previous), current=dict(current),
                                role=role, signalAuthority=False))
        self.helper_roles[pid] = dict(identity=dict(current), role=role)
        self.exec_candidates.discard(pid)
        return True

    def verify_helper(self, info):
        if self.ui_process and info['pid'] in self.ui_roles:
            # Validate the whole family together, after native membership resolves.
            # A child's PID can sort before its parent or debugserver sibling.
            return info
        if info['pid'] not in self.probe_members:
            return info
        path = info['path']
        if info['pid'] not in self.probe_monitors and path not in {'/usr/bin/xcrun', '/bin/zsh', '/usr/libexec/PlistBuddy', *self.probe_python,
                       '/Library/Developer/PrivateFrameworks/CoreDevice.framework/Versions/A/Resources/bin/devicectl', '/usr/sbin/screencapture', self.server_path}:
            return info
        # There are at most two forward execs. Never extend the observation cutoff.
        for _ in range(3):
            role = self.helper_role(info)
            # Other already admitted xcrun utility argv earn no exec allowance.
            if role is None and info['path'] != '/usr/bin/xcrun':
                self.reject('unverified read-only helper role', info['pid'], {}, info, 'helper argv')
            previous = self.helper_roles.get(info['pid'])
            if previous is not None and previous['role'] != role:
                self.reject('helper role changed during observation', info['pid'], previous['identity'], info, 'helper argv')
            if role is not None:
                self.helper_roles[info['pid']] = dict(identity=dict(info), role=role)
            fresh = process_identity(info['pid'])
            if all(fresh.get(k) == info.get(k) for k in ('pid', 'start', 'parent', 'group', 'path')):
                if role is not None:
                    self.events.append(dict(status='verifiedReadHelper', role=role, identity=dict(fresh), signalAuthority=False))
                return fresh
            evidence = self.helper_roles.get(info['pid'], {})
            pinned = evidence.get('identity', {})
            if (any(pinned.get(k) != fresh.get(k) for k in ('pid', 'start', 'parent', 'group', 'path'))
                    or evidence.get('role') != role):
                self.reject('helper changed across argv read', info['pid'], info, fresh, 'helper argv')
            info = fresh
        self.reject('helper exec sequence did not stabilize', info['pid'], {}, info, 'helper argv')

    def reject(self, message, pid, previous, current, context):
        keys = ('pid', 'start', 'parent', 'group', 'path')
        self.events.append(dict(status='observedMismatch', pid=pid, context=context,
            previous={k: previous.get(k) for k in keys},
            current={k: current.get(k) for k in keys},
            cutoff=self.cutoff, signalAuthority=False))
        raise IdentityChanged(message)

    def validate_ui_groups(self, snapshot, group):
        c = self.ui_contract
        members = session_members(snapshot, group, self.isolated_probe)
        roots = [r for r in snapshot if r[3] in {c['binary'], self.isolated_probe}]
        if len(roots) > 1:
            self.reject('combined UI/probe singleton exceeded', roots[-1][0], {}, self.row_identity(roots[-1]), 'UI root budget')
        if not any(r[3] == c['binary'] for r in roots):
            saved = self.ui_contract
            self.ui_contract = None
            try: return self.validate_groups(snapshot, group)
            finally: self.ui_contract = saved
        root = roots[0]
        if root[1] != group or root[2] != group:
            self.reject('UI parent/group differs', root[0], {}, self.row_identity(root), 'UI root admission')
        try:
            roles = self.ui_process.candidates(members, root, self.validation_pending)
        except ui_process_contract.Rejected as error:
            pid = self.ui_process.last_pid or root[0]
            row = next((r for r in members if r[0] == pid), root)
            self.reject(str(error), pid, {}, self.row_identity(row), 'UI group admission')
        self.ui_roles = roles
        self.probe_members = set(roles)
        self.probe_monitors = set()

    def validate_groups(self, snapshot, group):
        if self.ui_contract: return self.validate_ui_groups(snapshot, group)
        members = session_members(snapshot, group, self.isolated_probe)
        probes = {r[0]: r for r in members if r[3] == self.isolated_probe}
        if len(probes) > 1:
            row = list(probes.values())[-1]
            self.reject('duplicate isolated probe', row[0], {}, self.row_identity(row), 'group admission')
        isolated = {r[0] for r in probes.values() if r[1] == group and r[2] == r[0]}
        descendants = set(isolated)
        while True:
            found = {r[0] for r in members if r[1] in descendants}
            if found <= descendants:
                break
            descendants |= found
        helpers, auxiliaries = {}, set()
        self.probe_monitors = {r[0] for r in members if probes and r[1] == group and r[2] == group and r[3] == '/bin/ps'}
        for row in members:
            if self.target_candidate(row[0]):
                continue  # Deferred role; complete() cannot accept until resolved.
            if row[3] == self.isolated_probe and (row[1] != group or row[2] not in {group, row[0]}):
                self.reject('unexpected probe parent/group', row[0], {}, self.row_identity(row), 'group admission')
            valid_probe = (row[3] == self.isolated_probe and row[1] == group and row[2] == row[0])
            parent = probes.get(row[1])
            if (parent and parent[2] == parent[0] and row[3] in set(self.probe_python) | {'/bin/zsh'}
                    and row[2] != row[0]):
                self.reject('canonical Foundation helper group differs', row[0], {}, self.row_identity(row), 'group admission')
            helper_path = row[3] in self.probe_tools | set(self.probe_python) | ({'/bin/zsh'} if self.probe_developer else set())
            valid_tool = (helper_path and row[2] in {row[0], row[1]}
                          and ((parent and parent[1] == group and parent[2] == parent[0])
                               or parent_context_pending(row[1], {self.isolated_probe})))
            if valid_tool:
                helpers[row[0]] = row
            # Inherited-group product supervisors remain the owning callback's role.
            if (row[2] != group or row[0] in descendants) and not (valid_probe or valid_tool or row[3] == '/usr/libexec/PlistBuddy'):
                self.reject('unexpected separate process group', row[0], {}, self.row_identity(row), 'group admission')
        for row in members:
            if row[3] != '/usr/libexec/PlistBuddy':
                continue
            parent = helpers.get(row[1])
            if not (row[2] == row[1] and ((parent and parent[3] == '/bin/zsh')
                    or parent_context_pending(row[1], {'/bin/zsh'}))):
                self.reject('unexpected display wrapper descendant', row[0], {}, self.row_identity(row), 'group admission')
            auxiliaries.add(row[0])
        self.probe_members = set(helpers) | auxiliaries | self.probe_monitors
        # Identity Python and wrapper roots consume the same serial utility slot,
        # across every admitted group; neither consumes a debugger Python slot.
        roots = ({r[0] for r in members if r[3] in self.probe_tools} | set(helpers)) - self.probe_monitors
        if len(roots) > 1 or len(auxiliaries) > 1 or len(self.probe_monitors) > 1:
            row = next(r for r in members if r[0] in roots | auxiliaries | self.probe_monitors)
            self.reject('serialized utility budget exceeded', row[0], {}, self.row_identity(row), 'aggregate budget')

    @staticmethod
    def row_identity(row):
        return dict(pid=row[0], parent=row[1], group=row[2], path=row[3]) if row else {}

    def snapshot(self):
        self.check()
        result = rows(timeout=self.cutoff - self.clock())
        self.check()
        return result

    def validate_partial(self, validate, snapshot, relevant):
        # Keep every known parent in this pass, irrespective of PID/read order.
        # These paths can prove contradictions, but never replace final identities.
        known = {r[0]: r for r in snapshot if r[0] not in relevant or Path(r[3]).is_file()}
        for pid, partial in self.pass_identities.items():
            if all(key in partial for key in ('parent', 'group', 'path')):
                known[pid] = (pid, partial['parent'], partial['group'], partial['path'], 'S')
        if not relevant.intersection(known):
            return
        pending = relevant - known.keys()
        # A known parent's role can itself depend on an unresolved ancestor.
        while True:
            descendants = {r[0] for r in snapshot if r[0] in relevant and r[1] in pending}
            if descendants <= pending:
                break
            pending |= descendants
        self.validation_pending = pending
        self.validation_paths = {pid: row[3] for pid, row in known.items()}
        try:
            validate(list(known.values()))
        finally:
            self.validation_pending = set()
            self.validation_paths = {}

    def complete(self, group, validate, initial=None):
        self.group = group
        token = _observation.set(self)
        callback = validate
        def validate(snapshot):
            # A terminating ancestor must not hide an already-discovered child.
            self.validation_members = relevant
            try:
                self.validate_groups(snapshot, group)
                callback(snapshot)
            finally:
                self.validation_members = set()
        try:
            snapshot = initial if initial is not None else self.snapshot()
            pending = set()
            while True:
                self.check()
                current = {r[0]: r for r in snapshot}
                relevant = {r[0] for r in session_members(snapshot, group, self.isolated_probe)}
                # Include escaped or newly descended children, even outside the group.
                ancestors = {group} | set(self.samples) | relevant
                while True:
                    children = {r[0] for r in snapshot if r[1] in ancestors and r[0] != group}
                    if children <= ancestors:
                        break
                    ancestors |= children
                relevant |= ancestors - {group}
                relevant |= set(self.samples) | pending
                if self.target is not None:
                    relevant.add(self.target['pid'])
                    # Retain the entire target subtree, including while detached.
                    descendants = {self.target['pid']} | {r[0] for r in snapshot
                        if r[2] == self.target_binding['group']}
                    while True:
                        children = {r[0] for r in snapshot if r[1] in descendants}
                        if children <= descendants: break
                        descendants |= children
                    relevant |= descendants
                resolved, pending = [], set()
                self.pass_identities = {}
                self.full_identities = {}
                target_ready = True
                try:
                    target_ready = self.resolve_target(snapshot, group)
                except IdentityReadError:
                    target_ready = False
                if not target_ready:
                    pending.add(self.target['pid'])
                self.validate_partial(validate, snapshot, relevant)
                for pid in sorted(relevant):
                    row = current.get(pid)
                    if self.target_candidate(pid):
                        if target_ready and row is not None: resolved.append(row)
                        continue
                    if row is not None:
                        old = self.samples.get(pid)
                        if old and row[1:3] != old[1:3]:
                            self.reject('process parent/group changed during observation', pid,
                                        self.row_identity(old), self.row_identity(row), 'ps reconciliation')
                        self.samples[pid] = row
                        self.record(pid, 'ps', 0, 0, {'pid': pid, 'parent': row[1], 'group': row[2],
                            **({'path': row[3]} if Path(row[3]).is_file() else {})})
                    self.check()
                    info = identify_live_server(pid)
                    self.check()
                    # Fresh successful partial reads can already prove a violation,
                    # even when a later read proves termination. Never accept them
                    # as a substitute for a complete identity.
                    self.validate_partial(validate, snapshot, relevant)
                    entry = dict(pid=pid, status='unknown' if info is UNVERIFIED else 'goneOrZombie' if info is None else 'live', signalAuthority=False)
                    self.events.append(entry)
                    if info is UNVERIFIED:
                        pending.add(pid)
                    elif info is None and self.ui_process:
                        self.ui_process.gone(pid)
                        self.exec_candidates.discard(pid)
                    elif info is not None:
                        self.record(pid, 'identity', 0, 0, info)
                        try:
                            info = self.verify_helper(info)
                        except IdentityReadError:
                            pending.add(pid)
                            continue
                        if row is None:
                            pending.add(pid)  # Fresh full membership must agree as well.
                        else:
                            resolved.append((pid, info['parent'], info.get('group', row[2]), info['path'], row[4]))
                # A pending pass checks known contradictions, without treating an
                # unresolved parent as absent. Final acceptance is always strict.
                if pending:
                    self.validate_partial(validate, snapshot, relevant)
                else:
                    validate([r for r in snapshot if r[0] not in relevant] + resolved)
                self.check()
                if not pending:
                    complete_snapshot = [r for r in snapshot if r[0] not in relevant] + resolved
                    ui_roots = [r for r in complete_snapshot if self.ui_contract and r[3] == self.ui_contract['binary']]
                    if ui_roots:
                        try:
                            roles = self.ui_process.validate(complete_snapshot, ui_roots[0][0], set(self.ui_roles),
                                                             self.read_ui_identity, process_arguments)
                        except (IdentityReadError, ui_process_contract.Unstable):
                            snapshot = self.snapshot()
                            continue  # Retain all known members and the original cutoff.
                        except (ui_process_contract.Rejected, ui_process_contract.tools.Rejected,
                                ui_process_contract.artifacts.ContractError, KeyError, ValueError) as error:
                            pid = self.ui_process.last_pid or ui_roots[0][0]
                            info = self.ui_process.identities.get(pid, self.full_identities.get(pid, {'pid': pid}))
                            self.reject(str(error), pid, {}, info, 'UI semantic admission')
                        self.ui_roles = roles
                        self.exec_candidates.difference_update(roles)
                        for pid, role in roles.items():
                            self.helper_roles[pid] = dict(role=role, identity=dict(self.ui_process.identities[pid]))
                            self.events.append(dict(status='verifiedUIHelper', role=role,
                                identity=dict(self.ui_process.identities[pid]), signalAuthority=False))
                    if self.recording_owner:
                        self.recording_owner.settle(self, complete_snapshot)
                        if not self.resolve_target(complete_snapshot, group):
                            snapshot = self.snapshot(); continue
                    if self.target is not None and not self.target_valid:
                        raise IdentityChanged('target role remains unresolved')
                    if self.exec_candidates:
                        raise IdentityChanged('exec transition lacks fresh full identity')
                    self.check()
                    if self.recording_owner:
                        self.recording_owner.commit(self)
                    return [r for r in snapshot if r[0] not in relevant] + resolved
                snapshot = self.snapshot()
        finally:
            _observation.reset(token)

def check_budgets(fixture_count, server_count, mode):
    server_limit = SERVER_BUDGET if mode == 'traced' else 1
    if fixture_count > FIXTURE_BUDGET or server_count > server_limit:
        raise RuntimeError('exact executable instance budget exceeded')

def remaining_group_members(worker_pid):
    live, _, unknown = partition_group(rows(), worker_pid)
    return live + unknown

def partition_group(snapshot, worker_pid):
    members = [row for row in snapshot if row[2] == worker_pid and row[0] != worker_pid]
    live = [row for row in members if row[4][:1] in ('R', 'S', 'D', 'T', 'I', 'U')]
    zombies = [row for row in members if row[4].startswith('Z')]
    unknown = [row for row in members if row not in live and row not in zombies]
    return live, zombies, unknown

def wait_group_readback(worker_pid, timeout=GROUP_READBACK_SECONDS):
    started = {'monotonicNs': time.monotonic_ns(), 'unixNs': time.time_ns()}
    deadline = time.monotonic() + timeout
    while True:
        live, zombies, unknown = partition_group(rows(), worker_pid)
        if not (live or zombies or unknown) or time.monotonic() >= deadline:
            return {'request': started, 'result': {'monotonicNs': time.monotonic_ns(), 'unixNs': time.time_ns()},
                    'live': live, 'zombies': zombies, 'unknown': unknown,
                    'groupEmpty': not (live or zombies or unknown)}
        time.sleep(.05)

def graceful_stop(worker, details, timeout=WORKER_GRACE_SECONDS):
    if worker.poll() is not None:
        details.update(status='already exited', returncode=worker.returncode,
                       result={'monotonicNs': time.monotonic_ns(), 'unixNs': time.time_ns()})
        return
    details['request'] = {'signal': 'SIGTERM', 'pid': worker.pid,
                          'monotonicNs': time.monotonic_ns(), 'unixNs': time.time_ns()}
    worker.terminate()
    details['signalResult'] = {'returned': True, 'monotonicNs': time.monotonic_ns(), 'unixNs': time.time_ns()}
    try:
        worker.wait(timeout=timeout)
    except subprocess.TimeoutExpired:
        details.update(status='grace timeout', seconds=timeout,
                       result={'monotonicNs': time.monotonic_ns(), 'unixNs': time.time_ns()})
        return
    details.update(status='exited after TERM', returncode=worker.returncode,
                   result={'monotonicNs': time.monotonic_ns(), 'unixNs': time.time_ns()})

def finish_direct_worker(worker, details, timeout=WORKER_WAIT_SECONDS):
    """Only this Popen child is signalable; a historical PGID grants no authority."""
    details.update(pid=worker.pid, basis='direct unreaped Popen child',
                   request={'monotonicNs': time.monotonic_ns(), 'unixNs': time.time_ns()})
    if worker.poll() is None:
        details['signalRequest'] = {'signal': 'SIGKILL', 'pid': worker.pid,
                                    'monotonicNs': time.monotonic_ns(), 'unixNs': time.time_ns()}
        worker.kill()
        details['signalReturned'] = True
    else:
        details['signalSkipped'] = 'direct child already reaped; no PGID fallback'
    worker.wait(timeout=timeout)
    details.update(status='returned', returncode=worker.returncode,
                   result={'monotonicNs': time.monotonic_ns(), 'unixNs': time.time_ns()})


def observe_server_residual(pid, recorded):
    """The server is the worker's child, never a direct child handle of this parent."""
    entry = {'pid': pid, 'recordedStart': recorded['start'], 'signalAuthority': False}
    try:
        current = process_identity(pid)
    except IdentityChanged as error:
        return dict(entry, status='identity changed; not signalled', error=repr(error))
    except Exception as error:
        try:
            current = process_status(pid)
        except Exception:
            try:
                os.kill(pid, 0)
            except ProcessLookupError:
                return dict(entry, status='gone')
            except OSError:
                pass
            return dict(entry, status='unknown; not signalled', error=repr(error))
        if current['start'] != recorded['start']:
            return dict(entry, status='identity changed; not signalled')
        if current['state'] == 5:
            return dict(entry, status='zombie; current parent owns reap', current=current)
        return dict(entry, status='unknown; not signalled', current=current, error=repr(error))
    if current['start'] != recorded['start'] or current['path'] != recorded['path']:
        return dict(entry, status='identity changed; not signalled', current=current)
    return dict(entry, status='zombie; current parent owns reap' if current['state'] == 5
                else 'live; worker owns cleanup; not signalled', current=current)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--output', type=Path, required=True, help='New unique evidence directory')
    parser.add_argument('--case', required=True, choices=('connect', 'success', 'error', 'timeout', 'cancel', 'exit', 'paused', 'traced'))
    args = parser.parse_args()
    out = args.output.resolve()
    if out.exists():
        raise RuntimeError('output directory must not already exist')
    developer = Path(subprocess.check_output(['/usr/bin/xcode-select', '-p'], text=True, timeout=5).strip()).resolve()
    server_path = str((developer.parent / 'SharedFrameworks/LLDB.framework/Versions/A/Resources/debugserver').resolve())
    if not Path(server_path).is_file():
        raise RuntimeError('exact Xcode debugserver not found')
    fixture_path = str(out / 'owned-fixture')
    env = dict(os.environ, MAC_CU_REMOTE_WATCHDOG_PID=str(os.getpid()))
    owned_servers = {}
    unverified_servers = []
    reason = None
    cleanup_errors = []
    worker_grace = {'status': 'not attempted'}
    group_kill = {'status': 'disabled', 'reason': 'historical PGID is observation only, never signal authority'}
    worker_wait = {'status': 'not attempted'}
    server_cleanup = []
    group_readback = None
    def interrupted(signum, frame):
        raise KeyboardInterrupt('watchdog interrupted by signal ' + str(signum))
    previous = {sig: signal.signal(sig, interrupted) for sig in (signal.SIGTERM, signal.SIGINT)}
    original_mask = signal.pthread_sigmask(signal.SIG_BLOCK, (signal.SIGTERM, signal.SIGINT))
    try:
        worker = subprocess.Popen([sys.executable, str(HERE / 'remote_run.py'), '--output', str(out), '--case', args.case],
                                  env=env, stdin=subprocess.DEVNULL, start_new_session=True,
                                  preexec_fn=lambda: signal.pthread_sigmask(signal.SIG_SETMASK, original_mask))
    except BaseException:
        signal.pthread_sigmask(signal.SIG_SETMASK, original_mask)
        for sig, handler in previous.items():
            signal.signal(sig, handler)
        raise
    started_ns = time.monotonic_ns()
    deadline = time.monotonic() + DEADLINE_SECONDS
    work_deadline = deadline - CLEANUP_BUDGET_SECONDS
    try:
        signal.pthread_sigmask(signal.SIG_SETMASK, original_mask)
        if os.getpgid(worker.pid) != worker.pid:
            raise RuntimeError('worker process group isolation failed')
        while True:
            snapshot = rows()
            group = [row for row in snapshot if row[2] == worker.pid]
            fixture_count = sum(row[3] == fixture_path for row in group)
            servers = [row for row in snapshot if row[3] == server_path and (row[1] == worker.pid or row[2] == worker.pid)]
            mode_path = out / 'current-case'
            mode = mode_path.read_text().strip() if mode_path.exists() else ''
            live_servers = 0
            for pid, parent, group_id, path, stat in servers:
                if stat.startswith('Z'):
                    continue
                info = identify_live_server(pid)
                if info is None:
                    continue
                live_servers += 1
                if info is UNVERIFIED:
                    unverified_servers.append({'pid': pid, 'parent': parent, 'group': group_id,
                                               'stat': stat, 'monotonicNs': time.monotonic_ns(), 'unixNs': time.time_ns()})
                    if parent != worker.pid or group_id != worker.pid:
                        raise RuntimeError('unverified debugserver has unexpected parent or process group')
                    continue  # Count it, but never claim ownership or signal it individually.
                if info['parent'] != worker.pid or info['path'] != server_path:
                    raise RuntimeError('debugserver identity changed during registration')
                info['observedMonotonicNs'] = time.monotonic_ns()
                info['observedUnixNs'] = time.time_ns()
                old = owned_servers.setdefault(pid, info)
                if old['start'] != info['start']:
                    raise RuntimeError('debugserver PID was reused')
                if parent != worker.pid or group_id != worker.pid:
                    raise RuntimeError('unexpected debugserver parent or process group')
            check_budgets(fixture_count, live_servers, mode)
            status = worker.poll()
            if status is not None:
                live, zombies, unknown = partition_group(rows(), worker.pid)
                if live or zombies or unknown:
                    raise RuntimeError('worker exited leaving owned process-group members or zombies')
                if status != 0:
                    raise RuntimeError('worker failed: ' + str(status))
                break
            if time.monotonic() >= work_deadline:
                raise TimeoutError('worker budget exhausted; cleanup time reserved')
            time.sleep(.05)
    except BaseException as error:
        reason = repr(error)
    finally:
        signal.pthread_sigmask(signal.SIG_BLOCK, (signal.SIGTERM, signal.SIGINT))
        # Give the owned worker a bounded opportunity to release and reap its own children.
        try:
            graceful_stop(worker, worker_grace, timeout=min(WORKER_GRACE_SECONDS, max(0, deadline - time.monotonic())))
        except Exception as error:
            worker_grace.update(status='error', error=repr(error),
                                result={'monotonicNs': time.monotonic_ns(), 'unixNs': time.time_ns()})
            cleanup_errors.append('worker graceful stop: ' + repr(error))
        # Reap responsibility stays with the worker during its grace period. After it
        # exits, neither its descendants nor a reused PGID become this parent's children.
        try:
            finish_direct_worker(worker, worker_wait, timeout=min(WORKER_WAIT_SECONDS, max(0, deadline - time.monotonic())))
        except Exception as error:
            worker_wait.update(status='error', error=repr(error),
                               result={'monotonicNs': time.monotonic_ns(), 'unixNs': time.time_ns()})
            cleanup_errors.append('direct worker wait: ' + repr(error))
        for pid, recorded in owned_servers.items():
            try:
                entry = observe_server_residual(pid, recorded)
            except Exception as error:
                entry = {'pid': pid, 'status': 'unknown; not signalled', 'signalAuthority': False, 'error': repr(error)}
            entry['observedMonotonicNs'] = time.monotonic_ns()
            entry['observedUnixNs'] = time.time_ns()
            server_cleanup.append(entry)
            if entry['status'] != 'gone':
                cleanup_errors.append('recorded server residual: ' + str(pid) + ': ' + entry['status'])
        try:
            group_readback = wait_group_readback(worker.pid, timeout=min(GROUP_READBACK_SECONDS, max(0, deadline - time.monotonic())))
            if group_readback['live']:
                cleanup_errors.append('historical PGID has live members; ownership not inferred')
            if group_readback['zombies']:
                cleanup_errors.append('historical PGID has zombies; not reaped by this parent')
            if group_readback['unknown']:
                cleanup_errors.append('historical PGID has unknown-status members; not signalled')
        except Exception as error:
            cleanup_errors.append('group verification: ' + repr(error))
        for sig, handler in previous.items():
            signal.signal(sig, handler)
        if out.is_dir():
            (out / 'watchdog.json').write_text(json.dumps({'deadlineSeconds': DEADLINE_SECONDS,
                'fixtureBudget': FIXTURE_BUDGET, 'debugserverBudget': SERVER_BUDGET,
                'workBudgetSeconds': DEADLINE_SECONDS - CLEANUP_BUDGET_SECONDS, 'reservedCleanupSeconds': CLEANUP_BUDGET_SECONDS,
                'elapsedNs': time.monotonic_ns() - started_ns,
                'workerPID': worker.pid, 'reason': reason, 'ownedServers': list(owned_servers.values()),
                'unverifiedServerSnapshots': unverified_servers, 'workerGrace': worker_grace,
                'groupKill': group_kill, 'workerWait': worker_wait, 'serverCleanup': server_cleanup,
                'groupReadback': group_readback, 'groupReadbackGrantsSignalAuthority': False,
                'waitResponsibility': {'worker': 'watchdog direct child',
                    'fixtureAndServers': 'worker direct children',
                    'reparentedZombies': 'not children of watchdog; record only'},
                'cleanupErrors': cleanup_errors}, indent=2))
        signal.pthread_sigmask(signal.SIG_SETMASK, original_mask)
    if reason or cleanup_errors:
        print('watchdog failed:', reason, cleanup_errors, file=sys.stderr)
        return 1
    return 0

if __name__ == '__main__':
    raise SystemExit(main())
