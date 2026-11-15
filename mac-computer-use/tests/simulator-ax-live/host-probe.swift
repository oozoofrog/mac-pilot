import AppKit

func axLiveProbe() -> Never {
    let env = ProcessInfo.processInfo.environment
    guard let file = env["AX_LIVE_TARGET"] else {
        if let path = env["AX_BOOT_OUTPUT"], let id = env["FIXTURE_DEVICE"], let boot = SimulatorBootIdentity.current(deviceID: id) {
            try? Data(boot.key.utf8).write(to: URL(fileURLWithPath: path), options: .atomic)
        }
        fixtureSessionProbe()
    }
    if env["AX_LCD_PHASE"] == "1" { runSimulatorInspectorLiveCheck() }
    DispatchQueue.global().async {
        do {
            let target = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: file))) as! [String: Any]
            let id = target["deviceID"] as! String
            let expected = try SimulatorAXLifetime.current(target["pid"] as! Int32)
            guard expected.executable == target["path"] as? String,
                  [expected.startSeconds, expected.startMicroseconds] == target["start"] as? [UInt64],
                  let boot = SimulatorBootIdentity.current(deviceID: id),
                  boot.key == target["boot"] as? String else { throw ToolError("Fixture lifetime/boot mismatch") }
            let device = try bootedDevice(id)
            let screen = try activeScreen(of: device)
            let scope = try SimulatorInspectionHost.prepare(device: device, screen: screen)
            guard scope.runtime == "com.apple.CoreSimulator.SimRuntime.iOS-27-2|24B114" else { throw ToolError("Unexpected runtime") }
            if let method = class_getInstanceMethod(type(of: device), NSSelectorFromString("sendAccessibilityRequestAsync:completionQueue:completionHandler:")), let encoding = method_getTypeEncoding(method) {
                try Data(String(cString: encoding).utf8).write(to: URL(fileURLWithPath: env["AX_LIVE_OUTPUT"]!).appendingPathComponent("bridge-abi.txt"))
            }
            let hostPID = target["hostPID"] as! Int32
            func validate() throws -> SimulatorAXScope {
                guard NSWorkspace.shared.frontmostApplication?.processIdentifier == hostPID,
                      SimulatorBootIdentity.current(deviceID: id) == boot,
                      try SimulatorAXLifetime.current(expected.pid) == expected,
                      try simulatorFrontPid(device) == expected.pid else { throw ToolError("Fixture/front/focus changed") }
                return try SimulatorAXHostLifecycle.shared.current(deviceID: id)
            }
            _ = try validate()
            let out = URL(fileURLWithPath: env["AX_LIVE_OUTPUT"]!)
            if let runtime = device.value(forKey: "runtime") as? NSObject, let metadata = SimulatorInspectionHost.runtimeMetadata(runtime) {
                try JSONSerialization.data(withJSONObject: ["fingerprint": metadata.fingerprint, "source": metadata.source.path], options: [.sortedKeys]).write(to: out.appendingPathComponent("runtime-metadata.json"))
            }
            let snapshot = try simulatorAXSnapshot(device, screen: screen, scope: scope, currentScope: validate)
            try JSONSerialization.data(withJSONObject: snapshot.dictionary, options: [.sortedKeys]).write(to: out.appendingPathComponent("production-snapshot.json"), options: .atomic)
            simulatorAXInvalidate(snapshot.captureID)
            let identity = try simulatorAXLiveIdentity(device, scope: scope, validate: validate) {
                _ = try validate()
                let documents = URL(fileURLWithPath: target["documents"] as! String)
                try Data().write(to: documents.appendingPathComponent("recreate.request"), options: .atomic)
                let end = Date().addingTimeInterval(2)
                while Date() < end {
                    _ = try validate()
                    if let data = try? Data(contentsOf: documents.appendingPathComponent("ax-oracle.json")),
                       let oracle = try JSONSerialization.jsonObject(with: data) as? [String: Any], oracle["generation"] as? Int == 1 { return }
                    Thread.sleep(forTimeInterval: 0.05)
                }
                throw ToolError("Independent recreation oracle timed out")
            }
            try JSONSerialization.data(withJSONObject: identity, options: [.sortedKeys]).write(to: out.appendingPathComponent("identity.json"), options: .atomic)
            let rows = identity["rows"] as? [[String: Any]] ?? []
            guard rows.count == 9, rows.allSatisfy({ $0["sameWrapper"] as? Bool == true && $0["sameTranslation"] as? Bool == true && $0["occurrences"] as? Int == 1 }),
                  identity["recreatedOldWrapperOccurrences"] as? Int == 0, identity["recreatedSameWrapper"] as? Bool == false else { throw ToolError("Actual fixture identity qualification unsupported") }
            try qualifyFixture(device, scope: scope, executable: expected.executable, validate: validate,
                               documents: URL(fileURLWithPath: target["documents"] as! String), output: out)
            SimulatorAXInspectionService.shared.invalidateAll()
            print("Fixture action measurements completed; normal product factory used")
            exit(0)
        } catch { fputs("AX live probe: \(error)\n", stderr); exit(1) }
    }
    dispatchMain()
}

// The shared baseline reader's target fields, without requiring the unrelated capture Python resource.
struct AXLiveTarget { let path: String; let start: [UInt64] }
func axLiveTarget(pid: Int32, deviceID: String) throws -> AXLiveTarget {
    guard SimulatorBootIdentity.current(deviceID: deviceID) != nil else { throw ToolError("Boot identity unavailable") }
    let current = try SimulatorAXLifetime.current(pid)
    return AXLiveTarget(path: current.executable, start: [current.startSeconds, current.startMicroseconds])
}

#if SAX_LIVE_VALIDATION
func qualifyFixture(_ device: NSObject, scope: SimulatorAXScope, executable: String,
                    validate: @escaping () throws -> SimulatorAXScope,
                    documents: URL, output: URL) throws {
    var results: [[String: Any]] = []
    let service = SimulatorAXInspectionService.shared
    func oracle() throws -> [String: Any] {
        try JSONSerialization.jsonObject(with: Data(contentsOf: documents.appendingPathComponent("ax-oracle.json"))) as! [String: Any]
    }
    func persist() throws {
        try JSONSerialization.data(withJSONObject: results, options: [.sortedKeys]).write(to: output.appendingPathComponent("actions.json"), options: .atomic)
    }
    func capture(_ clear: Bool = true, _ svc: SimulatorAXInspectionService = .shared) throws -> SimulatorAXSnapshot {
        try simulatorAXSnapshot(device, screen: try activeScreen(of: device), scope: scope, currentScope: validate)
    }
    func node(_ snapshot: SimulatorAXSnapshot, _ id: String) throws -> SimulatorAXNode {
        guard let n = snapshot.nodes.first(where: { $0.row.identifier == "fixture." + id }) else { throw ToolError("Fixture node absent: \(id)") }
        return n
    }
    @discardableResult func perform(_ name: String, _ snapshot: SimulatorAXSnapshot, _ n: SimulatorAXNode,
                                    _ operation: SimulatorAXOperation, reject: Bool = false,
                                    svc: SimulatorAXInspectionService = .shared) throws -> SimulatorAXActionResult? {
        _ = try validate()
        let before = try oracle()
        var row: [String: Any] = ["case": name, "oracleBefore": before]
        let dispatchBefore = simulatorAXLiveEvidence()["dispatches"]!
        var answer: SimulatorAXActionResult?
        do {
            answer = try svc.action(SimulatorAXActionRequest(captureID: snapshot.captureID, nodeID: n.nodeID, operation: operation))
            row["hostResult"] = answer!.dictionary
        } catch { row["error"] = String(describing: error) }
        row["dispatchDelta"] = simulatorAXLiveEvidence()["dispatches"]! - dispatchBefore
        Thread.sleep(forTimeInterval: 0.25)
        _ = try validate()
        let after = try oracle(); row["oracleAfter"] = after
        row["oracleUnchanged"] = NSDictionary(dictionary: before).isEqual(to: after)
        row["expectedRejection"] = reject
        if reject { row["rejectionObserved"] = answer == nil || answer?.delivery == "notEntered" || answer?.delivery == "notDispatched" }
        results.append(row); try persist()
        return answer
    }
    for (name, id, op) in [("press", "press", SimulatorAXOperation.press), ("increment", "adjustable", .increment), ("decrement", "adjustable", .decrement), ("coveredPress", "covered", .press)] {
        let snap = try capture(); try perform(name, snap, node(snap, id), op)
    }
    for index in 0..<2 {
        let snap = try capture(); let n = try node(snap, "custom")
        if n.customHandles.count == 2 { try perform("custom\(index)", snap, n, .customAction(n.customHandles[index])) }
        else { results.append(["case": "custom\(index)", "unsupported": "Two handles absent"]); try persist() }
    }
    let text = try capture(); let textNode = try node(text, "text")
    let setter = try perform("setString", text, textNode, .setValue(expected: .string("initial"), new: .string("edited")))
    if let receipt = setter?.receipt {
        try perform("restoreString", text, textNode, .restore(receipt: receipt))
        try perform("receiptReuse", text, textNode, .restore(receipt: receipt), reject: true)
    }
    for (name, id, op, clear) in [("secure", "secure", SimulatorAXOperation.setValue(expected: .string("initial"), new: .string("edited")), true),
                                  ("disabled", "disabled", .press, true), 
                                  ("expectedMismatch", "text", .setValue(expected: .string("wrong"), new: .string("edited")), true),
                                  ("numericUnsupported", "text", .setValue(expected: .number(1), new: .number(2)), true),
                                  ("booleanUnsupported", "text", .setValue(expected: .boolean(false), new: .boolean(true)), true)] {
        let snap = try capture(clear); try perform(name, snap, node(snap, id), op, reject: true)
    }
    let old = try capture(); let oldNode = try node(old, "press")
    _ = try capture()
    try perform("refreshRevocation", old, oldNode, .press, reject: true)
    let closed = try capture(); let closedNode = try node(closed, "press")
    service.invalidate(closed.captureID)
    try perform("closeRevocation", closed, closedNode, .press, reject: true)
    let recreated = try capture(); let oldRecreated = try node(recreated, "recreated")
    let oldGeneration = try oracle()["generation"] as! Int
    try Data().write(to: documents.appendingPathComponent("recreate.request"), options: .atomic)
    let end = Date().addingTimeInterval(2)
    while try oracle()["generation"] as? Int == oldGeneration, Date() < end { Thread.sleep(forTimeInterval: 0.05) }
    guard try oracle()["generation"] as? Int == oldGeneration + 1 else { throw ToolError("Recreation oracle missing") }
    try perform("recreatedNode", recreated, oldRecreated, .press, reject: true)
    service.invalidateAll()
    results.append(["case": "cleanup", "evidence": simulatorAXLiveEvidence()])
    try persist()
}
#endif
