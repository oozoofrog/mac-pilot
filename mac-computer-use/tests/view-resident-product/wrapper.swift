import Foundation

// Test-only typed caller. Every operation uses the actual public Swift wrapper,
// bundled Python resource, production ledger, selected LLDB and resident image.
func residentProductOperation(_ file: String) throws -> [String: Any] {
    let q = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: file))) as! [String: Any]
    let t = q["target"] as! [String: Any]
    let target = SimulatorViewCaptureTarget(pid: (t["pid"] as! NSNumber).int32Value,
        start: (t["start"] as! [NSNumber]).map(\.uint64Value), path: t["path"] as! String, deviceID: t["deviceID"] as! String)
    func id(_ key: String) -> UUID { UUID(uuidString: q[key] as! String)! }
    let validationOnly = q["validationOnly"] as! Bool
    let sequence = (q["sequence"] as! NSNumber).uint64Value
    let cancellation = SimulatorViewCaptureCancellation()
    let cancelPath = file + ".cancel"
    let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global())
    timer.schedule(deadline: .now(), repeating: .milliseconds(10))
    timer.setEventHandler { if FileManager.default.fileExists(atPath: cancelPath) { cancellation.cancel() } }
    timer.resume()
    defer { timer.cancel() }
    func context(_ capture: UUID) -> SimulatorViewEditingContext {
        SimulatorViewEditingContext(target: target, ownerID: id("ownerID"), inspectionID: id("inspectionID"),
            targetEpoch: id("targetEpoch"), captureID: capture, validationOnly: validationOnly)
    }
    switch q["kind"] as! String {
    case "capture":
        var request = SimulatorViewEditableCaptureRequest(target: target)
        request.ownerID = id("ownerID"); request.inspectionID = id("inspectionID")
        request.operationID = id("operationID"); request.sequence = sequence; request.validationOnly = validationOnly
        if let capture = q["replaceCaptureID"] as? String { request.replacing = context(UUID(uuidString: capture)!) }
        let result = try simulatorCaptureEditableViews(request, cancellation: cancellation)
        if result.status == .success {
            let preserved = try SimulatorViewEditingContext(target: target, result: result)
            guard preserved.validationOnly == validationOnly else { throw ToolError("Capture route was not preserved") }
        }
        return result.content
    case "edit":
        let identity = SimulatorViewEditIdentity(editToken: id("nodeToken"),
            expectedParentToken: (q["expectedParentToken"] as? String).flatMap(UUID.init(uuidString:)),
            expectedWindowToken: id("expectedWindowToken"), expectedClass: q["expectedClass"] as! String)
        func scalar(_ key: String) -> SimulatorViewEditableValue {
            q["property"] as! String == "hidden" ? .hidden(q[key] as! Bool) : .alpha((q[key] as! NSNumber).doubleValue)
        }
        return try simulatorEditView(SimulatorViewEditRequest(context: context(id("captureID")), identity: identity,
            expected: scalar("expectedValue"), value: scalar("value"), operationID: id("operationID"), sequence: sequence),
            cancellation: cancellation).content
    case "revert":
        return try simulatorRevertView(SimulatorViewRevertRequest(context: context(id("captureID")), undoToken: id("undoToken"),
            operationID: id("operationID"), sequence: sequence), cancellation: cancellation).content
    case "release":
        return try simulatorReleaseViews(SimulatorViewReleaseRequest(context: context(id("captureID")),
            reason: SimulatorViewReleaseReason(rawValue: q["reason"] as! String)!, operationID: id("operationID"), sequence: sequence),
            cancellation: cancellation).content
    default: throw ToolError("Unknown test request")
    }
}
