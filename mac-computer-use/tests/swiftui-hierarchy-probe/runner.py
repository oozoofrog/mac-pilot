"""고정 device의 소유 fixture에서 외부 그래프와 A/B 픽셀을 수집한다."""
import argparse
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
sys.path[:0] = [str(HERE), str(HERE.parent / 'view-hierarchy-fixture')]
import protocol as p
import graph
import debugger
import worker_runtime
import session as s
import edit_qualification as q
s.TOTAL, s.WORK, s.GRACE = 660, 420, 235
s.CAPTURE_ADMISSION = 195
DEBUG_RECORDING = False
ORIGINAL_LAUNCH_ARGUMENTS = s.fixture_launch_arguments
ORIGINAL_WAIT_FOR_ORACLE = s.wait_for_oracle
READINESS_OUTPUT = None


def observed_wait_for_oracle(oracle, process_probe, target, stopping):
    try:
        return ORIGINAL_WAIT_FOR_ORACLE(oracle, process_probe, target, stopping)
    except TimeoutError:
        # Preserve the same eight-second readiness gate. Read-only failure evidence
        # is collected only after exact target/claim and cancellation checks.
        if READINESS_OUTPUT and not stopping():
            try:
                s.capture.verify_target(process_probe, target)
                p.require(json.loads(s.CLAIMS.read_text())[target['deviceID']]['by'] == os.environ['MAC_CU_FIXTURE_WORKER'], 'claim changed')
                with (READINESS_OUTPUT / 'readiness-screenshot.log').open('w') as log:
                    subprocess.run(['xcrun', 'simctl', 'io', target['deviceID'], 'screenshot',
                        str(READINESS_OUTPUT / 'readiness-timeout.png')], stdout=log, stderr=subprocess.STDOUT, check=True, timeout=8)
            except BaseException as error:
                s.save(READINESS_OUTPUT / 'readiness-evidence-error.json', {'error': repr(error)})
        raise


s.wait_for_oracle = observed_wait_for_oracle


def select_variant(recording, baseline=None):
    global DEBUG_RECORDING
    DEBUG_RECORDING = recording
    if recording:
        p.require(baseline is not None, 'recording variant requires completed no-flag baseline')
        baseline = Path(baseline)
        status = json.loads((baseline / 'session.json').read_text())
        parent = json.loads((baseline / 'parent.json').read_text())
        capture = status['experiment']['captures'][0]
        p.require(not status['errors'] and status['fixtureRemoved'] and status['restorationVerified'] and status['claimReleased']
                  and parent['group']['groupEmpty'] and not parent.get('error') and not parent.get('cleanupError'),
                  'baseline custody/cleanup is incomplete')
        p.require(capture['independentBefore']['graphDebugLaunchFlag'] is None and capture['independentBefore']['graphOracleCalls'] == 0
                  and capture['graphAssessment']['status'] == capture['directGraphAssessment']['status'] == 'emptyArray',
                  'flag comparison requires actual empty no-flag baseline')
        for name in ('external-graph.json', 'direct-makeViewDebugData.json'):
            p.require(graph.classify((baseline / 'artifacts/capture-1' / name).read_bytes())['status'] == 'emptyArray',
                      'baseline raw bytes differ')
    def launch(device, token):
        original = ORIGINAL_LAUNCH_ARGUMENTS(device, token)
        # Fixed simctl child variable for this one disposable process only.
        return ['/usr/bin/env', 'SIMCTL_CHILD_SWIFTUI_VIEW_DEBUG=287', *original] if recording else original
    s.fixture_launch_arguments = launch

def process_budget(snapshot, group, target, build, server_path, details, observation=None):
    if s.legacy_target_observation(snapshot, group, target, build, server_path, details, process_budget):
        return
    if s.watchdog._observation.get() is not None:
        return _process_budget(snapshot, group, target, build, server_path, details)
    events = details.setdefault('residentExecutableObservations', [])
    if observation is None:
        observation = s.watchdog.ProcessObservation(s.monotonic, events=events,
            **s.probe_family_options(build, server_path))
        # A legacy caller's snapshot has no clock provenance. Retain its PIDs
        # as unresolved seeds, but obtain a fresh ps inside this cutoff.
        observation.samples.update({r[0]: r for r in (snapshot or []) if r[2] == group and r[0] != group})
        snapshot = None
    observation.complete(group, lambda fresh: _process_budget(fresh, group, target, build, server_path, details), initial=snapshot)


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
    tool_paths = {'/usr/bin/env', '/usr/bin/xcrun', '/usr/bin/xcode-select', '/usr/bin/xcodebuild', '/usr/bin/codesign', '/usr/bin/plutil', '/bin/ps'}
    developer = next(parent for parent in Path(server_path).parents if parent.name == 'Contents') / 'Developer'
    tool_paths.add(str(developer / 'usr/bin/simctl'))
    tool_paths.add(str(developer / 'usr/bin/xcodebuild'))
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


def configure(build, bound_worker=False):
    ready = json.loads((build / 'prepared.json').read_text())
    if ready.get('dispatchPassed') is False:
        s.verify_prepared(build)  # 기존 compile-only 거절 진단을 유지한다.
    proof = ready.get('swiftUIProbe', {}).get('workerRuntime')
    worker_runtime.verify(proof, bound_worker=bound_worker)
    s.verify_prepared(build)
    debugger.RUNTIME_PROOF = proof
    s.BUNDLE = ready['swiftUIProbe']['bundleID']
    s.APP_NAME, s.EXECUTABLE = 'SwiftUIProbe.app', 'SwiftUIProbe'
    return ready['swiftUIProbe']


def wait(predicate, check, seconds=10):
    end = s.monotonic() + seconds
    while True:
        check(); value = predicate()
        if value: return value
        p.require(s.monotonic() < end, 'bounded observation incomplete')
        time.sleep(.04)


def run_case(session, build, out, device, target, before, data, claim, guard, stopping, deadline):
    manifest = configure(build)
    docs = Path(data) / 'Documents'
    folder = docs / 'swiftui-hierarchy-probe'; folder.mkdir(mode=0o700)
    report = {'passed': False, 'acceptance': 'pending offline graph/pixel assessment', 'captures': [],
              'variant': 'fresh-owned-launch-SWIFTUI_VIEW_DEBUG=287' if DEBUG_RECORDING else 'no-flag-baseline'}
    image = folder / 'resident-simulator.dylib'
    source = Path(manifest['helper'])
    p.require(hashlib.sha256(Path(target['path']).read_bytes()).hexdigest() == manifest['appSHA256'], 'installed app differs')
    with image.open('xb') as f: f.write(source.read_bytes())
    os.chmod(image, 0o700)
    p.require(hashlib.sha256(image.read_bytes()).hexdigest() == manifest['helperSHA256'], 'helper staging differs')
    pin = dict(target=target, path=str(image), sha256=manifest['helperSHA256'], uuid=manifest['helperUUID'], retainedForLifetime=True)
    s.save(folder / 'image-pin.json', pin)
    current = None; submitted = False; completed = False
    def check():
        claim.check(); guard.check()
        p.require(not stopping(), 'session stopped; no further admission')
        s.reserve(deadline, s.CLEANUP_BUDGET, 'protected cleanup reserve')
    def oracle(): return json.loads((docs / 'edit-oracle.json').read_text())
    def take(index):
        nonlocal current, submitted, completed
        check(); s.reserve(deadline, 90 + s.CLEANUP_BUDGET, 'capture and recovery')
        initial = oracle()
        p.require(initial['graphOracleCalls'] == 0, 'app graph instrumentation invalidates external evidence')
        p.require(initial['graphDebugLaunchFlag'] == ('287' if DEBUG_RECORDING else None), 'launch flag differs from fixed variant')
        channel = folder / ('capture-' + str(index)); channel.mkdir(mode=0o700)
        operation = str(uuid.uuid4()).upper()
        request = dict(experiment='swiftui-hierarchy-v1', operation='readSwiftUIGraphAndPixels',
            ownerID=os.environ['MAC_CU_FIXTURE_WORKER'], operationID=operation, sequence=index,
            target=target, expiresUnixMS=int(time.time() * 1000) + 120000, nodeGeneration=str(uuid.uuid4()).upper(),
            hiddenCount=0, sceneID=initial['sceneID'], parentName='fixture.root', image=str(image), imageUUID=manifest['helperUUID'])
        current = p.Admission(channel); current.reserve(request)
        row = dict(request=request, independentBefore=initial, sourceAndImagePin=pin)
        report['captures'].append(row)
        s.save(channel / 'oracle-before.json', initial)
        submitted = True; completed = False
        bootstrap = debugger.supervise(request, channel, check); row['bootstrap'] = bootstrap
        terminal = wait(lambda: json.loads((channel / 'terminal.json').read_text()) if (channel / 'terminal.json').exists() else None, check)
        row['terminal'] = current.observe(terminal)
        p.require(terminal['poolExited'] and terminal['operationContexts'] == 0 and terminal['traced'] == 0
                  and terminal['mainThread'] and not terminal['caught'] and not terminal['channelError'], 'callback/pool incomplete')
        p.require(terminal['imageUUID'] == manifest['helperUUID'] and
                  bootstrap['image']['textStart'] <= terminal['callbackPC'] < bootstrap['image']['textEnd'], 'callback not pinned')
        p.require(bootstrap['submitReturnedNS'] <= terminal['callbackNS'] <= terminal['workFinishedNS'] <=
                  terminal['poolExitedNS'] <= terminal['publicationNS'], 'callback completion order differs')
        if terminal['captureEntered']:
            sentinel = json.loads((channel / 'pool-sentinel-deallocated.json').read_text())
            p.require(sentinel['remaining'] == 0 and terminal['workFinishedNS'] <= sentinel['monotonicNS'] <= terminal['poolExitedNS'], 'local pool sentinel not released')
        s.capture.verify_target(s.capture.ProcessProbe(), target)
        after = wait(lambda: (lambda sample: sample if sample['sequence'] > initial['sequence'] and
            sample['unixSeconds'] > time.time() - 0.5 else None)(oracle()), check)
        s.save(channel / 'oracle-after.json', after)
        row['independentAfter'] = after
        completed = True
        check()
        subprocess.run(['xcrun', 'simctl', 'io', device, 'screenshot', str(channel / 'independent-screen.png')], check=True, timeout=8)
        row['sameTargetResponsiveUntraced'] = True
        try: p.Admission(channel).reserve(request)
        except FileExistsError: row['replayRefusedBeforeDebugger'] = True
        else: raise RuntimeError('replay was admitted')
        row['stageReceipts'] = graph.receipts(channel)
        graph_path = channel / 'external-graph.json'
        row['graphAssessment'] = graph.assess(channel, 'typed', 'external-graph.json')
        direct = channel / 'direct-makeViewDebugData.json'
        row['directGraphAssessment'] = graph.assess(channel, 'direct', 'direct-makeViewDebugData.json')
        s.save(channel / 'graph-assessment.json', {'typed': row['graphAssessment'], 'direct': row['directGraphAssessment']})
        return row
    try:
        first = take(1)
        if first['terminal']['targetResult']['outcome'] == 'captured' and first['graphAssessment']['status'] == 'rootArray':
            check(); request = dict(action='alternate', session=os.environ['MAC_CU_FIXTURE_WORKER'], pid=target['pid'],
                                   requestID=str(uuid.uuid4()), issuedUnixSeconds=time.time())
            s.save(docs / 'branch-control.json', request)
            changed = wait(lambda: (lambda o: o if o['branch'] == 'delta' and o['controlReceipt'].get('requestID') == request['requestID'] else None)(oracle()), check)
            # Wait for a later ordinary main timer tick to settle layout without pumping the run loop.
            wait(lambda: oracle()['sequence'] >= changed['sequence'] + 3, check)
            report['branchControl'] = dict(request=request, receipt=changed)
            second = take(2)
            report['captureIdentity'] = dict(expired=first['request']['operationID'], current=second['request']['operationID'],
                oldHostingTokenExpired=first['request']['nodeGeneration'], newHostingToken=second['request']['nodeGeneration'], editableProperties=[])
            p.require(first['request']['operationID'] != second['request']['operationID'] and second['bootstrap']['image']['loadCount'] == 0,
                      'capture identity reused or helper reloaded')
        report['targetAfter'] = s.capture.verify_target(s.capture.ProcessProbe(), target)
        observed = s.probe(build, out, 'probe-after', device)
        p.require(observed['frontPID'] == target['pid'] and observed['frontStart'] == target['start'] and observed['frontPath'] == target['path']
                  and observed['hostPID'] == before['hostPID'], 'target/foreground changed')
        # Raw collection alone cannot satisfy the session's qualification flag.
        # Actual graph/schema and fixed ROI/frame review must supply acceptance.
        report['transactionCompleted'] = True
        report['passed'] = False
        return report
    except BaseException as error:
        report['error'] = repr(error)
        if submitted and not completed:
            if current and not current.revoked:
                try: current.cancel('uncertain completion; no next operation')
                except BaseException as cancel_error: report['cancelError'] = repr(cancel_error)
            raise s.ProbeCleanupUnknown('resident completion uncertain; preserve owned target and claim: ' + repr(error)) from error
        raise
    finally:
        s.save(out / 'experiment.json', report)
        if folder.exists(): shutil.copytree(folder, out / 'artifacts', ignore=shutil.ignore_patterns('resident-simulator.dylib'))
        for name in ('edit-oracle.json', 'geometry-oracle.json', 'branch-control.json'):
            if (docs / name).exists(): shutil.copyfile(docs / name, out / name)


def main():
    global READINESS_OUTPUT
    if sys.argv[1:2] in (['--worker'], ['--worker-guard']):
        if len(sys.argv) not in (8, 10) or (len(sys.argv) == 10 and sys.argv[8] != '--recording-baseline'): return 64
        build, out, device, token, parent, deadline = sys.argv[2:8]
        READINESS_OUTPUT = Path(out)
        select_variant(len(sys.argv) == 10, sys.argv[9] if len(sys.argv) == 10 else None)
        configure(Path(build), bound_worker=True)
        if sys.argv[1] == '--worker-guard': return s.guard_worker(Path(out), float(deadline), token, int(parent))
        q.require_full_preparation(Path(build))
        return s.worker(Path(build), Path(out), device, token, int(parent), float(deadline), experiment=run_case)
    parser = argparse.ArgumentParser(allow_abbrev=False)
    parser.add_argument('--build', type=Path, required=True); parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--device', required=True); parser.add_argument('--deadline', required=True)
    parser.add_argument('--guard', action='store_true')
    parser.add_argument('--recording-baseline', type=Path, help='Completed empty no-flag baseline; enables fixed fresh-launch 287 variant')
    args = parser.parse_args()
    select_variant(args.recording_baseline is not None, args.recording_baseline)
    configure(args.build); q.require_full_preparation(args.build)
    p.require(args.device == '64A62D96-12FE-4D9C-81AE-ED9C3A2174F0', 'fixed ordinary device only')
    end, receipt = s.received_deadline(args.deadline, s.TOTAL)
    return s.parent(args.build, args.output, args.device, end, receipt, args.guard,
                    worker_script=HERE / 'runner.py', process_check=process_budget,
                    worker_arguments=['--recording-baseline', str(args.recording_baseline)] if args.recording_baseline else [])

if __name__ == '__main__': raise SystemExit(main())
