"""Unwired Darwin inventory. Raw evidence only; no role or execution authority."""
import ctypes as C
import errno
import math
import os
import time
from dataclasses import dataclass, field

MAX_PIDS = 16384
PATH_BYTES = 4096
MAX_TARGETS = 16


class BSDInfo(C.Structure):
    # Selected SDK sys/proc_info.h: proc_bsdinfo; Darwin uid_t/gid_t are uint32.
    _fields_ = [(n, C.c_uint32) for n in (
        'flags', 'status', 'xstatus', 'pid', 'ppid', 'uid', 'gid', 'ruid',
        'rgid', 'svuid', 'svgid', 'reserved')]
    _fields_ += [('comm', C.c_char * 16), ('name', C.c_char * 32)]
    _fields_ += [(n, C.c_uint32) for n in ('nfiles', 'pgid', 'pjobc', 'tdev', 'tpgid')]
    _fields_ += [('nice', C.c_int32), ('start_sec', C.c_uint64), ('start_usec', C.c_uint64)]


@dataclass(frozen=True)
class Status:
    pid: int
    parent: int
    group: int
    start: tuple
    state: int

    def lifetime(self):
        return self.pid, self.parent, self.group, self.start


class Libproc:
    """Fixed typed reads; no dynamic command or syscall selection."""
    def __init__(self):
        self.lib = C.CDLL('/usr/lib/libproc.dylib', use_errno=True)
        declarations = {
            'proc_listpids': [C.c_uint32, C.c_uint32, C.c_void_p, C.c_int],
            'proc_pidinfo': [C.c_int, C.c_int, C.c_uint64, C.c_void_p, C.c_int],
            'proc_pidpath': [C.c_int, C.c_void_p, C.c_uint32],
        }
        for name, args in declarations.items():
            fn = getattr(self.lib, name)
            fn.argtypes, fn.restype = args, C.c_int

    def enumerate(self):
        buf = (C.c_int32 * MAX_PIDS)()
        C.set_errno(0)
        size = self.lib.proc_listpids(1, 0, buf, C.sizeof(buf))
        error = C.get_errno()
        # proc_listpids returns bytes, unlike proc_listallpids (PID count).
        valid = 0 < size < C.sizeof(buf) and size % C.sizeof(C.c_int32) == 0
        return size, error, tuple(buf[:size // 4]) if valid else ()

    def status(self, pid):
        buf = BSDInfo()
        C.set_errno(0)
        size = self.lib.proc_pidinfo(pid, 3, 0, C.byref(buf), C.sizeof(buf))
        error = C.get_errno()
        valid = size == C.sizeof(buf) and buf.pid == pid and 1 <= buf.status <= 5
        value = Status(pid, buf.ppid, buf.pgid, (buf.start_sec, buf.start_usec), buf.status) if valid else None
        return size, error, value

    def path(self, pid):
        buf = C.create_string_buffer(PATH_BYTES)
        C.set_errno(0)
        size = self.lib.proc_pidpath(pid, buf, PATH_BYTES)
        error = C.get_errno()
        raw = buf.raw
        # Do not trust zeroed/partial buffers, absent NUL, or relative names.
        valid = 0 < size < PATH_BYTES and raw.find(b'\0') == size and raw.startswith(b'/')
        return size, error, os.fsdecode(raw[:size]) if valid else None

    def absent(self, pid):
        try:
            os.kill(pid, 0)  # Existence only. Never positive identity or signal authority.
            return 0, 0, False
        except OSError as exc:
            return -1, exc.errno, exc.errno == errno.ESRCH


def monotonic():
    return time.clock_gettime(time.CLOCK_MONOTONIC)


class Expired(TimeoutError):
    pass


@dataclass
class Result:
    rows: dict = field(default_factory=dict)
    unknown: dict = field(default_factory=dict)
    terminal: dict = field(default_factory=dict)
    members: set = field(default_factory=set)
    groups: set = field(default_factory=set)
    matches: dict = field(default_factory=dict)
    issues: list = field(default_factory=list)
    complete: bool = False
    elapsed: float = 0.0
    counts: dict = field(default_factory=dict)
    errors: dict = field(default_factory=dict)


class Inventory:
    """At most two samples, one inherited absolute CLOCK_MONOTONIC cutoff.

    complete means sampled global rows resolved, never atomic topology or admission.
    The caller supplies exact absolute executable paths, worker PID/group and may
    supply retained family IDs/groups. No retry resets the cutoff or sticky conflicts.
    """
    def __init__(self, cutoff, worker, targets=(), retained=(), groups=(), *,
                 backend=None, clock=monotonic, normalize=os.path.realpath):
        if not math.isfinite(cutoff) or not 0 < worker < 2**31:
            raise ValueError('finite inherited cutoff and positive worker required')
        if len(targets) > MAX_TARGETS or len(retained) > MAX_PIDS or len(groups) > MAX_PIDS:
            raise ValueError('input ceiling exceeded')
        if any(not isinstance(p, int) or not 0 < p < 2**31 for p in (*retained, *groups)):
            raise ValueError('invalid retained PID/group')
        if any(not isinstance(p, str) or not p.startswith('/') or len(os.fsencode(p)) >= PATH_BYTES for p in targets):
            raise ValueError('bounded absolute targets required')
        self.cutoff, self.clock, self.normalize = cutoff, clock, normalize
        self.backend = backend
        self.targets = targets
        self.pids, self.groups = {worker, *retained}, {worker, *groups}
        if max(len(self.pids), len(self.groups)) > MAX_PIDS:
            raise ValueError('combined retained ceiling exceeded')
        self.seen, self.previous, self.paths = set(self.pids), {}, {}
        self.conflicts = set()
        self.calls, self.errors, self.samples = {}, {}, 0

    def check(self):
        if self.clock() >= self.cutoff:
            raise Expired('inherited acceptance cutoff exhausted')

    def call(self, name, *args):
        self.check()
        result, error, value = getattr(self.backend, name)(*args)
        self.calls[name] = self.calls.get(name, 0) + 1
        if error:
            key = (name, error)
            self.errors[key] = self.errors.get(key, 0) + 1
        self.check()
        return result, error, value

    def normalized(self, path):
        self.check()
        try:
            return self.normalize(path)
        finally:
            self.check()

    def remember(self, status):
        old = self.previous.get(status.pid)
        if old and old.lifetime() != status.lifetime():
            self.conflicts.add(status.pid)
        self.previous[status.pid] = status

    def sample(self):
        out, start = Result(), self.clock()
        if self.samples >= 2:
            out.issues.append('sample ceiling exceeded')
            return out
        self.samples += 1
        try:
            self.check()
            if self.backend is None:
                self.backend = Libproc()
                self.check()
            targets = tuple(self.normalized(p) for p in self.targets)
            size, error, listed = self.call('enumerate')
            if not 0 < size < MAX_PIDS * 4 or size % 4 or len(listed) != size // 4:
                out.issues.append('enumeration failed, partial, or saturated')
                return out
            if len(set(listed)) != len(listed) or any(p < 0 or p >= 2**31 for p in listed):
                out.issues.append('invalid enumeration')
                return out
            if len(self.seen | set(listed)) > MAX_PIDS:
                out.issues.append('cumulative PID ceiling exceeded')
                return out
            self.seen.update(listed)
            out.unknown = {pid: 'not yet read' for pid in self.seen}
            for pid in sorted(self.seen):
                self.check()
                out.unknown[pid] = 'not resolved'
                if pid == 0:
                    out.unknown[pid] = 'PID zero: no executable exclusion established'
                    continue  # kill(0,0) is group-scoped, never use it here.
                _, _, before = self.call('status', pid)
                if before is not None:
                    self.remember(before)
                _, _, path = self.call('path', pid)
                if path is not None:
                    try:
                        path = self.normalized(path)
                    except OSError:
                        path = None
                _, _, after = self.call('status', pid)
                if after is not None:
                    self.remember(after)
                if before is not None and after is not None and path is not None:
                    old = self.paths.get(pid)
                    if old is not None and old != path:
                        self.conflicts.add(pid)
                    self.paths[pid] = path
                    out.rows[pid] = (after, path)
                    del out.unknown[pid]
                else:
                    _, _, absent = self.call('absent', pid)
                    if absent:
                        out.terminal[pid] = 'fresh ESRCH'
                        del out.unknown[pid]
                    elif after is not None and after.state == 5:
                        # Fresh zombie fact is retained, but missing path still
                        # blocks global exact-executable accounting.
                        out.terminal[pid] = 'zombie (not reaped)'
            # Retain topology from successful partial reads, never as identity.
            while True:
                self.check()
                added = {p for p, s in self.previous.items()
                         if s.parent in self.pids or s.group in self.groups}
                added |= {p for p, (_, path) in out.rows.items() if path in targets}
                new_groups = {s.group for p, s in self.previous.items() if p in self.pids | added}
                if added <= self.pids and new_groups <= self.groups:
                    break
                self.pids |= added
                self.groups |= new_groups
                if len(self.groups) > MAX_PIDS:
                    out.issues.append('retained group ceiling exceeded')
                    return out
            out.matches = {t: tuple(p for p, (_, path) in out.rows.items() if path == t) for t in targets}
            if self.conflicts:
                out.issues.append('observed identity change: ' + ','.join(map(str, sorted(self.conflicts))))
            if any(len(pids) > 1 for pids in out.matches.values()):
                out.issues.append('duplicate exact executable')
            if out.unknown:
                out.issues.append('global unresolved PIDs; counts are lower bounds')
            self.check()
            out.complete = not out.issues
        except Expired:
            out.issues.append('cutoff exhausted; raw results rejected')
        finally:
            out.members, out.groups = set(self.pids), set(self.groups)
            out.counts, out.errors = dict(self.calls), dict(self.errors)
            out.elapsed = self.clock() - start
        return out
