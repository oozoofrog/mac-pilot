"""고정 요청, 재전송 거절, 비공개 채널과 build-only 진입 거절을 확인한다."""
import json
import os
from pathlib import Path
import tempfile
import time
import unittest
import uuid
from unittest.mock import patch

import protocol as p
import runner
import graph


def request():
    uid = lambda: str(uuid.uuid4()).upper()
    return dict(experiment='swiftui-hierarchy-v1', operation='readSwiftUIGraphAndPixels',
        ownerID=uid(), operationID=uid(), sequence=1,
        target=dict(pid=123, start=[100, 1], path='/private/tmp/owned.app/SwiftUIProbe', deviceID=uid()),
        expiresUnixMS=int(time.time() * 1000) + 30000, nodeGeneration=uid(), hiddenCount=0,
        sceneID='fixed-scene', parentName='fixture.root', image='/private/tmp/owned/helper.dylib', imageUUID=uid())


class ProbeContractTests(unittest.TestCase):
    def test_recording_variant_requires_baseline_evidence(self):
        with self.assertRaisesRegex(RuntimeError, 'completed no-flag baseline'): runner.select_variant(True)
        runner.select_variant(False)

    def test_graph_error_and_empty_bytes_never_satisfy_root_array(self):
        for raw, status in ((None, 'nil'), (b'[]', 'emptyArray'), (b'{"error":"serializer failed"}', 'errorObject'),
                            (b'not json', 'malformed'), (b'[{"type":"Text"}]', 'malformed')):
            self.assertEqual(graph.classify(raw)['status'], status)
        result = graph.classify(b'[{"properties":[{"id":0,"attribute":{}}],"children":[]}]')
        self.assertEqual(result['status'], 'rootArray')
        self.assertEqual(result['nodes'][0]['index'], 0)

    def test_two_bounded_sequences_keep_distinct_digests(self):
        first = request(); raw, digest = p.encode(first)
        second = dict(first, sequence=2, operationID=str(uuid.uuid4()).upper())
        raw2, digest2 = p.encode(second)
        self.assertEqual(p.WIRE.unpack(raw)[5], 1)
        self.assertEqual(p.WIRE.unpack(raw2)[5], 2)
        self.assertNotEqual(digest, digest2)
        self.assertEqual(len(raw), 2554)

    def test_no_extra_selector_or_operation_or_unbounded_sequence(self):
        for patch in ({'selector': 'anything'}, {'operation': 'edit'}, {'sequence': 0}, {'sequence': 3},
                      {'image': '/private/tmp/../replacement.dylib'}, {'expiresUnixMS': int(time.time() * 1000) + 121000}):
            with self.subTest(patch=patch), self.assertRaises(RuntimeError): p.encode(dict(request(), **patch))

    def test_reservation_cannot_be_replayed_or_overwritten(self):
        with tempfile.TemporaryDirectory() as tmp:
            folder = Path(tmp).resolve(); os.chmod(folder, 0o700)
            value = request(); ledger = p.Admission(folder); ledger.reserve(value)
            before = (folder / 'request.bin').read_bytes()
            with self.assertRaises(FileExistsError): p.Admission(folder).reserve(value)
            self.assertEqual(before, (folder / 'request.bin').read_bytes())

    def test_symlink_channel_is_refused(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp).resolve(); target = root / 'target'; target.mkdir(mode=0o700)
            alias = root / 'alias'; alias.symlink_to(target, target_is_directory=True)
            with self.assertRaises(OSError): p.Admission(alias).reserve(request())

    def test_receipt_does_not_restore_cancelled_authority(self):
        with tempfile.TemporaryDirectory() as tmp:
            folder = Path(tmp).resolve(); os.chmod(folder, 0o700)
            value = request(); ledger = p.Admission(folder); ledger.reserve(value); ledger.cancel('test cancellation')
            receipt = dict(requestDigest=ledger.digest, operationID=value['operationID'], authorityRestored=False, admissionClosed=True)
            self.assertEqual(ledger.observe(receipt)['inspectionAuthority'], 'revoked')
            with self.assertRaises(RuntimeError): ledger.observe(dict(receipt, authorityRestored=True))

    def test_build_only_manifest_cannot_launch_a_session(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp).resolve()
            (root / 'prepared.json').write_text(json.dumps(dict(dispatchPassed=False, wholeProbeVerified=False,
                editQualificationReady=False, hashes={})))
            with self.assertRaisesRegex(RuntimeError, 'dispatch guards not proved'): runner.configure(root)


class ResidentIdentityBudgetTests(unittest.TestCase):
    """Exercise caller decisions, without launching a worker or trusting ps names."""
    server = '/Applications/Xcode.app/Contents/SharedFrameworks/LLDB.framework/Versions/A/Resources/debugserver'

    def check(self, identities, rows=None):
        details = {}
        rows = rows or [(23, 40, 40, '/nonexistent/(debugserver)', 'S')]
        with patch.object(runner.s.watchdog, 'rows', return_value=rows), \
             patch.object(runner.s.watchdog, 'identify_live_server', side_effect=identities), \
             patch.object(runner.s.watchdog.os, 'kill', side_effect=AssertionError('signal')), \
             patch.object(runner.s.watchdog.os, 'killpg', side_effect=AssertionError('group signal')):
            runner.process_budget(rows, 40, None, Path('/private/tmp/build'), self.server, details)
        return details

    def identity(self, **changes):
        return dict(dict(pid=23, parent=40, start=[100, 1], state=2, path=self.server), **changes)

    def test_short_ps_name_requires_fresh_identity(self):
        result = self.check([self.identity()])
        self.assertEqual(result['lastResidentProcessSample'][0][3], self.server)
        self.assertFalse(result['residentExecutableObservations'][0]['signalAuthority'])

    def test_unknown_live_identity_fails_closed(self):
        w = runner.s.watchdog
        now = [0.0]
        observation = w.ProcessObservation(lambda: now[0])
        def unknown(pid):
            now[0] += 1
            return w.UNVERIFIED
        with patch.object(w, 'identify_live_server', side_effect=unknown), patch.object(w, 'rows', return_value=[]):
            with self.assertRaises(w.ObservationExpired):
                runner.process_budget([(23, 40, 40, '/short', 'S')], 40, None,
                    Path('/private/tmp/build'), self.server, {}, observation=observation)
        self.assertEqual(now[0], 3)

    def test_fresh_exit_is_excluded_from_active_budget(self):
        result = self.check([None])
        self.assertEqual(result['lastResidentProcessSample'], [])
        self.assertEqual(next(e['status'] for e in result['residentExecutableObservations'] if 'status' in e), 'goneOrZombie')

    def test_reused_pid_is_not_downgraded_to_exit(self):
        with self.assertRaises(runner.s.watchdog.IdentityChanged):
            self.check([runner.s.watchdog.IdentityChanged('changed start')])

    def test_changed_parent_and_wrong_executable_fail_closed(self):
        for identity, message in [(self.identity(parent=99), 'parent changed'),
                                  (self.identity(path='/unowned/executable'), 'unknown process')]:
            with self.subTest(identity=identity), self.assertRaisesRegex(RuntimeError, message):
                self.check([identity])

    def test_two_fresh_servers_exceed_active_budget(self):
        rows = [(pid, 40, 40, '/nonexistent/(debugserver)', 'S') for pid in (23, 24)]
        with self.assertRaisesRegex(RuntimeError, 'resident executable budget exceeded'):
            self.check([self.identity(), self.identity(pid=24)], rows)


class IsolatedCustodyTests(unittest.TestCase):
    server = ResidentIdentityBudgetTests.server

    def observe(self, transform=lambda rows: rows, identity_change=None, callback=None, stop=None):
        w = runner.s.watchdog
        with tempfile.TemporaryDirectory() as directory:
            build = Path(directory).resolve()
            probe = build / 'session-probe'; probe.touch()
            rows = transform([(100, 40, 100, str(probe), 'S'), (101, 100, 100, '/bin/ps', 'S')])
            details = {}
            now = [0.0]
            def read(timeout):
                now[0] += .25
                return rows
            def identify(pid):
                row = next(r for r in rows if r[0] == pid)
                info = dict(pid=pid, parent=row[1], group=row[2], path=row[3], start=[10, pid], state=2)
                if identity_change:
                    return identity_change(w, info)
                w._observation.get().record(pid, 'controlled', 1, 0, info)
                return info
            self.details = details
            with patch.object(runner.s, 'monotonic', side_effect=lambda: now[0]), \
                 patch.object(w, 'rows', side_effect=read), \
                 patch.object(w, 'identify_live_server', side_effect=identify):
                guard = type('Guard', (), {'check': staticmethod(stop)})() if stop else None
                return runner.s.observe_processes(40, None, build, self.server, details, 1,
                    input_guard=guard, process_check=callback or runner.process_budget)

    def test_ordinary_fixture_contract_admits_isolated_probe(self):
        self.observe(callback=lambda *args: None)

    def test_reject_wrong_parent_path_group_nested_and_duplicate(self):
        cases = [lambda r: [(100, 77, 100, r[0][3], 'S'), r[1]],
                 lambda r: [(100, 40, 100, '/bin/ps', 'S'), r[1]],
                 lambda r: [r[0], (101, 100, 999, '/bin/ps', 'S')],
                 lambda r: r + [(102, 101, 100, '/bin/ps', 'S')],
                 lambda r: r + [(102, 40, 102, r[0][3], 'S')],
                 lambda r: r + [(102, 40, 40, '/usr/bin/plutil', 'S')]]
        for transform in cases:
            with self.subTest(transform=transform), self.assertRaises(RuntimeError):
                self.observe(transform)

    def test_unknown_isolated_parent_never_accepts(self):
        def unknown(w, info):
            return w.UNVERIFIED if info['pid'] == 100 else info
        with self.assertRaises(runner.s.watchdog.ObservationExpired):
            self.observe(identity_change=unknown)

    def test_live_isolated_utility_is_not_dropped_when_probe_exits(self):
        def parent_exits(w, info):
            info = dict(info, state=5 if info['pid'] == 100 else 2)
            w._observation.get().record(info['pid'], 'controlled-status', 1, 0, info)
            return None if info['pid'] == 100 else info
        # Read the live utility first, then observe the probe's termination.
        with self.assertRaisesRegex(runner.s.watchdog.IdentityChanged, 'unexpected separate process group'):
            self.observe(transform=lambda rows: [rows[0], (99, *rows[1][1:])],
                         identity_change=parent_exits)
        event = self.details['residentExecutableObservations'][-1]
        self.assertEqual(event['pid'], 99)
        self.assertEqual(event['context'], 'group admission')
        self.assertFalse(event['signalAuthority'])

    def test_known_probe_escaping_records_old_and_current_identity(self):
        def escape(w, info):
            obs = w._observation.get()
            obs.record(info['pid'], 'controlled-first', 1, 0, info)
            obs.record(info['pid'], 'controlled-second', 1, 0, dict(info, group=999))
        with self.assertRaises(runner.s.watchdog.IdentityChanged):
            self.observe(identity_change=escape)
        event = self.details['residentExecutableObservations'][-1]
        self.assertEqual(event['status'], 'observedMismatch')
        self.assertEqual(event['pid'], 100)
        self.assertEqual(event['previous']['group'], 100)
        self.assertEqual(event['current']['group'], 999)
        self.assertEqual(event['previous']['path'], event['current']['path'])
        self.assertFalse(event['signalAuthority'])

    def test_previously_seen_worker_group_probe_cannot_become_isolated(self):
        w = runner.s.watchdog
        with tempfile.TemporaryDirectory() as directory:
            build = Path(directory).resolve(); probe = build / 'session-probe'; probe.touch()
            snapshots = iter([[(100, 40, 40, str(probe), 'S')],
                              [(100, 40, 100, str(probe), 'S')]])
            details = {}
            with patch.object(runner.s, 'monotonic', return_value=0), \
                 patch.object(w, 'rows', side_effect=lambda timeout: next(snapshots)), \
                 patch.object(w, 'identify_live_server', return_value=w.UNVERIFIED):
                with self.assertRaisesRegex(w.IdentityChanged, 'parent/group changed'):
                    runner.s.observe_processes(40, None, build, self.server, details, 3,
                                               process_check=runner.process_budget)
            event = details['residentExecutableObservations'][-1]
            self.assertEqual((event['pid'], event['previous']['group'], event['current']['group']),
                             (100, 40, 100))
            self.assertEqual(event['context'], 'ps reconciliation')

    def test_cancel_before_observation_propagates(self):
        def cancel(): raise InterruptedError('controlled cancel')
        with self.assertRaises(InterruptedError): self.observe(stop=cancel)


class CompleteObservationTests(unittest.TestCase):
    server = ResidentIdentityBudgetTests.server
    row = (23, 40, 40, '/short', 'S')

    def check_probe_utility(self, short_probe, utility_pid, isolated=False):
        w = runner.s.watchdog
        with tempfile.TemporaryDirectory() as directory:
            build = Path(directory).resolve()
            probe = build / 'session-probe'; probe.touch()
            pgid = 100 if isolated else 40
            rows = [(100, 40, pgid, '/nonexistent/(session-probe)' if short_probe else str(probe), 'S'),
                    (utility_pid, 100, pgid, '/usr/bin/xcrun', 'S')]
            def identity(pid):
                info = dict(pid=pid, parent=40 if pid == 100 else 100, group=pgid,
                            start=[1000, pid], state=2, path=str(probe) if pid == 100 else '/usr/bin/xcrun')
                # Preserve the kernel boundary's real partial-evidence side effect.
                w._observation.get().record(pid, 'controlled-kernel', 1, 0, info)
                return info
            details = {}
            with patch.object(runner.s, 'monotonic', return_value=0), \
                 patch.object(w, 'rows', return_value=rows), \
                 patch.object(w, 'identify_live_server', side_effect=identity), \
                 patch.object(w, 'process_identity', side_effect=identity), \
                 patch.object(w, 'process_arguments', return_value=['/usr/bin/xcrun', 'simctl', 'list', 'devices', 'booted', '-j']):
                try:
                    actual = runner.s.observe_processes(40, None, build, self.server, details, 3,
                                                        process_check=runner.process_budget)
                except RuntimeError as error:
                    self.fail('valid probe-owned utility rejected: ' + str(error))
            self.assertEqual({r[0]: r[1:4] for r in actual},
                             {100: (40, pgid, str(probe)), utility_pid: (100, pgid, '/usr/bin/xcrun')})

    def test_declared_isolated_probe_and_direct_utility(self):
        self.check_probe_utility(short_probe=False, utility_pid=101, isolated=True)

    def test_isolated_short_probe_with_lower_utility_pid(self):
        self.check_probe_utility(short_probe=True, utility_pid=99, isolated=True)

    def test_short_probe_parent_is_resolved_before_utility_topology_acceptance(self):
        self.check_probe_utility(short_probe=True, utility_pid=101)

    def test_utility_pid_before_probe_keeps_parent_context(self):
        self.check_probe_utility(short_probe=False, utility_pid=99)

    def observe_pending_probe(self, probe_states, utility_paths=('/usr/bin/xcrun',)):
        w = runner.s.watchdog
        now = [0.0]
        with tempfile.TemporaryDirectory() as directory:
            build = Path(directory).resolve()
            probe = build / 'session-probe'; probe.touch()
            rows = [(100, 40, 40, '/nonexistent/(session-probe)', 'S')]
            rows += [(101 + i, 100, 40, path, 'S') for i, path in enumerate(utility_paths)]
            def snapshot(timeout):
                now[0] += .25
                return rows
            def identity(pid):
                state = next(probe_states) if pid == 100 else 'utility'
                if state == 'unknown': return w.UNVERIFIED
                if state == 'gone': return None
                path = (str(probe) if state == 'probe' else self.server) if pid == 100 else utility_paths[pid - 101]
                info = dict(pid=pid, parent=40 if pid == 100 else 100, group=40,
                            start=[1000, pid], state=2, path=path)
                w._observation.get().record(pid, 'controlled-kernel', 1, 0, info)
                return info
            with patch.object(runner.s, 'monotonic', side_effect=lambda: now[0]), \
                 patch.object(w, 'rows', side_effect=snapshot), \
                 patch.object(w, 'identify_live_server', side_effect=identity):
                return runner.s.observe_processes(40, None, build, self.server, {}, 1,
                                                   process_check=runner.process_budget)

    def test_unknown_parent_requires_later_complete_probe_identity(self):
        actual = self.observe_pending_probe(iter(['unknown', 'probe']))
        self.assertEqual([(r[0], r[1]) for r in actual], [(100, 40), (101, 100)])
        self.assertFalse(runner.s.watchdog.parent_context_pending(100))

    def test_persistent_unknown_parent_never_passes(self):
        import itertools
        with self.assertRaises(runner.s.watchdog.ObservationExpired):
            self.observe_pending_probe(itertools.repeat('unknown'))
        self.assertFalse(runner.s.watchdog.parent_context_pending(100))

    def test_missing_or_wrong_parent_fails_final_topology(self):
        for state in ('gone', 'server'):
            with self.subTest(state=state), self.assertRaisesRegex(RuntimeError, 'unknown process'):
                self.observe_pending_probe(iter([state]))

    def test_pending_parent_does_not_hide_path_or_count_violation(self):
        for paths, error in [(('/unexpected',), 'unknown process'),
                             (('/usr/bin/xcrun', '/usr/bin/codesign'), 'serialized utility budget')]:
            with self.subTest(paths=paths), self.assertRaisesRegex(RuntimeError, error):
                self.observe_pending_probe(iter(['unknown']), paths)

    def run_observation(self, snapshots, identities, deadline=3, check=lambda: None, validate=None):
        w = runner.s.watchdog
        self.now = [0.0]
        self.events = []
        def read(timeout):
            self.timeouts.append(timeout)
            self.now[0] += .25
            return next(snapshots)
        observation = w.ProcessObservation(lambda: self.now[0], deadline, check, self.events)
        self.timeouts = []
        with patch.object(w, 'rows', side_effect=read), patch.object(w, 'identify_live_server', side_effect=identities), \
             patch.object(w.os, 'kill', side_effect=AssertionError('signal')), \
             patch.object(w.os, 'waitpid', side_effect=AssertionError('reap')):
            if validate:
                return observation.complete(40, validate)
            return runner.process_budget(None, 40, None, Path('/private/tmp/build'), self.server, {}, observation)

    def test_unknown_then_reaped_actual_caller_and_disappearance(self):
        w = runner.s.watchdog
        self.run_observation(iter([[self.row], []]), [w.UNVERIFIED, None])
        self.assertEqual(self.timeouts, [3, 2.75])
        self.assertTrue(all(e['signalAuthority'] is False for e in self.events))

    def test_disappearance_never_clears_unknown(self):
        w = runner.s.watchdog
        import itertools
        with self.assertRaises(w.ObservationExpired):
            self.run_observation(iter([[self.row], [], [], []]), itertools.repeat(w.UNVERIFIED), deadline=1)
        self.assertEqual(self.timeouts, [1, .75, .5, .25])

    def test_new_descendant_and_duplicate_cannot_be_retried_away(self):
        w = runner.s.watchdog
        def identity(pid):
            return dict(pid=pid, parent=40, group=40, start=[pid, 1], path=self.server, state=2)
        for extra in [(24, 40, 40, '/short', 'S'), (24, 40, 99, '/short', 'S')]:
            with self.subTest(extra=extra), self.assertRaises(RuntimeError):
                self.run_observation(iter([[self.row], [self.row, extra]]),
                    [w.UNVERIFIED, identity(23), identity(24)])

    def test_partial_lifetime_path_parent_and_group_changes_reject(self):
        w = runner.s.watchdog
        for key, value in [('start', [2, 1]), ('parent', 99), ('group', 99), ('path', '/changed')]:
            now = [0.0]
            obs = w.ProcessObservation(lambda: now[0])
            base = dict(pid=23, parent=40, group=40, start=[1, 1], path=self.server)
            calls = []
            def read(pid):
                calls.append(pid)
                obs.record(pid, 'controlled-partial', 1, 0, base if len(calls) == 1 else dict(base, **{key: value}))
                return w.UNVERIFIED
            with self.subTest(key=key), patch.object(w, 'rows', return_value=[self.row]), \
                 patch.object(w, 'identify_live_server', side_effect=read), self.assertRaises(w.IdentityChanged):
                obs.complete(40, lambda rows: None)
            self.assertEqual(len(calls), 2)

    def test_unexpected_successful_partial_path_cannot_be_hidden_by_exit(self):
        w = runner.s.watchdog
        obs = w.ProcessObservation(lambda: 0)
        def read(pid):
            obs.record(pid, 'proc_pidpath', 12, 0, dict(pid=pid, parent=40,
                group=40, start=[1, 1], path='/unexpected'))
            return None
        with patch.object(w, 'rows', return_value=[self.row]), \
             patch.object(w, 'identify_live_server', side_effect=read), self.assertRaisesRegex(RuntimeError, 'unknown process'):
            runner.process_budget(None, 40, None, Path('/private/tmp/build'), self.server, {}, obs)

    def test_cutoff_crossing_ps_identity_and_final_acceptance(self):
        w = runner.s.watchdog
        for stage in ('ps', 'identity', 'acceptance'):
            now = [0.0]
            obs = w.ProcessObservation(lambda: now[0], 1)
            def rows(timeout):
                if stage == 'ps': now[0] = 1
                return [self.row]
            def identity(pid):
                if stage == 'identity': now[0] = 1
                return None
            def validate(rows):
                if stage == 'acceptance': now[0] = 1
            with self.subTest(stage=stage), patch.object(w, 'rows', side_effect=rows), \
                 patch.object(w, 'identify_live_server', side_effect=identity), self.assertRaises(w.ObservationExpired):
                obs.complete(40, validate)

    def test_input_and_parent_interrupt_during_reconciliation_propagate(self):
        w = runner.s.watchdog
        for error in (InterruptedError('input'), runner.s.native.NativeCheckInterrupted('signal')):
            calls = []
            def check():
                if calls: raise error
            def identity(pid):
                calls.append(pid)
                return w.UNVERIFIED
            with self.subTest(error=error), self.assertRaises(type(error)):
                self.run_observation(iter([[self.row]]), identity, check=check)


if __name__ == '__main__': unittest.main()
