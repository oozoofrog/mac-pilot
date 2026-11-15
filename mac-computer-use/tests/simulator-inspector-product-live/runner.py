"""Sole-runtime-owner entry. --guard is headless; --live requires explicit authorization."""
import argparse
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import time
sys.dont_write_bytecode = True
HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import evidence
spec = importlib.util.spec_from_file_location('product_runner', HERE.parent / 'view-resident-product/runner.py')
product = importlib.util.module_from_spec(spec); spec.loader.exec_module(product)
s, q = product.s, product.q
s.TOTAL, s.WORK, s.GRACE, s.CAPTURE_ADMISSION = 1500, 1260, 235, 195
UI_BUILD = None
RECORDING_TRANSITION = False

def process_budget(snapshot, group, target, build, server_path, details):
    if server_path is None:
        return product.process_budget(snapshot, group, target, build, server_path, details)
    observation = s.watchdog._observation.get()
    q.require(observation is not None, 'UI budget requires native observation')
    contract = observation.ui_contract
    q.require(contract is not None, 'UI contract was not bound before observation')
    members = s.watchdog.session_members(snapshot, group, str((build / 'session-probe').resolve()))
    ui = [r for r in members if r[3] == contract['binary']]
    probe = [r for r in members if r[3] == str((build / 'session-probe').resolve())]
    q.require(len(ui) + len(probe) <= 1, 'combined exact UI/probe budget exceeded')
    if not ui:
        return product.process_budget(snapshot, group, target, build, server_path, details)
    q.require(ui[0][1:3] == (group, group), 'UI direct worker parent/group differs')
    remaining = s.without_read_probe_helpers(members, details)
    remaining = [r for r in remaining if r[0] != ui[0][0]]
    # Native observer verifies every UI child argv/role and group. Only the
    # worker's existing serial inventory utility/monitor remains outside it.
    tools = s.probe_tool_paths(server_path)
    q.require(len(remaining) <= 1 and all(r[1] == group and r[2] == group and r[3] in tools for r in remaining),
              'unknown worker child or utility budget exceeded')
    details['uiBudget'] = 'UI1 OR probe1; display2 (family total6), identity1, capture/preparationSupervisor1, captureWorker1, debugger1, screenshot1, captureUtility1 (family total5), workerUtility1'

def wait_ui_cleanup(child, out, deadline):
    """Keep this parent alive while the real UI owner settles; never replay release."""
    if child is not None:
        while child.poll() is None and s.monotonic() < deadline:
            cleanup = out / 'ui-cleanup.json'
            if cleanup.exists():
                try:
                    if json.loads(cleanup.read_text()).get('state') == 'unresolved': break
                except (OSError, ValueError): pass
            time.sleep(.025)


def experiment(session, build, out, device, target, before, data, claim, guard, stopping, deadline):
    session.verify_prepared(UI_BUILD)
    binary = UI_BUILD / 'InspectorProductCheck.app/Contents/MacOS/check'
    request = dict(target, focusedRemainder=("swiftui" if json.loads((build / "prepared.json").read_text())["ordinaryProductApp"]["entry"] == "SwiftUI.App" else "pendingOnly"), recordingTransition=RECORDING_TRANSITION, fixtureSession=os.environ["MAC_CU_FIXTURE_WORKER"], documents=str(Path(data) / 'Documents'), hostPID=before['hostPID'],
                   ownerDeadlineMonotonic=min(s.monotonic() + 1100, deadline - s.CLEANUP_BUDGET), output=str(out), ledger=str(evidence.ledger_path(target)))
    s.save(out / 'ui-request.json', request)
    recording_worker = None
    if RECORDING_TRANSITION:
        import recording_owner
        def check_recording():
            guard.input_guard.check()
            q.require(not stopping(), 'cancelled recording admission')
        recording_worker = recording_owner.Worker(session, out, target, data, claim,
                                                  request['ownerDeadlineMonotonic'], check_recording)
        claim.recording = recording_worker
    env = {k:v for k,v in os.environ.items() if not k.startswith(('MAC_CU_', 'DYLD_', 'PYTHON', 'FIXTURE_'))}
    env['INSPECTOR_PRODUCT_REQUEST'] = str(out / 'ui-request.json')
    # NSWorkspace caches activation notifications. This CLI worker has no AppKit
    # event loop, so service its read-only run loop before every focus read.
    import ctypes as c
    cf = c.CDLL('/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation')
    mode = c.c_void_p.in_dll(cf, 'kCFRunLoopDefaultMode')
    cf.CFRunLoopRunInMode.argtypes = [c.c_void_p, c.c_double, c.c_bool]
    cf.CFRunLoopRunInMode.restype = c.c_int32
    original_focus = guard.read_focus
    def fresh_focus():
        cf.CFRunLoopRunInMode(mode, .001, False)
        return original_focus()
    guard.read_focus = fresh_focus
    child = None
    try:
        claim.check(); guard.check(); s.reserve(deadline, 1100 + s.CLEANUP_BUDGET, 'UI sequence and cleanup')
        with (out / 'ui.log').open('w') as log:
            child = subprocess.Popen([str(binary), '--native-check'], env=env, stdout=log, stderr=subprocess.STDOUT)
            acquired = False; launch = s.monotonic()
            while child.poll() is None:
                claim.check(); guard.input_guard.check()
                q.require(not stopping(), 'cancelled; stop new UI admission')
                focus = guard.read_focus()
                if focus == child.pid: acquired = True
                s.save(out / 'last-ui-focus.json', dict(actual=focus, expected=child.pid, original=before['hostPID'], acquired=acquired, elapsed=s.monotonic()-launch))
                q.require(focus == child.pid or (not acquired and s.monotonic() - launch < 3 and focus == before['hostPID'])
                          or (((out / 'ui-result.json').exists() or (out / 'ui-cleanup.json').exists()) and focus == before['hostPID']), 'UI focus lost; no reacquisition')
                s.reserve(deadline, s.CLEANUP_BUDGET, 'cleanup reserve')
                q.require(s.monotonic() - launch < 1100, 'UI watchdog deadline')
                if recording_worker: recording_worker.tick()
                time.sleep(.025)
            child.wait(timeout=1)
        targets = [target]
        if recording_worker:
            targets.append(recording_worker.admitted()['target'])
        operations = evidence.collect_lifetimes(targets, out)
        q.require(child.returncode == 0, 'UI workflow failed: ' + str(out / 'ui.log'))
        result = json.loads((out / 'ui-result.json').read_text())
        q.require(result['passed'], 'UI assertions failed')
        guard.check()
        return dict(passed=True, method='local AppKit controls; actual rendered windows; no physical pointer/human approval', joinedOperations=len(operations))
    except BaseException as error:
        (out / 'stop-ui').touch()
        if recording_worker:
            try: recording_worker.cancel_before_dispatch()
            except Exception as cancellation_error:
                s.save(out / 'recording-cancel-error.json', dict(error=repr(cancellation_error)))
        # Allow the actual UI owner to drain already-started coordinator work.
        # No new release, target call, focus acquisition, or deadline extension.
        wait_ui_cleanup(child, out, deadline - s.CLEANUP_BUDGET)
        if recording_worker:
            cancel_deadline = min(s.monotonic() + 5, deadline - s.CLEANUP_BUDGET)
            try:
                while s.monotonic() < cancel_deadline and recording_worker.arm is not None and recording_worker.arm.state in ('arming','armed','cancelling'):
                    if recording_worker.cancel_before_dispatch(): break
                    time.sleep(.025)
            except Exception as cancellation_error:
                s.save(out / 'recording-cancel-drain-error.json', dict(error=repr(cancellation_error)))
            if child is not None and child.poll() is not None and (recording_worker.arm is None or recording_worker.arm.state == 'cancelled'):
                try: recording_worker.cleanup_binding()
                except Exception: pass  # Unproven release/quiescence retains custody below.
                else: raise RuntimeError('UI failed before recording dispatch; exact original cleanup verified: ' + repr(error)) from error
        # No target termination authority until exact release receipt and UI exit.
        # Shared session catches this type and preserves app/data/device claim.
        raise s.ProbeCleanupUnknown('UI/custody incomplete; preserve target and claim: ' + repr(error)) from error

def main():
    global UI_BUILD
    if sys.argv[1:2] in (['--worker'], ['--worker-guard']):
        if len(sys.argv) != 10 or sys.argv[8] != '--ui-build': return 64
        build, out, device, token, parent, deadline = sys.argv[2:8]
        UI_BUILD = Path(sys.argv[9])
        s.bind_ui_process_contract(UI_BUILD, Path(build), device, Path(out))
        if sys.argv[1] == '--worker-guard': return s.guard_worker(Path(out), float(deadline), token, int(parent))
        return s.worker(Path(build), Path(out), device, token, int(parent), float(deadline), experiment=experiment)
    p = argparse.ArgumentParser(allow_abbrev=False)
    for name in ('build', 'ui-build', 'output'): p.add_argument('--' + name, required=True, type=Path)
    p.add_argument('--device', required=True); p.add_argument('--deadline', required=True)
    mode = p.add_mutually_exclusive_group(required=True); mode.add_argument('--guard', action='store_true'); mode.add_argument('--live', action='store_true')
    a = p.parse_args(); UI_BUILD = a.ui_build.resolve()
    s.bind_ui_process_contract(UI_BUILD, a.build, a.device, a.output)
    s.verify_prepared(UI_BUILD); q.require_full_preparation(a.build)
    q.require(json.loads((UI_BUILD / 'prepared.json').read_text())['product'] == str(a.build.resolve()), 'UI/product preparation mismatch')
    if a.live: q.require_lldb_python(s.capture)
    deadline, receipt = s.received_deadline(a.deadline, s.TOTAL)
    return s.parent(a.build, a.output, a.device, deadline, receipt, guard=a.guard, worker_script=Path(__file__),
                    worker_arguments=['--ui-build', str(UI_BUILD)], process_check=process_budget)

if __name__ == '__main__': raise SystemExit(main())
