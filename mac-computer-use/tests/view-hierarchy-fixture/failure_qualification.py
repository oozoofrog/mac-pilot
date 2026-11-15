"""Four bounded fixture cases. No general fault framework or production fault switch."""
import copy
import hashlib
import json
import os
from pathlib import Path
import time

import edit_qualification as q

CASES = ('throw', 'cancel', 'replace', 'reparent')
CONTROL_SECONDS = 8
SENTINEL_SECONDS = 6


def read_bounded(path):
    q.require(path.is_file() and not path.is_symlink() and path.stat().st_size <= 262144,
              'missing or unbounded independent fixture evidence: ' + str(path))
    return json.loads(path.read_text())


def fault_events(value, request_id, generation):
    q.require(value.get('schemaVersion') == 1 and isinstance(value.get('events'), list)
              and len(value['events']) <= 256, 'invalid independent event envelope')
    return [e for e in value['events'] if e['requestID'] == request_id and e['nodeGeneration'] == generation]


def assert_fault_receipt(receipt, folder):
    q.require(receipt.get('mutationOutcome') == 'uncertain' and receipt.get('needsRefresh') is True
              and receipt.get('undoToken') is None and receipt.get('phase') == 'dispatchResultLost',
              'missing target answer must remain uncertain and must not invent undo')
    q.require((folder / 'dispatch.json').is_file() and not (folder / 'answer.json').exists(),
              'fault did not exercise dispatched/missing-answer boundary')


def assert_graph_receipt(receipt, reason):
    q.require(receipt.get('status') == 'conflict' and receipt.get('reasonCode') == reason
              and receipt.get('setterEntered') is False and receipt.get('mutationOutcome') == 'notEntered'
              and receipt.get('undoToken') is None, 'stale weak/graph identity was not refused before setter')


class Runtime(q.Runtime):
    def __init__(self, *args, **kwargs):
        super().__init__(*args, **kwargs)
        self.events_file = self.oracle.parent / 'fault-events.json'
        self.control_id = self.control_generation = None
        self.cancel_on_entry = False
        self.cancel_sent = False

    def check(self):
        super().check()
        if self.cancel_on_entry and not self.cancel_sent and self.child is not None and self.child.poll() is None:
            events = fault_events(read_bounded(self.events_file), self.control_id, self.control_generation)
            # Require the independently persisted applied-value marker, not dispatch timing.
            entered = [e for e in events if e['phase'] == 'finiteDelayEntered']
            if entered:
                folder = Path(self.records[-1]['folder'])
                self.s.save(folder / 'parent-cancellation.json', {
                    'reason': 'owned finite setter entered after applying hidden', 'entryEvent': entered[-1],
                    'parentPID': os.getpid(), 'monotonicSeconds': self.now(), 'unixSeconds': time.time(),
                    'controlPath': str(folder / 'cancel'), 'nextOperationsAllowed': False})
                (folder / 'cancel').touch(mode=0o600, exist_ok=False)
                self.cancel_sent = True

    def operation(self, request, label):
        q.require(not self.cancel_sent, 'parent cancellation forbids every subsequent target operation')
        return super().operation(request, label)

    def sample(self, label, after=None):
        self.foreground(label + '-after')
        until = self.now() + CONTROL_SECONDS
        threshold = self.last_operation_start if after is None else after
        while True:
            self.check()
            value = read_bounded(self.oracle)
            q.require(value['schemaVersion'] == 1 and 0 < len(value['samples']) <= 128, 'invalid model oracle')
            sample = value['samples'][-1]
            if sample['unixSeconds'] >= threshold:
                break
            q.require(self.now() < until, 'fresh model oracle not observed')
            time.sleep(.05)
        q.require(sample['pid'] == self.target['pid'] and sample['name'] == q.TARGET_NAME
                  and sample['className'] == q.TARGET_CLASS and sample['sceneActivationState'] == 0,
                  'independent target/scene identity differs')
        self.s.save(self.out / (label + '-edit-oracle.json'), value)
        self.s.save(self.out / (label + '-fault-events.json'), read_bounded(self.events_file))
        self.last_sample = sample
        return value, sample

    def observe(self, label, hidden, alpha, hidden_delta, alpha_delta):
        previous = self.last_sample
        value, sample = self.sample(label)
        counts = previous['setterCounts'] if previous else value['constructionBaseline']
        q.require(sample['setterCounts'] == {'hidden': counts['hidden'] + hidden_delta,
                  'alpha': counts['alpha'] + alpha_delta}, 'independent setter counts differ')
        q.require(sample['hidden'] is hidden and sample['alpha'] == alpha, 'independent model values differ')
        self.records[-1]['oracleSample'] = sample
        self.persist()

    def control(self, action):
        self.check()
        self.s.reserve(self.deadline, CONTROL_SECONDS + q.PRE + q.OPERATION + q.POST + q.SESSION_CLEANUP,
                       'fixture control, complete operation and cleanup')
        self.s.capture.verify_target(self.pp, self.target)
        self.control_id, self.control_generation = q.uid(), self.last_sample['nodeGeneration']
        request = {'requestID': self.control_id, 'action': action,
            'session': os.environ['MAC_CU_FIXTURE_WORKER'], 'pid': self.target['pid'],
            'nodeGeneration': self.control_generation, 'issuedUnixSeconds': time.time()}
        self.s.save(self.out / 'fixture-control-request.json', request)
        self.s.save(self.oracle.parent / 'fault-control.json', request)
        expected = {'replace': 'deallocatedAndRecreated', 'reparent': 'reparented'}.get(action, 'armed')
        until = self.now() + CONTROL_SECONDS
        while True:
            self.check()
            value = read_bounded(self.oracle)
            receipt = value.get('controlReceipt') or {}
            if receipt.get('requestID') == self.control_id and receipt.get('status') == expected:
                self.s.save(self.out / 'fixture-control-receipt.json', receipt)
                self.sample('control', after=request['issuedUnixSeconds'])
                return receipt
            q.require(self.now() < until, 'fixture control not acknowledged; no operation follows')
            time.sleep(.05)

    def host_fence(self, request, label):
        """Canonical admission only. A child-construction attempt is an immediate failure."""
        self.check()
        self.s.capture.verify_target(self.pp, self.target)
        folder = self.out / label; folder.mkdir(mode=0o700)
        self.s.save(folder / 'request.json', request)
        spawn_attempts = []
        def forbidden_spawn(argv, **_):
            spawn_attempts.append(argv)
            raise AssertionError('old uncertain authority attempted debugger child construction')
        result = self.s.capture.supervise(request, folder, self.pp, lambda: False,
            popen=forbidden_spawn, ledger_root=self.out / 'ledger')
        self.s.save(folder / 'result.json', result)
        self.s.save(folder / 'admission.json', {'requestDigest': self.s.capture.edit_backend.digest(request),
            'spawnAttempts': spawn_attempts, 'dispatchPresent': (folder / 'dispatch.json').exists(),
            'answerPresent': (folder / 'answer.json').exists(), 'debuggerChildrenCreated': len(spawn_attempts)})
        q.require(not spawn_attempts and not (folder / 'dispatch.json').exists()
                  and not (folder / 'answer.json').exists(), 'old authority reached debugger dispatch')
        q.require(result.get('mutationOutcome') == 'uncertain' and result.get('undoToken') is None,
                  'old authority lost uncertainty or supplied undo')
        return result


def run(runtime, case):
    q.require(case in CASES, 'unknown bounded case')
    report = {'case': case, 'qualified': False, 'automaticRetries': 0, 'UIClaim': False,
              'captureTTLSeconds': 120, 'finiteSetterDelaySeconds': 4,
              'controlBudgetSeconds': CONTROL_SECONDS, 'sentinelObservationSeconds': SENTINEL_SECONDS}
    try:
        sequence = q.Sequence(runtime)
        sequence.capture('capture')
        initial = copy.deepcopy(runtime.last_sample)
        report['initial'] = initial
        action = {'throw': 'throwAfterWrite', 'cancel': 'slowAfterWrite', 'replace': 'replace', 'reparent': 'reparent'}[case]
        control = runtime.control(action)
        report['control'] = control
        node, context = sequence.selected, sequence.context
        q.require(time.time() < context['editing']['expiresAt'] and runtime.now() < sequence.expiry_monotonic,
                  'capture expired before case; no renewal')
        request = dict(schemaVersion=2, kind='edit', target=runtime.target, validationOnly=True,
            ownerID=sequence.owner, inspectionID=sequence.inspection, operationID=q.uid(), sequence=2,
            targetEpoch=context['targetEpoch'], captureID=context['captureID'], nodeToken=node['editToken'],
            expectedParentToken=node['parentID'], expectedWindowToken=node['windowToken'], expectedClass=node['className'],
            property='hidden', expectedValue=False, value=True)
        runtime.cancel_on_entry = case == 'cancel'
        receipt = runtime.operation(request, case)
        folder = Path(runtime.records[-1]['folder'])
        report.update(receipt=receipt, dispatchPresent=(folder / 'dispatch.json').exists(),
                      answerPresent=(folder / 'answer.json').exists())
        model, sample = runtime.sample('recovered')
        report['recovered'] = sample
        for key in ('windowGeneration', 'sceneGeneration', 'sceneID'):
            q.require(initial[key] == sample[key], 'unexpected independent scene/window generation change')
        if case in ('throw', 'cancel'):
            assert_fault_receipt(receipt, folder)
            q.require(receipt['status'] == ('expressionError' if case == 'throw' else 'cancelled'),
                      'unexpected actual fault outcome; retain original receipt')
            q.require(sample['nodeGeneration'] == initial['nodeGeneration']
                      and sample['parentGeneration'] == initial['parentGeneration']
                      and sample['hidden'] is True and sample['alpha'] == 1
                      and sample['setterCounts'] == {'hidden': initial['setterCounts']['hidden'] + 1,
                                                   'alpha': initial['setterCounts']['alpha']},
                      'independent entered/applied values or counters differ')
            events = fault_events(read_bounded(runtime.events_file), runtime.control_id, runtime.control_generation)
            phases = [e['phase'] for e in events]
            q.require(phases.count('hiddenSetterEntered') == 1 and phases.count('hiddenApplied') == 1
                      and phases.count('sentinelCreated') == 1, 'missing independent entry/write/sentinel proof')
            if case == 'cancel':
                q.require(runtime.cancel_sent and (folder / 'parent-cancellation.json').is_file()
                          and phases.count('finiteDelayEntered') == 1, 'cancellation was not after independent setter entry')
            # Observe cleanup; never run an injected release or manufacture a missing dealloc.
            until = runtime.now() + SENTINEL_SECONDS
            while 'sentinelDeallocated' not in phases and runtime.now() < until:
                runtime.check(); time.sleep(.1)
                events = fault_events(read_bounded(runtime.events_file), runtime.control_id, runtime.control_generation)
                phases = [e['phase'] for e in events]
            report['faultEvents'] = events
            report['sentinelDeallocatedAfterRecovery'] = phases.count('sentinelDeallocated') == 1
            report['setterReturned'] = phases.count('hiddenSetterReturned') == 1
            # Host admission only, also after cancellation. operation() still forbids
            # every subsequent target operation; host_fence forbids child creation.
            replay = runtime.host_fence(request, 'old-operation-replay')
            q.require(replay.get('replayed') is True, 'old operation did not return retained receipt')
            blocked = runtime.host_fence({**request, 'operationID': q.uid(), 'sequence': 3}, 'old-authority-new-id')
            q.require(blocked.get('status') == 'outcomeUncertain', 'old authority was not quarantined')
            _, after_fences = runtime.sample('after-fences', after=time.time())
            q.require(after_fences['setterCounts'] == sample['setterCounts'], 'fence attempts entered another setter')
            report['oldAuthorityNoDispatch'] = True
            report['qualified'] = report['sentinelDeallocatedAfterRecovery']
            if not report['qualified']:
                report['blocker'] = 'Autoreleased setter sentinel was not deallocated during the bounded post-recovery observation.'
        else:
            assert_graph_receipt(receipt, 'weakNil' if case == 'replace' else 'staleGraph')
            q.require(report['dispatchPresent'] and report['answerPresent'], 'graph refusal did not run canonical target expression')
            q.require(sample['setterCounts'] == initial['setterCounts'] and sample['hidden'] is False and sample['alpha'] == 1,
                      'stale token reached a setter or changed the target')
            if case == 'replace':
                events = read_bounded(runtime.events_file)['events']
                deaths = [e for e in events if e['phase'] == 'targetDeallocated' and e['nodeGeneration'] == initial['nodeGeneration']]
                q.require(len(deaths) == 1 and control['oldWeakNil'] is True
                          and sample['nodeGeneration'] != initial['nodeGeneration']
                          and sample['frame'] == initial['frame'], 'independent deallocation/replacement not established')
                report['naturalSameAddressReuse'] = control['oldAddress'] == control['newAddress']
                report['replacementAllocations'] = 1
            else:
                q.require(sample['nodeGeneration'] == initial['nodeGeneration']
                          and sample['parentGeneration'] != initial['parentGeneration']
                          and sample['parentName'] == 'fixture.reparent', 'independent reparenting not established')
            report['qualified'] = True
        runtime.s.save(runtime.out / 'fault-events-final.json', read_bounded(runtime.events_file))
    except BaseException as error:
        report['error'] = repr(error)
        raise
    finally:
        runtime.s.save(runtime.out / 'failure-case.json', report)
    # A leaked sentinel blocks product qualification, but does not falsify safe
    # process recovery or prevent the existing exact fixture disposal path.
    return report
