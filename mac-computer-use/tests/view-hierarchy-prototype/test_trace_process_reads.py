"""Pure tests: all process/pipe effects are mocked; no child is created."""
import json
import os
from pathlib import Path
import subprocess
import threading
import types
import unittest
from unittest.mock import patch

from trace_process_reads import ProcessReadTrace


class TraceTests(unittest.TestCase):
    def setUp(self):
        self.directory = Path('/private-diagnostic')
        self.files, self.modes, self.fds = {}, {}, {}
        self.info = types.SimpleNamespace(st_mode=0o40700, st_uid=100)
        def open_file(path, flags, mode):
            name = Path(path).name
            if name in self.files:
                raise FileExistsError()
            self.files[name] = b''
            self.modes[name] = mode
            fd = 100 + len(self.fds)
            self.fds[fd] = name
            return fd
        def write_file(fd, data):
            self.files[self.fds[fd]] += data
            return len(data)
        for target, replacement in (
                ('os.open', open_file), ('os.write', write_file), ('os.close', lambda fd: None),
                ('os.getuid', lambda: 100), ('pathlib.Path.lstat', lambda path: self.info),
                ('time.clock_gettime', lambda clock: 10.0)):
            guard = patch(target, replacement)
            guard.start()
            self.addCleanup(guard.stop)
        # Fail closed if a regression attempts any real process effect.
        for target in ('subprocess.Popen.__init__', 'subprocess._fork_exec',
                       'os.read', 'os.waitpid', 'os.kill', 'os.fork', 'os.execve'):
            if target == 'subprocess._fork_exec' and not hasattr(subprocess, '_fork_exec'):
                continue
            guard = patch(target, side_effect=AssertionError('unmocked process effect'))
            guard.start()
            self.addCleanup(guard.stop)

    def records(self):
        return [json.loads(line) for line in self.files['trace.jsonl'].decode().splitlines()]

    def test_call_order_and_identity(self):
        sentinel = object()
        owner = types.SimpleNamespace(rows=lambda: sentinel)
        original = owner.rows
        with ProcessReadTrace(self.directory, 'inventory', cutoff=12, deadline=25) as trace:
            trace.bind(owner, 'rows', 'rows')
            self.assertIs(owner.rows(), sentinel)
        self.assertIs(owner.rows, original)
        self.assertEqual([(r['stage'], r['edge']) for r in self.records()],
                         [('trace', 'enter'), ('rows', 'enter'), ('rows', 'return'), ('trace', 'exit')])
        self.assertTrue(all(r['clock'] == 'CLOCK_MONOTONIC' and r['cutoff'] == 12 for r in self.records()))

    def test_fork_pipe_select_reap_boundaries_mocked(self):
        # Synthetic call sites use the reviewed stdlib filename; effects remain mocks.
        scope = {'os': os, 'subprocess': subprocess}
        exec(compile('def _execute_child():\n p = subprocess._fork_exec("secret argv")\n os.read(10, 50)\n os.read(10, 50)\n return p\ndef _communicate():\n subprocess._PopenSelector.select(None)\n os.read(11, 50)\n os.read(11, 50)\n os.waitpid(123, 0)\n', subprocess.__file__, 'exec'), scope)
        with patch('subprocess._fork_exec', return_value=123, create=True), patch('os.read', side_effect=[b'', b'err', b'abc', b'']), patch('os.waitpid', return_value=(123, 0)), patch.object(subprocess._PopenSelector, 'select', return_value=[]):
            with ProcessReadTrace(self.directory, 'inventory'):
                self.assertEqual(scope['_execute_child'](), 123)
                scope['_communicate']()
        records = self.records()
        self.assertEqual([r['stage'] for r in records if r['edge'] == 'enter'],
                         ['trace', 'fork_exec', 'error-pipe-read', 'error-pipe-read', 'select', 'output-read', 'output-read', 'reap'])
        self.assertTrue(any(r.get('pid') == 123 for r in records))
        self.assertEqual([r['eof'] for r in records if r.get('stage') == 'output-read' and r['edge'] == 'return'], [False, True])
        self.assertNotIn('secret', self.files['trace.jsonl'].decode())

    def test_timeout_identity_private_partial_and_missing(self):
        error = subprocess.TimeoutExpired(['PRIVATE argv'], 3, output=b'PRIVATE output' * 10, stderr=None)
        owner = types.SimpleNamespace(run=lambda: (_ for _ in ()).throw(error))
        with ProcessReadTrace(self.directory, 'cli-parent', partial_bytes=8) as trace:
            trace.bind(owner, 'run', 'parent')
            with self.assertRaises(subprocess.TimeoutExpired) as raised:
                owner.run()
            self.assertIs(raised.exception, error)
            self.assertIs(raised.exception.stdout, error.stdout)
        self.assertEqual(self.files['stdout.partial'], error.stdout[:8])
        self.assertFalse('stderr.partial' in self.files)
        self.assertEqual(self.modes['stdout.partial'], 0o600)
        text = self.files['trace.jsonl'].decode()
        self.assertNotIn('PRIVATE', text)
        self.assertTrue(any(r.get('present') is False for r in self.records()))

    def test_bounds(self):
        with ProcessReadTrace(self.directory, 'observer', max_bytes=2048, max_events=8) as trace:
            for _ in range(200):
                with trace.span('snapshot'):
                    pass
        self.assertLessEqual(len(self.files['trace.jsonl']), 2048)
        self.assertLessEqual(len(self.records()), 8)
        self.assertEqual(sum(r['edge'] == 'truncated' for r in self.records()), 1)

    def test_cancel_restore_nesting_and_foreign_thread(self):
        calls = []
        owner = types.SimpleNamespace(run=lambda: calls.append(1))
        original = owner.run
        error = KeyboardInterrupt()
        with self.assertRaises(KeyboardInterrupt) as raised:
            with ProcessReadTrace(self.directory, 'readback') as trace:
                trace.bind(owner, 'run', 'readback')
                with self.assertRaises(RuntimeError):
                    with ProcessReadTrace(self.directory, 'readback'):
                        pass
                thread = threading.Thread(target=owner.run)
                thread.start()
                thread.join(1)
                self.assertFalse(thread.is_alive())
                with trace.span('cleanup'):
                    raise error
        self.assertIs(raised.exception, error)
        self.assertIs(owner.run, original)
        self.assertEqual(calls, [1])
        self.assertFalse(any(r['stage'] == 'readback' for r in self.records()))

    def test_rows_normalization_and_unknown_missing_stage(self):
        namespace = {'os': os}
        exec('def rows():\n result = []\n for text in ("SECRET path", "ANOTHER"):\n  result.append(os.path.realpath(text))\n return result', namespace)
        owner = types.SimpleNamespace(rows=namespace['rows'])
        with patch('os.path.realpath', side_effect=lambda path: path):
            with ProcessReadTrace(self.directory, 'inventory') as trace:
                trace.bind_inventory(owner, 'rows')
                self.assertEqual(len(owner.rows()), 2)
        records = self.records()
        self.assertEqual([r['row_index'] for r in records if r['stage'] == 'normalization' and r['edge'] == 'enter'], [0, 1])
        self.assertFalse(any(r['stage'] == 'fork_exec' for r in records))
        self.assertNotIn('SECRET', self.files['trace.jsonl'].decode())

    def test_storage_failure_does_not_replace_error(self):
        error = ValueError('PRIVATE')
        with ProcessReadTrace(self.directory, 'observer') as trace:
            with patch('os.write', side_effect=OSError('full')):
                with self.assertRaises(ValueError) as raised:
                    with trace.span('snapshot'):
                        raise error
                self.assertIs(raised.exception, error)
                self.assertTrue(trace.storage_failed)

    def test_byte_limit_and_empty_stream(self):
        with ProcessReadTrace(self.directory, 'observer', max_bytes=2048, max_events=4096) as trace:
            for _ in range(200):
                with trace.span('validation'):
                    pass
        self.assertLessEqual(len(self.files['trace.jsonl']), 2048)
        self.assertTrue(trace.truncated)

    def test_popen_and_fork_error_identity(self):
        owner = types.SimpleNamespace(pid=123)
        error = OSError('PRIVATE')
        with patch.object(subprocess.Popen, '__init__', return_value=None) as constructor, patch('subprocess._fork_exec', side_effect=error, create=True) as fork:
            with ProcessReadTrace(self.directory, 'inventory'):
                subprocess.Popen.__init__(owner, ['PRIVATE'])
                with self.assertRaises(OSError) as raised:
                    subprocess._fork_exec('PRIVATE')
                self.assertIs(raised.exception, error)
            self.assertIs(subprocess.Popen.__init__, constructor)
            self.assertIs(subprocess._fork_exec, fork)
        self.assertTrue(any(r.get('pid') == 123 for r in self.records()))
        self.assertTrue(any(r['stage'] == 'fork_exec' and r['edge'] == 'exception' for r in self.records()))

    def test_empty_partial_is_present(self):
        error = subprocess.TimeoutExpired('PRIVATE', 3, output=b'', stderr=b'abcdef')
        with self.assertRaises(subprocess.TimeoutExpired):
            with ProcessReadTrace(self.directory, 'cli-parent', partial_bytes=3):
                raise error
        self.assertEqual(self.files['stdout.partial'], b'')
        self.assertEqual(self.files['stderr.partial'], b'abc')
        self.assertTrue(any(r.get('present') is True and r.get('stored_bytes') == 0 for r in self.records()))

    def test_local_39_module_hook_and_unicode_truncation(self):
        fork = types.SimpleNamespace(fork_exec=lambda *args: 321)
        error = subprocess.TimeoutExpired('PRIVATE', 3, output='éé')
        with patch.object(subprocess, '_posixsubprocess', fork, create=True):
            original = fork.fork_exec
            with self.assertRaises(subprocess.TimeoutExpired):
                with ProcessReadTrace(self.directory, 'inventory', partial_bytes=3):
                    self.assertEqual(fork.fork_exec('PRIVATE'), 321)
                    raise error
            self.assertIs(fork.fork_exec, original)
        self.assertEqual(len(self.files['stdout.partial']), 3)
        self.assertTrue(any(r['stage'] == 'timeout-output' and r.get('truncated') for r in self.records()))

    def test_invalid_directory_and_recovery(self):
        self.info.st_mode = 0o40755
        with self.assertRaises(ValueError):
            with ProcessReadTrace(self.directory, 'observer'):
                pass
        self.info.st_mode = 0o40700
        with ProcessReadTrace(self.directory, 'observer'):
            pass


if __name__ == '__main__':
    unittest.main()
