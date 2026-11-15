"""Exercise native launcher guards with bounded command-line fixtures, never a GUI."""
import importlib.util
import os
from pathlib import Path
import shutil
import signal
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from unittest import mock

SUPPORT = Path(__file__).resolve().parents[2] / 'mac-computer-use/tests/native_check_support.py'
spec = importlib.util.spec_from_file_location('native_check_support', SUPPORT)
support = importlib.util.module_from_spec(spec)
spec.loader.exec_module(support)


@unittest.skipUnless(sys.platform == 'darwin' and shutil.which('swiftc'), 'macOS native process checks')
class NativeCheckSafetyTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.directory = tempfile.TemporaryDirectory(prefix='native-check-guards-')
        cls.root = Path(cls.directory.name)
        cls.entry = cls.root / 'main.swift'
        cls.guarded = cls.root / 'guarded'
        production = '''import Foundation
// Chrome starts mac-cu as the native messaging host
if CommandLine.arguments.contains("--check-screen-recording") { exit(1) }
exit(70)
'''
        cls.entry.write_text(support.isolated_main(production, 'print("root"); exit(0)'))
        subprocess.run(['swiftc', str(cls.entry), '-o', str(cls.guarded)], check=True, capture_output=True, timeout=30)
        cls.worker = cls.root / 'worker'
        # A fixed fan-out of three sleeping copies tests the independent instance budget.
        # No fixture recursively launches copies, and none imports AppKit or has an app bundle.
        cls.entry.write_text('''import Foundation
if CommandLine.arguments.contains("--fan-out") || CommandLine.arguments.contains("--orphan") {
    for _ in 0..<3 {
        let child = Process(); child.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
        child.arguments = ["--linger"]; try! child.run()
    }
    if CommandLine.arguments.contains("--orphan") { exit(0) }
}
if CommandLine.arguments.contains("--fail") { exit(9) }
if CommandLine.arguments.contains("--ok") { exit(0) }
Thread.sleep(forTimeInterval: 20)
''')
        subprocess.run(['swiftc', str(cls.entry), '-o', str(cls.worker)], check=True, capture_output=True, timeout=30)

    @classmethod
    def tearDownClass(cls):
        cls.directory.cleanup()

    def run_owned(self, executable, arguments, **options):
        with open(os.devnull, 'w') as log:
            return support.run_owned(executable, arguments, environment=dict(os.environ), log=log, **options)

    def test_helper_and_rejected_routes_are_headless(self):
        with open(os.devnull, 'w') as log:
            support.check_routes(self.guarded, dict(os.environ), log)
        self.assertEqual(self.run_owned(self.guarded, ['--native-check'], timeout=2), 0)
        self.assertEqual(support.instances(self.guarded), [])

    def test_timeout_cleans_only_owned_processes(self):
        unrelated = subprocess.Popen(['/bin/sleep', '20'])
        try:
            with self.assertRaises(TimeoutError):
                self.run_owned(self.worker, ['--linger'], timeout=0.2)
            self.assertIsNone(unrelated.poll())
            self.assertEqual(support.instances(self.worker), [])
        finally:
            unrelated.terminate(); unrelated.wait(timeout=3)

    def test_instance_budget_cleans_fixed_fan_out(self):
        with self.assertRaisesRegex(RuntimeError, 'instance budget'):
            self.run_owned(self.worker, ['--fan-out'], timeout=3, max_instances=2)
        self.assertEqual(support.instances(self.worker), [])

    def test_root_exit_with_surviving_copies_fails_and_cleans(self):
        with self.assertRaisesRegex(RuntimeError, 'after root exit'):
            self.run_owned(self.worker, ['--orphan'], timeout=3, max_instances=4)
        self.assertEqual(support.instances(self.worker), [])

    def test_interrupt_cleans_owned_processes(self):
        # Wait for actual monitoring instead of assuming process startup takes <300ms.
        ready = threading.Event()
        original_scan = support.instances
        scans = 0
        def scan(executable):
            nonlocal scans
            scans += 1
            if scans == 1:
                time.sleep(0.4)  # A slow preflight used to consume the old timer.
            result = original_scan(executable)
            handler = signal.getsignal(signal.SIGTERM)
            if callable(handler) and handler.__name__ == 'interrupted':
                ready.set()
            return result
        def interrupt():
            if ready.wait(5):
                os.kill(os.getpid(), signal.SIGTERM)
        sender = threading.Thread(target=interrupt)
        with mock.patch.object(support, 'instances', side_effect=scan):
            sender.start()
            try:
                with self.assertRaises(support.NativeCheckInterrupted):
                    self.run_owned(self.worker, ['--linger'], timeout=3)
            finally:
                sender.join(timeout=6)
        self.assertTrue(ready.is_set())
        self.assertEqual(support.instances(self.worker), [])

    def test_normal_exit_preserves_status(self):
        self.assertEqual(self.run_owned(self.worker, ['--ok'], timeout=2), 0)
        self.assertEqual(self.run_owned(self.worker, ['--fail'], timeout=2), 9)
        for timeout in [0, -1, float('inf'), float('nan')]:
            with self.assertRaises(ValueError):
                self.run_owned(self.worker, ['--ok'], timeout=timeout)

    def test_interrupt_inside_subprocess_poll_is_not_swallowed(self):
        # CPython poll handles OSError from waitpid internally. Deliver the real
        # signal at that boundary, without a timing-dependent sender thread.
        import inspect
        import errno
        from types import SimpleNamespace
        original = subprocess.Popen._internal_poll
        parameters = inspect.signature(original).parameters
        delivered = False
        def polling(process, *args, **kwargs):
            nonlocal delivered
            if not delivered and process.args[0] == str(self.worker):
                delivered = True
                def interrupted_wait(*_):
                    os.kill(os.getpid(), signal.SIGTERM)
                    return 0, 0
                if '_del_safe' in parameters:
                    kwargs['_del_safe'] = SimpleNamespace(waitpid=interrupted_wait, WNOHANG=os.WNOHANG, ECHILD=errno.ECHILD)
                else:
                    self.assertIn('_waitpid', parameters, 'Inspect changed CPython poll boundary')
                    kwargs['_waitpid'] = interrupted_wait
            return original(process, *args, **kwargs)
        with mock.patch.object(subprocess.Popen, '_internal_poll', polling):
            with self.assertRaisesRegex(RuntimeError, 'interrupted by signal'):
                self.run_owned(self.worker, ['--linger'], timeout=0.5)
        self.assertTrue(delivered)
        self.assertEqual(support.instances(self.worker), [])


if __name__ == '__main__':
    unittest.main()
