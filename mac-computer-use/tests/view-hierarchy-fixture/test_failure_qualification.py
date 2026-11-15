"""Focused fault admission/cancellation evidence checks. No GUI or LLDB process."""
import copy
import json
import os
from pathlib import Path
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch

import edit_qualification as q
import failure_qualification as f
import session
from test_edit_qualification import FakeRuntime


class FailureQualificationChecks(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='mac-cu-failure-tests-')
        self.addCleanup(self.tmp.cleanup)
        self.out = Path(self.tmp.name).resolve()

    def runtime(self):
        runtime = f.Runtime.__new__(f.Runtime)
        runtime.s = session
        runtime.out = self.out
        runtime.claim = SimpleNamespace(check=lambda: None)
        runtime.input_guard = SimpleNamespace(check=lambda: None)
        runtime.stopping = lambda: False
        runtime.cancel_on_entry = True
        runtime.cancel_sent = False
        runtime.control_id, runtime.control_generation = q.uid(), q.uid()
        runtime.events_file = self.out / 'events.json'
        runtime.child = SimpleNamespace(poll=lambda: None)
        runtime.records = [{'folder': str(self.out)}]
        runtime.now = session.monotonic
        return runtime

    def event(self, runtime, phase, **fields):
        return {'phase': phase, 'requestID': runtime.control_id, 'nodeGeneration': runtime.control_generation,
                'pid': 42, 'detail': {}, **fields}

    def write_events(self, runtime, events):
        session.save(runtime.events_file, {'schemaVersion': 1, 'events': events})

    def test_parent_cancellation_waits_for_exact_independent_entry(self):
        runtime = self.runtime()
        for events in ([], [self.event(runtime, 'hiddenSetterEntered')],
                       [self.event(runtime, 'finiteDelayEntered', requestID=q.uid())],
                       [self.event(runtime, 'finiteDelayEntered', nodeGeneration=q.uid())]):
            self.write_events(runtime, events)
            runtime.check()
            self.assertFalse((self.out / 'cancel').exists())
        self.write_events(runtime, [self.event(runtime, 'hiddenApplied'), self.event(runtime, 'finiteDelayEntered')])
        runtime.check()
        self.assertTrue(runtime.cancel_sent)
        self.assertTrue((self.out / 'cancel').is_file())
        proof = json.loads((self.out / 'parent-cancellation.json').read_text())
        self.assertEqual(proof['entryEvent']['requestID'], runtime.control_id)
        self.assertFalse(proof['nextOperationsAllowed'])
        runtime.check()  # Exactly one cancellation marker, never a second request.
        with self.assertRaisesRegex(RuntimeError, 'forbids every subsequent'):
            runtime.operation({}, 'must-not-dispatch')

    def test_input_loss_prevents_control_action(self):
        runtime = self.runtime()
        runtime.input_guard = SimpleNamespace(check=lambda: (_ for _ in ()).throw(InterruptedError('input')))
        self.write_events(runtime, [self.event(runtime, 'finiteDelayEntered')])
        with self.assertRaises(InterruptedError):
            runtime.check()
        self.assertFalse((self.out / 'cancel').exists())

    def test_uncertain_receipt_never_promoted_from_external_model(self):
        (self.out / 'dispatch.json').write_text('{}')
        receipt = dict(mutationOutcome='uncertain', needsRefresh=True, undoToken=None, phase='dispatchResultLost')
        f.assert_fault_receipt(receipt, self.out)
        for delta in ({'mutationOutcome': 'notEntered'}, {'mutationOutcome': 'appliedObserved'},
                      {'needsRefresh': False}, {'undoToken': q.uid()}, {'phase': 'readback'}):
            with self.assertRaises(RuntimeError):
                f.assert_fault_receipt({**receipt, **delta}, self.out)
        (self.out / 'answer.json').write_text('{}')
        with self.assertRaises(RuntimeError):
            f.assert_fault_receipt(receipt, self.out)

    def test_graph_refusal_requires_exact_reason_and_nonentry(self):
        for reason in ('weakNil', 'staleGraph'):
            receipt = dict(status='conflict', reasonCode=reason, setterEntered=False,
                           mutationOutcome='notEntered', undoToken=None)
            f.assert_graph_receipt(receipt, reason)
            for delta in ({'reasonCode': 'expectedValueChanged'}, {'setterEntered': True},
                          {'mutationOutcome': 'uncertain'}, {'undoToken': q.uid()}):
                with self.assertRaises(RuntimeError):
                    f.assert_graph_receipt({**receipt, **delta}, reason)

    def test_actual_ledger_quarantine_refuses_replay_and_new_operation_before_children(self):
        fake = FakeRuntime(self.out)
        sequence = q.Sequence(fake)
        sequence.capture('capture')
        fake.mode, fake.fail_label = 'lost', 'hidden'
        with self.assertRaises(RuntimeError):
            sequence.edit_and_undo('hidden', False, True, 1, 0)
        original = copy.deepcopy(fake.requests[-1])
        runtime = self.runtime()
        runtime.cancel_on_entry = False
        runtime.cancel_sent = True
        runtime.pp, runtime.target = fake.probe, fake.target
        replay = runtime.host_fence(original, 'replay')
        self.assertTrue(replay['replayed'])
        blocked = runtime.host_fence({**original, 'operationID': q.uid(), 'sequence': 3}, 'blocked')
        self.assertEqual(blocked['status'], 'outcomeUncertain')
        for label in ('replay', 'blocked'):
            proof = json.loads((self.out / label / 'admission.json').read_text())
            self.assertEqual(proof['spawnAttempts'], [])
            self.assertFalse(proof['dispatchPresent'])
        with self.assertRaisesRegex(RuntimeError, 'forbids every subsequent'):
            runtime.operation(original, 'cancelled-target-operation')

    def test_public_contract_still_rejects_fixture_controls(self):
        fake = FakeRuntime(self.out)
        q.Sequence(fake).capture('capture')
        original = fake.requests[0]
        for field in ('faultMode', 'action', 'selector', 'expression', 'address', 'force'):
            with self.assertRaises(session.capture.CaptureError):
                session.capture.request_contract({**original, field: 'throwAfterWrite'})

    def test_malformed_or_symlinked_event_evidence_is_not_entry(self):
        runtime = self.runtime()
        with self.assertRaises(RuntimeError):
            runtime.check()
        target = self.out / 'other.json'; target.write_text('{}')
        runtime.events_file.symlink_to(target)
        with self.assertRaises(RuntimeError):
            runtime.check()

    def test_worker_rejects_unknown_failure_family_before_any_mutation(self):
        args = ['session.py', '--worker', '/build', '/out', q.uid(), 'token', '1', '1000', '--failure-case', 'arbitrary']
        with patch.object(session.sys, 'argv', args), patch.object(session, 'worker') as worker:
            self.assertEqual(session.main(), 64)
            worker.assert_not_called()


if __name__ == '__main__':
    unittest.main()
