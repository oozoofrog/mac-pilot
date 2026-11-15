"""Opt-in diagnostic preparation. Imports do not install hooks or run processes."""
import contextlib
import functools
import json
import math
import os
from pathlib import Path
import stat
import subprocess
import sys
import threading
import time

_ACTIVE = threading.Lock()
_ROLES = {'inventory', 'cli-parent', 'observer', 'readback'}
_STAGES = {'rows', 'instances', 'snapshot', 'validation', 'checkpoint',
           'parent', 'receipt-read', 'receipt-write', 'cleanup', 'readback',
           'parse', 'normalization'}


class ProcessReadTrace:
    """One serial diagnostic scope; no execution, signaling, or deadline authority.

    Temporary process-wide bindings bypass instrumentation on all other threads.
    Call only in a quiescent diagnostic interpreter; no concurrent hook owners.
    """
    def __init__(self, private_directory, role, *, cutoff=None, deadline=None,
                 max_bytes=65536, max_events=256, partial_bytes=4096):
        if role not in _ROLES:
            raise ValueError('undeclared diagnostic role')
        if not (2048 <= max_bytes <= 1048576 and 4 <= max_events <= 4096
                and 0 <= partial_bytes <= 65536):
            raise ValueError('invalid diagnostic bounds')
        for value in (cutoff, deadline):
            if value is not None and (type(value) not in (int, float) or not math.isfinite(value)):
                raise ValueError('deadline must use session CLOCK_MONOTONIC')
        self.directory = Path(private_directory)
        self.role, self.cutoff, self.deadline = role, cutoff, deadline
        self.max_bytes, self.max_events, self.partial_bytes = max_bytes, max_events, partial_bytes
        self.fd = None
        self.events = self.bytes = 0
        self.truncated = self.storage_failed = False
        self._patches = []
        self._busy = False
        self._partial_saved = False
        self._used = False
        self._row_index = None

    def _record(self, stage, edge, **fields):
        # Only internal, fixed-schema callers may supply fields; no text/argv API.
        if self.fd is None or self._busy or threading.get_ident() != self.thread:
            return
        self._busy = True
        try:
            record = dict(stage=stage, edge=edge, role=self.role,
                          clock='CLOCK_MONOTONIC', t=time.clock_gettime(time.CLOCK_MONOTONIC),
                          cutoff=self.cutoff, deadline=self.deadline, **fields)
            data = (json.dumps(record, separators=(',', ':'), allow_nan=False) + '\n').encode()
            if self.truncated:
                return
            if self.events >= self.max_events - 1 or self.bytes + len(data) > self.max_bytes - 512:
                data = (json.dumps(dict(stage='trace', edge='truncated', clock='CLOCK_MONOTONIC',
                                        t=record['t'], cutoff=self.cutoff, deadline=self.deadline)) + '\n').encode()
                self.truncated = True
            # No Python buffering or queue. A partial/failed write makes the tail unknown.
            written = os.write(self.fd, data)
            self.bytes += written
            self.events += 1
            if written != len(data):
                self.storage_failed = self.truncated = True
        except Exception:
            self.storage_failed = self.truncated = True
        finally:
            self._busy = False

    def _timeout(self, error):
        if not isinstance(error, subprocess.TimeoutExpired) or self._partial_saved:
            return
        self._partial_saved = True
        remaining = self.partial_bytes
        for label, value in (('stdout', error.stdout), ('stderr', error.stderr)):
            if value is None:
                self._record('timeout-output', label, present=False)
                continue
            if type(value) not in (bytes, str):
                self._record('timeout-output', label, present=True, unsupported=True)
                continue
            # Slice before encoding; never encode an unbounded string.
            prefix = value[:remaining]
            encoded = prefix.encode('utf-8') if type(value) is str else prefix
            data = encoded[:remaining]
            was_truncated = len(prefix) < len(value) or len(encoded) > remaining
            stored = 0
            try:
                fd = os.open(str(self.directory / (label + '.partial')), os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_APPEND, 0o600)
                try:
                    stored = os.write(fd, data)
                finally:
                    os.close(fd)
            except OSError:
                self.storage_failed = True
            remaining -= len(data)
            self._record('timeout-output', label, present=True, stored_bytes=stored,
                         source_units=len(value), units='characters' if type(value) is str else 'bytes',
                         truncated=(was_truncated or stored < len(data)),
                         encoding='utf-8' if type(value) is str else 'bytes')

    def _patch(self, owner, name, stage, *, filter_call=None, result_kind=None):
        original = getattr(owner, name)
        @functools.wraps(original)
        def wrapped(*args, **kwargs):
            if threading.get_ident() != self.thread or self._busy or (filter_call and not filter_call(sys._getframe(1))):
                return original(*args, **kwargs)
            caller = sys._getframe(1)
            actual_stage = stage
            fields = {}
            if stage in ('receipt-read', 'receipt-write') and args and isinstance(args[0], Path):
                name = args[0].name
                fields['path_id'] = name if name in ('session.json', 'parent.json', 'target.json') else 'other'
            if stage == 'pipe-read':
                actual_stage = 'error-pipe-read' if caller.f_code.co_name == '_execute_child' else 'output-read'
            if stage == 'normalization':
                if self._row_index is not None:
                    fields['row_index'] = self._row_index
                    self._row_index += 1
            frame = caller
            for _ in range(8):
                if frame is None:
                    break
                for key in ('cutoff', 'deadline'):
                    value = frame.f_locals.get(key)
                    if type(value) in (int, float) and math.isfinite(value):
                        fields.setdefault('inherited_' + key, value)
                subject = frame.f_locals.get('self')
                if subject is not None and type(subject).__module__ in ('remote_watchdog',):
                    value = subject.__dict__.get('cutoff')
                    if type(value) in (int, float) and math.isfinite(value):
                        fields.setdefault('inherited_cutoff', value)
                frame = frame.f_back
            del frame, caller
            self._record(actual_stage, 'enter', **fields)
            previous_row = self._row_index
            if stage in ('rows', 'instances'):
                self._row_index = 0
            try:
                result = original(*args, **kwargs)
            except BaseException as error:
                # Names/messages/args from arbitrary exception classes are excluded.
                if stage in ('rows', 'instances'):
                    self._row_index = previous_row
                kind = ('TimeoutExpired' if isinstance(error, subprocess.TimeoutExpired) else
                        'KeyboardInterrupt' if isinstance(error, KeyboardInterrupt) else
                        'OSError' if isinstance(error, OSError) else
                        type(error).__name__ if type(error).__name__ in ('ObservationExpired', 'IdentityReadError', 'IdentityChanged', 'TimeoutError', 'ValueError', 'RuntimeError') else 'other')
                self._record(actual_stage, 'exception', exception=kind)
                try:
                    self._timeout(error)
                except Exception:
                    self.storage_failed = True
                raise
            if stage in ('rows', 'instances'):
                self._row_index = previous_row
            fields = {}
            if stage == 'Popen.communicate' and type(result) is tuple:
                fields['stream_units'] = [len(v) if type(v) in (bytes, str) else None for v in result]
            if result_kind == 'pid' and type(result) is int and result > 0:
                fields['pid'] = result
            elif result_kind == 'read' and type(result) is bytes:
                fields = dict(bytes=len(result), eof=not result)
            elif result_kind == 'rows' and type(result) is list:
                fields['rows'] = len(result)
            elif result_kind == 'popen' and args:
                pid = getattr(args[0], 'pid', None)
                if type(pid) is int and pid > 0:
                    fields['pid'] = pid
            self._record(actual_stage, 'return', **fields)
            return result
        self._patches.append((owner, name, original))
        setattr(owner, name, wrapped)

    def bind(self, owner, name, stage):
        """Wrap a reviewed existing function. Never evaluates a command or argv."""
        if self.fd is None or threading.get_ident() != self.thread or stage not in _STAGES:
            raise ValueError('inactive scope or undeclared stage')
        self._patch(owner, name, stage, result_kind='rows' if stage in ('rows', 'instances') else None)

    @contextlib.contextmanager
    def span(self, stage):
        """Explicit caller milestones (including receipt parse/validation)."""
        if self.fd is None or stage not in _STAGES or threading.get_ident() != self.thread:
            raise ValueError('inactive scope or undeclared stage')
        self._record(stage, 'enter')
        try:
            yield
        except BaseException as error:
            self._record(stage, 'exception', exception='TimeoutExpired' if isinstance(error, subprocess.TimeoutExpired) else 'other')
            try:
                self._timeout(error)
            except Exception:
                self.storage_failed = True
            raise
        else:
            self._record(stage, 'return')

    def __enter__(self):
        if self._used or not _ACTIVE.acquire(False):
            raise RuntimeError('nested/concurrent/reused trace forbidden')
        self._used = True
        self.thread = threading.get_ident()
        try:
            info = self.directory.lstat()
            if not stat.S_ISDIR(info.st_mode) or info.st_uid != os.getuid() or info.st_mode & 0o077:
                raise ValueError('use an owned private directory, mode 0700')
            self.fd = os.open(str(self.directory / 'trace.jsonl'), os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_APPEND, 0o600)
            self._patch(subprocess, 'check_output', 'check_output')
            for name in ('__init__', '_execute_child', 'communicate', '_communicate', '_check_timeout',
                         'poll', '_internal_poll', 'wait', '_wait', '_try_wait', 'kill'):
                if hasattr(subprocess.Popen, name):
                    self._patch(subprocess.Popen, name, 'Popen.' + name,
                                result_kind='popen' if name == '__init__' else None)
            # Current local Xcode CPython3.9 calls _posixsubprocess.fork_exec.
            posix_module = getattr(subprocess, '_posixsubprocess', None)
            if posix_module is not None:
                self._patch(posix_module, 'fork_exec', 'fork_exec', result_kind='pid')
            # Other reviewed runtimes may instead bind the direct alias.
            if hasattr(subprocess, '_fork_exec'):
                self._patch(subprocess, '_fork_exec', 'fork_exec', result_kind='pid')
            def in_subprocess(frame):
                return frame.f_code.co_filename == subprocess.__file__
            def pipe_read(frame):
                return in_subprocess(frame) and frame.f_code.co_name in ('_execute_child', '_communicate')
            self._patch(os, 'read', 'pipe-read', filter_call=pipe_read, result_kind='read')
            self._patch(os, 'waitpid', 'reap', filter_call=in_subprocess)
            selector = getattr(subprocess, '_PopenSelector', None)
            if selector is not None:
                self._patch(selector, 'select', 'select', filter_call=in_subprocess)
            # No path contents. Row index derives from existing result, no frame retention.
            def normalization(frame):
                return frame.f_code.co_name in ('rows', 'instances') and frame.f_code in self._row_codes
            self._row_codes = set()
            self._patch(os.path, 'realpath', 'normalization', filter_call=normalization)
            self._record('trace', 'enter')
            return self
        except BaseException:
            self.__exit__(None, None, None)
            raise

    def bind_inventory(self, owner, name):
        """Bind reviewed rows/instances and their per-row realpath calls."""
        if name not in ('rows', 'instances'):
            raise ValueError('expected inventory function')
        self._row_codes.add(getattr(owner, name).__code__)
        self.bind(owner, name, name)

    def __exit__(self, kind, error, traceback):
        try:
            if error is not None:
                try:
                    self._timeout(error)
                except Exception:
                    self.storage_failed = True
            self._record('trace', 'exit')
        finally:
            for owner, name, original in reversed(self._patches):
                setattr(owner, name, original)
            self._patches.clear()
            try:
                if self.fd is not None:
                    os.close(self.fd)
            finally:
                self.fd = None
                _ACTIVE.release()
        return False
