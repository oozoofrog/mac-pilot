"""Pure watchdog checks; no subprocess, fixture, debugger, or desktop is launched."""
import signal
import ctypes
import errno
from types import SimpleNamespace
from unittest.mock import Mock
import subprocess
import unittest
from unittest.mock import patch
import remote_watchdog as watchdog
import remote_run

class WatchdogGuard(unittest.TestCase):
    def test_unidentified_live_server_is_conservatively_unverified(self):
        with patch.object(watchdog, 'process_identity', side_effect=RuntimeError('unavailable')), \
             patch.object(watchdog, 'gone_or_zombie', return_value=False):
            self.assertIs(watchdog.identify_live_server(23), watchdog.UNVERIFIED)
        with self.assertRaises(RuntimeError):
            watchdog.check_budgets(1, 2, 'success')  # Includes the unverified server.

    def test_known_identity_change_is_not_downgraded_to_unknown(self):
        with patch.object(watchdog, 'process_identity', side_effect=watchdog.IdentityChanged('reused')):
            with self.assertRaises(watchdog.IdentityChanged):
                watchdog.identify_live_server(23)

    def test_snapshot_separates_live_zombie_and_unknown(self):
        rows = [(1, 0, 40, '/worker', 'S'), (2, 40, 40, '/live', 'S'),
                (3, 1, 40, '/defunct', 'Z'), (4, 1, 40, '/unknown', '?'),
                (5, 1, 99, '/other', 'S')]
        live, zombies, unknown = watchdog.partition_group(rows, 1)
        self.assertEqual((live, zombies, unknown), ([], [], []))
        live, zombies, unknown = watchdog.partition_group(rows, 40)
        self.assertEqual([r[0] for r in live], [1, 2])
        self.assertEqual([r[0] for r in zombies], [3])
        self.assertEqual([r[0] for r in unknown], [4])

    def test_zombie_is_not_group_empty_and_never_live(self):
        snapshot = [(2, 1, 40, '/defunct', 'Z')]
        with patch.object(watchdog, 'rows', return_value=snapshot), \
             patch.object(watchdog.time, 'monotonic', side_effect=[0, 6]):
            result = watchdog.wait_group_readback(40, timeout=5)
        self.assertFalse(result['groupEmpty'])
        self.assertEqual(result['live'], [])
        self.assertEqual(result['zombies'][0][0], 2)
        self.assertEqual(result['unknown'], [])

    def test_unknown_group_member_is_live_for_cleanup_but_zombie_is_not(self):
        snapshot = [(23215, 1, 23205, '/defunct', 'Z'), (33, 1, 23205, '/unknown', '?')]
        with patch.object(watchdog, 'rows', return_value=snapshot):
            self.assertEqual([row[0] for row in watchdog.remaining_group_members(23205)], [33])
        with patch.object(watchdog, 'rows', return_value=snapshot[:1]):
            self.assertEqual(watchdog.remaining_group_members(23205), [])
            self.assertEqual(watchdog.partition_group(snapshot[:1], 23205)[1][0][0], 23215)

    def test_ps_snapshot_keeps_zombie_state_and_parent(self):
        data = ' 23215 1 23205 Z <defunct>\n 33 1 23205 ? /tmp/unknown\n'
        with patch.object(watchdog.subprocess, 'check_output', return_value=data):
            snapshot = watchdog.rows()
        self.assertEqual((snapshot[0][0], snapshot[0][1], snapshot[0][2], snapshot[0][4]), (23215, 1, 23205, 'Z'))
        live, zombies, unknown = watchdog.partition_group(snapshot, 23205)
        self.assertEqual((len(live), len(zombies), len(unknown)), (0, 1, 1))

    def test_worker_grace_records_request_and_timeout(self):
        class Worker:
            pid = 42
            returncode = None
            def poll(self): return None
            def terminate(self): self.terminated = True
            def wait(self, timeout): raise subprocess.TimeoutExpired('worker', timeout)
        worker, record = Worker(), {}
        watchdog.graceful_stop(worker, record)
        self.assertTrue(worker.terminated)
        self.assertEqual(record['request']['pid'], 42)
        self.assertTrue(record['signalResult']['returned'])
        self.assertEqual(record['status'], 'grace timeout')
        self.assertIn('result', record)

    def test_worker_grace_reaps_direct_worker_before_group_cleanup(self):
        class Worker:
            pid = 42
            returncode = None
            def poll(self): return None
            def terminate(self): self.terminated = True
            def wait(self, timeout): self.returncode = 1
        worker, record = Worker(), {}
        watchdog.graceful_stop(worker, record)
        self.assertTrue(worker.terminated)
        self.assertEqual(record['status'], 'exited after TERM')
        self.assertEqual(record['returncode'], 1)
        self.assertLessEqual(record['request']['monotonicNs'], record['result']['monotonicNs'])

    def test_worker_term_does_not_interrupt_its_own_finally(self):
        state = {'active': False}
        with self.assertRaises(KeyboardInterrupt):
            remote_run.interrupt_worker(state, signal.SIGTERM)
        self.assertIsNone(remote_run.interrupt_worker(state, signal.SIGINT))

    def test_reserved_time_covers_sequential_cleanup_and_parent_readback(self):
        # start_server unwind, holder, final recovery probe, four children,
        # final fixture probe/wait; plus scheduling and evidence margin.
        worker_max = 10 + 8 + (5 + 3) + 4 * (5 + 5) + (3 + 5)
        self.assertGreaterEqual(watchdog.WORKER_GRACE_SECONDS, worker_max + 10)
        self.assertGreaterEqual(watchdog.CLEANUP_BUDGET_SECONDS,
            watchdog.WORKER_GRACE_SECONDS + watchdog.WORKER_WAIT_SECONDS
            + watchdog.GROUP_READBACK_SECONDS + 2 * watchdog.PROCESS_READ_TIMEOUT_SECONDS)
        self.assertEqual(watchdog.DEADLINE_SECONDS, 480)

    def test_all_four_direct_children_get_both_waits_before_parent_grace(self):
        elapsed = [0]
        calls = []
        class Child:
            returncode = None
            def __init__(self, name): self.name = name
            def poll(self): return None
            def terminate(self): calls.append((self.name, 'TERM', elapsed[0]))
            def kill(self): calls.append((self.name, 'KILL', elapsed[0]))
            def wait(self, timeout):
                elapsed[0] += timeout
                if calls[-1][1] == 'TERM':
                    raise subprocess.TimeoutExpired(self.name, timeout)
                self.returncode = -signal.SIGKILL
        children = [(str(i), Child(str(i))) for i in range(4)]
        results = remote_run.cleanup_children(children, 'traced')
        self.assertEqual(elapsed[0], 40)
        self.assertLess(elapsed[0] + 10 + 8 + 8 + 8, watchdog.WORKER_GRACE_SECONDS)
        self.assertEqual([r['status'] for r in results.values()], ['forced'] * 4)
        self.assertEqual([(name, sig) for name, sig, _ in calls],
                         [(str(i), sig) for i in range(4) for sig in ('TERM', 'KILL')])


class DirectChildAuthority(unittest.TestCase):
    class Worker:
        pid = 42
        def __init__(self, returncode=None):
            self.returncode = returncode
            self.killed = False
        def poll(self): return self.returncode
        def kill(self): self.killed = True
        def wait(self, timeout):
            if self.returncode is None: self.returncode = -signal.SIGKILL
            return self.returncode

    def test_direct_unreaped_worker_handle_can_be_killed_and_waited(self):
        worker, record = self.Worker(), {}
        with patch.object(watchdog.os, 'killpg') as killpg, patch.object(watchdog.os, 'kill') as kill:
            watchdog.finish_direct_worker(worker, record)
        self.assertTrue(worker.killed)
        self.assertEqual(record['returncode'], -signal.SIGKILL)
        self.assertEqual(record['signalRequest']['pid'], 42)
        killpg.assert_not_called()
        kill.assert_not_called()

    def test_reaped_worker_and_reused_pgid_never_authorize_signals(self):
        worker, record = self.Worker(returncode=0), {}
        # These are unrelated processes that happen to reuse the old group number.
        snapshot = [(43, 1, 42, '/unrelated', 'S'), (44, 1, 42, '/unknown', '?')]
        with patch.object(watchdog, 'rows', return_value=snapshot), \
             patch.object(watchdog.os, 'killpg') as killpg, patch.object(watchdog.os, 'kill') as kill:
            watchdog.finish_direct_worker(worker, record)
            observed = watchdog.wait_group_readback(42, timeout=0)
        self.assertFalse(worker.killed)
        self.assertFalse(observed['groupEmpty'])
        self.assertIn('already reaped', record['signalSkipped'])
        killpg.assert_not_called()
        kill.assert_not_called()

    def test_registered_descendant_identity_still_is_not_a_direct_child_handle(self):
        original = {'start': [3, 4], 'path': '/debugserver'}
        actual = dict(original, pid=23, parent=1, state=2)
        with patch.object(watchdog, 'process_identity', return_value=actual), \
             patch.object(watchdog.os, 'killpg') as killpg, patch.object(watchdog.os, 'kill') as kill:
            result = watchdog.observe_server_residual(23, original)
        self.assertFalse(result['signalAuthority'])
        self.assertTrue(result['status'].startswith('live'))
        killpg.assert_not_called()
        kill.assert_not_called()

    def test_ancestor_only_and_reused_identity_never_authorize_signals(self):
        original = {'start': [3, 4], 'path': '/debugserver'}
        actual = {'pid': 23, 'parent': 42, 'start': [9, 9], 'state': 2, 'path': '/debugserver'}
        with patch.object(watchdog, 'process_identity', return_value=actual), \
             patch.object(watchdog.os, 'killpg') as killpg, patch.object(watchdog.os, 'kill') as kill:
            result = watchdog.observe_server_residual(23, original)
        self.assertIn('identity changed', result['status'])
        killpg.assert_not_called()
        kill.assert_not_called()

    def test_unknown_is_neither_gone_nor_signal_authority(self):
        with patch.object(watchdog, 'process_identity', side_effect=RuntimeError('unknown')), \
             patch.object(watchdog, 'process_status', side_effect=RuntimeError('unknown')), \
             patch.object(watchdog.os, 'killpg') as killpg, patch.object(watchdog.os, 'kill') as kill:
            result = watchdog.observe_server_residual(23, {'start': [3, 4], 'path': '/debugserver'})
        self.assertIn('unknown', result['status'])
        self.assertFalse(result['signalAuthority'])
        kill.assert_called_once_with(23, 0)  # Read-only existence probe, never a terminating signal.
        killpg.assert_not_called()

    def test_zombie_is_recorded_without_signal_or_reap(self):
        with patch.object(watchdog, 'process_identity', side_effect=RuntimeError('zombie path unavailable')), \
             patch.object(watchdog, 'process_status', return_value={'start': [3, 4], 'state': 5}), \
             patch.object(watchdog.os, 'kill') as kill, patch.object(watchdog.os, 'waitpid') as waitpid:
            result = watchdog.observe_server_residual(23, {'start': [3, 4], 'path': '/debugserver'})
        self.assertIn('zombie', result['status'])
        self.assertFalse(result['signalAuthority'])
        kill.assert_not_called()
        waitpid.assert_not_called()

    def test_source_has_no_group_kill_or_nonzero_os_kill(self):
        import ast
        from pathlib import Path
        module = ast.parse(Path(watchdog.__file__).read_text())
        for node in ast.walk(module):
            if not isinstance(node, ast.Call) or not isinstance(node.func, ast.Attribute): continue
            if isinstance(node.func.value, ast.Name) and node.func.value.id == 'os':
                self.assertNotEqual(node.func.attr, 'killpg')
                if node.func.attr == 'kill':
                    self.assertIsInstance(node.args[1], ast.Constant)
                    self.assertEqual(node.args[1].value, 0)
        self.assertGreater(watchdog.CLEANUP_BUDGET_SECONDS, watchdog.WORKER_GRACE_SECONDS)
        self.assertGreater(watchdog.DEADLINE_SECONDS - watchdog.CLEANUP_BUDGET_SECONDS, 0)


class KernelIdentityBoundaries(unittest.TestCase):
    def library(self, states, path_result=0, denied=False):
        states = iter(states)
        def info(pid, flavor, arg, ptr, size):
            if denied:
                ctypes.set_errno(errno.EPERM)
                return 0
            b = ptr._obj
            b.pid, b.ppid, b.start_sec, b.start_usec = pid, 40, 100, 1
            b.status = next(states)
            return size
        def path(pid, buffer, size):
            ctypes.set_errno(errno.ESRCH if path_result == 0 else 0)
            buffer.value = b'/bin/cat' if path_result else b''
            return path_result
        return SimpleNamespace(proc_pidinfo=Mock(side_effect=info), proc_pidpath=Mock(side_effect=path))

    def test_unavailable_path_and_fresh_live_status_stay_unknown(self):
        lib = self.library([2, 2])
        with patch.object(watchdog.ctypes, 'CDLL', return_value=lib):
            self.assertIs(watchdog.identify_live_server(23), watchdog.UNVERIFIED)
        self.assertEqual(lib.proc_pidinfo.call_count, 2)

    def test_unavailable_path_and_fresh_zombie_are_terminal(self):
        lib = self.library([2, 5])
        with patch.object(watchdog.ctypes, 'CDLL', return_value=lib), patch.object(watchdog.os, 'kill') as kill:
            self.assertIsNone(watchdog.identify_live_server(23))
        kill.assert_not_called()

    def test_denied_reads_do_not_mean_absent(self):
        for error, expected in [(PermissionError(errno.EPERM, 'denied'), watchdog.UNVERIFIED),
                                (ProcessLookupError(errno.ESRCH, 'absent'), None)]:
            with self.subTest(error=error), patch.object(watchdog.ctypes, 'CDLL', return_value=self.library([], denied=True)), \
                 patch.object(watchdog.os, 'kill', side_effect=error) as kill:
                self.assertIs(watchdog.identify_live_server(23), expected)
                kill.assert_called_once_with(23, 0)

    def test_libproc_esrch_with_successful_kill0_stays_unknown_until_reap(self):
        # Recorded CLI exit sequence: libproc cannot observe the unreaped PID,
        # but kill0 still succeeds. Neither read is a fresh zombie proof.
        def unavailable(*args):
            ctypes.set_errno(errno.ESRCH)
            return 0
        lib = SimpleNamespace(proc_pidinfo=Mock(side_effect=unavailable))
        with patch.object(watchdog.ctypes, 'CDLL', return_value=lib), \
             patch.object(watchdog.os, 'kill', return_value=None) as kill:
            self.assertIs(watchdog.identify_live_server(23), watchdog.UNVERIFIED)
            kill.assert_called_once_with(23, 0)

    def test_start_change_across_successful_path_read_is_rejected(self):
        lib = self.library([], path_result=8)
        states = [dict(pid=23, parent=40, state=2, start=start) for start in ([100, 1], [101, 1])]
        with patch.object(watchdog.ctypes, 'CDLL', return_value=lib), \
             patch.object(watchdog, 'process_status', side_effect=states):
            with self.assertRaises(watchdog.IdentityChanged): watchdog.identify_live_server(23)


class ReconciliationKernelTests(unittest.TestCase):
    def test_partial_syscalls_survive_path_failure_and_reuse(self):
        now = [0.0]
        calls = []
        def info(pid, flavor, arg, ptr, size):
            calls.append('info')
            ptr._obj.pid, ptr._obj.ppid, ptr._obj.pgid = pid, 40, 40
            ptr._obj.start_sec = 100 if len(calls) == 1 else 101
            ptr._obj.status = 2
            return size
        def path(*args):
            calls.append('path')
            ctypes.set_errno(errno.ESRCH)
            return 0
        lib = SimpleNamespace(proc_pidinfo=Mock(side_effect=info), proc_pidpath=Mock(side_effect=path))
        obs = watchdog.ProcessObservation(lambda: now[0])
        with patch.object(watchdog.ctypes, 'CDLL', return_value=lib), \
             patch.object(watchdog, 'rows', return_value=[(23, 40, 40, '/short', 'S')]), \
             self.assertRaises(watchdog.IdentityChanged):
            obs.complete(40, lambda rows: None)
        events = [e for e in obs.events if e.get('syscall', '').startswith('proc_')]
        self.assertEqual([e['syscall'] for e in events], ['proc_pidinfo', 'proc_pidpath', 'proc_pidinfo'])
        self.assertEqual(events[1]['errno'], errno.ESRCH)
        self.assertEqual(events[1]['identity']['start'], [100, 0])
        self.assertNotIn('path', events[1]['identity'])

    def test_persistent_denied_reads_and_failed_buffers_fail_closed(self):
        now = [0.0]
        def denied(pid, flavor, arg, ptr, size):
            now[0] += .25
            ptr._obj.pid, ptr._obj.status = pid, 5  # Failed buffer must never prove zombie.
            ctypes.set_errno(errno.EPERM)
            return 0
        obs = watchdog.ProcessObservation(lambda: now[0], 1)
        lib = SimpleNamespace(proc_pidinfo=Mock(side_effect=denied))
        with patch.object(watchdog.ctypes, 'CDLL', return_value=lib), \
             patch.object(watchdog, 'rows', return_value=[(23, 40, 40, '/short', 'S')]), \
             patch.object(watchdog.os, 'kill', side_effect=PermissionError(errno.EPERM, 'denied')) as kill, \
             self.assertRaises(watchdog.ObservationExpired):
            obs.complete(40, lambda rows: None)
        self.assertTrue(all(e['identity'] is None for e in obs.events if e.get('syscall') == 'proc_pidinfo'))
        self.assertTrue(all(c.args == (23, 0) for c in kill.call_args_list))


class ObservationTimingCharacterization(unittest.TestCase):
    """Known blockers, not acceptance tests for a reconciliation implementation."""

    def test_normalization_stops_at_cutoff_before_next_global_path(self):
        now = [0.0]
        resolved = []
        def resolve(path):
            resolved.append(path)
            now[0] = 3.0
            return path
        data = '1 0 99 S /first\n2 0 99 S /second\n'
        obs = watchdog.ProcessObservation(lambda: now[0])
        with patch.object(watchdog.subprocess, 'check_output', return_value=data), \
             patch.object(watchdog.os.path, 'realpath', side_effect=resolve):
            with self.assertRaises(watchdog.ObservationExpired):
                obs.complete(40, lambda rows: None)
        self.assertEqual(resolved, ['/first'])

    def test_normalization_checks_input_before_next_global_path(self):
        interrupted = [False]
        resolved = []
        def check():
            if interrupted[0]:
                raise InterruptedError('controlled input')
        def resolve(path):
            resolved.append(path)
            interrupted[0] = True
            return path
        data = '1 0 99 S /first\n2 0 99 S /second\n'
        obs = watchdog.ProcessObservation(lambda: 0.0, check=check)
        with patch.object(watchdog.subprocess, 'check_output', return_value=data), \
             patch.object(watchdog.os.path, 'realpath', side_effect=resolve):
            with self.assertRaises(InterruptedError):
                obs.complete(40, lambda rows: None)
        self.assertEqual(resolved, ['/first'])

    def test_ps_timeout_cleanup_wait_is_outside_timeout(self):
        elapsed = [0.0]
        waits = []
        class PS:
            args = ['/bin/ps']
            returncode = None
            def __enter__(self): return self
            def __exit__(self, *args): return False
            def communicate(self, input=None, timeout=None):
                elapsed[0] += timeout
                raise subprocess.TimeoutExpired(self.args, timeout)
            def kill(self): pass
            def wait(self, timeout=None):
                waits.append(timeout)
                elapsed[0] += .25  # Deterministic scheduler/reap delay, no actual sleep.
                self.returncode = -9
                return self.returncode
        # Exercise the real check_output/run implementation with only Popen faked.
        with patch.object(watchdog.subprocess, 'Popen', return_value=PS()):
            with self.assertRaises(subprocess.TimeoutExpired): watchdog.rows()
        self.assertEqual(waits, [None])
        self.assertEqual(elapsed[0], watchdog.PROCESS_READ_TIMEOUT_SECONDS + .25)

    def test_identity_has_no_hard_return_bound_and_retains_partial_failure(self):
        elapsed = [0.0]
        status = dict(pid=23, parent=40, start=[100, 1], state=2)
        def path(*args):
            elapsed[0] += watchdog.PROCESS_READ_TIMEOUT_SECONDS + .25
            ctypes.set_errno(errno.ESRCH)
            return 0
        lib = SimpleNamespace(proc_pidpath=Mock(side_effect=path))
        with patch.object(watchdog, 'process_status', return_value=status), \
             patch.object(watchdog.ctypes, 'CDLL', return_value=lib):
            with self.assertRaises(RuntimeError) as raised:
                watchdog.process_identity(23)
        self.assertGreater(elapsed[0], watchdog.PROCESS_READ_TIMEOUT_SECONDS)
        self.assertEqual(raised.exception.args, ('cannot identify owned PID 23',))
        self.assertEqual(raised.exception.identity, status)
        self.assertEqual(raised.exception.errno, errno.ESRCH)
        self.assertEqual(raised.exception.syscall, 'proc_pidpath')
        self.assertEqual(raised.exception.result, 0)

    def test_single_shot_unknown_then_reap_requires_a_new_observation(self):
        def unavailable(*args):
            ctypes.set_errno(errno.ESRCH)
            return 0
        lib = SimpleNamespace(proc_pidinfo=Mock(side_effect=unavailable))
        # Reap boundary is controlled through the next kill0 result. No children run.
        with patch.object(watchdog.ctypes, 'CDLL', return_value=lib), \
             patch.object(watchdog.os, 'kill', side_effect=[None, ProcessLookupError(errno.ESRCH, 'reaped')]) as kill, \
             patch.object(watchdog.os, 'killpg', side_effect=AssertionError('group signal')), \
             patch.object(watchdog.os, 'waitpid', side_effect=AssertionError('observer reaped child')):
            self.assertIs(watchdog.identify_live_server(23), watchdog.UNVERIFIED)
            self.assertIsNone(watchdog.identify_live_server(23))
        self.assertEqual(kill.call_args_list, [unittest.mock.call(23, 0)] * 2)


if __name__ == '__main__':
    unittest.main()
