"""Owned ordinary-app qualification through the real Swift schema-2 wrappers."""
import argparse
import base64
import functools
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import time
import uuid

sys.dont_write_bytecode = True
HERE = Path(__file__).resolve().parent
FIXTURE = HERE.parent / 'view-hierarchy-fixture'
sys.path[:0] = [str(FIXTURE), str(HERE.parent / 'view-resident-lifetime')]
import session as s
import edit_qualification as q


s.TOTAL, s.WORK, s.GRACE = 900, 660, 235
s.CAPTURE_ADMISSION = 195
s.BUNDLE = 'local.mac-pilot.resident-product'
s.APP_NAME = 'ResidentProduct.app'
s.EXECUTABLE = 'ResidentProduct'

def process_budget(snapshot, group, target, build, server_path, details):
    if s.legacy_target_observation(snapshot, group, target, build, server_path, details, process_budget):
        return
    return _process_budget(snapshot, group, target, build, server_path, details)


def _process_budget(snapshot, group, target, build, server_path, details):
    """Exact executable budgets and direct parent topology; never signal authority."""
    members = s.watchdog.session_members(snapshot, group, str((build / 'session-probe').resolve()))
    if server_path is None:
        q.require(not members, 'headless guard worker created a child')
        details['budget'] = 'headless guard: parent1 worker1; no worker children or target'
        return
    python = str(Path(sys.executable).resolve())
    python_paths = {python, str(Path(python).parent.parent / 'Resources/Python.app/Contents/MacOS/Python')}
    probe = str((build / 'session-probe').resolve())
    server = str(server_path)
    # ps can expose an exec-transition name such as 'ps'/'(ps)', not an executable
    # path. Resolve that exact PID with the kernel; never trust the short name.
    resolved = []
    for row in members:
        if not Path(row[3]).is_file():
            entry = {'sample': row, 'status': 'reading', 'signalAuthority': False}
            observations = details.setdefault('residentExecutableObservations', [])
            observations.append(entry)
            del observations[:-512]
            # A process can exit between ps and proc_pidinfo, while kill(pid, 0)
            # still succeeds for its zombie. Use the shared fresh exit/zombie
            # readback; unknown or reused identities must still fail closed.
            identity = s.watchdog.identify_live_server(row[0])
            if identity is None:
                entry['status'] = 'goneOrZombie'
                continue
            if identity is s.watchdog.UNVERIFIED:
                # Keep unknown ownership closed. A short tool may still be exiting:
                # only a fresh confirmed exit/zombie can remove it from this budget.
                entry['exitRechecks'] = []
                for _ in range(4):
                    gone = s.watchdog.gone_or_zombie(row[0])
                    entry['exitRechecks'].append({'monotonic': s.monotonic(), 'goneOrZombie': gone})
                    if gone: break
                    time.sleep(.025)
                if gone:
                    entry['status'] = 'confirmedExitAfterUnknown'
                    continue
                entry['status'] = 'unknown'
                raise RuntimeError('cannot verify resident executable PID ' + str(row[0]))
            entry.update(status='live', identity=identity)
            q.require(identity['parent'] == row[1], 'process parent changed during executable readback')
            row = (*row[:3], identity['path'], row[4])
        resolved.append(row)
    members = resolved
    details['lastResidentProcessSample'] = members
    members = s.without_read_probe_helpers(members, details)
    q.require(sum(r[3] in python_paths for r in members) <= 2, 'resident Python executable budget exceeded')
    for executable in (probe, server):
        q.require(sum(r[3] == executable for r in members) <= 1, 'resident executable budget exceeded: ' + executable)
    if target is not None:
        q.require(sum(r[3] == target['path'] for r in snapshot) <= 1, 'exact fixture executable budget exceeded')
    probes = {r[0] for r in members if r[3] == probe}
    # These fixed tools support existing inventory/claim/probe/signature routes.
    # xcrun execs selected simctl; a probe may own one such read-only child.
    tool_paths = {'/usr/bin/xcrun', '/usr/bin/xcode-select', '/usr/bin/xcodebuild', '/usr/bin/codesign', '/usr/bin/plutil', '/bin/ps'}
    developer = next(parent for parent in Path(server_path).parents if parent.name == 'Contents') / 'Developer'
    tool_paths.add(str(developer / 'usr/bin/simctl'))
    tool_paths.add(str(developer / 'usr/bin/xcodebuild'))
    tool_paths.add('/Library/Developer/PrivateFrameworks/CoreSimulator.framework/Versions/A/Resources/bin/simctl')
    tools = [r for r in members if r[3] in tool_paths]
    q.require(len(tools) <= 1, 'serialized utility budget exceeded')
    python_rows = [r for r in members if r[3] in python_paths]
    supervisor_rows = [r for r in python_rows if r[1] in probes]
    supervisor_ids = {r[0] for r in supervisor_rows}
    worker_rows = [r for r in python_rows if r[1] in supervisor_ids]
    worker_ids = {r[0] for r in worker_rows}
    q.require(len(supervisor_rows) <= 1 and len(worker_rows) <= 1, 'supervisor/worker budget exceeded')
    for row in members:
        if row[3] == probe:
            q.require(row[1] == group, 'probe must be direct session child')
        elif row[3] == server:
            q.require(row[1] in supervisor_ids or s.watchdog.parent_context_pending(row[1], python_paths),
                      'debugserver not owned by wrapper supervisor')
        elif row[3] in python_paths:
            q.require(row[0] in supervisor_ids | worker_ids or s.watchdog.parent_context_pending(row[1], {*python_paths, probe}),
                      'unknown Python parent topology')
        else:
            q.require(row[3] in tool_paths and (row[1] in {group, *probes, *supervisor_ids, *worker_ids}
                      or s.watchdog.parent_context_pending(row[1], {*python_paths, probe})),
                      'unknown process/utility parent in product session')
    details['residentProcessBudgetSamples'] = details.get('residentProcessBudgetSamples', 0) + 1
    details['budget'] = 'parent1 sessionWorker1 app1 SwiftWrapper1 captureSupervisor1 lldbWorker1 debugserver1; serialized utility/identity helper1 plus display-version child1'


def wait(predicate, check, seconds=8):
    end = s.monotonic() + seconds
    while True:
        check(); value = predicate()
        if value: return value
        q.require(s.monotonic() < end, 'independent observation timed out')
        time.sleep(.025)


def run_case(session, build, out, device, target, before, data, claim, guard, stopping, deadline, *, case):
    q.require(s.BUNDLE != s.capture.FIXTURE_BUNDLE, 'ordinary app must not use fixture allowlist')
    docs = Path(data) / 'Documents'
    records = []; owner = q.uid(); inspection = q.uid(); sequence = 0; context = None; selected = None
    last_oracle = json.loads((docs / 'edit-oracle.json').read_text())['samples'][-1]
    observation_after = time.time()
    original_generation = last_oracle['nodeGeneration']
    def check():
        claim.check(); guard.check()
        q.require(not stopping(), 'session cancelled; no more admission')
        s.reserve(deadline, s.CLEANUP_BUDGET, 'exact target restoration reserve')
    def observe(label, hidden, alpha, hidden_delta=0, alpha_delta=0):
        nonlocal last_oracle
        prev = last_oracle
        sample = wait(lambda: next((x for x in reversed(json.loads((docs / 'edit-oracle.json').read_text())['samples'])
                if x['sequence'] > prev['sequence'] and x['unixSeconds'] > observation_after), None), check)
        q.require(sample['nodeGeneration'] == prev['nodeGeneration'] and sample['hidden'] == hidden and sample['alpha'] == alpha,
                  'independent state/generation differs at ' + label)
        q.require(sample['setterCounts']['hidden'] - prev['setterCounts']['hidden'] == hidden_delta
                  and sample['setterCounts']['alpha'] - prev['setterCounts']['alpha'] == alpha_delta,
                  'duplicate/missing setter at ' + label)
        s.save(out / (label + '-oracle.json'), sample); last_oracle = sample
        return sample
    def call(kind, label, fields=None, expect='success', cancel_control=None, exact_request=None):
        nonlocal sequence, observation_after
        check(); s.reserve(deadline, 165 + s.CLEANUP_BUDGET, 'wrapper operation and independent cleanup')
        sequence += 1
        request = exact_request or dict(schemaVersion=2, kind=kind, target=target, validationOnly=False,
            ownerID=owner, inspectionID=inspection, operationID=q.uid(), sequence=sequence,
            targetEpoch=context['targetEpoch'] if context else None, **(fields or {}))
        path = out / (label + '-request.json'); s.save(path, request)
        result_path = out / (label + '-result.json')
        env = {k:v for k,v in os.environ.items() if not k.startswith(('MAC_CU_', 'DYLD_', 'PYTHON', 'FIXTURE_'))}
        env['FIXTURE_OPERATION_REQUEST'] = str(path)
        record = {'label': label, 'request': request, 'started': s.monotonic()}; records.append(record)
        end = s.monotonic() + 165; revoked = False
        with result_path.open('w') as stdout, (out / (label + '-wrapper.log')).open('w') as stderr:
            child = subprocess.Popen([str(build / 'session-probe'), '--native-check'], env=env,
                stdin=subprocess.DEVNULL, stdout=stdout, stderr=stderr)
            try:
                while child.poll() is None:
                    check()
                    if cancel_control and not revoked:
                        events = json.loads((docs / 'fault-events.json').read_text())['events'] if (docs / 'fault-events.json').exists() else []
                        entry = next((e for e in events if e['requestID'] == cancel_control and e['phase'] == 'finiteDelayEntered'), None)
                        if entry:
                            Path(str(path) + '.cancel').touch(); revoked = True
                            record['cancel'] = {'entry': entry, 'requestedMonotonic': s.monotonic()}
                    if s.monotonic() >= end:
                        Path(str(path) + '.cancel').touch()
                        raise s.ProbeCleanupUnknown('wrapper deadline; custody remains owned, no forced cleanup')
                    time.sleep(.025)
                child.wait(timeout=1)
            except BaseException:
                Path(str(path) + '.cancel').touch()
                if child.poll() is None:
                    raise s.ProbeCleanupUnknown('wrapper still active; preserve target/claim and custody')
                raise
        if child.returncode != 0:
            raise s.ProbeCleanupUnknown('Swift wrapper failed; product custody receipt unavailable: ' + str(out / (label + '-wrapper.log')))
        try:
            result = json.loads(result_path.read_text())
        except Exception as error:
            raise s.ProbeCleanupUnknown('missing/malformed product receipt; retain custody') from error
        record.update(result=result, finished=s.monotonic())
        s.save(out / 'operations.json', records)
        evidence = result.get('evidenceDirectory')
        if evidence:
            shutil.copytree(evidence, out / (label + '-evidence'))
        cleanup = result.get('cleanup', {})
        never_dispatched = result.get('neverDispatched') is True
        if never_dispatched:
            q.require(evidence and set(p.name for p in Path(evidence).iterdir()) == {'request.json', 'result.json'}, 'host-only refusal has dispatch evidence')
            s.capture.verify_target(s.capture.ProcessProbe(), target)
        if result.get('targetCallbackPending') or cleanup.get('custodyRequired') or (evidence and not never_dispatched and not cleanup.get('childrenReaped')):
            raise s.ProbeCleanupUnknown('production callback/debugger custody unresolved; preserve exact target')
        if evidence and not never_dispatched and not cleanup.get('recovery', {}).get('verified'):
            raise s.ProbeCleanupUnknown('same-target recovery not verified')
        q.require(result['status'] == expect, label + ' returned ' + result['status'] + ': ' + str(result.get('message', result.get('reasonCode'))))
        if expect == 'success':
            q.require(cleanup.get('detach') == 'success' and cleanup.get('childrenReaped') is True, 'cleanup receipt differs')
            q.require(result.get('validationOnly') is False, 'normal route flag was not preserved')
        observation_after = time.time()
        return result, request
    def capture(label, refresh=False):
        nonlocal context, selected
        old = selected
        context, request = call('capture', label, {'replaceCaptureID': context['captureID'] if refresh else None})
        snapshot = context['snapshot']; selected = q.selection(snapshot, context)
        q.require(snapshot['processLifetime'] == target, 'current process texture identity mismatch')
        if old: q.require(selected['editToken'] != old['editToken'], 'stale token reused')
        textures = out / (label + '-textures'); textures.mkdir()
        for key, asset in snapshot['assets'].items():
            raw = asset.get('data') or asset.get('base64') or asset.get('dataBase64')
            if raw is None:
                raw = asset.get('content')
            q.require(isinstance(raw, str), 'PNG payload field unavailable: ' + str(asset.keys()))
            (textures / (key + '.png')).write_bytes(base64.b64decode(raw))
        observe(label, False, 1)
    def fields(prop, old, value):
        return {'captureID': context['captureID'], 'nodeToken': selected['editToken'],
                'expectedParentToken': selected['parentID'], 'expectedWindowToken': selected['windowToken'],
                'expectedClass': selected['className'], 'property': prop, 'expectedValue': old, 'value': value}
    def control(action):
        request = {'requestID': q.uid(), 'action': action, 'session': os.environ['MAC_CU_FIXTURE_WORKER'],
                   'pid': target['pid'], 'nodeGeneration': last_oracle['nodeGeneration'], 'issuedUnixSeconds': time.time()}
        s.save(docs / 'fault-control.json', request)
        receipt = wait(lambda: (lambda x: x if x and x.get('requestID') == request['requestID'] and (action != 'replace' or x.get('status') == 'deallocatedAndRecreated') else None)(
            json.loads((docs / 'edit-oracle.json').read_text()).get('controlReceipt')), check)
        s.save(out / (action + '-control.json'), {'request': request, 'receipt': receipt})
        return request, receipt
    try:
        capture('capture')
        if case in ('normal', 'swiftui'):
            for prop, old, value in [('hidden', False, True), ('alpha', 1.0, .5)]:
                applied, request = call('edit', prop, fields(prop, old, value))
                q.require(applied['mutationOutcome'] == 'appliedObserved' and applied['observed'] == value, 'missing actual readback')
                observe(prop, value if prop == 'hidden' else False, value if prop == 'alpha' else 1, int(prop == 'hidden'), int(prop == 'alpha'))
                if prop == 'hidden':
                    duplicate, _ = call('edit', 'replay', exact_request=request)
                    q.require(duplicate['operationID'] == applied['operationID'], 'cached replay receipt changed')
                    observe('replay', True, 1)
                reverted, _ = call('revert', prop + '-restore', {'captureID': context['captureID'], 'undoToken': applied['undoToken']})
                q.require(reverted['mutationOutcome'] == 'appliedObserved' and reverted['observed'] == old, 'missing revert readback')
                observe(prop + '-restore', False, 1, int(prop == 'hidden'), int(prop == 'alpha'))
            capture('refresh', refresh=True)
            call('release', 'release', {'captureID': context['captureID'], 'reason': 'close'})
            observe('release', False, 1)
            owner, inspection, sequence, context = q.uid(), q.uid(), 0, None
            capture('reopen')
            call('release', 'final-release', {'captureID': context['captureID'], 'reason': 'close'})
            observe('final-release', False, 1)
        elif case in ('weak', 'reparent', 'conflict'):
            if case != 'conflict':
                _, receipt = control('replace' if case == 'weak' else 'reparent')
                q.require(receipt['status'] == ('deallocatedAndRecreated' if case == 'weak' else 'reparented'), 'control incomplete')
            rejected, _ = call('edit', case, fields('hidden', case == 'conflict', True if case != 'conflict' else False), expect='conflict')
            q.require(rejected['setterEntered'] is False and rejected['mutationOutcome'] == 'notEntered', 'stale/conflict called setter')
            sample = json.loads((docs / 'edit-oracle.json').read_text())['samples'][-1]
            s.save(out / 'rejected-oracle.json', sample)
            q.require(sample['setterCounts'] == (json.loads((docs / 'edit-oracle.json').read_text())['constructionBaseline'] if case == 'weak' else last_oracle['setterCounts']), 'stale write changed setter count')
            call('release', 'rejection-release', {'captureID': context['captureID'], 'reason': 'close'})
        else:
            armed, _ = control('throwAfterWrite' if case == 'throw' else 'slowAfterWrite')
            changed, request = call('edit', case, fields('hidden', False, True),
                expect='outcomeUncertain' if case == 'throw' else 'cancelled', cancel_control=armed['requestID'] if case == 'cancel' else None)
            q.require(changed['mutationOutcome'] == ('uncertain' if case == 'throw' else 'enteredUnverified') and not changed.get('undoToken'), 'raw mutation semantics changed')
            observe('post-write', True, 1, 1, 0)
            events = json.loads((docs / 'fault-events.json').read_text())['events']
            s.save(out / 'post-write-events.json', events)
            terminal = changed['resident']
            sentinels = [e for e in events if e['requestID'] == armed['requestID'] and e['phase'] == 'sentinelDeallocated']
            q.require(len(sentinels) == 1 and terminal['workFinishedNS']/1e9 <= sentinels[0]['monotonicSeconds'] <= terminal['poolExitedNS']/1e9,
                      'native local pool did not drain setter sentinel')
            q.require(terminal['operationContexts'] == 0, 'native operation context remains')
            control('replace')
            final = json.loads((docs / 'edit-oracle.json').read_text())
            q.require(final['controlReceipt']['oldWeakNil'] is True, 'original node still retained')
            s.save(out / 'replacement-oracle.json', final)
            replay, _ = call('edit', 'uncertain-replay', exact_request=request,
                              expect='outcomeUncertain' if case == 'throw' else 'cancelled')
            q.require(replay['mutationOutcome'] == changed['mutationOutcome'], 'replay rewrote uncertainty')
            fresh = dict(request, operationID=q.uid(), sequence=sequence+1)
            blocked, _ = call('edit', 'new-id-refused', exact_request=fresh, expect='outcomeUncertain')
            q.require(blocked.get('neverDispatched') is True, 'quarantine admitted new dispatch')
        s.capture.verify_target(s.capture.ProcessProbe(), target)
        subprocess.run(['xcrun', 'simctl', 'io', device, 'screenshot', str(out / 'device.png')], check=True, timeout=8)
        return {'passed': True, 'case': case, 'normalRoute': True, 'bundleID': s.BUNDLE, 'operations': len(records), 'linksMacCU': False}
    finally:
        s.save(out / 'operations.json', records)
        key = hashlib.sha256(json.dumps(target, sort_keys=True, separators=(',', ':')).encode()).hexdigest()
        ledger = Path.home() / 'Library/Application Support/mac-cu/view-edit-ledger' / (key + '.json')
        if ledger.is_file(): shutil.copyfile(ledger, out / 'durable-ledger.json')


def main():
    if sys.argv[1:2] in (['--worker'], ['--worker-guard']):
        if len(sys.argv) != 10 or sys.argv[8] != '--case': return 64
        build, out, device, token, parent, deadline = sys.argv[2:8]
        if sys.argv[1] == '--worker-guard': return s.guard_worker(Path(out), float(deadline), token, int(parent))
        return s.worker(Path(build), Path(out), device, token, int(parent), float(deadline), experiment=functools.partial(run_case, case=sys.argv[9]))
    parser = argparse.ArgumentParser(allow_abbrev=False)
    parser.add_argument('--build', type=Path, required=True); parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--device', required=True); parser.add_argument('--deadline', required=True)
    parser.add_argument('--case', choices=['normal','weak','reparent','conflict','throw','cancel','swiftui'], required=True)
    parser.add_argument('--guard', action='store_true'); args = parser.parse_args()
    q.require_full_preparation(args.build)
    deadline, receipt = s.received_deadline(args.deadline, s.TOTAL)
    return s.parent(args.build, args.output, args.device, deadline, receipt, guard=args.guard,
                    worker_script=Path(__file__), worker_arguments=['--case', args.case], process_check=process_budget)

if __name__ == '__main__': raise SystemExit(main())
