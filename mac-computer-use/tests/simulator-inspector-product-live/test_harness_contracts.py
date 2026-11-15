"""Actual capture receipt/converter and dispatch regressions; no UI or guest access."""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import textwrap
import unittest
import uuid


class HarnessContracts(unittest.TestCase):
    def test_actual_compact_receipt_and_background_dispatch(self):
        here = Path(__file__).resolve().parent
        resources = here.parents[1] / 'skills/mac-computer-use/scripts'
        sys.path.insert(0, str(resources / 'view-capture'))
        sys.path.insert(0, str(here.parent))
        import edit_backend
        import native_check_support as safety
        out = Path(tempfile.mkdtemp(prefix='mac-cu-harness-contract-')).resolve()
        source = (here / 'live.swift').read_text()
        helper = source[source.index('func inspectorCaptureEnvelope'):source.index('func runInspectorProductLive')]
        start = source.index('    func background<T>')
        dispatch = textwrap.dedent(source[start:source.index('    let (device, active)', start)])
        current_scope = next(line.strip() for line in source.splitlines() if 'let currentScope =' in line)
        native = resources / 'mac-cu-src'
        capture, token, owner, inspection, epoch = [str(uuid.uuid4()).upper() for _ in range(5)]
        target = dict(pid=42, start=[100, 1], path='/private/synthetic/Fixture', deviceID='synthetic')
        scope = dict(deviceID='synthetic', bootIdentity='boot:1', displayID='main',
                     presentation='main|rot0', generation=1, runtime='synthetic|build')
        node = dict(id=token, editToken=token, className='SyntheticHost', parentToken=None,
                    windowToken=token, sceneID='scene', hidden=False, alpha=1.0, siblingIndex=0)
        graph = [dict(id=f'swiftui:{capture}:{token}:0', parentID=None, childOrdinal=0,
                      properties=[dict(id=0, attribute=dict(readableType='SwiftUI.Text'))])]
        host = dict(hostingNodeID=token, sceneID='scene', status='available', reason=None,
                    graphStatus='rootArray', nodes=graph,
                    rendering=dict(status='unavailable', representation='hostingSubtreeComposite',
                                   reason='headless fixture', assetID=None, drawHierarchyReturned=None))
        result = dict(status='success', operationID='capture', requestDigest='digest',
                      captureID=capture, captureTime='2026-11-10T00:00:00Z', target=target,
                      ownerID=owner, inspectionID=inspection, targetEpoch=epoch,
                      validationOnly=False, evidenceDirectory=str(out),
                      editing=dict(registryState='active', expiresAt=1.0, ownerID=owner,
                                   inspectionID=inspection, targetEpoch=epoch), editableNodes=[node],
                      cleanup=dict(childrenReaped=True, detach='success', recovery=dict(verified=True)),
                      swiftUI=dict(schemaVersion=1, captureID=capture, inspectionScope=scope, hosts=[host]),
                      inspectionScope=scope)
        ledger = object.__new__(edit_backend.Ledger)
        ledger.request = dict(kind='capture', operationID='capture')
        ledger.state = dict(authority='active', nodes={}, undo={}, operations={
            'capture': dict(state='reserved', digest='digest', kind='capture', sequence=1)},
            results={}, target=target, ownerID=owner, inspectionID=inspection, epoch=epoch)
        ledger.save = lambda: None
        ledger.finish(result)
        self.assertEqual(ledger.state['results']['capture']['status'], 'resultUnavailable')
        self.assertNotIn('snapshot', ledger.state['results']['capture'])
        (out / 'result.json').write_text(json.dumps(result))
        (out / 'ledger.json').write_text(json.dumps(ledger.state))
        main = r'''
import Foundation
import Darwin
struct ToolError: Error { let message: String; init(_ message: String) { self.message = message } }
let handleQueue = DispatchQueue(label: "headless-inspector-contract")
enum SimulatorInspectionHost {
    static func prepare(device: NSObject, screen: Int?) throws -> String {
        guard !Thread.isMainThread else { throw ToolError("Inspection identity requires background dispatch.") }
        return "background"
    }
}
DISPATCH
guard CommandLine.arguments == [CommandLine.arguments[0], "--native-check"],
      getenv("MAC_CU_NATIVE_CHECK_CHILD") == nil else { exit(64) }
let folder = URL(fileURLWithPath: ProcessInfo.processInfo.environment["INSPECTOR_CONTRACT_FOLDER"]!)
let state = try JSONSerialization.jsonObject(with: Data(contentsOf: folder.appendingPathComponent("ledger.json"))) as! [String: Any]
let resultURL = folder.appendingPathComponent("result.json")
let original = try JSONSerialization.jsonObject(with: Data(contentsOf: resultURL)) as! [String: Any]
let captureID = original["captureID"] as! String
func save(_ value: [String: Any]) { try! JSONSerialization.data(withJSONObject: value).write(to: resultURL, options: .atomic) }
func reject(_ value: [String: Any]) {
    do { _ = try inspectorCaptureEnvelope(value, captureID: captureID); fatalError("accepted mismatched receipt") } catch {}
}
var envelope = try inspectorCaptureEnvelope(state, captureID: captureID)
let target = state["target"] as! [String: Any]
let context = SimulatorInspectorContext(deviceID: target["deviceID"] as! String, displayID: "main", targetID: "target", targetLabel: "headless", presentationRevision: 1)
let snapshot = try SimulatorInspectorSnapshot.parse(envelope, context: context)
precondition(snapshot.captureID == captureID && !(snapshot.swiftUI?.nodes.isEmpty ?? true))
var rawSnapshot = envelope["snapshot"] as! [String: Any]
var wrongScope = rawSnapshot["inspectionScope"] as! [String: Any]
wrongScope["bootIdentity"] = "other-boot"; rawSnapshot["inspectionScope"] = wrongScope; envelope["snapshot"] = rawSnapshot
do { _ = try SimulatorInspectorSnapshot.parse(envelope, context: context); fatalError("accepted mismatched boot") } catch {}
for key in ["operationID", "requestDigest", "ownerID", "inspectionID", "targetEpoch", "captureID"] {
    var bad = original; bad[key] = "other"; save(bad); reject(state)
}
var bad = original; bad["target"] = [:] as [String: Any]; save(bad); reject(state)
bad = original; bad["validationOnly"] = true; save(bad); reject(state)
save(original)
var pending = state, ops = state["operations"] as! [String: [String: Any]]
let operationID = original["operationID"] as! String
ops[operationID]!["state"] = "reserved"; pending["operations"] = ops; reject(pending)
let linkTarget = folder.appendingPathComponent("linked-result.json")
try FileManager.default.moveItem(at: resultURL, to: linkTarget)
try FileManager.default.createSymbolicLink(at: resultURL, withDestinationURL: linkTarget)
reject(state); try FileManager.default.removeItem(at: resultURL)
try FileManager.default.moveItem(at: linkTarget, to: resultURL)
let file = try FileHandle(forWritingTo: resultURL); try file.truncate(atOffset: 16_777_217); try file.close()
reject(state); save(original)
let restoredEnvelope = try inspectorCaptureEnvelope(state, captureID: captureID)
precondition(restoredEnvelope["snapshot"] != nil)
print("PASS actual compact Ledger.finish receipt, full result join, production converter/consumer and negatives")
Task { @MainActor in
    do {
        precondition(Thread.isMainThread)
        let device = NSObject(), active: Int? = nil
        CURRENT_SCOPE
        precondition(currentScope == "background")
        print("PASS actual harness scope call dispatches away from the UI thread")
        exit(0)
    } catch { fputs("FAIL dispatch: \(error)\n", stderr); exit(1) }
}
RunLoop.main.run()
'''.replace('DISPATCH', dispatch).replace('CURRENT_SCOPE', current_scope)
        (out / 'helper.swift').write_text('import Foundation\nimport Darwin\n' + helper)
        (out / 'main.swift').write_text(main)
        executable = out / 'check'
        with (out / 'check.log').open('w') as log:
            subprocess.run(['xcrun', 'swiftc', str(native / 'SimulatorViewHierarchy.swift'),
                            str(native / 'SimulatorInspectorModel.swift'), str(out / 'helper.swift'),
                            str(out / 'main.swift'), '-o', str(executable)],
                           check=True, timeout=90, stdout=log, stderr=subprocess.STDOUT)
            env = dict(os.environ, INSPECTOR_CONTRACT_FOLDER=str(out))
            safety.check_routes(executable, env, log, production_helper=False)
            self.assertEqual(safety.run_owned(executable, ['--native-check'], environment=env,
                                             log=log, timeout=10, max_instances=1), 0)
        print(out, flush=True)


if __name__ == '__main__':
    unittest.main()
