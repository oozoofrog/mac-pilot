"""Actual production schema, ledger, supervisor, worker and safe-entry checks. No attach/GUI."""
import copy
import base64
import json
import os
from pathlib import Path
import stat
import tempfile
from types import SimpleNamespace
import unittest
import uuid
from unittest.mock import patch

from test_view_capture import capture, Probe, Engine
edit = capture.edit_backend


def uid():
    return str(uuid.uuid4()).upper()


def capture_payload(wire):
    root, node = uid(), uid()
    return {**edit.receipt(wire, 'success', 'captured', 'notApplicable'),
            **{k: wire[k] for k in ('ownerID', 'inspectionID', 'targetEpoch', 'requestDigest')},
            'captureID': wire['newCaptureID'], 'captureTime': '2026-11-09T00:00:00Z', 'needsRefresh': False,
            'editing': {**{k: wire[k] for k in ('ownerID', 'inspectionID', 'targetEpoch')},
                        'expiresAt': wire['expiresAt'], 'registryState': 'active'},
            'editableNodes': [
                {'id': root, 'editToken': root, 'className': 'UIWindow', 'parentToken': None, 'windowToken': root,
                 'hidden': False, 'alpha': 1, 'siblingIndex': 0},
                {'id': node, 'editToken': node, 'className': 'UIView', 'parentToken': root, 'windowToken': root,
                 'hidden': False, 'alpha': 1, 'siblingIndex': 0}]}


class EditTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='mac-cu-edit-test-')
        self.addCleanup(self.temporary.cleanup)
        self.folder = Path(self.temporary.name).resolve()
        app = self.folder / 'HierarchyFixture.app'; app.mkdir()
        import plistlib
        (app / 'Info.plist').write_bytes(plistlib.dumps({'CFBundleIdentifier': capture.FIXTURE_BUNDLE,
                                                      'CFBundleExecutable': 'HierarchyFixture'}))
        self.target = {'pid': 42, 'start': [100, 123], 'path': str(app / 'HierarchyFixture'), 'deviceID': uid()}
        self.probe = Probe(self.target)
        self.root = self.folder / 'ledger'
        self.events = []
        self.spawns = 0
        self.request = {'schemaVersion': 2, 'kind': 'capture', 'target': self.target, 'validationOnly': True,
                        'ownerID': uid(), 'inspectionID': uid(), 'targetEpoch': None, 'operationID': uid(),
                        'sequence': 1, 'replaceCaptureID': None}

    def call(self, request, mode='success'):
        folder = self.folder / uid(); folder.mkdir(mode=0o700)
        self.last_folder = folder
        owner = self
        class OperationEngine(Engine):
            def edit_operation(engine, answer):
                owner.events.append('dispatch')
                config = capture.read_json(folder / 'worker.json'); wire = config['editWire']
                _, durable = owner.state()
                owner.assertEqual(durable['operations'][request['operationID']]['wireDigest'], edit.digest(wire))
                if wire.get('transition'):
                    _, durable = owner.state()
                    owner.assertEqual(durable['transition'], wire['transition'])
                    owner.assertEqual(durable['operations'][request['operationID']]['state'], 'reserved')
                    owner.assertEqual(durable['retired'], wire['transition']['retired'] + [wire['transition']['predecessor']])
                    owner.assertEqual(durable['epoch'], wire['targetEpoch'])
                if mode == 'lost':
                    capture.fail('timeout', 'no target receipt')
                if mode == 'exception-trap':
                    capture.fail('expressionError', 'expression stopped at Objective-C exception throw')
                if wire['kind'] == 'capture':
                    payload = capture_payload(wire)
                else:
                    payload = {**edit.receipt(request, 'success', 'readbackMatched', 'appliedObserved'),
                               **{k: wire[k] for k in ('ownerID', 'inspectionID', 'targetEpoch', 'requestDigest')},
                               'setterEntered': True, 'phase': 'readback', 'needsRefresh': False,
                               'property': 'hidden', 'nodeToken': request.get('nodeToken'),
                               'before': False, 'requested': True, 'observed': True}
                    if wire['kind'] == 'release':
                        payload.update(mutationOutcome='notApplicable', setterEntered=False,
                                       before=None, requested=None, observed=None, authorityRevoked=True,
                                       registryReleased=True, remainingOwnedEntries=0, residualState='tombstone',
                                       releaseProof={k: wire[k] for k in ('ownerID', 'inspectionID', 'targetEpoch',
                                                                        'captureID', 'operationID', 'requestDigest', 'sequence', 'entryTransitionID')})
                    elif wire['kind'] == 'revert':
                        u = wire['undoReceipt']
                        payload.update(nodeToken=u['nodeToken'], property=u['property'], before=u['applied'],
                                       requested=u['before'], observed=u['before'])
                    elif mode == 'noChange':
                        payload.update(status='noChange', mutationOutcome='notEntered', setterEntered=False,
                                       observed=False, requested=False)
                    elif mode in ('weakNil', 'staleGraph', 'expectedValueChanged', 'undoConflict'):
                        payload.update(status='conflict', mutationOutcome='notEntered', setterEntered=False,
                                       reasonCode=mode, needsRefresh=True, observed=False)
                    elif mode in ('throwAfter', 'mismatch'):
                        payload.update(status='outcomeUncertain', mutationOutcome='uncertain', reasonCode=mode,
                                       needsRefresh=True, observed=None if mode == 'throwAfter' else False)
                    elif wire['kind'] == 'edit':
                        payload.update(undoToken=uid(), undoReceipt={'nodeToken': request['nodeToken'], 'property': 'hidden',
                            'before': False, 'applied': True, 'revision': request['sequence'],
                            'expectedParentToken': request['expectedParentToken'], 'expectedWindowToken': request['expectedWindowToken'],
                            'expectedClass': request['expectedClass']})
                if mode == 'bad-release-proof':
                    payload['releaseProof']['operationID'] = uid()
                if mode == 'release-false':
                    payload['registryReleased'] = False
                if mode == 'release-count':
                    payload['remainingOwnedEntries'] = True
                if mode == 'bad-readback-proof':
                    payload['observed'] = False
                if mode == 'bad-identity':
                    payload['targetEpoch'] = uid()
                if mode == 'bad-capture':
                    payload['editableNodes'][1]['parentToken'] = payload['editableNodes'][1]['editToken']
                if mode == 'cancel-after-readback':
                    (folder / 'cancel').touch()
                return payload
        class Child:
            def __init__(child, pid): child.pid, child.returncode = pid, None
            def poll(child):
                if child.pid == 201 and child.returncode is None:
                    if mode != 'lost-worker':
                        config = capture.read_json(folder / 'worker.json')
                        result = capture.run_engine(config, folder,
                            lambda control: OperationEngine(owner.probe, control, owner.events, mode), owner.probe)
                        capture.write_json(folder / 'engine.json', result)
                    child.returncode = 0
                return child.returncode
            def wait(child, timeout): child.returncode = 0; return 0
            def terminate(child): owner.events.append('terminate-child')
            def kill(child): owner.events.append('kill-child')
        def spawn(argv, **kwargs):
            operation = self.state()[1]['operations'][request['operationID']]
            self.assertEqual(operation['state'], 'reserved')
            self.assertEqual(len(operation['wireDigest']), 64)
            self.spawns += 1
            return Child(201 if '--worker' in argv else 200)
        with patch.object(capture, '_supervise', capture._supervise_debugger), patch.object(capture, 'recovered', return_value={'verified': True}):
            return capture.supervise(copy.deepcopy(request), folder, self.probe, lambda: False, popen=spawn,
                                     discover=lambda: (Path('/owned/debugserver'), Path('/owned/python'), Path('/owned/sdk')),
                                     ledger_root=self.root)

    def bootstrap(self):
        cap = self.call(self.request)
        self.assertEqual(cap['status'], 'success', cap)
        self.assertTrue(cap['cleanup']['childrenReaped'])
        node = cap['editableNodes'][1]
        self.edit = {k: self.request[k] for k in ('schemaVersion', 'target', 'validationOnly', 'ownerID', 'inspectionID')}
        self.edit.update(kind='edit', operationID=uid(), targetEpoch=cap['targetEpoch'], captureID=cap['captureID'],
            sequence=2, nodeToken=node['editToken'], expectedParentToken=node['parentToken'],
            expectedWindowToken=node['windowToken'], expectedClass=node['className'],
            property='hidden', expectedValue=False, value=True)
        return cap

    def state(self):
        path = next(self.root.glob('*.json'))
        return path, json.loads(path.read_text())

    def test_failed_wire_persistence_prevents_transport_children(self):
        with patch.object(edit.Ledger, 'bind_wire', side_effect=OSError('wire persistence failed')):
            result = self.call(self.request)
        self.assertTrue(result['neverDispatched'])
        self.assertEqual(result['mutationOutcome'], 'notEntered')
        self.assertEqual(self.spawns, 0)

    def test_final_wire_binding_is_one_shot(self):
        ledger = edit.Ledger(self.request, self.root)
        try:
            self.assertIsNone(ledger.reserve())
            wire = ledger.wire(uid())
            wire['textureRequestBase64'] = 'fixed internal request'
            ledger.bind_wire(wire)
            self.assertEqual(self.state()[1]['operations'][self.request['operationID']]['wireDigest'], edit.digest(wire))
            with self.assertRaisesRegex(edit.BackendError, 'fresh reservation'):
                ledger.bind_wire(dict(wire, newCaptureID=uid()))
        finally:
            ledger.close()

    def test_closed_schema_types_values_and_unknown_fields_zero_dispatch(self):
        cap = self.bootstrap()
        variants = []
        for key, value in [('schemaVersion', True), ('sequence', True), ('sequence', 0), ('sequence', 4097),
                           ('validationOnly', 1), ('operationID', '0x123'),
                           ('expectedParentToken', 1), ('expectedWindowToken', None), ('expectedClass', ''),
                           ('value', 1), ('expectedValue', 0), ('property', 'frame')]:
            value_request = copy.deepcopy(self.edit); value_request[key] = value; variants.append(value_request)
        for key in ('expression', 'selector', 'keyPath', 'address', 'answerPath', 'qualified', 'leaseID', 'requestDigest',
                    'transition', 'releaseProof', 'retired', 'lifecycleVersion'):
            r = copy.deepcopy(self.edit); r[key] = 'arbitrary'; variants.append(r)
        for v in (True, False, -0.01, 1.01, float('nan'), float('inf'), '0.5', None):
            r = copy.deepcopy(self.edit); r.update(property='alpha', expectedValue=1.0, value=v); variants.append(r)
        r = copy.deepcopy(self.edit); r['target']['address'] = 1; variants.append(r)
        before = self.spawns
        for r in variants:
            with self.subTest(r=r):
                response = self.call(r)
                self.assertIn(response['status'], ('invalidRequest', 'unavailable'))
                self.assertEqual(response['mutationOutcome'], 'notEntered')
        self.assertEqual(self.spawns, before)
        self.assertEqual(cap['editing']['registryState'], 'active')

    def test_alpha_boundaries_and_boolean_distinction(self):
        self.bootstrap()
        for n in (0, 0.5, 1):
            r = {**self.edit, 'property': 'alpha', 'expectedValue': 1.0, 'value': n}
            self.assertEqual(capture.request_contract(r)['value'], n)
        for field in ('expectedValue', 'value'):
            r = {**self.edit, 'property': 'alpha', 'expectedValue': 1.0, 'value': 0.5, field: True}
            with self.assertRaises(capture.CaptureError): capture.request_contract(r)

    def test_ownership_expiry_and_graph_admission_without_child(self):
        self.bootstrap(); count = self.spawns
        for key, value in [('ownerID', uid()), ('inspectionID', uid()), ('targetEpoch', uid()),
                           ('captureID', uid()), ('nodeToken', uid()), ('expectedClass', 'Other'),
                           ('expectedWindowToken', uid()), ('expectedParentToken', None)]:
            r = {**self.edit, key: value}
            result = self.call(r)
            self.assertIn(result['status'], ('ownershipConflict', 'expired', 'conflict'))
            self.assertEqual(result['mutationOutcome'], 'notEntered')
        path, state = self.state(); state['expiresAt'] = 0; edit.atomic_write(path, state)
        self.assertEqual(self.call(self.edit)['status'], 'expired')
        self.assertEqual(self.spawns, count)

    def test_target_identity_change_before_spawn(self):
        self.bootstrap(); count = self.spawns
        self.probe.target['start'] = [999, 1]
        result = self.call(self.edit)
        self.assertEqual(result['status'], 'identityChanged')
        self.assertEqual(result['mutationOutcome'], 'notEntered')
        self.assertEqual(self.spawns, count)

    def test_duplicate_digest_high_water_and_evicted_result_never_dispatch(self):
        self.bootstrap(); r = self.call(self.edit, 'noChange'); self.assertEqual(r['status'], 'noChange')
        count = self.spawns
        self.assertTrue(self.call(self.edit)['replayed']); self.assertEqual(self.spawns, count)
        self.assertEqual(self.call({**self.edit, 'value': False})['status'], 'conflict')
        self.assertEqual(self.call({**self.edit, 'operationID': uid()})['status'], 'resultUnavailable')
        path, state = self.state(); state['results'].pop(self.edit['operationID']); edit.atomic_write(path, state)
        self.assertEqual(self.call(self.edit)['status'], 'resultUnavailable')
        self.assertEqual(self.spawns, count)

    def test_uncertain_target_outcomes_quarantine_new_ids(self):
        for mode in ('lost', 'lost-worker', 'exception-trap', 'throwAfter', 'mismatch', 'bad-readback-proof', 'bad-identity'):
            with self.subTest(mode=mode):
                # Each scenario has an independent real ledger and capture.
                self.root = self.folder / uid(); self.probe = Probe(self.target); self.bootstrap()
                r = self.call(self.edit, mode)
                self.assertEqual(r['mutationOutcome'], 'uncertain', r)
                if mode == 'exception-trap':
                    self.assertEqual(r['phase'], 'dispatchResultLost')
                    self.assertEqual(r['reasonCode'], 'resultLost')
                    self.assertIsNone(r['observed'])
                    self.assertIsNone(r['undoToken'])
                    self.assertEqual(self.state()[1]['authority'], 'quarantined')
                count = self.spawns
                again = self.call({**self.edit, 'operationID': uid(), 'sequence': 3})
                self.assertEqual(again['status'], 'outcomeUncertain')
                self.assertEqual(self.spawns, count)

    def test_weak_nil_stale_graph_expected_conflict_remain_not_entered(self):
        for mode in ('weakNil', 'staleGraph', 'expectedValueChanged'):
            self.root = self.folder / uid(); self.bootstrap()
            r = self.call(self.edit, mode)
            self.assertEqual(r['status'], 'conflict'); self.assertEqual(r['mutationOutcome'], 'notEntered')
            self.assertFalse(r['setterEntered']); self.assertTrue(r['needsRefresh'])

    def test_receipt_survives_detach_failure_and_cancellation(self):
        for mode in ('bad-detach', 'cancel-after-readback'):
            self.root = self.folder / uid(); self.probe = Probe(self.target); self.bootstrap()
            r = self.call(self.edit, mode)
            self.assertIn(r['status'], ('cleanupFailed', 'cancelled'))
            self.assertEqual(r['mutationOutcome'], 'appliedObserved')
            self.assertTrue(r['observed']); self.assertTrue(r['setterEntered']); self.assertTrue(r['needsRefresh'])
            _, state = self.state(); self.assertEqual(state['authority'], 'quarantined'); self.assertFalse(state['undo'])
            self.assertEqual(state['results'][self.edit['operationID']]['mutationOutcome'], 'appliedObserved')

    def test_host_crash_reserved_operation_never_resumes_even_new_id(self):
        self.bootstrap(); ledger = edit.Ledger(self.edit, self.root)
        try: self.assertIsNone(ledger.reserve())
        finally: ledger.close()
        count = self.spawns
        self.assertEqual(self.call({**self.edit, 'operationID': uid(), 'sequence': 3})['status'], 'outcomeUncertain')
        self.assertEqual(self.call(self.edit)['status'], 'outcomeUncertain')
        self.assertEqual(self.spawns, count)

    def test_exclusive_target_reservation_uses_real_nonblocking_file_lock(self):
        self.bootstrap()
        first = edit.Ledger(self.edit, self.root)
        try:
            first.reserve()
            with self.assertRaises(capture.CaptureError) as error:
                edit.Ledger(self.edit, self.root)
            self.assertEqual(error.exception.status, 'busy')
        finally:
            first.close()

    def test_private_atomic_reservation_and_symlink_refusal(self):
        self.bootstrap(); path, state = self.state()
        self.assertEqual(stat.S_IMODE(path.stat().st_mode), 0o600)
        self.assertEqual(stat.S_IMODE(self.root.stat().st_mode), 0o700)
        count = self.spawns
        original = path.read_bytes()
        with patch.object(edit.os, 'replace', side_effect=OSError('injected rename failure')):
            r = self.call(self.edit)
        self.assertEqual(r['status'], 'ownershipFailed'); self.assertEqual(self.spawns, count)
        self.assertEqual(path.read_bytes(), original); self.assertFalse(list(self.root.glob('.reservation-*')))
        path.unlink(); destination = self.folder / 'unrelated'; destination.write_text('preserve')
        path.symlink_to(destination)
        r = self.call(self.edit)
        self.assertEqual(r['status'], 'ownershipFailed'); self.assertEqual(destination.read_text(), 'preserve')
        self.assertEqual(self.spawns, count)

    def test_undo_receipt_and_release_revoke_without_inverse(self):
        cap = self.bootstrap(); applied = self.call(self.edit)
        undo = {k: self.edit[k] for k in ('schemaVersion', 'target', 'validationOnly', 'ownerID', 'inspectionID', 'targetEpoch', 'captureID')}
        undo.update(kind='revert', operationID=uid(), sequence=3, undoToken=uid())
        count = self.spawns
        self.assertEqual(self.call(undo)['status'], 'undoConflict'); self.assertEqual(self.spawns, count)
        undo['undoToken'] = applied['undoToken']
        reverted = self.call(undo); self.assertEqual(reverted['mutationOutcome'], 'appliedObserved')
        release = {k: undo[k] for k in ('schemaVersion', 'target', 'validationOnly', 'ownerID', 'inspectionID', 'targetEpoch', 'captureID')}
        release.update(kind='release', operationID=uid(), sequence=4, reason='close')
        result = self.call(release); self.assertTrue(result['authorityRevoked']); self.assertTrue(result['registryReleased'])
        count = self.spawns; self.assertTrue(self.call(release)['replayed']); self.assertEqual(self.spawns, count)
        self.assertEqual(self.call({**self.edit, 'operationID': uid(), 'sequence': 5})['status'], 'outcomeUncertain')
        self.assertEqual(self.spawns, count)
        _, s = self.state(); self.assertFalse(s['nodes']); self.assertFalse(s['undo'])

    def test_release_revokes_even_if_target_has_exited(self):
        self.bootstrap()
        release = {k: self.edit[k] for k in ('schemaVersion', 'target', 'validationOnly', 'ownerID', 'inspectionID', 'targetEpoch', 'captureID')}
        release.update(kind='release', operationID=uid(), sequence=2, reason='targetChanged')
        self.probe.target['start'] = [101, 1]
        r = self.call(release)
        self.assertTrue(r['authorityRevoked']); self.assertEqual(r['mutationOutcome'], 'notEntered')
        self.assertEqual(self.state()[1]['authority'], 'revoked')

    def test_refresh_revokes_previous_capture_and_invalid_capture_grants_no_tokens(self):
        cap = self.bootstrap()
        r = {**self.request, 'targetEpoch': cap['targetEpoch'], 'replaceCaptureID': cap['captureID'],
             'operationID': uid(), 'sequence': 2}
        result = self.call(r, 'bad-capture')
        self.assertEqual(result['status'], 'invalidResponse'); self.assertNotIn('editing', result)
        self.assertNotIn('editableNodes', result)
        count = self.spawns
        self.assertEqual(self.call({**self.edit, 'operationID': uid(), 'sequence': 3})['status'], 'outcomeUncertain')
        self.assertEqual(self.spawns, count)

    def test_bounded_ledger_results_and_operations(self):
        self.bootstrap()
        # Exercise production finish's eviction against a populated bounded ledger.
        path, s = self.state()
        for n in range(edit.MAX_RESULTS): s['results'][uid()] = {'status': 'noChange'}
        while len(s['results']) > edit.MAX_RESULTS: del s['results'][next(iter(s['results']))]
        edit.atomic_write(path, s)
        self.call(self.edit, 'noChange')
        self.assertEqual(len(self.state()[1]['results']), edit.MAX_RESULTS)
        path, s = self.state()
        for n in range(len(s['operations']), edit.MAX_OPERATIONS):
            s['operations'][uid()] = {'digest': edit.digest(n), 'kind': 'edit', 'sequence': 2, 'state': 'finished'}
        edit.atomic_write(path, s); count = self.spawns
        self.assertEqual(self.call({**self.edit, 'operationID': uid(), 'sequence': 3})['status'], 'capacityExceeded')
        self.assertEqual(self.spawns, count)

    def test_fixed_texture_request_and_same_operation_join_validation(self):
        self.bootstrap()
        wire = capture.read_json(self.last_folder / 'worker.json')['editWire']
        texture = json.loads(base64.b64decode(wire['textureRequestBase64']))
        self.assertIn('snapshotImage', texture['DBGHierarchyRequestActions'][0]['propertyNames'])
        payload = capture_payload(wire); root, node = payload['editableNodes']
        payload.update(hierarchy={'topLevelGroups': {}}, textureCapture={'sameOperationIdentity': True},
            textureJoins={'0x1': {'nodeToken': root['editToken'], 'className': root['className'], 'parentAddress': None},
                          '0x2': {'nodeToken': node['editToken'], 'className': node['className'], 'parentAddress': '0x1'}})
        edit.validate_payload(payload, wire)
        bad = copy.deepcopy(payload); bad['editableNodes'][1]['id'] = uid()
        with self.assertRaises(capture.CaptureError) as error: edit.validate_payload(bad, wire)
        self.assertEqual(error.exception.status, 'invalidResponse')
        for key, value in [('nodeToken', root['editToken']), ('className', 'OtherClass'), ('parentAddress', None)]:
            bad = copy.deepcopy(payload); bad['textureJoins']['0x2'][key] = value
            with self.assertRaises(capture.CaptureError): edit.validate_payload(bad, wire)
        self.assertNotIn('compilerContextAfterMainProof', next(iter(self.state()[1]['results'].values())))
        self.assertNotIn('mainThreadEntry', next(iter(self.state()[1]['results'].values())))

    def test_final_ledger_write_failure_preserves_observed_receipt_and_reservation(self):
        self.bootstrap()
        write = edit.atomic_write
        def fail_final(path, state):
            op = state['operations'].get(self.edit['operationID'])
            if op and op['state'] == 'finished': raise OSError('injected final receipt sync failure')
            return write(path, state)
        with patch.object(edit, 'atomic_write', side_effect=fail_final): result = self.call(self.edit)
        self.assertEqual(result['status'], 'cleanupFailed')
        self.assertEqual(result['mutationOutcome'], 'appliedObserved'); self.assertTrue(result['observed'])
        self.assertTrue(result['needsRefresh']); self.assertIn('ledgerError', result)
        count = self.spawns
        self.assertEqual(self.call({**self.edit, 'operationID': uid(), 'sequence': 3})['status'], 'outcomeUncertain')
        self.assertEqual(self.spawns, count)

    def test_stale_failed_capture_can_release_attempted_owned_generation(self):
        cap = self.bootstrap()
        refresh = {**self.request, 'targetEpoch': cap['targetEpoch'], 'replaceCaptureID': cap['captureID'],
                   'operationID': uid(), 'sequence': 2}
        result = self.call(refresh, 'bad-detach')
        self.assertEqual(result['status'], 'cleanupFailed')
        release = {k: self.edit[k] for k in ('schemaVersion', 'target', 'validationOnly', 'ownerID', 'inspectionID', 'targetEpoch')}
        release.update(kind='release', captureID=result['captureID'], operationID=uid(), sequence=3, reason='cancel')
        self.probe = Probe(self.target)
        released = self.call(release)
        self.assertTrue(released['authorityRevoked'])
        wire = capture.read_json(self.last_folder / 'worker.json')['editWire']
        self.assertEqual(set(wire['releaseCaptureIDs']), {cap['captureID'], result['captureID']})

    def release_request(self, capture_result, request=None, sequence=2):
        request = request or self.request
        return {**{k: request[k] for k in ('schemaVersion', 'target', 'validationOnly', 'ownerID', 'inspectionID')},
                'kind': 'release', 'operationID': uid(), 'sequence': sequence, 'reason': 'close',
                'targetEpoch': capture_result['targetEpoch'], 'captureID': capture_result['captureID']}

    def next_inspection(self, different_owner=False):
        return {**self.request, 'inspectionID': uid(), 'operationID': uid(),
                'ownerID': uid() if different_owner else self.request['ownerID']}

    def test_real_supervisor_recapture_reopen_and_restart_rollover(self):
        first = self.bootstrap()
        for different_owner in (False, True, False):
            released = self.call(self.release_request(first))
            self.assertEqual(released['status'], 'success', released)
            self.assertTrue(released['registryReleased'])
            self.assertEqual(self.state()[1]['authority'], 'released')
            predecessor = self.state()[1]['releaseProof']
            old = self.request
            self.request = self.next_inspection(different_owner)
            first = self.call(self.request)  # Each call reconstructs Ledger from disk, like host restart.
            self.assertEqual(first['status'], 'success', first)
            wire = capture.read_json(self.last_folder / 'worker.json')['editWire']
            self.assertEqual(wire['transition']['predecessor'], predecessor)
            self.assertNotEqual(first['targetEpoch'], predecessor['targetEpoch'])
            self.assertEqual(self.state()[1]['retired'][-1]['inspectionID'], old['inspectionID'])
        self.assertEqual(len(self.state()[1]['retired']), 3)

    def test_rollover_old_capture_edit_revert_release_replay_never_dispatches(self):
        first = self.bootstrap(); applied = self.call(self.edit)
        release = self.release_request(first, sequence=3)
        self.assertEqual(self.call(release)['status'], 'success')
        undo = {**release, 'kind': 'revert', 'undoToken': applied['undoToken'], 'sequence': 4, 'operationID': uid()}
        undo.pop('reason')
        old_requests = [self.request, self.edit, release, undo]
        successor = self.call(self.next_inspection(True)); self.assertEqual(successor['status'], 'success')
        path, state = self.state(); persisted = path.read_bytes(); count = self.spawns
        for r in old_requests:
            for delayed in (r, {**r, 'operationID': uid()}):
                result = self.call(delayed)
                self.assertEqual(result['status'], 'expired', result)
                self.assertNotIn('editing', result); self.assertIsNone(result.get('undoToken'))
                self.assertEqual(path.read_bytes(), persisted)
        self.assertEqual(self.spawns, count)
        self.assertEqual(self.state()[1]['authority'], 'active')

    def test_exact_same_inspection_replacement_still_preserves_epoch(self):
        first = self.bootstrap()
        refresh = {**self.request, 'targetEpoch': first['targetEpoch'], 'replaceCaptureID': first['captureID'],
                   'sequence': 2, 'operationID': uid()}
        result = self.call(refresh)
        self.assertEqual(result['status'], 'success')
        self.assertEqual(result['targetEpoch'], first['targetEpoch'])
        self.assertNotEqual(result['captureID'], first['captureID'])
        self.assertFalse(self.state()[1]['retired'])
        self.assertNotIn('transition', capture.read_json(self.last_folder / 'worker.json')['editWire'])
        # An old release may never revoke the replacement.
        before = self.spawns
        self.assertEqual(self.call(self.release_request(first, sequence=3))['status'], 'expired')
        self.assertEqual(self.spawns, before)

    def test_rollover_refuses_active_quarantined_revoked_and_unreleased_predecessor(self):
        first = self.bootstrap()
        for authority in ('active', 'quarantined', 'revoked', 'expired'):
            path, state = self.state(); state['authority'] = authority; edit.atomic_write(path, state)
            count = self.spawns; before = path.read_bytes()
            result = self.call(self.next_inspection())
            self.assertEqual(result['status'], 'ownershipConflict')
            self.assertIn('predecessorNotVerifiedReleased', result['reasonCode'])
            self.assertEqual(self.spawns, count); self.assertEqual(path.read_bytes(), before)
        # Release may clean an owned payload, but an unresolved old reservation
        # must still block rollover even with a received target release receipt.
        path, state = self.state()
        state['operations'][self.request['operationID']]['state'] = 'reserved'
        edit.atomic_write(path, state)
        self.assertEqual(self.call(self.release_request(first))['status'], 'success')
        self.assertEqual(self.state()[1]['authority'], 'revoked')
        self.assertEqual(self.call(self.next_inspection())['status'], 'ownershipConflict')

    def test_release_receipt_loss_cleanup_failure_and_malformed_proof_cannot_rollover(self):
        for mode in ('lost', 'lost-worker', 'bad-detach', 'cancel-after-readback',
                     'bad-release-proof', 'release-false', 'release-count'):
            with self.subTest(mode=mode):
                self.root = self.folder / uid(); self.probe = Probe(self.target)
                first = self.bootstrap(); result = self.call(self.release_request(first), mode)
                self.assertNotEqual(result['status'], 'success')
                self.assertNotEqual(self.state()[1]['authority'], 'released')
                count = self.spawns
                self.assertEqual(self.call(self.next_inspection())['status'], 'ownershipConflict')
                self.assertEqual(self.spawns, count)

    def test_interrupted_rollover_reservation_never_dispatches_again(self):
        first = self.bootstrap(); self.call(self.release_request(first))
        successor = self.next_inspection(True)
        ledger = edit.Ledger(successor, self.root)
        try:
            self.assertIsNone(ledger.reserve())
            self.assertEqual(self.state()[1]['transition'], ledger.state['transition'])
            ledger.wire(uid())  # Simulate exit after wire reservation but before transport.
        finally:
            ledger.close()
        count = self.spawns
        result = self.call(successor)
        self.assertEqual(result['status'], 'outcomeUncertain')
        self.assertEqual(result['reasonCode'], 'interruptedReservation')
        self.assertEqual(self.call(self.next_inspection())['status'], 'ownershipConflict')
        self.assertEqual(self.call(self.request)['status'], 'expired')
        self.assertEqual(self.spawns, count)

    def test_lost_rollover_response_duplicate_and_new_id_stay_quarantined(self):
        first = self.bootstrap(); self.call(self.release_request(first))
        successor = self.next_inspection()
        result = self.call(successor, 'lost')
        self.assertEqual(result['mutationOutcome'], 'uncertain')
        count = self.spawns
        self.assertTrue(self.call(successor)['replayed'])
        self.assertEqual(self.call({**successor, 'operationID': uid()})['status'], 'resultUnavailable')
        self.assertEqual(self.call(self.next_inspection(True))['status'], 'ownershipConflict')
        self.assertEqual(self.spawns, count)

    def test_rollover_success_duplicate_does_not_publish_capture_or_redispatch(self):
        first = self.bootstrap(); self.call(self.release_request(first))
        successor = self.next_inspection()
        self.assertEqual(self.call(successor)['status'], 'success')
        count = self.spawns; state = self.state()[1]
        result = self.call(successor)
        self.assertTrue(result['replayed']); self.assertEqual(result['status'], 'resultUnavailable')
        self.assertNotIn('editableNodes', result); self.assertNotIn('editing', result)
        self.assertEqual(self.call({**successor, 'ownerID': uid()})['status'], 'ownershipConflict')
        self.assertEqual(self.state()[1], state); self.assertEqual(self.spawns, count)

    def test_rollover_atomic_reservation_failure_preserves_predecessor(self):
        first = self.bootstrap(); self.call(self.release_request(first))
        path, state = self.state(); before = path.read_bytes(); count = self.spawns
        with patch.object(edit.os, 'replace', side_effect=OSError('transition fsync/rename failure')):
            result = self.call(self.next_inspection())
        self.assertEqual(result['status'], 'ownershipFailed')
        self.assertEqual(path.read_bytes(), before); self.assertEqual(self.spawns, count)
        self.assertEqual(self.call(self.next_inspection())['status'], 'success')

    def test_lost_final_release_or_transition_persistence_cannot_advance(self):
        for operation in ('release', 'transition'):
            with self.subTest(operation=operation):
                self.root = self.folder / uid(); self.probe = Probe(self.target)
                first = self.bootstrap(); request = self.release_request(first)
                if operation == 'transition':
                    self.assertEqual(self.call(request)['status'], 'success')
                    request = self.next_inspection()
                write = edit.atomic_write
                def fail_final(path, state):
                    op = state['operations'].get(request['operationID'])
                    if op and op['state'] == 'finished':
                        raise OSError('lost terminal lifecycle persistence')
                    return write(path, state)
                with patch.object(edit, 'atomic_write', side_effect=fail_final):
                    result = self.call(request)
                self.assertEqual(result['status'], 'cleanupFailed')
                self.assertEqual(self.state()[1]['operations'][request['operationID']]['state'], 'reserved')
                count = self.spawns
                self.assertEqual(self.call(request)['status'], 'outcomeUncertain')
                self.assertEqual(self.call(self.next_inspection(True))['status'], 'ownershipConflict')
                self.assertEqual(self.spawns, count)

    def test_initial_pre_injection_rejection_does_not_fabricate_target_release(self):
        rejected = self.call(self.request, 'no-main')
        self.assertEqual(rejected['status'], 'unsupported')
        self.assertEqual(rejected['mutationOutcome'], 'notEntered')
        self.assertNotIn('dispatch', self.events)
        self.assertNotIn('registryReleased', rejected)
        self.assertFalse(self.state()[1].get('releaseProof'))
        count = self.spawns
        again = self.call(self.next_inspection())
        self.assertEqual(again['status'], 'ownershipConflict')
        self.assertIn('noTargetStateRetirementUnsupported', again['reasonCode'])
        self.assertEqual(self.spawns, count)

    def test_retired_history_capacity_refuses_without_eviction(self):
        current = self.bootstrap()
        for i in range(edit.MAX_RETIRED_EPOCHS):
            self.assertEqual(self.call(self.release_request(current))['status'], 'success')
            self.request = self.next_inspection(i % 2 == 0)
            current = self.call(self.request)
            self.assertEqual(current['status'], 'success', current)
        self.assertEqual(self.call(self.release_request(current))['status'], 'success')
        path, state = self.state(); before = path.read_bytes(); count = self.spawns
        self.assertEqual(len(state['retired']), edit.MAX_RETIRED_EPOCHS)
        self.assertEqual(self.call(self.next_inspection())['status'], 'capacityExceeded')
        self.assertEqual(self.spawns, count); self.assertEqual(path.read_bytes(), before)

    def test_unknown_or_malformed_prior_lifecycle_fails_closed(self):
        first = self.bootstrap(); self.call(self.release_request(first))
        path, original = self.state()
        variants = []
        for field, value in [('lifecycleVersion', 0), ('retired', None), ('retired', [{}]),
                             ('releaseProof', {}), ('operations', {uid(): 1}), ('transition', {})]:
            state = copy.deepcopy(original); state[field] = value; variants.append(state)
        legacy = copy.deepcopy(original); legacy.pop('lifecycleVersion'); variants.append(legacy)
        for field, value in [('status', 'cleanupFailed'), ('registryReleased', False), ('releaseProof', None)]:
            state = copy.deepcopy(original)
            state['results'][original['releaseProof']['operationID']][field] = value
            variants.append(state)
        for state in variants:
            edit.atomic_write(path, state); before = path.read_bytes(); count = self.spawns
            result = self.call(self.next_inspection())
            self.assertEqual(result['status'], 'ownershipFailed', result)
            self.assertEqual(path.read_bytes(), before); self.assertEqual(self.spawns, count)


class EntryTests(unittest.TestCase):
    def frames(self):
        return [
            {'function': 'mach_msg2_trap', 'module': '/usr/lib/system/libsystem_kernel.dylib'},
            {'function': '__CFRunLoopServiceMachPort', 'module': '/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation'},
            {'function': '__CFRunLoopRun', 'module': '/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation'},
            {'function': 'CFRunLoopRunSpecific', 'module': '/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation'},
            {'function': '-[UIApplication _run]', 'module': '/System/Library/PrivateFrameworks/UIKitCore.framework/UIKitCore'},
            {'function': 'UIApplicationMain', 'module': '/System/Library/PrivateFrameworks/UIKitCore.framework/UIKitCore'},
            {'function': 'main', 'module': '/fixture/HierarchyFixture'},
            {'function': 'start', 'module': '/usr/lib/dyld'}]

    def test_candidate_positive_and_conservative_rejections(self):
        frames = self.frames(); self.assertTrue(edit.safe_entry(frames, '/fixture/HierarchyFixture'))
        for index, field, value in [(0, 'function', 'semaphore_wait_trap'), (2, 'function', 'layoutSubviews'),
                                    (4, 'function', '-[UIView layoutIfNeeded]'), (3, 'module', '/app/CoreFoundation'),
                                    (6, 'module', '/other/HierarchyFixture'), (7, 'function', '<unknown>')]:
            bad = copy.deepcopy(frames); bad[index][field] = value
            self.assertFalse(edit.safe_entry(bad, '/fixture/HierarchyFixture'))
        self.assertFalse(edit.safe_entry(frames * 9, '/fixture/HierarchyFixture'))
        self.assertFalse(edit.GENERAL_APP_EDIT_QUALIFIED)
        self.assertFalse(capture.GENERAL_APP_CAPTURE_QUALIFIED)

    def swift_fixture_frames(self):
        # Saved before injection in the first schema-2 UIKit attach. Paths are
        # normalized test data; the exact app and shared runtime remain distinct.
        runtime = '/runtime/RuntimeRoot'
        rows = self.frames()
        for row in rows:
            if row['module'].startswith('/System/Library/'):
                row['module'] = runtime + row['module']
        app = '/fixture/HierarchyFixture'
        rows[6:6] = [
            {'function': 'static HierarchyFixture.FixtureEntry.main() -> ()', 'module': app},
            {'function': 'static HierarchyFixture.FixtureEntry.$main() -> ()', 'module': app}]
        rows[-1:-1] = [{'function': 'start_sim', 'module': runtime + '/usr/lib/dyld_sim'}]
        return rows

    def test_measured_swift_fixture_startup_tail_is_contiguous_and_exact(self):
        frames = self.swift_fixture_frames()
        self.assertTrue(edit.safe_entry(frames, '/fixture/HierarchyFixture'))
        for index, field, value in [
                (6, 'function', 'static OtherApp.Entry.main() -> ()'),
                (7, 'function', 'static HierarchyFixture.OtherEntry.$main() -> ()'),
                (6, 'module', '/other/HierarchyFixture'),
                (9, 'module', '/other/RuntimeRoot/usr/lib/dyld_sim'),
                (9, 'module', '/usr/lib/dyld_sim'),
                (9, 'function', 'arbitrary_callback'),
                (10, 'module', '/app/dyld')]:
            bad = copy.deepcopy(frames); bad[index][field] = value
            self.assertFalse(edit.safe_entry(bad, '/fixture/HierarchyFixture'), (index, field, value))
        variants = []
        missing = copy.deepcopy(frames); missing.pop(7); variants.append(missing)
        reordered = copy.deepcopy(frames); reordered[6], reordered[7] = reordered[7], reordered[6]; variants.append(reordered)
        callback = copy.deepcopy(frames); callback.insert(8, {'function': 'appCallback', 'module': '/fixture/HierarchyFixture'}); variants.append(callback)
        nested = copy.deepcopy(frames); nested[4:4] = nested[6:8]; del nested[8:10]; variants.append(nested)
        repeated = copy.deepcopy(frames); repeated[6:6] = repeated[6:8]; variants.append(repeated)
        for bad in variants:
            self.assertFalse(edit.safe_entry(bad, '/fixture/HierarchyFixture'))
        self.assertFalse(edit.GENERAL_APP_EDIT_QUALIFIED)
        self.assertFalse(capture.GENERAL_APP_CAPTURE_QUALIFIED)

    def test_actual_select_main_records_before_injection_and_rejects_unknown(self):
        for accepted, features in ((False, 0), (True, 0), (True, 1), (True, 2)):
            with tempfile.TemporaryDirectory() as folder:
                rows = self.frames()
                if not accepted: rows[0]['function'] = 'layoutSubviews'
                def frame(index):
                    path = Path(rows[index]['module'])
                    return SimpleNamespace(IsValid=lambda: True, GetFunctionName=lambda: rows[index]['function'],
                        GetModule=lambda: SimpleNamespace(GetFileSpec=lambda: SimpleNamespace(
                            GetDirectory=lambda: str(path.parent), GetFilename=lambda: path.name)))
                thread = SimpleNamespace(GetQueueName=lambda: 'com.apple.main-thread', GetThreadID=lambda: 7,
                    GetNumFrames=lambda: len(rows), GetFrameAtIndex=frame)
                engine = capture.LLDBEngine.__new__(capture.LLDBEngine)
                engine.config = {'request': {'schemaVersion': 2, 'target': {'path': '/fixture/HierarchyFixture'}},
                                 'sdkPath': '/sdk', 'evidenceDirectory': folder}
                engine.process = SimpleNamespace(GetNumThreads=lambda: 1, GetThreadAtIndex=lambda _: thread,
                    SetSelectedThread=lambda _: None, GetTarget=lambda: None)
                engine.debugger = engine.lldb = None; engine.control = lambda: None
                calls = []
                def evaluate(source):
                    self.assertTrue((Path(folder) / 'main-thread-entry.json').exists()); calls.append(source)
                    return SimpleNamespace(GetValueAsUnsigned=lambda: features if '__has_feature' in source else 1)
                engine.evaluate = evaluate
                with patch.object(capture, 'import_target_modules', return_value={}):
                    if accepted and not features & 1:
                        self.assertTrue(engine.select_main()['candidateIdle'])
                        self.assertEqual(engine.compiler_context['editExpressionOwnership'], 'MRC')
                        self.assertEqual(engine.compiler_context['editExceptionHandling'],
                            'targetCatchAndLLDBTrap' if features & 2 else 'lldbTrapAndHostUncertainty')
                    else:
                        with self.assertRaises(capture.CaptureError) as error: engine.select_main()
                        self.assertEqual(error.exception.status, 'unsupported' if accepted else 'unsafeEntry')
                self.assertEqual(len(calls), 2 if accepted else 0)
                evidence = json.loads((Path(folder) / 'main-thread-entry.json').read_text())
                self.assertEqual(evidence['frames'][0]['function'], rows[0]['function'])

    def test_actual_edit_evaluation_traps_exceptions_without_fixits_or_all_thread_retry(self):
        observed = {}
        class Options:
            def __getattr__(self, name):
                return lambda value: observed.update({name: value})
        engine = capture.LLDBEngine.__new__(capture.LLDBEngine)
        engine.config = {'request': {'schemaVersion': 2}, 'deadline': capture.monotonic() + 10}
        engine.control = lambda: None
        engine.lldb = SimpleNamespace(SBExpressionOptions=Options, eLanguageTypeObjC_plus_plus=1)
        engine.frame = SimpleNamespace(EvaluateExpression=lambda source, options:
            SimpleNamespace(GetError=lambda: SimpleNamespace(Fail=lambda: False)))
        engine.evaluate('1')
        self.assertIs(observed.get('SetAutoApplyFixIts'), False)
        self.assertIs(observed.get('SetTryAllThreads'), False)
        self.assertIs(observed.get('SetTrapExceptions'), True)
        self.assertIs(observed.get('SetUnwindOnError'), True)


if __name__ == '__main__':
    unittest.main()
