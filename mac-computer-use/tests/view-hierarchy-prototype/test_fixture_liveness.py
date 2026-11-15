"""Headless liveness and ownership checks; starts no target or debugger."""
import signal
import errno
import unittest
from unittest.mock import patch
import remote_run

BASE = {'pid': 91, 'start': '3:4', 'parent': 10, 'path': '/fixture', 'state': 2, 'traced': 0}

class PoisonedPopen:
    pid = 91
    returncode = 0  # ECHILD can leave this value even while the traced process exists.
    def poll(self):
        raise AssertionError('fixture liveness must not use Popen.poll')

class FixtureLiveness(unittest.TestCase):
    def test_traced_fixture_is_alive_and_not_signalled(self):
        traced = dict(BASE, parent=20, state=4, traced=1)
        with patch.object(remote_run, 'identity', return_value=traced), patch.object(remote_run.os, 'kill') as kill:
            self.assertEqual(remote_run.observe_fixture('/fixture', 91, BASE), traced)
            with self.assertRaises(RuntimeError):
                remote_run.cleanup_fixture('/fixture', PoisonedPopen(), BASE)
            kill.assert_not_called()

    def test_owned_resumed_fixture_is_signalled_and_os_exit_checked(self):
        states = [{'start': [3, 4], 'state': 2}, {'start': [3, 4], 'state': 5}]
        with patch.object(remote_run, 'identity', return_value=BASE), \
             patch.object(remote_run, 'process_status', side_effect=states), \
             patch.object(remote_run.os, 'waitpid', side_effect=[(0, 0), (0, 0), (91, signal.SIGTERM)]), \
             patch.object(remote_run.os, 'kill') as kill:
            result = remote_run.cleanup_fixture('/fixture', PoisonedPopen(), BASE)
            kill.assert_called_once_with(91, signal.SIGTERM)
            self.assertEqual(result['status'], 'exited')
            self.assertEqual(result['exitStatus'], 'verified waitpid status')
            self.assertEqual(result['observations'][-2]['kind'], 'same-start-zombie')

    def test_post_signal_waitpid_reaps_actual_signal_status(self):
        with patch.object(remote_run, 'identity', return_value=BASE), \
             patch.object(remote_run.os, 'waitpid', return_value=(91, signal.SIGTERM)), \
             patch.object(remote_run.os, 'kill') as kill:
            result = remote_run.cleanup_fixture('/fixture', PoisonedPopen(), BASE)
            kill.assert_called_once_with(91, signal.SIGTERM)
            self.assertEqual(result['terminalConfirmation']['terminal'], 'signaled')
            self.assertEqual(result['terminalConfirmation']['signal'], signal.SIGTERM)
            self.assertEqual(result['identityBeforeSignal'], BASE)
            self.assertTrue(result['signalResult']['returned'])

    def test_echild_and_unknown_are_not_exit_until_esrch(self):
        details = {}
        echild = ChildProcessError(errno.ECHILD, 'not child')
        with patch.object(remote_run, 'identity', return_value=BASE), \
             patch.object(remote_run, 'process_status', side_effect=RuntimeError('unavailable')), \
             patch.object(remote_run.os, 'waitpid', side_effect=echild), \
             patch.object(remote_run.os, 'kill', side_effect=[None, None, ProcessLookupError()]) as kill, \
             patch.object(remote_run.time, 'sleep'):
            result = remote_run.cleanup_fixture('/fixture', PoisonedPopen(), BASE, details=details)
            self.assertEqual(result['terminalConfirmation']['result'], 'ESRCH')
            self.assertEqual([x['kind'] for x in details['observations']], ['waitpid', 'status-unavailable', 'kill0'])
            self.assertEqual(kill.call_args_list[0].args, (91, signal.SIGTERM))
            self.assertEqual(len([c for c in kill.call_args_list if c.args[1] != 0]), 1)

    def test_stopped_wait_status_is_not_exit(self):
        stopped = (signal.SIGSTOP << 8) | 0x7f
        with patch.object(remote_run, 'identity', return_value=BASE), \
             patch.object(remote_run, 'process_status', return_value={'start': [3, 4], 'state': 4}), \
             patch.object(remote_run.os, 'waitpid', side_effect=[(91, stopped), (91, signal.SIGTERM)]), \
             patch.object(remote_run.os, 'kill') as kill, patch.object(remote_run.time, 'sleep'):
            result = remote_run.cleanup_fixture('/fixture', PoisonedPopen(), BASE)
            self.assertTrue(result['observations'][0]['stopped'])
            self.assertIsNone(result['observations'][0]['terminal'])
            self.assertEqual(result['terminalConfirmation']['terminal'], 'signaled')
            kill.assert_called_once_with(91, signal.SIGTERM)

    def test_post_signal_pid_reuse_fails_without_second_signal(self):
        details = {}
        with patch.object(remote_run, 'identity', return_value=BASE), \
             patch.object(remote_run, 'process_status', return_value={'start': [9, 9], 'state': 2}), \
             patch.object(remote_run.os, 'waitpid', return_value=(0, 0)), \
             patch.object(remote_run.os, 'kill') as kill:
            with self.assertRaises(RuntimeError):
                remote_run.cleanup_fixture('/fixture', PoisonedPopen(), BASE, details=details)
            kill.assert_called_once_with(91, signal.SIGTERM)
            self.assertEqual(details['identityBeforeSignal'], BASE)
            self.assertTrue(details['signalResult']['returned'])

    def test_post_signal_unknown_timeout_preserves_evidence_without_second_signal(self):
        details = {}
        with patch.object(remote_run, 'identity', return_value=BASE), \
             patch.object(remote_run, 'process_status', side_effect=RuntimeError('unavailable')), \
             patch.object(remote_run.os, 'waitpid', side_effect=ChildProcessError(errno.ECHILD, 'not child')), \
             patch.object(remote_run.os, 'kill', return_value=None) as kill, \
             patch.object(remote_run.time, 'monotonic', side_effect=[0, 1, 6]), \
             patch.object(remote_run.time, 'sleep'):
            with self.assertRaises(TimeoutError):
                remote_run.cleanup_fixture('/fixture', PoisonedPopen(), BASE, details=details)
            self.assertEqual(details['signalRequest']['signal'], 'SIGTERM')
            self.assertTrue(details['signalResult']['returned'])
            self.assertEqual(details['observations'][-1]['kind'], 'status-unavailable')
            self.assertEqual([c.args[1] for c in kill.call_args_list], [signal.SIGTERM, 0])

    def test_pre_signal_unknown_never_signals_fixture(self):
        with patch.object(remote_run, 'identity', side_effect=RuntimeError('unavailable')), \
             patch.object(remote_run, 'process_status', side_effect=RuntimeError('unavailable')), \
             patch.object(remote_run.os, 'kill', return_value=None) as kill:
            with self.assertRaises(RuntimeError):
                remote_run.cleanup_fixture('/fixture', PoisonedPopen(), BASE)
            self.assertEqual([c.args[1] for c in kill.call_args_list], [0])

    def test_reused_zombie_is_not_the_fixture(self):
        with patch.object(remote_run, 'process_status', return_value={'start': [9, 9], 'state': 5}):
            with self.assertRaises(RuntimeError):
                remote_run.fixture_terminal(91, BASE)

    def test_unknown_live_pid_is_not_treated_as_exited(self):
        with patch.object(remote_run, 'process_status', side_effect=RuntimeError('not readable')), \
             patch.object(remote_run.os, 'kill', return_value=None):
            with self.assertRaises(RuntimeError):
                remote_run.fixture_terminal(91, BASE)

    def test_traced_rejection_requires_unchanged_fixture_and_holder(self):
        traced = dict(BASE, parent=20, state=4, traced=1)
        result = {'outcome': 'preflight rejected', 'attachRequested': False, 'attached': False,
                  'before': traced, 'after': traced}
        remote_run.check_result('traced', result, traced, fixture_baseline=BASE, holder_server_pid=20)
        for bad in (dict(traced, parent=21), dict(traced, start='other'), dict(traced, traced=0)):
            with self.assertRaises(RuntimeError):
                remote_run.check_result('traced', result, bad, fixture_baseline=BASE, holder_server_pid=20)
        with self.assertRaises(RuntimeError):
            remote_run.check_result('traced', dict(result, attachRequested=True), traced,
                                    fixture_baseline=BASE, holder_server_pid=20)

    def test_holder_recovery_waits_for_running_without_signalling(self):
        observations = []
        with patch.object(remote_run, 'observe_fixture', side_effect=[dict(BASE, state=4), BASE]), \
             patch.object(remote_run.time, 'sleep'), patch.object(remote_run.os, 'kill') as kill:
            result = remote_run.wait_for_fixture_resume('/fixture', 91, BASE, observations)
        self.assertEqual(result['state'], 2)
        self.assertEqual([item['fixture']['state'] for item in observations], [4, 2])
        kill.assert_not_called()

    def test_holder_recovery_rejects_parent_change_and_unavailable(self):
        for result in (dict(BASE, parent=11), RuntimeError('unavailable')):
            observations = []
            with self.subTest(result=result), patch.object(remote_run, 'observe_fixture', side_effect=[result]), \
                 patch.object(remote_run.time, 'sleep') as sleep:
                with self.assertRaises(RuntimeError):
                    remote_run.wait_for_fixture_resume('/fixture', 91, BASE, observations)
                self.assertEqual(len(observations), 1)
                sleep.assert_not_called()

    def test_holder_recovery_does_not_accept_persistent_stop(self):
        observations = []
        with patch.object(remote_run, 'observe_fixture', return_value=dict(BASE, state=4)), \
             patch.object(remote_run.time, 'monotonic', side_effect=[0, 1, 6]), \
             patch.object(remote_run.time, 'sleep'):
            with self.assertRaises(TimeoutError):
                remote_run.wait_for_fixture_resume('/fixture', 91, BASE, observations)
        self.assertEqual(observations[0]['fixture']['state'], 4)

    def test_finalization_failure_overrides_preliminary_pass(self):
        evidence = {'case': 'checks passed; see limitations'}
        remote_run.finalize_case_evidence(evidence, 1)
        self.assertEqual(evidence['case'], 'failed')
        self.assertEqual(evidence['preFinalizationCase'], 'checks passed; see limitations')
        self.assertEqual(evidence['failureCount'], 1)

if __name__ == '__main__':
    unittest.main()
