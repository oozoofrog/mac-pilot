"""Canonical request/ledger tests through the legacy fake transport; no resident-runtime proof."""
import copy
import datetime
import json
import os
from pathlib import Path
import plistlib
import subprocess
import sys
import tempfile
import time
from types import SimpleNamespace
import unittest
from unittest.mock import patch

sys.dont_write_bytecode = True
HERE = Path(__file__).resolve().parent
sys.path[:0] = [str(HERE), str(HERE.parent)]
import session
import edit_qualification as q
from test_view_capture import capture, Probe, Engine
from test_view_edit_backend import capture_payload


class FakeRuntime:
    """Real schema/ledger and legacy supervisor with a fake engine; no Simulator/GUI."""
    def __init__(self, folder):
        folder = folder.resolve()
        self.folder = folder
        app = folder / 'HierarchyFixture.app'; app.mkdir()
        (app / 'Info.plist').write_bytes(plistlib.dumps({'CFBundleIdentifier': capture.FIXTURE_BUNDLE,
            'CFBundleExecutable': 'HierarchyFixture'}))
        self.target = {'pid': 42, 'start': [100, 123], 'path': str(app / 'HierarchyFixture'), 'deviceID': q.uid()}
        self.probe = Probe(self.target)
        self.requests, self.results, self.observations, self.events = [], [], [], []
        self.values, self.counts = {'hidden': False, 'alpha': 1.0}, {'hidden': 0, 'alpha': 0}
        self.last_counts = dict(self.counts)
        self.mode, self.fail_label = 'success', None
        self.offset = 0
        self.expire_after_capture = False

    def now(self):
        return session.monotonic() + self.offset

    def operation(self, request, label):
        capture.request_contract(request)
        self.requests.append(copy.deepcopy(request))
        folder = self.folder / ('operation-%02d' % len(self.requests)); folder.mkdir(mode=0o700)
        runtime = self
        mode = self.mode if label == self.fail_label else 'success'
        class OperationEngine(Engine):
            def edit_operation(engine, answer):
                wire = capture.read_json(folder / 'worker.json')['editWire']
                runtime.events.append('dispatch')
                if mode == 'lost':
                    capture.fail('timeout', 'lost target result after entry')
                if wire['kind'] == 'capture':
                    result = capture_payload(wire)
                    result['editableNodes'][1]['className'] = q.TARGET_CLASS
                else:
                    result = {**capture.edit_backend.receipt(request, 'success', 'readbackMatched', 'appliedObserved'),
                        **{k: wire[k] for k in ('ownerID', 'inspectionID', 'targetEpoch', 'requestDigest', 'captureID')},
                        'setterEntered': True, 'phase': 'readback', 'needsRefresh': False}
                    if wire['kind'] == 'release':
                        result.update(mutationOutcome='notApplicable', setterEntered=False, authorityRevoked=True,
                            registryReleased=True, remainingOwnedEntries=0, residualState='tombstone', needsRefresh=True,
                            releaseProof={k: wire[k] for k in ('ownerID', 'inspectionID', 'targetEpoch', 'captureID',
                                'operationID', 'requestDigest', 'sequence', 'entryTransitionID')})
                    else:
                        if wire['kind'] == 'edit':
                            prop, value, token = request['property'], request['value'], request['nodeToken']
                        else:
                            undo = wire['undoReceipt']; prop, value, token = undo['property'], undo['before'], undo['nodeToken']
                        before = runtime.values[prop]
                        runtime.values[prop] = value; runtime.counts[prop] += 1
                        result.update(nodeToken=token, property=prop, before=before, requested=value, observed=value)
                        if wire['kind'] == 'edit':
                            result.update(undoToken=q.uid(), undoReceipt={'nodeToken': token, 'property': prop,
                                'before': before, 'applied': value, 'revision': request['sequence'],
                                **{k: request[k] for k in ('expectedParentToken', 'expectedWindowToken', 'expectedClass')}})
                        if mode == 'cancel-after-readback':
                            (folder / 'cancel').touch()
                return result
        class Child:
            def __init__(self, pid): self.pid, self.returncode = pid, None
            def poll(self):
                if self.pid == 201 and self.returncode is None:
                    config = capture.read_json(folder / 'worker.json')
                    result = capture.run_engine(config, folder,
                        lambda control: OperationEngine(runtime.probe, control, runtime.events, mode), runtime.probe)
                    capture.write_json(folder / 'engine.json', result)
                    self.returncode = 0
                return self.returncode
            def wait(self, timeout): self.returncode = 0; return 0
            def terminate(self): runtime.events.append('terminate-child')
            def kill(self): runtime.events.append('kill-child')
        def spawn(argv, **kwargs):
            return Child(201 if '--worker' in argv else 200)
        with patch.object(capture, '_supervise', capture._supervise_debugger), \
             patch.object(capture, 'recovered', return_value={'verified': True, 'target': self.target}):
            result = capture.supervise(request, folder, self.probe, lambda: False, popen=spawn,
                discover=lambda: (Path('/owned/debugserver'), Path('/owned/python'), Path('/owned/sdk')),
                ledger_root=self.folder / 'ledger')
        self.results.append(result)
        return result

    def convert(self, result, label):
        raw = copy.deepcopy(result['editableNodes'])
        root, child = raw
        for node in raw:
            node['parentID'] = node.pop('parentToken'); node['children'] = []
        root['children'] = [child]; child['assetID'] = 'asset-1'
        return {'captureID': result['captureID'], 'processLifetime': self.target, 'roots': [root],
                'capabilities': {'textures': True}, 'assets': {'asset-1': {'captureID': result['captureID'],
                    'nodeID': child['editToken']}}}

    def observe(self, label, hidden, alpha, hidden_delta, alpha_delta):
        assert self.values == {'hidden': hidden, 'alpha': alpha}
        assert self.counts == {'hidden': self.last_counts['hidden'] + hidden_delta,
                               'alpha': self.last_counts['alpha'] + alpha_delta}
        self.last_counts = dict(self.counts)
        self.observations.append(label)
        if label == 'capture' and self.expire_after_capture:
            self.offset += 121


class SequenceChecks(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='mac-cu-edit-sequence-test-')
        self.addCleanup(self.temp.cleanup)
        self.runtime = FakeRuntime(Path(self.temp.name))

    def test_complete_real_backend_sequence_and_server_undo_rollover(self):
        q.Sequence(self.runtime).run()
        requests = self.runtime.requests
        self.assertEqual([r['kind'] for r in requests],
                         ['capture', 'edit', 'revert', 'edit', 'revert', 'release', 'capture', 'release', 'capture', 'release'])
        self.assertEqual([r['sequence'] for r in requests], [1, 2, 3, 4, 5, 6, 1, 2, 1, 2])
        self.assertEqual(len({r['operationID'] for r in requests}), 10)
        self.assertEqual(len({r['inspectionID'] for r in requests}), 3)
        self.assertEqual(requests[0]['ownerID'], requests[6]['ownerID'])
        self.assertNotEqual(requests[0]['ownerID'], requests[8]['ownerID'])
        self.assertEqual(len({self.runtime.results[i]['targetEpoch'] for i in (0, 6, 8)}), 3)
        for i in (2, 4):
            self.assertEqual(requests[i]['undoToken'], self.runtime.results[i - 1]['undoToken'])
            self.assertNotIn('value', requests[i])
        self.assertEqual(self.runtime.counts, {'hidden': 2, 'alpha': 2})
        self.assertEqual(self.runtime.events.count('dispatch'), 10)
        ledger = json.loads(next((self.runtime.folder / 'ledger').glob('*.json')).read_text())
        self.assertEqual(len(ledger['retired']), 2)
        self.assertEqual(ledger['authority'], 'released')

    def test_uncertainty_stops_without_release_undo_or_new_id_retry(self):
        self.runtime.mode, self.runtime.fail_label = 'lost', 'alpha'
        with self.assertRaisesRegex(RuntimeError, 'operation failed; no retry'):
            q.Sequence(self.runtime).run()
        self.assertEqual(len(self.runtime.requests), 4)
        self.assertEqual(self.runtime.results[-1]['mutationOutcome'], 'uncertain')
        self.assertEqual(self.runtime.observations, ['capture', 'hidden', 'hidden-undo'])

    def test_observed_mutation_survives_cancellation_and_sequence_stops(self):
        self.runtime.mode, self.runtime.fail_label = 'cancel-after-readback', 'hidden'
        with self.assertRaisesRegex(RuntimeError, 'operation failed; no retry'):
            q.Sequence(self.runtime).run()
        self.assertEqual(len(self.runtime.requests), 2)
        self.assertEqual(self.runtime.results[-1]['mutationOutcome'], 'appliedObserved')
        self.assertTrue(self.runtime.results[-1]['observed'])
        self.assertEqual(self.runtime.counts, {'hidden': 1, 'alpha': 0})

    def test_monotonic_expiry_cannot_auto_extend_or_recapture(self):
        self.runtime.expire_after_capture = True
        with self.assertRaisesRegex(RuntimeError, 'monotonic TTL expired'):
            q.Sequence(self.runtime).run()
        self.assertEqual(len(self.runtime.requests), 1)

    def test_selection_rejects_wrong_assets_or_ambiguous_named_target(self):
        seq = q.Sequence(self.runtime)
        seq.capture('capture')
        result = self.runtime.results[0]
        for damage in ('captureID', 'asset', 'duplicate', 'address'):
            snapshot = self.runtime.convert(result, 'capture')
            if damage == 'captureID': snapshot['captureID'] = q.uid()
            elif damage == 'asset': snapshot['assets']['asset-1']['nodeID'] = q.uid()
            elif damage == 'duplicate': snapshot['roots'][0]['children'] *= 2
            else: snapshot['roots'][0]['children'][0]['editToken'] = '0x123'
            with self.assertRaises((ValueError, RuntimeError)):
                q.selection(snapshot, result)

    def test_digest_binds_sequence_and_closed_schema_rejects_transport_knobs(self):
        seq = q.Sequence(self.runtime); seq.capture('capture')
        request, result = self.runtime.requests[0], self.runtime.results[0]
        with self.assertRaisesRegex(RuntimeError, 'digest mismatch'):
            q.clean_receipt(result, dict(request, sequence=2))
        for key in ('ledger_root', 'force', 'expression', 'address', 'mutationEnabled'):
            with self.assertRaises(capture.CaptureError):
                capture.request_contract(dict(request, **{key: True}))

    def test_alpha_integer_json_is_numeric_but_hidden_requires_boolean(self):
        self.assertTrue(q.value_matches(1, 1.0))
        self.assertTrue(q.value_matches(0.5, 0.5))
        self.assertFalse(q.value_matches(True, 1.0))
        self.assertFalse(q.value_matches(1, True))
        self.assertFalse(q.value_matches(float('nan'), 0.5))


class RunnerChecks(unittest.TestCase):
    def test_incompatible_python_refuses_before_device_claim_or_fixture_install(self):
        with tempfile.TemporaryDirectory() as name:
            root = Path(name).resolve(); (root / 'lldb').mkdir()
            (root / 'lldb/__init__.py').write_text('raise ImportError("incompatible LLDB extension")\n')
            with patch.object(session, 'verify_prepared'), patch.object(q, 'require_full_preparation'), \
                 patch.object(session.capture, 'tools_for_xcode', return_value=(root / 'debugserver', root, root / 'sdk')), \
                 patch.object(session, 'booted', side_effect=AssertionError('device touched before interpreter admission')):
                with self.assertRaisesRegex(RuntimeError, 'LLDB Python preflight'):
                    session.parent(root, root / 'out', q.uid(), session.monotonic() + q.TOTAL - 1, {},
                                   edit_qualification=True)
            self.assertFalse((root / 'out').exists())

    def test_pre_attach_failure_is_known_only_with_complete_no_dispatch_cleanup_proof(self):
        for damage in (None, 'attachRequested', 'connected', 'setterEntered', 'dispatch', 'answer',
                       'main-thread-entry', 'recovery', 'children', 'mutationOutcome', 'closeError'):
            with self.subTest(damage=damage), tempfile.TemporaryDirectory() as name:
                root = Path(name).resolve(); (root / 'operations').mkdir()
                r = q.Runtime.__new__(q.Runtime)
                r.s, r.out, r.deadline, r.now = session, root, session.monotonic() + 1000, session.monotonic
                r.target = {'pid': 42, 'start': [1, 2], 'path': '/fixture', 'deviceID': q.uid()}
                r.records, r.operation_index, r.child = [], 0, None
                r.foreground = lambda _: None; r.check = lambda: None; r.stopping = lambda: False
                r.pp = None
                request = dict(schemaVersion=2, kind='capture', target=r.target, validationOnly=True,
                    ownerID=q.uid(), inspectionID=q.uid(), operationID=q.uid(), sequence=1,
                    targetEpoch=None, replaceCaptureID=None)
                receipt = {'status': 'failed', 'phase': 'admission', 'reasonCode': 'notDispatched',
                    'mutationOutcome': 'notEntered', 'setterEntered': False, 'connected': False,
                    'attachRequested': False, 'message': 'LLDB import failed', 'target': r.target,
                    'operationID': request['operationID'], 'cleanup': {'childrenReaped': True,
                        'recovery': {'verified': True, 'target': r.target}, 'detach': 'not attempted', 'closeError': None}}
                if damage in ('attachRequested', 'connected', 'setterEntered'): receipt[damage] = True
                if damage == 'recovery': receipt['cleanup']['recovery']['verified'] = False
                if damage == 'children': receipt['cleanup']['childrenReaped'] = False
                if damage == 'mutationOutcome': receipt['mutationOutcome'] = 'uncertain'
                if damage == 'closeError': receipt['cleanup']['closeError'] = 'unknown'
                class Child:
                    pid = 123456
                    def poll(self): return 0
                    def wait(self, timeout): return 0
                def spawn(argv, **kwargs):
                    folder = Path(argv[4])
                    session.save(folder / 'result.json', receipt)
                    session.save(folder / 'owned-children.json', {'allReapedAndAbsent': True})
                    if damage in ('dispatch', 'answer', 'main-thread-entry'):
                        session.save(folder / (damage + '.json'), {})
                    return Child()
                with patch.object(session.capture, 'verify_target', return_value=r.target), \
                     patch.object(session.subprocess, 'Popen', side_effect=spawn), \
                     patch.object(session.watchdog, 'process_identity', return_value={'pid': Child.pid}), \
                     patch.object(session, 'finish_capture'):
                    with self.assertRaises(RuntimeError) as raised:
                        r.operation(request, 'pre-attach-failure')
                if damage is None:
                    self.assertNotIsInstance(raised.exception, session.ProbeCleanupUnknown)
                    self.assertIn('before attach; cleanup verified', str(raised.exception))
                else:
                    self.assertIsInstance(raised.exception, session.ProbeCleanupUnknown)
                self.assertEqual(r.records[0]['receipt'], receipt)

    def test_supervisor_evidence_failure_cannot_lose_child_handle_before_canonical_cleanup(self):
        import runpy
        entry = runpy.run_path(str(HERE / 'edit-supervisor.py'), run_name='edit_supervisor_test')['main']
        with tempfile.TemporaryDirectory() as name:
            root = Path(name).resolve(); folder = root / 'operations/op'; folder.mkdir(parents=True, mode=0o700)
            session.save(folder / 'request.json', {'test': 'transport boundary'})
            saved = session.save
            failed = [False]
            children = []
            def save(path, value):
                if path.name == 'owned-children.json' and not failed[0]:
                    failed[0] = True
                    raise OSError('injected evidence write failure')
                saved(path, value)
            class Child:
                def __init__(self): self.pid, self.returncode = 42000 + len(children), None; children.append(self)
                def poll(self): return self.returncode
                def wait(self, timeout): self.returncode = 0; return 0
            def supervise(request, out, probe, cancelled, popen, ledger_root):
                first = popen(['/owned/debugserver'])
                second = popen([sys.executable, '-I', 'canonical-worker'])
                first.wait(timeout=1); second.wait(timeout=1)
                return {'status': 'success', 'cleanup': {'childrenReaped': True}}
            with patch.object(sys, 'argv', ['edit-supervisor.py', '--owned-operation', str(folder), str(root / 'ledger')]), \
                 patch.dict(os.environ, MAC_CU_EDIT_PARENT=str(os.getppid()), MAC_CU_FIXTURE_WORKER='test'), \
                 patch.object(session, 'save', side_effect=save), \
                 patch.object(session.subprocess, 'Popen', side_effect=lambda *a, **k: Child()), \
                 patch.object(session.capture, 'supervise', side_effect=supervise), \
                 patch.object(session.capture, 'ProcessProbe', return_value=None), \
                 patch.object(session.watchdog, 'process_identity', return_value={'pid': 1, 'parent': os.getpid(), 'path': '/owned', 'start': [1, 0]}), \
                 patch.object(session.watchdog, 'process_status', side_effect=ProcessLookupError()), \
                 patch.object(session.os, 'kill', side_effect=ProcessLookupError()), \
                 patch.object(session.signal, 'signal'):
                self.assertEqual(entry(), 0)
            self.assertEqual([c.returncode for c in children], [0, 0])
            evidence = json.loads((folder / 'owned-children.json').read_text())
            self.assertFalse(evidence['allReapedAndAbsent'])
            self.assertIn('evidenceError', evidence['children'][0])

    def test_runtime_keeps_receipt_and_checks_cleanup_even_after_input_interrupt(self):
        for clean in (True, False):
            with self.subTest(clean=clean), tempfile.TemporaryDirectory() as name:
                root = Path(name).resolve(); (root / 'operations').mkdir()
                r = q.Runtime.__new__(q.Runtime)
                r.s, r.out, r.deadline, r.now = session, root, session.monotonic() + 1000, session.monotonic
                r.target = {'pid': 42, 'start': [1, 2], 'path': '/fixture', 'deviceID': q.uid()}
                r.records, r.operation_index, r.child = [], 0, None
                r.foreground = lambda _: None; r.check = lambda: None; r.stopping = lambda: False
                r.pp = None
                request = dict(schemaVersion=2, kind='capture', target=r.target, validationOnly=True,
                    ownerID=q.uid(), inspectionID=q.uid(), operationID=q.uid(), sequence=1,
                    targetEpoch=None, replaceCaptureID=None)
                receipt = {'status': 'cancelled', 'mutationOutcome': 'appliedObserved', 'observed': True,
                    'operationID': request['operationID'], 'cleanup': {'childrenReaped': clean,
                        'recovery': {'verified': True}, 'detach': 'success'}}
                class Child:
                    pid = 123456
                    def poll(self): return 0
                    def wait(self, timeout): return 0
                def spawn(argv, **kwargs):
                    folder = Path(argv[4])
                    session.save(folder / 'result.json', receipt)
                    session.save(folder / 'owned-children.json', {'allReapedAndAbsent': clean})
                    return Child()
                with patch.object(session.capture, 'verify_target', return_value=r.target), \
                     patch.object(session.subprocess, 'Popen', side_effect=spawn), \
                     patch.object(session.watchdog, 'process_identity', return_value={'pid': Child.pid}), \
                     patch.object(session, 'finish_capture', side_effect=InterruptedError('input observed')):
                    expected = InterruptedError if clean else session.ProbeCleanupUnknown
                    with self.assertRaises(expected):
                        r.operation(request, 'interrupt')
                record = json.loads((root / 'edit-sequence.json').read_text())['operations'][0]
                self.assertEqual(record['receipt'], receipt)
                self.assertIn('input observed', record['observerError'])
                self.assertEqual(len(r.records), 1)
                self.assertTrue((Path(record['folder']) / 'cancel').is_file())

    def test_converter_export_uses_canonical_data_field_and_token_asset_mapping(self):
        import base64
        with tempfile.TemporaryDirectory() as name:
            root = Path(name); folder = root / 'operation'; folder.mkdir()
            r = q.Runtime.__new__(q.Runtime)
            r.s, r.build, r.out, r.device = session, root, root, 'device'
            r.records = [{'folder': str(folder)}]; r.check = lambda: None
            token, capture_id = q.uid(), q.uid()
            result = {'captureID': capture_id, 'target': {'pid': 42}}
            image = b'canonical-converter-output'
            node = {'id': token, 'editToken': token, 'windowToken': q.uid(), 'className': q.TARGET_CLASS,
                    'assetID': 'asset', 'children': []}
            snapshot = {'captureID': capture_id, 'processLifetime': result['target'], 'roots': [node],
                'capabilities': {'textures': True}, 'assets': {'asset': {'captureID': capture_id,
                    'nodeID': token, 'data': base64.b64encode(image).decode(), 'descendantContent': 'unknown'}}}
            with patch.object(session, 'probe', return_value=snapshot):
                self.assertEqual(r.convert(result, 'capture'), snapshot)
            mapping = json.loads((folder / 'asset-map.json').read_text())
            self.assertEqual(mapping['selectedToken'], token)
            self.assertFalse(mapping['pixelsReviewed'] or mapping['LCD3DQualified'])
            self.assertEqual(Path(mapping['assets'][0]['path']).read_bytes(), image)

    def test_full_serial_budget_and_per_operation_cleanup_reservation(self):
        self.assertGreaterEqual(q.TOTAL, q.MINIMUM)
        self.assertEqual(q.MINIMUM, 180 + 10 * (25 + 163 + 72) + 117 + 5)
        self.assertGreater(q.WORK, 180 + 10 * (25 + 163 + 72))
        with patch.object(session, 'monotonic', return_value=100):
            budget = session.session_budget(100 + q.MINIMUM - 1, True)
            with self.assertRaises(TimeoutError):
                session.reserve(budget['captureAdmissionMonotonic'], 0, 'all ten operations')
            runtime = q.Runtime.__new__(q.Runtime)
            runtime.s, runtime.deadline = session, 100 + q.OPERATION + q.POST + q.SESSION_CLEANUP - 1
            runtime.foreground = lambda *_: self.fail('must not start a probe/operation')
            with self.assertRaises(TimeoutError):
                runtime.operation({}, 'denied')

    def test_desktop_focus_and_input_change_cancel_without_reactivation(self):
        focus = [42]
        inputs = [0]
        guard = q.DesktopGuard(session.InputGuard(read=lambda: tuple(inputs)), 42, lambda: focus[0])
        guard.check(); focus[0] = 43
        with self.assertRaises(InterruptedError): guard.check()
        focus[0] = 42; inputs[0] += 1
        with self.assertRaises(InterruptedError): guard.check()

    def test_process_budget_rejects_duplicate_workers_and_unknown_children(self):
        group = 50
        python = str(Path(sys.executable).resolve())
        base = [(50, 1, 50, python, 'S'), (60, 50, 50, python, 'S'),
                (61, 60, 50, python, 'S'), (62, 60, 50, '/debugserver', 'S')]
        q.check_process_budget(base, group, {'path': '/fixture'}, Path('/build'), Path('/debugserver'), {})
        for extra in ((63, 60, 50, python, 'S'), (63, 60, 50, '/unknown', 'S'), (63, 61, 50, '/unknown', 'S')):
            with self.assertRaises(RuntimeError):
                q.check_process_budget(base + [extra], group, {'path': '/fixture'}, Path('/build'), Path('/debugserver'), {})

    def test_real_edit_guard_route_finite_deadline_and_no_mutation(self):
        with tempfile.TemporaryDirectory() as name:
            root = Path(name); build = root / 'build'; build.mkdir()
            (build / 'prepared.json').write_text(json.dumps({'dispatchPassed': True, 'hashes': {},
                'wholeProbeVerified': True, 'editQualificationReady': True}))
            deadline = datetime.datetime.fromtimestamp(time.time() + q.TOTAL, datetime.timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')
            output = root / 'out'
            command = [sys.executable, '-B', str(HERE / 'session.py'), '--guard', '--edit-qualification',
                '--build', str(build), '--output', str(output), '--device', q.uid(), '--deadline', deadline]
            run = subprocess.run(command, capture_output=True, text=True, timeout=10)
            self.assertEqual(run.returncode, 0, run.stderr)
            parent = json.loads((output / 'parent.json').read_text())
            worker = json.loads((output / 'session.json').read_text())
            self.assertEqual(parent['deadlineMonotonic'], worker['deadlineMonotonic'])
            self.assertEqual(parent['totalDeadlineSeconds'], q.TOTAL)
            self.assertEqual(worker['mutationCount'], 0)
            self.assertTrue(parent['group']['groupEmpty'])
            self.assertTrue(parent['workerDeadlineTransmissionVerified'])

    def test_fixture_only_manifest_cannot_authorize_runtime(self):
        with tempfile.TemporaryDirectory() as name:
            build = Path(name)
            (build / 'prepared.json').write_text(json.dumps({'wholeProbeVerified': False, 'editQualificationReady': False}))
            with self.assertRaisesRegex(RuntimeError, 'fresh whole probe'):
                q.require_full_preparation(build)

    def test_supervisor_entry_is_closed_and_import_does_not_attach(self):
        for args in ([], ['--owned-operation', '/unowned', '/unowned/ledger'], ['--capture', 'expression']):
            run = subprocess.run([sys.executable, '-I', str(HERE / 'edit-supervisor.py'), *args],
                                 capture_output=True, timeout=5)
            self.assertEqual(run.returncode, 64)

    def test_generation_and_counter_oracle_fail_without_followup_operation(self):
        # Exercise the actual observation implementation with a narrowly injected
        # read-only foreground boundary and no screenshot-capable label.
        with tempfile.TemporaryDirectory() as name:
            root = Path(name)
            r = q.Runtime.__new__(q.Runtime)
            r.s, r.out, r.target, r.device = session, root, {'pid': 42}, 'device'
            r.oracle = root / 'edit-oracle.json'
            r.records = [{}]; r.operation_index = 1; r.last_operation_start = time.time() - 1
            r.now = session.monotonic; r.check = lambda: None; r.foreground = lambda _: None
            sample = {'sequence': 2, 'unixSeconds': time.time(), 'pid': 42, 'name': q.TARGET_NAME,
                      'className': q.TARGET_CLASS, 'sceneActivationState': 0, 'hidden': False, 'alpha': 1,
                      'setterCounts': {'hidden': 2, 'alpha': 2},
                      **{k: 'stable' for k in ('nodeGeneration', 'parentGeneration', 'windowGeneration', 'sceneGeneration', 'sceneID')}}
            r.last_sample = dict(sample, sequence=1)
            oracle = {'schemaVersion': 1, 'constructionBaseline': {'hidden': 0, 'alpha': 0}, 'samples': [sample]}
            r.oracle.write_text(json.dumps(oracle))
            r.observe('final-release', False, 1, 0, 0)
            for field, value in (('nodeGeneration', 'changed'), ('hidden', True), ('setterCounts', {'hidden': 3, 'alpha': 2})):
                modified = dict(sample, sequence=3, **{field: value})
                r.oracle.write_text(json.dumps(dict(oracle, samples=[modified])))
                with self.assertRaises(RuntimeError):
                    r.observe('final-release', False, 1, 0, 0)


if __name__ == '__main__':
    unittest.main()
