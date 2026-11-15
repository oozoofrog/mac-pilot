import Foundation
import Darwin
guard CommandLine.arguments == [CommandLine.arguments[0], "--native-check"], getenv("MAC_CU_NATIVE_CHECK_CHILD") == nil else { exit(64) }
let context = SimulatorInspectorContext(deviceID: "synthetic", displayID: "main", targetID: "42:10:path", targetLabel: "synthetic", presentationRevision: 1)
let model = SimulatorInspectorModel(context: context)
assert(!model.canPrepareRecording)
func snapshot(_ status: String?, _ reason: String?) -> SimulatorInspectorSnapshot {
    let host = InspectorSwiftUIHost(hostingNodeID: "host", sceneID: "scene", status: status ?? "", reason: reason, graphStatus: .null, rendering: .null, roots: [], compositeAssetID: nil)
    let graph = InspectorSwiftUIGraph(scope: .null, processLifetime: .null, nodes: [:], hosts: ["host": host], order: [])
    return .init(swiftUI: status == nil ? nil : graph, captureID: UUID().uuidString, capturedAt: "synthetic", context: context, nodes: [:], roots: [], order: [], assets: [:], editable: [], editing: nil, renderingLimitations: [])
}
for state: String? in [nil, "available", "error", "overbudget", "unavailable", "empty"] {
    let generation = model.beginCapture()!
    assert(!model.canPrepareRecording)
    assert(model.accept(snapshot(state, nil), generation: generation))
    assert(!model.canPrepareRecording, "absence alone must not enable restart")
}
for state in ["empty", "unavailable"] {
    let generation = model.beginCapture()!
    let s = snapshot(state, "SwiftUI recording preparation required")
    assert(model.accept(s, generation: generation)); assert(model.canPrepareRecording)
    model.invalidate(); assert(!model.canPrepareRecording); assert(model.selection == nil); assert(model.pending == nil)
    let new = model.beginCapture()!
    assert(!model.accept(s, generation: new), "old capture IDs must not regain authority")
    assert(!model.accept(snapshot(state, nil), generation: generation), "old generation must fail")
}
print("PASS explicit preparation eligibility, absent/error refusal, invalidation, old capture/generation rejection")
