import Foundation
import CoreFoundation
import Darwin

struct ToolError: Error { let message: String; init(_ message: String) { self.message = message } }

@main struct ViewEditSelfcheck {
    static func main() throws {
        guard CommandLine.arguments == [CommandLine.arguments[0], "--native-check"], getenv("MAC_CU_NATIVE_CHECK_CHILD") == nil else { exit(64) }
        let target = SimulatorViewCaptureTarget(pid: 42, start: [100, 123], path: "/not-a-fixture", deviceID: UUID().uuidString)
        let owner = UUID(), inspection = UUID(), epoch = UUID(), capture = UUID(), window = UUID(), child = UUID()
        let editing: [String: Any] = ["ownerID": owner.uuidString, "inspectionID": inspection.uuidString,
            "targetEpoch": epoch.uuidString, "expiresAt": Date().addingTimeInterval(120).timeIntervalSince1970, "registryState": "active"]
        let roots: [[String: Any]] = [
            ["id": window.uuidString, "editToken": window.uuidString, "className": "UIWindow", "parentToken": NSNull(),
             "windowToken": window.uuidString, "hidden": false, "alpha": 1.0, "siblingIndex": 0],
            ["id": child.uuidString, "editToken": child.uuidString, "className": "UIView", "parentToken": window.uuidString,
             "windowToken": window.uuidString, "hidden": false, "alpha": 0.5, "siblingIndex": 0]]
        var result: [String: Any] = ["schemaVersion": 2, "status": "success", "validationOnly": true, "target": target.json,
            "ownerID": owner.uuidString, "inspectionID": inspection.uuidString, "targetEpoch": epoch.uuidString,
            "captureID": capture.uuidString, "captureTime": "2026-11-09T00:00:00Z", "editing": editing, "editableNodes": roots,
            "cleanup": ["childrenReaped": true, "detach": "success", "recovery": ["verified": true]]]
        let image: [String: Any] = ["propertyName": "snapshotImage", "propertyFormat": "image", "propertyRuntimeType": "UIImage", "fetchStatus": 4,
            "propertyValue": ["imageData": "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+/a6cAAAAASUVORK5CYII=", "metadata": ["width": 30, "height": 40]]]
        result["hierarchy"] = ["topLevelGroups": ["com.apple.UIKit.UIWindow": ["debugHierarchyObjects": [
            ["objectID": "0x1", "className": "UIWindow", "properties": [image], "childGroup": ["debugHierarchyObjects": [
                ["objectID": "0x2", "className": "UIView", "properties": [image]]]]]]]]]
        let joins: [String: [String: Any]] = [
            "0x1": ["nodeToken": window.uuidString, "className": "UIWindow", "parentAddress": NSNull()],
            "0x2": ["nodeToken": child.uuidString, "className": "UIView", "parentAddress": "0x1"]]
        result["textureJoins"] = joins; result["textureCapture"] = ["sameOperationIdentity": true, "status": "collected"]
        let snapshot = try simulatorEditableViewHierarchySnapshot(result: result, target: target.json)
        let assets = snapshot["assets"] as! [String: [String: Any]]
        assert(assets.count == 2 && Set(assets.values.compactMap { $0["nodeID"] as? String }) == [window.uuidString, child.uuidString])
        assert(assets.values.allSatisfy { $0["descendantContent"] as? String == "unknown" })
        var badJoins = joins; badJoins["0x2"]?["nodeToken"] = window.uuidString; result["textureJoins"] = badJoins
        let ambiguous = try simulatorEditableViewHierarchySnapshot(result: result, target: target.json)
        assert((ambiguous["assets"] as! [String: Any]).isEmpty, "ambiguous join grants no textures")
        badJoins = joins; badJoins["0x2"]?["className"] = "OtherClass"; result["textureJoins"] = badJoins
        let mismatch = try simulatorEditableViewHierarchySnapshot(result: result, target: target.json)
        assert((mismatch["assets"] as! [String: Any]).count == 1, "wrong class never joins child texture")
        result["textureJoins"] = joins
        assert((snapshot["editing"] as! [String: Any])["expiresAt"] is String)
        let nodes = snapshot["roots"] as! [[String: Any]]
        let selected = (nodes[0]["children"] as! [[String: Any]])[0]
        assert(selected["editToken"] as? String == child.uuidString)
        assert(selected["parentID"] as? String == window.uuidString)
        assert(selected["windowToken"] as? String == window.uuidString)
        assert(selected["alpha"] as? Double == 0.5)
        assert(selected["assetID"] is String && assets[selected["assetID"] as! String]?["nodeID"] as? String == child.uuidString)
        let identity = try SimulatorViewEditIdentity(node: selected)
        assert(identity.editToken == child && identity.expectedParentToken == window)
        let context = try SimulatorViewEditingContext(target: target, result: SimulatorViewCaptureResult(result))
        assert(context.captureID == capture && context.targetEpoch == epoch && context.validationOnly)
        var ordinary = result; ordinary["validationOnly"] = false
        let ordinaryContext = try SimulatorViewEditingContext(target: target, result: SimulatorViewCaptureResult(ordinary))
        assert(!ordinaryContext.validationOnly)
        result["cleanup"] = ["childrenReaped": true, "detach": "failed", "recovery": ["verified": true]]
        do { _ = try simulatorEditableViewHierarchySnapshot(result: result, target: target.json); fatalError("cleanup failure granted tokens") } catch {}
        result["cleanup"] = ["childrenReaped": true, "detach": "success", "recovery": ["verified": true]]
        var malformed = roots; malformed[1]["hidden"] = 1; result["editableNodes"] = malformed
        do { _ = try simulatorEditableViewHierarchySnapshot(result: result, target: target.json); fatalError("numeric hidden accepted") } catch {}
        malformed = roots; malformed[1]["parentToken"] = child.uuidString; result["editableNodes"] = malformed
        do { _ = try simulatorEditableViewHierarchySnapshot(result: result, target: target.json); fatalError("cyclic graph accepted") } catch {}
        let op = UUID(), undo = UUID()
        let receipt: [String: Any] = ["status": "cleanupFailed", "operationID": op.uuidString, "mutationOutcome": "appliedObserved",
            "before": false, "requested": true, "observed": true, "undoToken": undo.uuidString, "needsRefresh": true,
            "cleanup": ["detach": "failed"]]
        let parsed = try SimulatorViewMutationResult(receipt, operationID: op)
        assert(parsed.status == .cleanupFailed && parsed.mutationOutcome == .appliedObserved)
        assert(parsed.before == .hidden(false) && parsed.observed == .hidden(true) && parsed.undoToken == undo)
        assert(parsed.needsRefresh)
        do { _ = try SimulatorViewMutationResult(receipt, operationID: UUID()); fatalError("mismatched receipt accepted") } catch {}
        assert(!SimulatorViewEditableValue.alpha(.nan).isValid && !SimulatorViewEditableValue.alpha(1.01).isValid)
        assert(SimulatorViewEditableValue.alpha(0).isValid && SimulatorViewEditableValue.alpha(1).isValid)
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            defer { done.signal() }
            do {
                // Real packaged helper + production schema validation. This nonfixture
                // target is refused BEFORE the ledger, process probe or child creation.
                let cancel = SimulatorViewCaptureCancellation()
                var request = SimulatorViewEditableCaptureRequest(target: target)
                request.validationOnly = true
                let cap = try simulatorCaptureEditableViews(request, cancellation: cancel)
                assert(cap.status == .unsupported)
                let edit = try simulatorEditView(SimulatorViewEditRequest(context: context, identity: identity,
                    expected: .hidden(false), value: .hidden(true), operationID: op, sequence: 2), cancellation: cancel)
                assert(edit.status == .unsupported && edit.mutationOutcome == .notEntered)
                let revert = try simulatorRevertView(SimulatorViewRevertRequest(context: context, undoToken: undo,
                    operationID: UUID(), sequence: 3), cancellation: cancel)
                let release = try simulatorReleaseViews(SimulatorViewReleaseRequest(context: context, reason: .close,
                    operationID: UUID(), sequence: 4), cancellation: cancel)
                assert(revert.status == .unsupported && release.status == .unsupported)
                for (content, kind) in [(cap.content, "capture"), (edit.content, "edit"), (revert.content, "revert"), (release.content, "release")] {
                    let folder = URL(fileURLWithPath: content["evidenceDirectory"] as! String)
                    let wire = try JSONSerialization.jsonObject(with: Data(contentsOf: folder.appendingPathComponent("request.json"))) as! [String: Any]
                    assert(wire["kind"] as? String == kind && wire["schemaVersion"] as? Int == 2)
                    assert(wire["target"] is [String: Any] && wire["operationID"] is String)
                    if kind == "edit" {
                        assert(CFGetTypeID(wire["value"] as! NSNumber) == CFBooleanGetTypeID())
                        assert(wire["nodeToken"] as? String == identity.editToken.uuidString)
                    }
                    print("PASS real \(kind) helper schema refusal; evidence \(folder.path)")
                }
                cancel.cancel(); assert(cancel.isCancelled)
            } catch { fatalError("Typed editable helper roundtrip failed: \(error)") }
        }
        assert(done.wait(timeout: .now() + 20) == .success)
        print("PASS typed editable snapshot, receipts, cancellation and four helper wrappers")
    }
}
