"""Compile the actual owner wait; CLI doubles, no UI/target evidence."""
import importlib.util
import json
import os
import contextlib
from pathlib import Path
import subprocess
import tempfile
import unittest

class OwnerWait(unittest.TestCase):
    def test_actual_swift_wait_survives_cancellation_and_reports_unresolved(self):
        here=Path(__file__).resolve().parent
        source=(here/'live.swift').read_text()
        start=source.index('func inspectorOwnerMonotonic')
        end=source.index('@MainActor private var failureCustody',start)
        test='''
@main struct Check {
    @MainActor static func main() async {
        guard CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--native-check",
              getenv("MAC_CU_NATIVE_CHECK_CHILD") == nil else { exit(64) }
        setenv("MAC_CU_NATIVE_CHECK_CHILD", "1", 1)
        let ledgerURL = URL(fileURLWithPath: CommandLine.arguments[2])
        let realState = try! JSONSerialization.jsonObject(with: Data(contentsOf: ledgerURL)) as! [String: Any]
        let resultURL = ledgerURL.deletingLastPathComponent().appendingPathComponent("result.json")
        let original = try! JSONSerialization.jsonObject(with: Data(contentsOf: resultURL)) as! [String: Any]
        func save(_ result: [String: Any]) {
            try! JSONSerialization.data(withJSONObject: result).write(to: resultURL, options: .atomic)
        }
        // The state was serialized by actual Ledger.finish, which omits these fields.
        precondition(inspectorHostChildrenSettled(realState))
        for (key, value) in [("childrenReaped", false as Any), ("debuggerClosed", false as Any),
                             ("activeCall", "submission" as Any), ("custodyRequired", true as Any)] {
            var bad = original, cleanup = original["cleanup"] as! [String: Any]
            cleanup[key] = value; bad["cleanup"] = cleanup; save(bad)
            precondition(!inspectorHostChildrenSettled(realState))
        }
        for (key, value) in [("operationID", "other" as Any), ("requestDigest", "other" as Any),
                             ("ownerID", "other" as Any), ("inspectionID", "other" as Any),
                             ("target", [:] as [String: Any]), ("validationOnly", true as Any)] {
            var bad = original; bad[key] = value; save(bad)
            precondition(!inspectorHostChildrenSettled(realState))
        }
        try! FileManager.default.removeItem(at: resultURL)
        precondition(!inspectorHostChildrenSettled(realState))
        save(original)
        var reserved = realState, ops = reserved["operations"] as! [String: [String: Any]]
        ops["release"]!["state"] = "reserved"; reserved["operations"] = ops
        precondition(!inspectorHostChildrenSettled(reserved))
        precondition(inspectorHostChildrenSettled(realState))
        precondition(!inspectorHostChildrenSettled([:]))
        var running = true
        let started = Date()
        let waiter = Task { @MainActor in
            await waitForInspectorOwner(deadline: inspectorOwnerMonotonic() + 2) { !running }
        }
        waiter.cancel()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { running = false }
        let settled = await waiter.value
        precondition(settled && Date().timeIntervalSince(started) >= 0.19)
        let unresolved = await waitForInspectorOwner(deadline: inspectorOwnerMonotonic()) { false }
        precondition(!unresolved)
        let alreadySettled = await waitForInspectorOwner(deadline: inspectorOwnerMonotonic()) { true }
        precondition(alreadySettled)
        print("PASS actual wait with cancelled task and delayed headless custody double; unresolved retained")
    }
}
'''
        import sys
        sys.path.insert(0,str(here.parent))
        import native_check_support as safety
        evidence=Path(os.environ['MAC_CU_RECORDING_EVIDENCE']).parent if 'MAC_CU_RECORDING_EVIDENCE' in os.environ else Path('/private/tmp')
        evidence.mkdir(parents=True,exist_ok=True)
        with contextlib.nullcontext(tempfile.mkdtemp(prefix='mac-cu-recording-integration-owner-',dir=evidence)) as directory:
            out=Path(directory); swift=out/'check.swift';binary=out/'check'
            swift.write_text('import Foundation\nimport Darwin\n'+source[start:end]+test)
            subprocess.run(['swiftc','-parse-as-library',str(swift),'-o',str(binary)],check=True,timeout=60)
            ledger=out/'ledger.json'
            # Exact current production Ledger.finish output from synthetic prior state.
            import sys
            resources=here.parents[1]/'skills/mac-computer-use/scripts/view-capture'
            sys.path.insert(0,str(resources))
            import edit_backend
            target={'pid':123,'start':[100,1],'path':'/private/owned/Fixture','deviceID':'DEVICE'}
            request={'kind':'release','operationID':'release'}
            operation=object.__new__(edit_backend.Ledger);operation.request=request
            operation.state={'authority':'active','nodes':{},'undo':{},'operations':{'release':{'state':'reserved','digest':'digest','kind':'release','sequence':2}},'results':{},'target':target,'ownerID':'owner','inspectionID':'inspection','epoch':'epoch'}
            operation.save=lambda:None
            result={'status':'expired','operationID':'release','requestDigest':'digest','target':target,'ownerID':'owner','inspectionID':'inspection','targetEpoch':'epoch','validationOnly':False,'reasonCode':'registryMissing','mutationOutcome':'notEntered','setterEntered':False,'needsRefresh':True,'evidenceDirectory':str(out),'cleanup':{'childrenReaped':True,'debuggerClosed':True,'activeCall':None,'detach':'success','recovery':{'verified':True}}}
            operation.finish(result)
            self.assertNotIn('debuggerClosed',operation.state['results']['release']['cleanup'])
            (out/'result.json').write_text(json.dumps(result))
            ledger.write_text(json.dumps(operation.state))
            with (out/'owner-wait.log').open('w') as log:
                safety.check_routes(binary,dict(os.environ),log,production_helper=False)
                inherited=dict(os.environ,MAC_CU_NATIVE_CHECK_CHILD='1')
                self.assertEqual(safety.run_owned(binary,['--native-check',str(ledger)],environment=inherited,log=log,timeout=5,max_instances=1),64)
                self.assertEqual(safety.run_owned(binary,['--native-check',str(ledger)],environment=dict(os.environ),log=log,timeout=5,max_instances=1),0)
                self.assertFalse(safety.instances(binary))
            print(out,flush=True)
    def test_failure_path_keeps_failure_status_and_real_coordinator_join(self):
        here=Path(__file__).resolve().parent
        source=(here/'live.swift').read_text()
        self.assertIn('if let failureCustody, !(await failureCustody())',source)
        self.assertIn('lcd.inspectionHostWorkSettled',source)
        self.assertIn('exit(1)',source)
        self.assertIn('return // Keep NSApplication.run',source)
        self.assertNotIn('try? await Task.sleep',source)

class ParentWait(unittest.TestCase):
    def test_child_exit_or_explicit_unresolved_never_kills_or_replays(self):
        from unittest.mock import Mock, patch
        here=Path(__file__).resolve().parent
        spec=importlib.util.spec_from_file_location('owner_runner',here/'runner.py')
        runner=importlib.util.module_from_spec(spec);spec.loader.exec_module(runner)
        with tempfile.TemporaryDirectory() as directory:
            out=Path(directory); child=Mock();child.poll.side_effect=[None,None,1]
            with patch.object(runner.s,'monotonic',return_value=0),patch.object(runner.time,'sleep') as sleep:
                runner.wait_ui_cleanup(child,out,10)
                self.assertEqual(sleep.call_count,2)
            child.terminate.assert_not_called();child.kill.assert_not_called()
            (out/'ui-cleanup.json').write_text('{"state":"unresolved"}')
            child.poll.side_effect=None;child.poll.return_value=None
            with patch.object(runner.s,'monotonic',return_value=0),patch.object(runner.time,'sleep') as sleep:
                runner.wait_ui_cleanup(child,out,10);sleep.assert_not_called()
            child.terminate.assert_not_called()

    def test_real_headless_child_failure_is_reaped_after_settlement(self):
        import sys,time
        here=Path(__file__).resolve().parent
        spec=importlib.util.spec_from_file_location('real_owner_runner',here/'runner.py')
        runner=importlib.util.module_from_spec(spec);spec.loader.exec_module(runner)
        with tempfile.TemporaryDirectory() as directory:
            # CLI custody double, not a UI, Simulator fixture, or capture helper.
            child=subprocess.Popen([sys.executable,'-c','import time; time.sleep(.2); raise SystemExit(1)'],start_new_session=True)
            started=time.monotonic()
            try:
                runner.wait_ui_cleanup(child,Path(directory),runner.s.monotonic()+3)
                self.assertEqual(child.poll(),1)
                self.assertGreaterEqual(time.monotonic()-started,.19)
            finally:
                if child.poll() is None: child.kill()
                child.wait(timeout=2)
