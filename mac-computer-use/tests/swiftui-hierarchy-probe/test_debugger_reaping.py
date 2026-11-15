"""Headless direct-handle reaping; no debugger, fixture, or target execution."""
import json
import os
from pathlib import Path
import tempfile
import threading
import unittest
from contextlib import ExitStack
from unittest.mock import patch

import debugger as d


class Handle:
    def __init__(self, pid):
        self.pid = pid
        self.returncode = None
        self.exited = False
        self.reaped = threading.Event()
        self.error = None

    def poll(self):
        if self.error:
            raise self.error
        if self.exited:
            self.returncode = 0
            self.reaped.set()
        return self.returncode

    def wait(self, timeout=None):
        value = self.poll()
        if value is None:
            raise d.subprocess.TimeoutExpired('fake', timeout)
        return value

    def terminate(self):
        raise AssertionError('unexpected signal')

    kill = terminate


class SupervisorReapingTests(unittest.TestCase):
    def run_supervisor(self, mode='early'):
        server, worker = Handle(8001), Handle(8002)
        observations = []
        threads_before = set(threading.enumerate())
        with tempfile.TemporaryDirectory() as tmp, ExitStack() as stack:
            folder = Path(tmp)
            def receipt(closed=True):
                (folder / 'debugger-result.json').write_text(json.dumps(dict(
                    status='submitted', detach='success', debuggerClosed=closed)))
            def check():
                if not launched:
                    return
                if mode not in ('normal', 'error', 'recovered_error', 'grace'):
                    server.exited = True
                    observations.append(server.reaped.wait(1))
                    observations.append(worker.returncode is None)
                if mode == 'grace':
                    raise RuntimeError('cancel during worker lifetime')
                if mode == 'cancel':
                    receipt()
                    worker.exited = True
                    raise RuntimeError('cancelled')
                if mode in ('error', 'recovered_error'):
                    server.error = OSError('reaper failed')
                    # Allow the reaper to encounter the injected error before final cleanup.
                    error_seen.wait(1)
                if mode == 'failure':
                    worker.exited = server.exited = True
                    return
                receipt(mode != 'missing')
                if mode == 'missing':
                    (folder / 'debugger-result.json').write_text(json.dumps(dict(status='submitted', detach='success')))
                worker.exited = True
                server.exited = True
            if mode == 'grace':
                def grace_wait(timeout=None):
                    self.assertEqual(timeout, d.CHILD_GRACE_SECONDS)
                    server.exited = True
                    observations.extend([server.reaped.wait(1), worker.returncode is None])
                    raise d.subprocess.TimeoutExpired('fake live worker', timeout)
                worker.wait = grace_wait
            launched = []
            def popen(*args, **kwargs):
                owned = server if not launched else worker
                launched.append(owned)
                if mode == 'spawn_failure' and owned is worker:
                    server.exited = True
                    raise OSError('worker spawn failed')
                return owned
            stop_child = d.c.stop_child
            def checked_stop(owned):
                self.assertFalse(any(t.name == 'swiftui-server-reaper' for t in threading.enumerate()))
                if mode == 'recovered_error' and owned is server:
                    server.error = None
                return stop_child(owned)
            stack.enter_context(patch.object(d.c, 'stop_child', checked_stop))
            error_seen = threading.Event()
            original_poll = server.poll
            def poll():
                try:
                    return original_poll()
                except OSError:
                    error_seen.set()
                    raise
            server.poll = poll
            for obj, name, value in (
                (d.worker_runtime, 'verify', lambda *_: None),
                (d.worker_runtime, 'worker_env', lambda: {}),
                (d, 'RUNTIME_PROOF', {'context': {'pythonPath': '/fake/python'}}),
                (d.p, 'validate', lambda *_: None),
                (d.c, 'verify_target', lambda *_: None),
                (d.c, 'ProcessProbe', lambda: type('Probe', (), {'identity': lambda _, pid:
                    {'parent': os.getpid(), 'path': '/fake/server', 'pid': pid}})()),
                (d, 'admit_fixture', lambda *_: {'bundleID': 'local.mac-pilot.swiftui-probe.test'}),
                (d.c, 'tools_for_xcode', lambda: ('/fake/server', '/fake/python', '/fake/sdk')),
                (d.subprocess, 'Popen', popen),
                (d.c, 'recovered', lambda *_, **__: {'verified': True}),
            ):
                stack.enter_context(patch.object(obj, name, value))
            failure = None
            try:
                d.supervise({'target': {}}, folder, check)
            except RuntimeError as error:
                failure = str(error)
            result = json.loads((folder / 'bootstrap.json').read_text())
        self.assertEqual(set(threading.enumerate()), threads_before)
        return result, observations, failure, server, worker

    def test_exited_server_reaped_while_worker_still_live(self):
        result, observations, failure, _, _ = self.run_supervisor()
        self.assertEqual(observations, [True, True])
        self.assertIsNone(failure)
        self.assertTrue(result['childrenReaped'])
        self.assertLessEqual(result['serverReaper']['reapedNS'], result['childrenCleanupStartedNS'])

    def test_normal_close_and_simultaneous_final_cleanup(self):
        result, _, failure, server, worker = self.run_supervisor('normal')
        self.assertIsNone(failure)
        self.assertTrue(result['serverReaper']['joined'])
        self.assertTrue(result['childrenReaped'])
        self.assertEqual((server.returncode, worker.returncode), (0, 0))

    def test_cancellation_still_joins_and_reaps_with_closed_receipt(self):
        result, observations, failure, server, worker = self.run_supervisor('cancel')
        self.assertIsNotNone(failure)
        self.assertIn('cancelled', result['supervisorError'])
        self.assertTrue(result['serverReaper']['joined'])
        self.assertTrue(result['childrenReaped'])
        self.assertEqual(observations, [True, True])

    def test_missing_debugger_closed_keeps_custody_even_after_reap(self):
        result, _, failure, _, _ = self.run_supervisor('missing')
        self.assertIsNotNone(failure)
        self.assertTrue(result['custodyRequired'])
        self.assertFalse(result['childrenReaped'])
        self.assertFalse(result['recovery']['verified'])
        self.assertEqual(result['serverReaper']['returncode'], 0)

    def test_reaper_error_is_reported_and_never_accepts_capture(self):
        result, _, failure, _, _ = self.run_supervisor('error')
        self.assertIsNotNone(failure)
        self.assertIn('reaper failed', result['serverReaper']['error'])
        self.assertIn('reaper failed', result['debugserverCleanupError'])
        self.assertFalse(result['childrenReaped'])

    def test_reaper_error_rejects_success_even_if_final_cleanup_succeeds(self):
        result, _, failure, _, _ = self.run_supervisor('recovered_error')
        self.assertTrue(result['childrenReaped'])
        self.assertTrue(result['recovery']['verified'])
        self.assertIsNotNone(failure)
        self.assertIn('reaper failed', result['serverReaper']['error'])

    def test_worker_failure_without_receipt_retains_custody(self):
        result, _, failure, _, _ = self.run_supervisor('failure')
        self.assertIsNotNone(failure)
        self.assertTrue(result['serverReaper']['joined'])
        self.assertTrue(result['custodyRequired'])
        self.assertFalse(result['childrenReaped'])

    def test_worker_spawn_failure_still_joins_and_cleans_direct_server(self):
        result, _, failure, server, _ = self.run_supervisor('spawn_failure')
        self.assertIsNotNone(failure)
        self.assertIn('worker spawn failed', result['supervisorError'])
        self.assertTrue(result['serverReaper']['joined'])
        self.assertEqual(server.returncode, 0)

    def test_reaper_remains_independent_during_worker_grace(self):
        result, observations, failure, _, worker = self.run_supervisor('grace')
        self.assertEqual(observations, [True, True])
        self.assertIsNotNone(failure)
        self.assertTrue(result['bootstrapTimeout'])
        self.assertTrue(result['custodyRequired'])
        self.assertFalse(result['childrenReaped'])
        self.assertIsNone(worker.returncode)

    def test_live_handle_stops_without_signal_or_reap(self):
        server = Handle(9001)
        reaper = d.ServerReaper(server)
        evidence = reaper.finish()
        self.assertTrue(evidence['joined'])
        self.assertNotIn('returncode', evidence)
        self.assertIsNone(server.returncode)
        self.assertFalse(reaper.thread.is_alive())

    def test_unknown_jit_caller_retains_engine(self):
        class Engine:
            active_call = 'submission'
            def detach(self):
                raise AssertionError('detach')
            def close(self):
                raise AssertionError('close')
        result = {}
        self.assertFalse(d.finish_engine(Engine(), result))
        self.assertTrue(result['custodyRequired'])
        self.assertFalse(result['debuggerClosed'])


if __name__ == '__main__':
    unittest.main()
