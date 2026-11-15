import Foundation
import simd
import Darwin

guard Array(CommandLine.arguments.dropFirst()).first == "--native-check", getenv("MAC_CU_NATIVE_CHECK_CHILD") == nil else { exit(64) }
setenv("MAC_CU_NATIVE_CHECK_CHILD", "1", 1)
var checks = 0
func check(_ condition: @autoclosure () -> Bool, _ name: String) { guard condition() else { fatalError(name) }; checks += 1; print("PASS \(name)") }
func rejects(_ name: String, _ body: () throws -> Void) { do { try body(); fatalError(name) } catch { checks += 1; print("PASS \(name)") } }
let context = SimulatorInspectorContext(deviceID: "synthetic-device",displayID: "display",targetID: "target",targetLabel: "Fixture",presentationRevision: 1)
func node(_ id: String, asset: String? = nil) -> [String: Any] {
    var d: [String:Any] = ["id": id,"sceneID":"synthetic-scene","className":"UIView","parentID":NSNull(),"children":[],"hidden":false,"alpha":1.0,"editToken":"opaque-\(id)","editableProperties":["hidden","alpha"],"geometry":["coordinateSpace":"UIScreen.fixedCoordinateSpace points","corners":[[0.0,0.0],[100.0,0.0],[100.0,200.0],[0.0,200.0]]]]
    if let asset { d["assetID"] = asset }; return d
}
func envelope(_ roots: [[String:Any]]) -> [String: Any] {
    ["captureID":"capture","capturedAt":"2026-11-09T00:00:00Z","roots":roots,"capabilities":["editableProperties":["hidden","alpha"]],"editing":["inspectionID":"inspection","ownerID":"owner","targetEpoch":"epoch","expiresAt":"2099-01-01T00:00:00Z","registryState":"active"]]
}
let snapshot = try SimulatorInspectorSnapshot.parse(envelope([node("a"),node("b")]),context: context)
let model = SimulatorInspectorModel(context: context)
let g = model.beginCapture()!
check(model.accept(snapshot,generation:g),"capture accepted")
check(model.selection == nil,"capture has no selection")
check(snapshot.visibleIDs(query:"missing").isEmpty,"filter no match")
check(model.selection == nil,"filter cannot select")
model.select("a"); check(model.canEdit("hidden"),"capability gate")
model.draft = ("a",.alpha(.nan)); check(model.beginEdit() == nil,"nonfinite draft rejected")
model.draft = ("a",.alpha(0.5)); let command = model.beginEdit()!
check(command.editToken == "opaque-a" && command.envelope["nodeID"] == nil,"opaque token target")
check(model.beginCapture() == nil,"pending blocks capture")
check(!model.canEdit("hidden"),"pending blocks conflicting edits")
let wrong = try InspectorReceipt(["operationID":UUID().uuidString,"status":"applied"])
check(!model.complete(wrong,generation:g,nodeID:"a"),"wrong operation ignored")
let receipt = try InspectorReceipt(["operationID":command.operationID.uuidString,"status":"success","mutationOutcome":"observed_applied","undoToken":"server-undo","needsRefresh":true])
check(model.complete(receipt,generation:g,nodeID:"a"),"matching receipt accepted")
check(!model.canEdit("alpha"),"second edit requires capture")
check(model.canRevert(),"server undo available")
model.select("b"); check(!model.canRevert(),"undo bound to original node")
check(model.draft?.nodeID == "a","declined or original draft retained")
model.select("a"); check(!model.canRevert(now:Date.distantFuture),"undo expires")
check(!model.canEdit("hidden",now:Date.distantFuture),"edit expires")
model.invalidate(); check(!model.complete(receipt,generation:g,nodeID:"a"),"late receipt ignored")
check(model.selection == nil && model.stale,"invalidation clears authority/selection")
let next = model.beginCapture()!; model.invalidate()
check(!model.accept(snapshot,generation:next),"stale capture ignored")
let other = SimulatorInspectorContext(deviceID:"other",displayID:"display",targetID:"target",targetLabel:"Fixture",presentationRevision:1)
let otherModel = SimulatorInspectorModel(context:other), otherG = otherModel.beginCapture()!
check(!otherModel.accept(snapshot,generation:otherG),"context mismatch rejected")
check(!otherModel.acceptBoundCapture(snapshot,generation:otherG),"capture cannot bind another device")
let unresolved = SimulatorInspectorContext(deviceID:context.deviceID,displayID:context.displayID,targetID:"",targetLabel:"Capture pending",presentationRevision:1)
let bindingModel = SimulatorInspectorModel(context:unresolved)
check(!bindingModel.acceptBoundCapture(snapshot,generation:0),"target binding requires explicit pending capture")
let bindingGeneration = bindingModel.beginCapture()!
check(bindingModel.acceptBoundCapture(snapshot,generation:bindingGeneration) && bindingModel.context == context && bindingModel.selection == nil,"explicit capture binds attested target without node selection")
let changedPresentation = SimulatorInspectorContext(deviceID:context.deviceID,displayID:context.displayID,targetID:"target",targetLabel:"Fixture",presentationRevision:2)
let changedSnapshot = try SimulatorInspectorSnapshot.parse(envelope([node("a")]),context:changedPresentation)
let replacementGeneration = bindingModel.beginCapture()!
check(!bindingModel.acceptBoundCapture(changedSnapshot,generation:replacementGeneration),"capture cannot bind changed presentation")
rejects("duplicate IDs") { _ = try SimulatorInspectorSnapshot.parse(envelope([node("a"),node("a")]),context:context) }
var bad = node("a"); bad["parentID"] = "self"
rejects("parent mismatch") { _ = try SimulatorInspectorSnapshot.parse(envelope([bad]),context:context) }
bad = node("a"); bad["geometry"] = ["coordinateSpace":"superview","corners":[[0.0,0.0],[1,0],[1,1],[0,1]]]
rejects("wrong coordinate space") { _ = try SimulatorInspectorSnapshot.parse(envelope([bad]),context:context) }
bad = node("a"); bad["geometry"] = ["coordinateSpace":"UIScreen.fixedCoordinateSpace points","corners":[[Double.nan,0.0],[1,0],[1,1],[0,1]]]
rejects("nonfinite geometry") { _ = try SimulatorInspectorSnapshot.parse(envelope([bad]),context:context) }
// Test-authored one-pixel PNG; no local capture IDs or images.
let png = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGP4z8DwHwAFAAH/iZk9HQAAAABJRU5ErkJggg=="
func asset(_ id: String) -> [String:Any] { ["nodeID":id,"captureID":"capture","format":"png","encoding":"base64","pixelWidth":1,"pixelHeight":1,"data":png] }
var images = envelope([node("a",asset:"one"),node("b",asset:"two")]); images["assets"] = ["one":asset("a"),"two":asset("b")]
let identical = try SimulatorInspectorSnapshot.parse(images,context:context)
check(identical.assets.count == 2,"identical images on distinct nodes valid")
var raw = asset("a"); raw["data"] = "not PNG"
rejects("malformed base64 PNG") { _ = try InspectorAsset.parse("one",raw,captureID:"capture") }
raw = asset("a"); raw["pixelWidth"] = 4097
rejects("declared dimension mismatch") { _ = try InspectorAsset.parse("one",raw,captureID:"capture") }
raw = asset("a"); raw["data"] = String(repeating:"A",count:6*1024*1024)
rejects("oversized base64 before decode") { _ = try InspectorAsset.parse("one",raw,captureID:"capture") }
raw = asset("a"); raw["captureID"] = "other"
rejects("capture local asset join") { _ = try InspectorAsset.parse("one",raw,captureID:"capture") }
var many:[String:[String:Any]] = [:]; for i in 0..<65 { many[String(i)] = asset("a") }; images["assets"] = many
rejects("image count limit") { _ = try SimulatorInspectorSnapshot.parse(images,context:context) }
// Header-only oversized synthetic descriptors must fail before a decoder is called.
var bigBytes = Data(base64Encoded: png)!
for offset in [16,20] { bigBytes.replaceSubrange(offset..<offset+4,with:[0,0,16,0]) }
var budgetNodes: [[String:Any]] = [], budgetAssets: [String:[String:Any]] = [:]
for i in 0..<3 {
    let id = "budget-\(i)"; budgetNodes.append(node(id,asset:id))
    var a = asset(id); a["data"] = bigBytes.base64EncodedString(); a["pixelWidth"] = 4096; a["pixelHeight"] = 4096; budgetAssets[id] = a
}
var budgetEnvelope = envelope(budgetNodes); budgetEnvelope["assets"] = budgetAssets
rejects("aggregate decoded RGBA budget") { _ = try SimulatorInspectorSnapshot.parse(budgetEnvelope,context:context) }
var nested = node("leaf")
for i in (0..<130).reversed() { nested["parentID"] = "depth-\(i)"; var parent = node("depth-\(i)"); parent["children"] = [nested]; nested = parent }
rejects("hierarchy depth bound") { _ = try SimulatorInspectorSnapshot.parse(envelope([nested]),context:context) }
var child = node("child"); child["parentID"] = "parent"; var parent = node("parent"); parent["children"] = [child]
let layered = try SimulatorInspectorSnapshot.parse(envelope([parent]),context:context)
var straight = InspectorCamera(); straight.yaw = 0; straight.pitch = 0
let layers = layered.order.compactMap { layered.nodes[$0] }
check(straight.ordered(layers,matrix:straight.matrix(nodes:layers,aspect:1)).map(\.id) == ["parent","child"],"transparent layers render rear before front")
let n = snapshot.nodes["a"]!, nodes = [n], size = SIMD2<Float>(800,600)
var camera = InspectorCamera(); camera.yaw = 0; camera.pitch = 0
let matrix = camera.matrix(nodes:nodes,aspect: size.x/size.y)
let polygon = camera.projected(n,matrix:matrix,size:size)
check(polygon.count == 4,"quad projects")
check(InspectorCamera.contains(SIMD2(400,300),polygon:polygon),"center hits projected polygon")
check(!InspectorCamera.contains(SIMD2(0,0),polygon:polygon),"outside misses")
camera.yaw = 0.8; camera.pitch = 0.4
let rotated = camera.projected(n,matrix:camera.matrix(nodes:nodes,aspect:size.x/size.y),size:size)
check(rotated != polygon,"orbit changes projection")
check(InspectorCamera.contains(rotated.reduce(.zero,+)/Float(rotated.count),polygon:rotated),"rotated polygon picking")
let behind:[SIMD4<Float>] = [SIMD4(-1,-1,-1,1),SIMD4(1,-1,-1,1),SIMD4(1,1,-1,1)]
check(InspectorCamera.clipped(behind).isEmpty,"near clipping prevents hidden hit")
check(camera.ordered([snapshot.nodes["b"]!,snapshot.nodes["a"]!],matrix:matrix).map(\.id) == ["b","a"],"equal-depth drawing preserves captured stacking order")

// Canonical Python wire parser -> exact product envelope -> typed Swift consumer.
let fixtureDir = ProcessInfo.processInfo.environment["INSPECTOR_FIXTURE_DIR"]!
let scope: [String:Any] = ["deviceID":context.deviceID,"bootIdentity":"synthetic-boot","displayID":context.displayID,"presentation":"synthetic-presentation","generation":1,"runtime":"synthetic-runtime"]
func swiftEnvelope(_ name: String, capture: String = "capture") throws -> [String:Any] {
    let parsed = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath:fixtureDir).appendingPathComponent(name+"-sanitized-normalized.json"))) as! [String:Any]
    let records = parsed["nodes"] as! [[String:Any]]
    let graph: [[String:Any]] = records.map { n in
        let index = n["index"] as! Int
        return ["id":"swiftui:\(capture):host:\(index)", "parentID":(n["parentIndex"] as? Int).map { "swiftui:\(capture):host:\($0)" } as Any? ?? NSNull(), "childOrdinal":n["childOrdinal"]!, "properties":n["properties"]!]
    }
    var d = envelope([node("host")]); d["captureID"] = capture; d["inspectionScope"] = scope; d["processLifetime"] = ["synthetic":true]
    d["swiftUI"] = ["schemaVersion":1,"captureID":capture,"inspectionScope":scope,"hosts":[["hostingNodeID":"host","sceneID":"synthetic-scene","status":"available","reason":NSNull(),"graphStatus":"rootArray","nodes":graph,"rendering":["status":"unavailable","representation":"hostingSubtreeComposite","assetID":NSNull(),"drawHierarchyReturned":NSNull(),"reason":"Synthetic no image"]]]]
    return d
}
func alterHost(_ raw: [String:Any], _ change: (inout [String:Any]) -> Void) -> [String:Any] {
    var raw = raw, section = raw["swiftUI"] as! [String:Any], hosts = section["hosts"] as! [[String:Any]]
    change(&hosts[0]); section["hosts"] = hosts; raw["swiftUI"] = section; return raw
}
let charlieRaw = try swiftEnvelope("charlie"), deltaRaw = try swiftEnvelope("delta",capture:"next")
let charlie = try SimulatorInspectorSnapshot.parse(charlieRaw,context:context), delta = try SimulatorInspectorSnapshot.parse(deltaRaw,context:context)
check(charlie.swiftUI?.nodes.count == 102 && delta.swiftUI?.nodes.count == 106,"stored charlie/delta topology through canonical wire parser")
check(charlie.nodes.count == 1 && charlie.swiftUI?.nodes.values.allSatisfy { charlie.nodes[$0.id] == nil } == true,"cross-kind registry separation")
let swiftID = charlie.swiftUI!.order.last!
check(charlie.visibleIDs(query:"SYNTHETIC text 101").contains("host") && charlie.visibleIDs(query:"SYNTHETIC text 101").contains(swiftID),"property search preserves ancestors")
check(charlie.children("host") == charlie.swiftUI!.hosts["host"]!.roots,"real roots joined under hosting node")
check(charlie.swiftUI!.nodes.values.allSatisfy { $0.children.allSatisfy { charlie.swiftUI!.nodes[$0] != nil } },"graph children remain declarative IDs")
let sm = SimulatorInspectorModel(context:context), sg = sm.beginCapture()!
check(sm.accept(charlie,generation:sg),"SwiftUI capture accepted")
sm.select("host"); sm.draft = ("host",.alpha(0.4)); let pendingCommand = sm.beginEdit()!
sm.select(swiftID)
check(sm.selection == swiftID && sm.draft == nil && !sm.canEdit("alpha") && !sm.canRevert(),"SwiftUI selection clears draft and edit/undo gates during pending UIKit operation")
sm.draft = (swiftID,.hidden(true)); check(sm.beginEdit() == nil,"SwiftUI ID never produces mutation command")
let pendingReceipt = try InspectorReceipt(["operationID":pendingCommand.operationID.uuidString,"status":"success","undoToken":"synthetic-undo"])
check(!sm.complete(pendingReceipt,generation:sg,nodeID:swiftID),"pending receipt rejects cross-kind node substitution")
check(sm.complete(pendingReceipt,generation:sg,nodeID:"host") && sm.pending == nil && !sm.canRevert(),"pending UIKit receipt completes without SwiftUI undo authority")
let replacement = sm.beginCapture()!; check(sm.accept(delta,generation:replacement),"capture replaced")
sm.select(swiftID); check(sm.selection == nil,"old graph ID rejected after replacement")
let replay = sm.beginCapture()!; check(!sm.accept(delta,generation:replay),"consumed SwiftUI capture cannot reactivate same IDs")
let fresh = sm.beginCapture()!, third = try SimulatorInspectorSnapshot.parse(try swiftEnvelope("delta",capture:"third"),context:context); check(sm.accept(third,generation:fresh),"fresh graph after rejected replay")
let nextID = sm.snapshot!.swiftUI!.order[0]; sm.select(nextID); sm.invalidate(); sm.select(nextID)
check(sm.selection == nil && sm.draft == nil,"cancel/close invalidation rejects retained graph IDs")
let changed = SimulatorInspectorContext(deviceID:context.deviceID,displayID:context.displayID,targetID:"changed",targetLabel:"Changed",presentationRevision:2)
sm.invalidate(context:changed); sm.select(nextID); check(sm.selection == nil,"context change rejects graph ID")
let reopened = SimulatorInspectorModel(context:context); reopened.select(nextID); check(reopened.selection == nil,"reopen has no prior IDs")
for state in ["empty","unavailable","error","overbudget"] {
    let raw = alterHost(charlieRaw) { $0["status"] = state; $0["nodes"] = [] }
    let parsed = try SimulatorInspectorSnapshot.parse(raw,context:context)
    check(parsed.swiftUI?.hosts["host"]?.status == state && parsed.swiftUI?.nodes.isEmpty == true,"truthful \(state) graph status")
}
func rejectHost(_ name: String, _ change: (inout [String:Any]) -> Void) {
    rejects(name) { _ = try SimulatorInspectorSnapshot.parse(alterHost(charlieRaw,change),context:context) }
}
rejectHost("scene mismatch") { $0["sceneID"] = "foreign-scene" }
rejectHost("unknown hosting token") { $0["hostingNodeID"] = "other" }
rejectHost("available empty graph rejected") { $0["nodes"] = [] }
rejectHost("nonavailable graph data rejected") { $0["status"] = "error" }
rejectHost("foreign capture node namespace") { var ns = $0["nodes"] as! [[String:Any]]; ns[0]["id"] = "swiftui:old:host:0"; $0["nodes"] = ns }
rejectHost("duplicate graph IDs") { var ns = $0["nodes"] as! [[String:Any]]; ns[1]["id"] = ns[0]["id"]; $0["nodes"] = ns }
rejectHost("forward/cyclic graph edge") { var ns = $0["nodes"] as! [[String:Any]]; ns[0]["parentID"] = ns.last!["id"]; $0["nodes"] = ns }
rejectHost("wrong child ordinal") { var ns = $0["nodes"] as! [[String:Any]]; ns[0]["childOrdinal"] = 2; $0["nodes"] = ns }
rejectHost("boolean property ID") { var ns = $0["nodes"] as! [[String:Any]]; ns[0]["properties"] = [["id":true,"attribute":[:]]]; $0["nodes"] = ns }
rejectHost("metadata string budget") { $0["reason"] = String(repeating:"a",count:262145) }
rejectHost("malformed metadata subattributes") { var ns = $0["nodes"] as! [[String:Any]]; ns[0]["properties"] = [["id":0,"attribute":["subattributes":true]]]; $0["nodes"] = ns }
var mismatch = charlieRaw; mismatch["inspectionScope"] = scope.merging(["bootIdentity":"other"]) { _,new in new }
rejects("boot scope mismatch") { _ = try SimulatorInspectorSnapshot.parse(mismatch,context:context) }
var section = charlieRaw["swiftUI"] as! [String:Any]; section["hosts"] = (section["hosts"] as! [[String:Any]]) + (section["hosts"] as! [[String:Any]])
mismatch = charlieRaw; mismatch["swiftUI"] = section
rejects("duplicate hosting tokens") { _ = try SimulatorInspectorSnapshot.parse(mismatch,context:context) }
mismatch = charlieRaw; mismatch["swiftUI"] = NSNull()
rejects("malformed present section not ignored") { _ = try SimulatorInspectorSnapshot.parse(mismatch,context:context) }
var representable = node("representable",asset:"child-image"); representable["parentID"] = "host"
var nestedHost = node("nested"); nestedHost["parentID"] = "representable"; representable["children"] = [nestedHost]
var hosting = node("host",asset:"composite"); hosting["children"] = [representable]
var composite = charlieRaw; composite["roots"] = [hosting]
var compositeAsset = asset("host"); compositeAsset["representation"] = "hostingSubtreeComposite"; compositeAsset["descendantContent"] = "all"
composite["assets"] = ["composite":compositeAsset,"child-image":asset("representable")]
composite = alterHost(composite) { $0["rendering"] = ["status":"available","representation":"hostingSubtreeComposite","assetID":"composite","drawHierarchyReturned":true,"reason":NSNull()] }
let compositeSnapshot = try SimulatorInspectorSnapshot.parse(composite,context:context)
check(compositeSnapshot.paintsTexture("host") && !compositeSnapshot.paintsTexture("representable") && !compositeSnapshot.paintsTexture("nested"),"composite suppresses representable and nested hosting descendant painting")
check(compositeSnapshot.nodes["representable"]!.corners.count == 4 && compositeSnapshot.children("host").contains("representable"),"suppressed descendant retains outline and verified selection geometry")
check(compositeSnapshot.nodes[swiftID] == nil && camera.projected(compositeSnapshot.nodes["representable"]!,matrix:matrix,size:size).count == 4,"SwiftUI tree-only and UIKit projection preserved")
rejects("drawHierarchy false cannot claim composite success") { _ = try SimulatorInspectorSnapshot.parse(alterHost(composite) { var r = $0["rendering"] as! [String:Any]; r["drawHierarchyReturned"] = false; $0["rendering"] = r },context:context) }
rejects("composite cannot enter UIKit-only snapshot") { var d = composite; d["swiftUI"] = nil; _ = try SimulatorInspectorSnapshot.parse(d,context:context) }
rejectHost("scope accepts no missing representation") { var r = $0["rendering"] as! [String:Any]; r["representation"] = "guessed"; $0["rendering"] = r }
rejectHost("duplicate property IDs") { var ns = $0["nodes"] as! [[String:Any]]; ns[0]["properties"] = [["id":0,"attribute":[:]], ["id":0,"attribute":[:]]]; $0["nodes"] = ns }
rejectHost("graph aggregate count budget") { $0["nodes"] = Array(repeating: ["id":"x"],count:4097) }
let huge = try InspectorValue(["nested":[String(repeating:"x",count:10000)]])
check(huge.displayText(limit:100).count == 101,"bounded property display without metadata truncation")
let exactInteger = try InspectorValue(NSNumber(value:UInt64.max))
check(exactInteger.text == String(UInt64.max),"integer metadata exactness")
if CommandLine.arguments.count == 3 {
    let real = try JSONSerialization.jsonObject(with:Data(contentsOf:URL(fileURLWithPath:CommandLine.arguments[2]))) as! [String:Any]
    let parsed = try SimulatorInspectorSnapshot.parse(real,context:context)
    check(!parsed.nodes.isEmpty,"real saved snapshot parses (source data only)")
}
print("PASS \(checks) headless assertions; no NSApplication, GPU or Simulator lifecycle")
