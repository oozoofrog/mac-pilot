import Foundation
import Darwin
struct ToolError: Error { let message: String; init(_ message: String) { self.message = message } }
guard CommandLine.arguments == [CommandLine.arguments[0], "--native-check"], getenv("MAC_CU_NATIVE_CHECK_CHILD") == nil else { exit(64) }
let capture = UUID().uuidString, token = UUID().uuidString
let target: [String: Any] = ["pid": 42, "deviceID": "synthetic"]
let scope: [String: Any] = ["deviceID": "synthetic", "bootIdentity": "boot:1", "displayID": "main", "presentation": "main|rot0", "generation": 1, "runtime": "synthetic|build"]
let owner = UUID().uuidString, inspection = UUID().uuidString, epoch = UUID().uuidString
let png = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+/a6cAAAAASUVORK5CYII="
let node: [String: Any] = ["id": token, "editToken": token, "className": "SyntheticHost", "parentToken": NSNull(), "windowToken": token, "sceneID": "scene", "hidden": false, "alpha": 1.0, "siblingIndex": 0]
let graph: [[String: Any]] = [["id": "swiftui:\(capture):\(token):0", "parentID": NSNull(), "childOrdinal": 0, "properties": [["id": 0, "attribute": ["readableType": "SwiftUI.Text"]]]]]
let host: [String: Any] = ["hostingNodeID": token, "sceneID": "scene", "status": "available", "reason": NSNull(), "graphStatus": "rootArray", "nodes": graph,
    "rendering": ["status": "available", "representation": "hostingSubtreeComposite", "assetID": NSNull(), "drawHierarchyReturned": true, "reason": NSNull(), "data": png, "pointWidth": 1.0, "pointHeight": 1.0]]
let section: [String: Any] = ["schemaVersion": 1, "captureID": capture, "inspectionScope": scope, "hosts": [host]]
var result: [String: Any] = ["status": "success", "captureID": capture, "captureTime": "synthetic", "target": target,
    "ownerID": owner, "inspectionID": inspection, "targetEpoch": epoch,
    "editing": ["registryState": "active", "expiresAt": 1.0, "ownerID": owner, "inspectionID": inspection, "targetEpoch": epoch], "editableNodes": [node],
    "cleanup": ["childrenReaped": true, "detach": "success", "recovery": ["verified": true]]]
let legacy = try simulatorEditableViewHierarchySnapshot(result: result, target: target)
assert(legacy["swiftUI"] == nil)
result["swiftUI"] = section; result["inspectionScope"] = scope
let snapshot = try simulatorEditableViewHierarchySnapshot(result: result, target: target)
let assets = snapshot["assets"] as! [String: [String: Any]]
assert(assets.count == 1)
assert(assets.values.first?["representation"] as? String == "hostingSubtreeComposite")
assert(assets.values.first?["descendantContent"] as? String == "all")
let output = (snapshot["swiftUI"] as! [String: Any])["hosts"] as! [[String: Any]]
assert((output[0]["rendering"] as! [String: Any])["data"] == nil)
assert((output[0]["rendering"] as! [String: Any])["assetID"] as? String == assets.keys.first)
for key in ["captureID", "inspectionScope", "hosts"] {
    var bad = section; bad[key] = "invalid"; result["swiftUI"] = bad
    do { _ = try simulatorEditableViewHierarchySnapshot(result: result, target: target); fatalError("accepted contradictory section") } catch {}
}
var badHost = host; badHost["sceneID"] = "other"; var bad = section; bad["hosts"] = [badHost]; result["swiftUI"] = bad
do { _ = try simulatorEditableViewHierarchySnapshot(result: result, target: target); fatalError("accepted wrong scene") } catch {}
print("PASS legacy UIKit, composite PNG join, graph identity, scope and scene rejection")

let typed = try SimulatorViewInspectionScope(scope)
for key in ["deviceID", "bootIdentity", "displayID", "presentation", "runtime", "generation"] {
    var changed = scope; changed[key] = key == "generation" ? 2 : "changed"
    let observed = try SimulatorViewInspectionScope(changed)
    assert(typed != observed, "scope drift must revoke acceptance")
}
for value: Any in [true, -1, 1.5, "1"] {
    var invalid = scope; invalid["generation"] = value
    do { _ = try SimulatorViewInspectionScope(invalid); fatalError("invalid generation") } catch {}
}
print("PASS typed scope boot/runtime/display/presentation/generation drift and malformed generation")

let consumer = try SimulatorInspectorSnapshot.parse(snapshot, context: .init(deviceID: "synthetic", displayID: "main", targetID: "target", targetLabel: "synthetic", presentationRevision: 1))
assert(consumer.swiftUI?.nodes.count == 1)
assert(consumer.swiftUI?.hosts[token]?.compositeAssetID == assets.keys.first)
print("PASS backend snapshot directly consumed by stable UI model")
