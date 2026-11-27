import Foundation

/// The helper's own budget: devicectl copies (3 × up to 45 s) plus local decoding. The parent waits a little longer so it
/// never cuts the helper off between the readback and the ready marker.
let sensorReplayHelperTimeout: TimeInterval = 150

struct SensorReplayStagingBackend {
    var identity: () -> AgentIdentity?
    var physicalAllowed: () -> UUID?
    var checkPhysicalAccess: (UUID) throws -> Void
    var approveSimulator: () throws -> Void
    var bootedSimulatorName: (String) throws -> String
    var collaborationStore: () -> CollaborationStore
    var helperPath: () -> String
    var helperTimeout: TimeInterval = sensorReplayHelperTimeout
    var isCancelled: () -> Bool
    var now: () -> Date = Date.init
}

#if !SENSOR_REPLAY_DELIVERY_SELFCHECK
extension SensorReplayStagingBackend {
    static let live = SensorReplayStagingBackend(
        identity: { currentSession?.identity },
        physicalAllowed: { currentSession?.physicalTestAllowed },
        checkPhysicalAccess: { try physicalDeviceTool.checkFixtureAccess($0) },
        approveSimulator: { try approve("Simulator", bundleID: "com.apple.iphonesimulator") },
        bootedSimulatorName: { udid in
            let device = try bootedDevice(udid)
            return device.value(forKey: "name") as? String ?? "The device"
        },
        collaborationStore: { .standard },
        helperPath: { Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/macpilot-sensor-replay").path },
        isCancelled: { currentSession?.requestCancelled == true }
    )
}

func stageSensorReplay(_ arguments: [String: Any]) throws -> [String: Any] {
    try stageSensorReplay(arguments, backend: .live)
}
#endif

func stageSensorReplay(_ arguments: [String: Any], backend: SensorReplayStagingBackend) throws -> [String: Any] {
    guard let platform = arguments["platform"] as? String,
          let id = (arguments["device"] as? String).flatMap(UUID.init(uuidString:)),
          let app = arguments["app"] as? String, !app.isEmpty,
          let fixture = arguments["fixture"] as? String, fixture.hasPrefix("/") else {
        throw ToolError("Supply platform, device UUID, app bundle ID and absolute fixture path.")
    }
    let identity = backend.identity()
    let store = backend.collaborationStore()
    var simulatorName: String?
    switch platform {
    case "device":
        guard backend.physicalAllowed() == id else { throw ToolError("Allow the device in this connection first.") }
        try backend.checkPhysicalAccess(id)
    case "simulator":
        try backend.approveSimulator()
        let name = try backend.bootedSimulatorName(id.uuidString)
        simulatorName = name
        // A listening app on a device another session holds would consume this fixture: refuse instead of warning.
        if let claim = simulatorClaimByAnother(udid: id.uuidString, identity: identity.flatMap { $0.pid > 0 ? $0 : nil },
                                               store: store, now: backend.now()) {
            throw ToolError("\(name) is in use by another agent session (\(claim.label), since \(claim.since)). "
                + "Fixtures staged there would reach that session's app. Ask for the device first: "
                + "sim-pilot request --udid \(id.uuidString) --note \"<why>\".")
        }
    default: throw ToolError("Use device or simulator.")
    }
    let task = SimulatorPreparationTask()
    if backend.isCancelled() { task.cancel() }
    // The request queue is serial: a cancelled or dropped request must stop the helper's process group now.
    let finished = DispatchSemaphore(value: 0)
    DispatchQueue.global(qos: .utility).async {
        while finished.wait(timeout: .now() + 0.05) == .timedOut {
            if backend.isCancelled() { task.cancel(); return }
        }
    }
    defer { finished.signal() }
    let output: String
    do {
        output = try task.run(backend.helperPath(), [platform, id.uuidString, app, fixture], timeout: backend.helperTimeout, stream: false)
    } catch let error as SimulatorPreparationError {
        var text = error.agentText(command: "Sensor replay staging", prefix: "Sensor replay: ")
        if error.kind == .cancelled || error.kind == .timedOut {
            text += " The fixture may or may not have been staged; the app ignores it unless its .ready marker exists."
        }
        throw ToolError(text)
    }
    guard let receipt = try? JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any] else {
        throw ToolError("Invalid sensor staging receipt.")
    }
    var content: [[String: Any]] = [["type": "text", "text": output]]
    // Staging writes to the device, so it counts as this session's use, like simulator input.
    if let simulatorName, let identity, identity.pid > 0,
       let notice = simulatorCollaborationNotice(udid: id.uuidString, name: simulatorName, mutates: true,
                                                 identity: identity, store: store, now: backend.now()) {
        content.append(["type": "text", "text": notice])
    }
    return ["content": content, "structuredContent": receipt]
}
