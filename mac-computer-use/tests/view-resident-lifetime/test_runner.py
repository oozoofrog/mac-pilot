import importlib.util
import os
from pathlib import Path
import plistlib
import subprocess
import sys
import unittest
from unittest.mock import patch, Mock

import debugger
import protocol as p
import runner


class IsolatedProbeObservation(unittest.TestCase):
    def test_shared_isolated_probe_and_aggregate_utility_contract(self):
        import tempfile
        w = runner.s.watchdog
        server = '/Applications/Xcode.app/Contents/SharedFrameworks/LLDB.framework/Versions/A/Resources/debugserver'
        with tempfile.TemporaryDirectory() as directory:
            build = Path(directory).resolve(); probe = build / 'session-probe'; probe.touch()
            for extra in (False, True):
                rows = [(100, 40, 100, str(probe), 'S'), (101, 100, 100, '/bin/ps', 'S')]
                if extra: rows.append((102, 40, 40, '/usr/bin/plutil', 'S'))
                def identify(pid):
                    row = next(r for r in rows if r[0] == pid)
                    return dict(pid=pid, parent=row[1], group=row[2], path=row[3], start=[10, pid], state=2)
                with patch.object(runner.s, 'monotonic', return_value=0), \
                     patch.object(w, 'rows', return_value=rows), \
                     patch.object(w, 'identify_live_server', side_effect=identify):
                    def observe():
                        return runner.s.observe_processes(40, None, build, server, {}, 3,
                                                         process_check=runner.process_budget)
                    if extra:
                        with self.assertRaisesRegex(RuntimeError, 'utility budget'): observe()
                    else:
                        self.assertEqual(len(observe()), 2)


class RunnerTests(unittest.TestCase):
    def test_ambiguous_jit_call_never_detaches_or_destroys(self):
        for phase in ('load', 'submission'):
            engine = Mock(active_call=phase)
            result = {}
            self.assertTrue(hasattr(debugger, 'finish_engine'), 'missing guarded cleanup')
            self.assertFalse(debugger.finish_engine(engine, result))
            engine.detach.assert_not_called()
            engine.close.assert_not_called()
            self.assertTrue(result['custodyRequired'])

    def test_completed_call_closes_only_after_successful_detach(self):
        self.assertTrue(hasattr(debugger, 'finish_engine'), 'missing guarded cleanup')
        for outcome in ('success', 'detach failed'):
            engine = Mock(active_call=None)
            engine.detach.return_value = outcome
            result = {}
            closed = debugger.finish_engine(engine, result)
            self.assertEqual(closed, outcome == 'success')
            self.assertEqual(engine.close.call_count, int(outcome == 'success'))

    def test_missing_or_pending_worker_receipt_preserves_both_children(self):
        self.assertTrue(hasattr(debugger, 'finish_children'), 'missing guarded child cleanup')
        for receipt in ({}, {'status': 'submitted'}, {'custodyRequired': True}):
            child, server = Mock(pid=11), Mock(pid=12)
            child.poll.return_value = server.poll.return_value = None
            result = dict(receipt)
            with patch.object(debugger.c, 'stop_child', side_effect=AssertionError('discarded JIT custody')):
                self.assertFalse(debugger.finish_children(child, server, result))
            self.assertFalse(result['childrenReaped'])
            self.assertTrue(result['custodyRequired'])

    def test_closed_worker_receipt_allows_direct_child_reap(self):
        self.assertTrue(hasattr(debugger, 'finish_children'), 'missing guarded child cleanup')
        child, server = Mock(pid=11, returncode=0), Mock(pid=12, returncode=0)
        result = {'debuggerClosed': True}
        with patch.object(debugger.c, 'stop_child', return_value=0) as stop:
            self.assertTrue(debugger.finish_children(child, server, result))
        self.assertEqual(stop.call_count, 2)
        self.assertTrue(result['childrenReaped'])

    def test_clock_uses_same_guest_and_host_epoch(self):
        with patch.object(p.time, 'clock_gettime', return_value=123.0) as read, \
             patch.object(p.time, 'monotonic', side_effect=AssertionError('wrong clock epoch')):
            self.assertEqual(p.monotonic(), 123.0)
            read.assert_called_once_with(p.time.CLOCK_MONOTONIC)
        with patch.object(p.time, 'clock_gettime_ns', return_value=123000000000) as read:
            self.assertEqual(p.monotonic_ns(), 123000000000)
            read.assert_called_once_with(p.time.CLOCK_MONOTONIC)

    def test_exact_process_topology_and_budget(self):
        group = 10
        target = {'path': '/fixture/HierarchyFixture'}
        server = Path('/Applications/Xcode.app/Contents/SharedFrameworks/LLDB.framework/Versions/A/Resources/debugserver')
        build = Path('/private/tmp/fixture-build')
        python = str(Path(sys.executable).resolve())
        rows = [(10, 1, group, python, 'S'), (11, group, group, str(server), 'S'),
                (12, group, group, python, 'S'), (13, 1, 13, target['path'], 'S')]
        runner._process_budget(rows, group, target, build, server, {})
        invalid = [rows + [(14, group, group, python, 'S')],
                   rows + [(14, 12, group, '/bin/sh', 'S')],
                   rows + [(14, 1, 14, target['path'], 'S')],
                   rows + [(14, group, group, '/usr/bin/xcrun', 'S'), (15, group, group, '/bin/ps', 'S')]]
        for snapshot in invalid:
            with self.subTest(snapshot=snapshot), self.assertRaises(RuntimeError):
                runner._process_budget(snapshot, group, target, build, server, {})

    def test_observed_simctl_and_python_framework_executable_paths(self):
        group = 10
        python = str(Path(sys.executable).resolve())
        framework_python = str(Path(python).parent.parent / 'Resources/Python.app/Contents/MacOS/Python')
        core_simctl = '/Library/Developer/PrivateFrameworks/CoreSimulator.framework/Versions/A/Resources/bin/simctl'
        server = Path('/Applications/Xcode.app/Contents/SharedFrameworks/LLDB.framework/Versions/A/Resources/debugserver')
        rows = [(11, group, group, framework_python, 'S'), (12, group, group, core_simctl, 'R')]
        runner.process_budget(rows, group, None, Path('/fixture-build'), server, {})
        with self.assertRaisesRegex(RuntimeError, 'executable budget'):
            runner.process_budget(rows + [(13, group, group, python, 'S')], group, None, Path('/fixture-build'), server, {})

    def test_ps_transient_name_requires_kernel_identity(self):
        server = Path('/Applications/Xcode.app/Contents/SharedFrameworks/LLDB.framework/Versions/A/Resources/debugserver')
        for name in ('(ps)', 'ps'):
            row = (11, 10, 10, str(Path(name).resolve()), 'R')
            with self.subTest(name=name), patch.object(runner.s.watchdog, 'process_identity', return_value={'pid': 11, 'parent': 10, 'path': '/bin/ps', 'state': 2}):
                runner.process_budget([row], 10, None, Path('/fixture-build'), server, {})
            with patch.object(runner.s.watchdog, 'process_identity', return_value={'pid': 11, 'parent': 99, 'path': '/bin/ps', 'state': 2}):
                with self.assertRaises(RuntimeError):
                    runner.process_budget([row], 10, None, Path('/fixture-build'), server, {})

    def test_transient_executable_exit_or_zombie_needs_fresh_readback(self):
        server = Path('/Applications/Xcode.app/Contents/SharedFrameworks/LLDB.framework/Versions/A/Resources/debugserver')
        row = (11, 10, 10, str(Path('(debugserver)').resolve()), 'S')
        with patch.object(runner.s.watchdog, 'process_identity', side_effect=RuntimeError('cannot read owned PID status 11')), \
             patch.object(runner.s.watchdog, 'gone_or_zombie', return_value=True) as confirm, \
             patch.object(os, 'kill', side_effect=AssertionError('observer does not signal')), \
             patch.object(os, 'waitpid', side_effect=AssertionError('observer does not reap')):
            details = {}
            runner.process_budget([row], 10, None, Path('/fixture-build'), server, details)
        confirm.assert_called_once_with(11)
        self.assertEqual(details['lastResidentProcessSample'], [])
        self.assertEqual(details['residentExecutableObservations'][0]['status'], 'goneOrZombie')

    def test_transient_unknown_or_reused_pid_is_not_discarded(self):
        server = Path('/Applications/Xcode.app/Contents/SharedFrameworks/LLDB.framework/Versions/A/Resources/debugserver')
        row = (11, 10, 10, str(Path('(debugserver)').resolve()), 'Z')
        for failure in (RuntimeError('unavailable'), runner.s.watchdog.IdentityChanged('reused')):
            with self.subTest(failure=type(failure).__name__), \
                 patch.object(runner.s.watchdog, 'process_identity', side_effect=failure), \
                 patch.object(runner.s.watchdog, 'gone_or_zombie', return_value=False), \
                 patch.object(os, 'kill', side_effect=AssertionError('observer does not signal')), \
                 patch.object(os, 'waitpid', side_effect=AssertionError('observer does not reap')):
                with self.assertRaises(RuntimeError):
                    runner.process_budget([row], 10, None, Path('/fixture-build'), server, {})

    def test_worker_unknown_suffix_cannot_acquire_runtime(self):
        with patch.object(sys, 'argv', ['runner.py', '--worker', '/build', '/out', 'device', 'token', '1', '2', '--case', 'C', '--prepared', '/p']), \
             patch.object(runner.s, 'worker', side_effect=AssertionError('runtime entry')):
            self.assertEqual(runner.main(), 64)

    def test_inherited_worker_guard_cannot_pass_parent_identity(self):
        with patch.dict(os.environ, {'MAC_CU_FIXTURE_WORKER': 'unexpected'}), \
             patch.object(runner.s, 'save', side_effect=AssertionError('guard wrote result')):
            with self.assertRaisesRegex(RuntimeError, 'exact parent/token'):
                runner.s.guard_worker(Path('/unowned'), runner.s.monotonic() + 480, 'ours', os.getppid())

    def test_existing_fixture_signature_is_read_only_and_fail_closed(self):
        signed = plistlib.dumps({'com.apple.security.get-task-allow': True})
        def run(args, **kwargs):
            self.assertNotIn('--sign', args)
            return subprocess.CompletedProcess(args, 0, signed, b'')
        with patch.object(debugger.c, 'validation_policy'), patch.object(debugger.subprocess, 'run', side_effect=run):
            result = debugger.admit_fixture({'path': '/fixture/HierarchyFixture.app/HierarchyFixture'})
            self.assertFalse(result['targetResigned'])
        with patch.object(debugger.c, 'validation_policy'), \
             patch.object(debugger.subprocess, 'run', return_value=subprocess.CompletedProcess([], 0, plistlib.dumps({}), b'')):
            with self.assertRaisesRegex(RuntimeError, 'original signed Simulator debug entitlement'):
                debugger.admit_fixture({'path': '/fixture/HierarchyFixture.app/HierarchyFixture'})

    def test_runtime_requires_final_probe_and_general_gate_stays_disabled(self):
        self.assertFalse(debugger.c.GENERAL_APP_CAPTURE_QUALIFIED)
        with patch.object(runner, 'verify_preparation', return_value={}), \
             patch.object(runner.s, 'parent', side_effect=AssertionError('runtime parent constructed')), \
             patch.object(sys, 'argv', ['runner.py', '--prepared', '/p', '--output', '/o', '--device',
                 '11111111-1111-4111-8111-111111111111', '--deadline', '2099-01-01T00:00:00Z', '--case', 'A']):
            with self.assertRaisesRegex(RuntimeError, 'final canonical whole-host native freeze'):
                runner.main()


if __name__ == '__main__':
    unittest.main()
