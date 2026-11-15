"""Guarded two-case runner. Runtime entry requires a completed canonical native freeze."""
import argparse
import functools
import hashlib
import json
import os
from pathlib import Path
import shutil
import stat
import subprocess
import sys
import time
import uuid

HERE = Path(__file__).resolve().parent
FIXTURE = HERE.parent / 'view-hierarchy-fixture'
sys.dont_write_bytecode = True
sys.path[:0] = [str(HERE), str(FIXTURE)]
import protocol as p
import session as s
import debugger
import edit_qualification as q

# Same protected lifecycle with a finite, smaller-than-matrix session budget.
# 240s work, 235s cooperative cleanup reserve, 5s receipt. No deadline extension.
s.TOTAL, s.WORK, s.GRACE = 480, 240, 235
s.CAPTURE_ADMISSION = 195


def verify_preparation(prepared):
    value = json.loads((prepared / 'prepared.json').read_text())
    p.require(value['headlessPassed'] is True and value['guestExecuted'] is False, 'headless preparation incomplete')
    for name, digest in value['hashes'].items():
        p.require(hashlib.sha256(Path(name).read_bytes()).hexdigest() == digest, 'preparation input changed: ' + name)
    return value


def independent(path):
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    try:
        info = os.fstat(fd)
        p.require(stat.S_ISREG(info.st_mode) and info.st_uid == os.getuid() and info.st_nlink == 1 and
                  0 < info.st_size <= 262144, 'unsafe fixture oracle')
        data = os.read(fd, 262145)
        p.require(len(data) == info.st_size, 'oracle changed during read')
        return json.loads(data)
    finally:
        os.close(fd)


def process_budget(snapshot, group, target, build, server_path, details):
    if s.legacy_target_observation(snapshot, group, target, build, server_path, details, process_budget):
        return
    return _process_budget(snapshot, group, target, build, server_path, details)


def _process_budget(snapshot, group, target, build, server_path, details):
    """Exact executable budgets and direct parent topology; never signal authority."""
    members = s.watchdog.session_members(snapshot, group, str((build / 'session-probe').resolve()))
    if server_path is None:
        p.require(not members, 'headless guard worker created a child')
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
                entry['status'] = 'unknown'
                raise RuntimeError('cannot verify resident executable PID ' + str(row[0]))
            entry.update(status='live', identity=identity)
            p.require(identity['parent'] == row[1], 'process parent changed during executable readback')
            row = (*row[:3], identity['path'], row[4])
        resolved.append(row)
    members = resolved
    details['lastResidentProcessSample'] = members
    members = s.without_read_probe_helpers(members, details)
    p.require(sum(r[3] in python_paths for r in members) <= 1, 'resident Python executable budget exceeded')
    for executable in (probe, server):
        p.require(sum(r[3] == executable for r in members) <= 1, 'resident executable budget exceeded: ' + executable)
    if target is not None:
        p.require(sum(r[3] == target['path'] for r in snapshot) <= 1, 'exact fixture executable budget exceeded')
    probes = {r[0] for r in members if r[3] == probe}
    # These fixed tools support existing inventory/claim/probe/signature routes.
    # xcrun execs selected simctl; a probe may own one such read-only child.
    tool_paths = {'/usr/bin/xcrun', '/usr/bin/xcode-select', '/usr/bin/codesign', '/usr/bin/plutil', '/bin/ps'}
    developer = next(parent for parent in Path(server_path).parents if parent.name == 'Contents') / 'Developer'
    tool_paths.add(str(developer / 'usr/bin/simctl'))
    tool_paths.add('/Library/Developer/PrivateFrameworks/CoreSimulator.framework/Versions/A/Resources/bin/simctl')
    tools = [r for r in members if r[3] in tool_paths]
    p.require(len(tools) <= 1, 'serialized utility budget exceeded')
    for row in members:
        if row[3] in {*python_paths, probe, server}:
            p.require(row[1] == group, 'unexpected debugger/probe parent')
        else:
            p.require(row[3] in tool_paths and (row[1] in {group, *probes}
                      or s.watchdog.parent_context_pending(row[1], {probe})), 'unknown process or descendant in resident session')
    details['residentProcessBudgetSamples'] = details.get('residentProcessBudgetSamples', 0) + 1
    details['budget'] = 'parent1 worker1 fixture1 lldbWorker1 debugserver1 probe1; serialized utility/identity helper1 plus display-version child1; no supervisor process'


def wait(predicate, check, seconds=8):
    until = p.monotonic() + seconds
    while True:
        check()
        value = predicate()
        if value:
            return value
        p.require(p.monotonic() < until, 'observation pending/uncertain at deadline')
        time.sleep(.025)


def run_case(session, build, out, device, target, before, data, claim, input_guard, stopping, deadline, *, case, prepared):
    manifest = verify_preparation(prepared)
    selected_server, _, selected_sdk = s.capture.tools_for_xcode()
    p.require(str(selected_server) == manifest['debugserverPath'] and str(selected_sdk) == manifest['simulatorSDK'],
              'selected Xcode/Simulator SDK changed since preparation')
    p.require(hashlib.sha256(Path(target['path']).read_bytes()).digest() ==
              hashlib.sha256((build / 'HierarchyFixture.app/HierarchyFixture').read_bytes()).digest(),
              'installed fixture binary differs from final canonical build')
    s.reserve(deadline, 210, 'resident bootstrap, independent observations and fixture restoration')
    documents = Path(data) / 'Documents'
    folder = documents / 'resident-lifetime'
    folder.mkdir(mode=0o700)
    fd = p.directory(folder); os.close(fd)
    ledger = p.Admission(folder)
    armed_id = generation = None
    cancel_record = None
    report = {'case': case, 'passed': False, 'residentImageCount': 1, 'generalGatesEnabled': False}
    def check():
        nonlocal cancel_record
        claim.check(); input_guard.check()
        p.require(not stopping(), 'session cancelled; target completion must remain independent')
        s.reserve(deadline, s.CLEANUP_BUDGET, 'protected cleanup reserve')
        if case == 'B' and armed_id and ledger.digest and not ledger.revoked:
            events = independent(documents / 'fault-events.json')['events']
            entry = next((e for e in events if e['requestID'] == armed_id and e['nodeGeneration'] == generation
                          and e['phase'] == 'finiteDelayEntered'), None)
            if entry:
                cancel_record = ledger.cancel('finite setter entered; authority revoked without target interruption', entry)
                delay = cancel_record['monotonicNS'] / 1e9 - entry['monotonicSeconds']
                p.require(0 <= delay <= 1.0, 'post-entry host cancellation was not prompt')
                report['hostCancellation'] = cancel_record
    try:
        initial = independent(documents / 'edit-oracle.json')['samples'][-1]
        p.require(initial['pid'] == target['pid'] and initial['name'] == 'fixture.editTarget' and
                  initial['className'] == 'MacCUQualificationEditTarget' and initial['hidden'] is False and
                  initial['parentName'] == 'fixture.root' and initial['sceneActivationState'] == 0,
                  'independent initial fixture identity/state differs')
        generation = initial['nodeGeneration']; armed_id = str(uuid.uuid4()).upper()
        control = {'requestID': armed_id, 'action': 'throwAfterWrite' if case == 'A' else 'slowAfterWrite',
                   'session': os.environ['MAC_CU_FIXTURE_WORKER'], 'pid': target['pid'],
                   'nodeGeneration': generation, 'issuedUnixSeconds': time.time()}
        check(); s.save(documents / 'fault-control.json', control)
        def armed():
            value = independent(documents / 'edit-oracle.json')
            receipt = value.get('controlReceipt') or {}
            return receipt if receipt.get('requestID') == armed_id and receipt.get('status') == 'armed' else None
        report['armed'] = wait(armed, check)
        source_image = prepared / 'resident-simulator.dylib'
        image = folder / 'resident-simulator.dylib'
        # New private owned directory; O_EXCL avoids replacing any target resource.
        fd = os.open(image, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o700)
        try:
            with os.fdopen(fd, 'wb') as f:
                f.write(source_image.read_bytes()); f.flush(); os.fsync(f.fileno())
        except BaseException:
            raise
        p.require(hashlib.sha256(image.read_bytes()).hexdigest() == manifest['helperSHA256'], 'staged helper changed')
        subprocess.run(['/usr/bin/codesign', '--verify', '--strict', str(image)], check=True, timeout=5,
                       stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
        request = {'experiment': 'resident-lifetime-v1', 'operation': 'setHiddenTrue',
                   'ownerID': os.environ['MAC_CU_FIXTURE_WORKER'], 'operationID': armed_id, 'sequence': 1,
                   'target': target, 'expiresUnixMS': int(time.time() * 1000) + 120000,
                   'nodeGeneration': generation, 'hiddenCount': initial['setterCounts']['hidden'],
                   'sceneID': initial['sceneID'], 'parentName': initial['parentName'],
                   'image': str(image), 'imageUUID': manifest['helperUUID']}
        report.update(request=request, initial=initial, requestDigest=ledger.reserve(request))
        s.save(out / 'resident-case.json', report)
        bootstrap = debugger.supervise(request, folder, check)
        report['bootstrap'] = bootstrap
        def terminal():
            try:
                return json.loads(p.read(folder, 'terminal.json'))
            except FileNotFoundError:
                return None
        result = wait(terminal, check, 8)
        report['result'] = ledger.observe(result)
        p.require(result['setterEntered'] is True and result['poolExited'] is True and
                  result['operationContexts'] == 0 and result['mainThread'] is True and result['traced'] == 0 and
                  result['channelError'] is False,
                  'callback entry/context/pool proof missing')
        image_evidence = bootstrap['image']
        p.require(result['imageUUID'] == manifest['helperUUID'] and
                  image_evidence['textStart'] <= result['callbackPC'] < image_evidence['textEnd'], 'callback PC is not in pinned image')
        accepted = json.loads(p.read(folder, 'accepted.json'))
        entered = json.loads(p.read(folder, 'entered.json'))
        work = json.loads(p.read(folder, 'work-finished.json'))
        p.require(accepted['requestDigest'] == ledger.digest and
                  accepted['monotonicNS'] <= bootstrap['submitReturnedNS'] <= result['callbackNS'] <=
                  entered['monotonicNS'] <= work['monotonicNS'] == result['workFinishedNS'] <=
                  result['poolExitedNS'] <= result['publicationNS'], 'receipt/submit/callback/pool/publication order differs')
        p.require(result['outcome'] == ('uncertain' if case == 'A' else 'enteredUnverified') and
                  result['caught'] is (case == 'A') and result['undo'] is None, 'wrong finite fault outcome')
        if case == 'B':
            p.require(ledger.revoked and cancel_record is not None and result['cancelObserved'], 'post-entry cancellation not proved')
        # Observe post-write state BEFORE the independent replacement control removes it.
        observed_after = time.time()
        def post_write():
            value = independent(documents / 'edit-oracle.json')
            sample = value['samples'][-1]
            return value if sample['unixSeconds'] >= observed_after else None
        after = wait(post_write, check)
        sample = after['samples'][-1]
        p.require(sample['nodeGeneration'] == generation and sample['hidden'] is True and sample['alpha'] == initial['alpha'] and
                  sample['setterCounts'] == {'hidden': initial['setterCounts']['hidden'] + 1,
                                            'alpha': initial['setterCounts']['alpha']}, 'post-write value/exactly-one-setter oracle differs')
        events = independent(documents / 'fault-events.json')['events']
        selected = [e for e in events if e['requestID'] == armed_id and e['nodeGeneration'] == generation]
        phases = [e['phase'] for e in selected]
        for phase in ('hiddenSetterEntered', 'hiddenApplied', 'sentinelCreated', 'sentinelDeallocated'):
            p.require(phases.count(phase) == 1, 'independent event count differs: ' + phase)
        if case == 'B':
            p.require(phases.count('finiteDelayReturned') == 1 and phases.count('hiddenSetterReturned') == 1,
                      'cancelled finite setter did not return once')
        sentinel = next(e for e in selected if e['phase'] == 'sentinelDeallocated')
        p.require(result['workFinishedNS'] / 1e9 <= sentinel['monotonicSeconds'] <= result['poolExitedNS'] / 1e9,
                  'sentinel was not drained by the callback local pool')
        report['postWriteOracle'] = after; report['faultEvents'] = selected
        # Durable admission refusal only; no second load/submission or inspection authority.
        try:
            p.Admission(folder).reserve(request)
        except FileExistsError:
            report['replayAdmission'] = {'refused': True, 'debuggerChildrenCreated': 0, 'setterDispatches': 0}
        else:
            raise RuntimeError('durable replay reservation unexpectedly succeeded')
        replacement_id = str(uuid.uuid4()).upper()
        s.save(documents / 'fault-control.json', dict(control, requestID=replacement_id, action='replace', issuedUnixSeconds=time.time()))
        def replaced():
            receipt = independent(documents / 'edit-oracle.json').get('controlReceipt') or {}
            return receipt if receipt.get('requestID') == replacement_id and receipt.get('status') == 'deallocatedAndRecreated' else None
        report['weakClearing'] = wait(replaced, check)
        p.require(report['weakClearing']['oldWeakNil'] is True and report['weakClearing']['oldGeneration'] == generation,
                  'independent weak target clearing missing')
        final_events = independent(documents / 'fault-events.json')['events']
        p.require(sum(e['phase'] == 'targetDeallocated' and e['nodeGeneration'] == generation for e in final_events) == 1,
                  'original target did not independently deallocate once')
        report['targetAfter'] = s.capture.verify_target(s.capture.ProcessProbe(), target)
        observed = s.probe(build, out, 'resident-after', device)
        p.require(observed['frontPID'] == target['pid'] and observed['frontStart'] == target['start'] and
                  observed['frontPath'] == target['path'] and observed['hostPID'] == before['hostPID'], 'post-operation foreground lifetime changed')
        report.update(passed=True, responsiveEvidence='fresh main-timer oracle after publication plus independent replacement receipt',
                      operationContextsRemaining=0, residentImageCost=image_evidence, originalProcessUntraced=True)
        return report
    except BaseException as error:
        report['error'] = repr(error)
        if ledger.digest:
            if not ledger.revoked:
                try:
                    ledger.cancel('experiment stopped; pending/uncertain, no further admission')
                except BaseException as cancel_error:
                    report['cancelError'] = repr(cancel_error)
            # Never terminate a fixture whose callback completion/recovery is unknown.
            raise s.ProbeCleanupUnknown('resident experiment stopped; preserve target/claim: ' + repr(error)) from error
        raise
    finally:
        s.save(out / 'resident-case.json', report)
        # Evidence is copied before the protected session may remove its own data.
        for name in ('request.bin', 'cancel', 'accepted.json', 'entered.json', 'work-finished.json', 'terminal.json',
                     'reservation.json', 'authority.json', 'bootstrap.json', 'debugger-result.json', 'loaded-image.json',
                     'load-attempt.json', 'submission-attempt.json', 'debugger.log'):
            source = folder / name
            if source.is_file() and not source.is_symlink() and source.stat().st_size <= 262144:
                shutil.copyfile(source, out / ('resident-' + name))


def main():
    if sys.argv[1:2] in (['--worker'], ['--worker-guard']):
        if len(sys.argv) != 12 or sys.argv[8] != '--case' or sys.argv[9] not in ('A', 'B') or sys.argv[10] != '--prepared':
            return 64
        build, out, device, token, parent, deadline = sys.argv[2:8]
        prepared = Path(sys.argv[11]); verify_preparation(prepared)
        if sys.argv[1] == '--worker-guard':
            return s.guard_worker(Path(out), float(deadline), token, int(parent))
        q.require_full_preparation(Path(build))
        action = functools.partial(run_case, case=sys.argv[9], prepared=prepared)
        return s.worker(Path(build), Path(out), device, token, int(parent), float(deadline), experiment=action)
    parser = argparse.ArgumentParser(description=__doc__, allow_abbrev=False)
    parser.add_argument('--prepared', type=Path, required=True)
    parser.add_argument('--build', type=Path)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--device', required=True)
    parser.add_argument('--deadline', required=True)
    parser.add_argument('--case', choices=('A', 'B'), required=True)
    parser.add_argument('--guard', action='store_true')
    args = parser.parse_args()
    prepared = args.prepared.resolve(); verify_preparation(prepared)
    build = args.build.resolve() if args.build else prepared / 'guard-build'
    if not args.guard:
        p.require(args.build is not None, 'runtime requires final canonical whole-host native freeze via --build')
        q.require_full_preparation(build); q.require_lldb_python(s.capture)
    deadline, receipt = s.received_deadline(args.deadline, s.TOTAL)
    return s.parent(build, args.output.resolve(), str(uuid.UUID(args.device)).upper(), deadline, receipt, args.guard,
                    worker_script=HERE / 'runner.py', worker_arguments=['--case', args.case, '--prepared', str(prepared)],
                    process_check=process_budget)


if __name__ == '__main__':
    raise SystemExit(main())
