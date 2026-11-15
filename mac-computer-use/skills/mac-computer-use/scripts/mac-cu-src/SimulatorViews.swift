import Foundation
import CoreFoundation
import Darwin

// DBGTargetHub's undocumented request/property protocol is retained from the original
// mac-cu view debugger implementation; collection is now owned by view-capture/capture.py.

/// A process lifetime, never a PID alone. Obtain with simulatorViewCaptureTarget before capture.
struct SimulatorViewCaptureTarget {
    let pid: Int32
    let start: [UInt64]
    let path: String
    let deviceID: String
    var json: [String: Any] { ["pid": pid, "start": start, "path": path, "deviceID": deviceID.uppercased()] }
}

final class SimulatorViewCaptureCancellation {
    private let lock = NSLock()
    private var value = false
    func cancel() { lock.lock(); value = true; lock.unlock() }
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return value }
}

struct SimulatorViewCaptureRequest {
    let target: SimulatorViewCaptureTarget
    var query = ""
    /// Only the dedicated hierarchy fixture is admitted while live validation is pending.
    var validationOnly = false
    /// Fixture-only experiment; ordinary app texture collection has no qualified target-side budget.
    var validationTextureProbe = false
}

enum SimulatorViewCaptureStatus: String {
    case success, unavailable, unsupported, cancelled, timeout, invalidRequest, invalidResponse
    case identityUnknown, identityChanged, targetUnavailable, ownershipFailed, expressionError, cleanupFailed, failed
    case noChange, rejected, conflict, expired, busy, outcomeUncertain, resultUnavailable, undoConflict
    case ownershipConflict, keyCollision, capacityExceeded, unsafeEntry
}

struct SimulatorViewCaptureResult {
    let status: SimulatorViewCaptureStatus
    let content: [String: Any]
    init(_ content: [String: Any]) throws {
        guard let raw = content["status"] as? String, let status = SimulatorViewCaptureStatus(rawValue: raw),
              JSONSerialization.isValidJSONObject(content) else { throw ToolError("Invalid UIKit capture result.") }
        self.status = status
        self.content = content
    }
}

private func simulatorViewCaptureResource() throws -> URL {
    let executable = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
    let candidates = [Bundle.main.resourceURL?.appendingPathComponent("view-capture/capture.py"),
                      executable.deletingLastPathComponent().appendingPathComponent("view-capture/capture.py")].compactMap { $0 }
    guard let resource = candidates.first(where: { FileManager.default.fileExists(atPath: $0.path) }) else {
        throw ToolError("UIKit capture resource is unavailable. Build with the canonical setup resources.")
    }
    return resource
}

/// Runs off the main thread. The supervisor owns an exact debugserver and worker, with a
/// 45s work deadline + 100s cleanup budget. No generic shell timeout or process-group kill.
private func simulatorViewCaptureHelper(arguments: [String], cancellation: SimulatorViewCaptureCancellation,
                                        folder: URL) throws -> [String: Any] {
    guard !Thread.isMainThread else { throw ToolError("UIKit capture must run off the main thread.") }
    let resource = try simulatorViewCaptureResource()
    let output = folder.appendingPathComponent("result.json")
    FileManager.default.createFile(atPath: output.path, contents: nil, attributes: [.posixPermissions: 0o600])
    let handle = try FileHandle(forWritingTo: output)
    defer { try? handle.close() }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
    process.arguments = ["python3", "-I", resource.path] + arguments
    process.standardOutput = handle
    process.standardError = FileHandle.nullDevice
    process.standardInput = FileHandle.nullDevice
    // Do not propagate Python injection, dyld injection or native-test entry markers.
    process.environment = ProcessInfo.processInfo.environment.filter {
        !$0.key.hasPrefix("PYTHON") && !$0.key.hasPrefix("DYLD_") && !$0.key.hasPrefix("MAC_CU_")
    }
    let deadline = Date().addingTimeInterval(160)
    try process.run()
    var forced = false
    while process.isRunning {
        if cancellation.isCancelled {
            FileManager.default.createFile(atPath: folder.appendingPathComponent("cancel").path,
                                           contents: Data(), attributes: [.posixPermissions: 0o600])
        }
        if Date() >= deadline {
            // This is only our unreaped supervisor child. Its inner 145s budget has expired.
            process.terminate()
            let grace = Date().addingTimeInterval(3)
            while process.isRunning && Date() < grace { Thread.sleep(forTimeInterval: 0.025) }
            if process.isRunning { Darwin.kill(process.processIdentifier, SIGKILL) }
            forced = true
            break
        }
        Thread.sleep(forTimeInterval: 0.025)
    }
    process.waitUntilExit()
    if forced { throw ToolError("Capture supervisor exceeded cleanup deadline; recovery is unverified. Evidence: \(folder.path)") }
    let size = (try FileManager.default.attributesOfItem(atPath: output.path)[.size] as? NSNumber)?.intValue ?? 0
    guard size <= 32 * 1024 * 1024,
          let value = try JSONSerialization.jsonObject(with: Data(contentsOf: output)) as? [String: Any],
          value["status"] is String else { throw ToolError("Invalid UIKit capture helper response.") }
    return value
}

private func simulatorViewCaptureFolder() throws -> URL {
    // Foundation URL resolution can retain /var; the nofollow reader needs /private/var.
    guard let temporaryPath = realpath(FileManager.default.temporaryDirectory.path, nil) else {
        throw ToolError("Cannot resolve private capture temporary directory.")
    }
    defer { free(temporaryPath) }
    let folder = URL(fileURLWithPath: String(cString: temporaryPath)).appendingPathComponent("mac-cu-views-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false,
                                          attributes: [.posixPermissions: 0o700])
    return folder
}

/// Read-only identity probe. This does not attach, launch, stop or resume the app.
func simulatorViewCaptureTarget(pid: Int32, deviceID: String) throws -> SimulatorViewCaptureTarget {
    do {
        let identity = try SimulatorTargetIdentity.read(pid: pid, deviceID: deviceID)
        return SimulatorViewCaptureTarget(pid: identity.pid, start: identity.start,
                                          path: identity.path, deviceID: identity.deviceID)
    } catch { throw ToolError(String(describing: error)) }
}

/// Production backend, callable for guarded isolated validation. Publish only after verified detach
/// and same-lifetime recovery. Consumers must keep capture UI and coordinate overlays disabled.
func simulatorCaptureViews(_ request: SimulatorViewCaptureRequest,
                           cancellation: SimulatorViewCaptureCancellation = SimulatorViewCaptureCancellation()) throws -> SimulatorViewCaptureResult {
    guard request.target.pid > 0, request.target.start.count == 2, request.target.start[0] > 0,
          request.target.start[1] < 1_000_000, request.target.path.hasPrefix("/"),
          !request.target.path.contains("\0"), UUID(uuidString: request.target.deviceID) != nil,
          request.query.utf8.count <= 1024, !request.query.contains("\0") else { throw ToolError("Invalid UIKit capture request.") }
    guard !request.validationTextureProbe || request.validationOnly else { throw ToolError("Texture probe requires fixture validation.") }
    if !request.validationOnly {
        return try SimulatorViewCaptureResult(["schemaVersion": 1, "status": "unavailable", "verified": false, "overlayEnabled": false,
                "message": "UIKit capture is unverified and disabled for ordinary apps.", "target": request.target.json])
    }
    let folder = try simulatorViewCaptureFolder()
    // Preserve failure evidence; successful captures leave no temporary artifacts.
    var succeeded = false
    defer { if succeeded { try? FileManager.default.removeItem(at: folder) } }
    let file = folder.appendingPathComponent("request.json")
    var wire: [String: Any] = ["schemaVersion": 1, "target": request.target.json,
                               "query": request.query, "validationOnly": request.validationOnly]
    if request.validationTextureProbe { wire["validationTextureProbe"] = true }
    try JSONSerialization.data(withJSONObject: wire).write(to: file)
    var result = try simulatorViewCaptureHelper(arguments: ["--capture", file.path], cancellation: cancellation, folder: folder)
    if result["status"] as? String == "success" {
        guard let hierarchy = result["hierarchy"] as? [String: Any], let groups = hierarchy["topLevelGroups"] as? [String: Any],
              let captureID = result["captureID"] as? String, let time = result["captureTime"] as? String else {
            throw ToolError("Invalid UIKit hierarchy result. Evidence: \(folder.path)")
        }
        var snapshot = try simulatorViewHierarchySnapshot(groups: groups, pid: request.target.pid, captureID: captureID,
                                                          capturedAt: time, geometry: result["geometry"] as? [String: Any])
        snapshot["processLifetime"] = request.target.json
        snapshot["screenGeometry"] = result["geometry"] ?? NSNull()
        snapshot["verified"] = false
        snapshot["overlayEnabled"] = false
        snapshot["coordinateLimit"] = "Runtime bounds corners in UIScreen.fixedCoordinateSpace points; clipping and LCD alignment unverified."
        result["snapshot"] = snapshot
        result["text"] = simulatorViewsText(groups: groups, pid: request.target.pid, query: request.query,
                                             seconds: Int((result["elapsedSeconds"] as? Double ?? 0).rounded()))
        succeeded = true
    } else { result["evidenceDirectory"] = folder.path }
    return try SimulatorViewCaptureResult(result)
}

/// Ordinary MCP/UI callers cannot opt in to fixture validation or reach a legacy direct attach.
func simulatorViews(pid: Int32, deviceID: String, query: String) throws -> SimulatorViewCaptureResult {
    guard pid > 0, UUID(uuidString: deviceID) != nil, query.utf8.count <= 1024, !query.contains("\0") else {
        throw ToolError("Invalid UIKit views request.")
    }
    return try SimulatorViewCaptureResult(["schemaVersion": 1, "status": "unavailable", "verified": false, "overlayEnabled": false,
            "pid": pid, "deviceID": deviceID, "message": "UIKit capture is unverified and disabled. Isolated fixture validation is required."])
}

private let layoutAttributes = ["", "left", "right", "top", "bottom", "leading", "trailing", "width", "height", "centerX",
                                "centerY", "lastBaseline", "firstBaseline", "leftMargin", "rightMargin", "topMargin",
                                "bottomMargin", "leadingMargin", "trailingMargin", "centerXWithinMargins", "centerYWithinMargins"]
private let layoutRelations = [-1: "<=", 0: "=", 1: ">="]

/// The text fallback renders the same raw response as the structured snapshot. Frames are
/// superview observations and must never be accumulated into inferred screen rectangles.
func simulatorViewsText(groups: [String: Any], pid: Int32, query: String, seconds: Int, maxLines: Int = 400) -> String {
    func value(_ object: [String: Any], _ name: String) -> Any? {
        (object["properties"] as? [[String: Any]])?.first { $0["propertyName"] as? String == name }?["propertyValue"]
    }
    func number(_ any: Any?) -> Double? {
        guard let value = (any as? String).flatMap({ Double($0) }), value.isFinite else { return nil }
        return value  // Includes hexadecimal floats, "0x1.d2p+8".
    }
    func short(_ n: Double) -> String { String(format: n == n.rounded() ? "%.0f" : "%.1f", n) }

    // Constraints by the address of their first item.
    var constraintsOf: [String: [String]] = [:]
    var names: [String: String] = [:]
    func collect(_ any: Any?) {
        if let list = any as? [Any] { list.forEach(collect); return }
        guard let object = any as? [String: Any] else { return }
        if let id = object["objectID"] as? String, let cls = object["className"] as? String { names[id] = cls }
        object.values.forEach { if $0 is [Any] || $0 is [String: Any] { collect($0) } }
    }
    collect(groups)
    for case let constraint as [String: Any] in ((groups["com.apple.UIKit.NSLayoutConstraint"] as? [String: Any])?["debugHierarchyObjects"] as? [Any] ?? []) {
        guard value(constraint, "active") as? String != "0", let first = value(constraint, "firstItem") as? [String: Any],
              let firstAddress = first["memoryAddress"] as? String else { continue }
        func attribute(_ key: String) -> String {
            let n = Int(value(constraint, key) as? String ?? "") ?? 0
            return layoutAttributes[safe: n].flatMap { $0.isEmpty ? nil : $0 } ?? "attribute(\(n))"
        }
        var line = "\(attribute("firstAttribute")) \(layoutRelations[Int(value(constraint, "relation") as? String ?? "0") ?? 0] ?? "?") "
        if let second = value(constraint, "secondItem") as? [String: Any], let address = second["memoryAddress"] as? String {
            let other = address == firstAddress ? "self" : "\((second["className"] as? String ?? "?").split(separator: ".").last ?? "")(\(address))"
            line += "\(other).\(attribute("secondAttribute"))"
            if let m = number(value(constraint, "multiplier")), m != 1 { line += " × \(short(m))" }
            if let c = number(value(constraint, "constant")), c != 0 { line += c > 0 ? " + \(short(c))" : " − \(short(-c))" }
        } else {
            line += short(number(value(constraint, "constant")) ?? 0)
        }
        if let p = number(value(constraint, "priority")), p != 1000 { line += " @\(short(p))" }
        if let id = value(constraint, "identifier") as? String, !id.isEmpty { line += " id=\(id)" }
        constraintsOf[firstAddress, default: []].append(line)
    }

    // The views, from the windows down.
    var lines: [String] = []
    let wanted = query.lowercased()
    func describe(_ view: [String: Any], depth: Int, inMatch: Bool) {
        let id = view["objectID"] as? String ?? "?", cls = view["className"] as? String ?? "?"
        let identifier = value(view, "accessibilityIdentifier") as? String ?? "", label = value(view, "accessibilityLabel") as? String ?? ""
        let matches = inMatch || wanted.isEmpty || [cls, identifier, label].contains { $0.lowercased().contains(wanted) }
        if matches {
            guard lines.count < maxLines else { return }
            var line = String(repeating: "  ", count: depth) + cls + " (\(id))"
            if let f = (value(view, "frame") as? [Any])?.compactMap(number), f.count == 4 {
                line += " \(short(f[0])),\(short(f[1])) \(short(f[2]))×\(short(f[3]))"
            }
            if value(view, "hidden") as? String == "1" { line += " hidden" }
            if let a = number(value(view, "alpha")), a < 1 { line += " alpha=\(short(a))" }
            if !identifier.isEmpty { line += " id=\(identifier)" }
            if !label.isEmpty { line += " \"\(label.prefix(60))\"" }
            if let text = value(view, "text") as? String, !text.isEmpty { line += " text=\"\(text.prefix(60))\"" }
            lines.append(line)
            for c in constraintsOf[id] ?? [] where lines.count < maxLines { lines.append(String(repeating: "  ", count: depth + 1) + "| " + c) }
        }
        let children = ((view["childGroup"] as? [String: Any])?["debugHierarchyObjects"] as? [Any]) ?? []
        for case let child as [String: Any] in children { describe(child, depth: matches ? depth + 1 : depth, inMatch: matches && !wanted.isEmpty) }
    }
    for case let window as [String: Any] in ((groups["com.apple.UIKit.UIWindow"] as? [String: Any])?["debugHierarchyObjects"] as? [Any] ?? []) {
        describe(window, depth: 0, inMatch: false)
    }
    let header = """
        Views of pid \(pid) (\(names.count) objects; capture session \(seconds) s; UIKit and screen alignment unverified). \
        Each line: class (address) x,y width×height in its superview, then hidden, alpha, id, label, text. \
        Lines with | are the view's active constraints (first item is the view; self is the view).
        """
    if lines.isEmpty { return header + "\n" + (wanted.isEmpty ? "No window." : "No view matches \"\(query)\".") }
    return header + "\n" + lines.joined(separator: "\n") + (lines.count >= maxLines ? "\n… more views: use query to narrow." : "")
}

private extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}

// MARK: - Internal fixture-only editable protocol (schema 2)

/// These APIs use the same supervisor and cancellation object as schema 1. Root
/// serializes operations and supplies the exact target lifetime; no UI state lives here.
enum SimulatorViewEditableValue: Equatable {
    case hidden(Bool)
    case alpha(Double)
    var property: String { if case .hidden = self { return "hidden" }; return "alpha" }
    var json: Any { switch self { case .hidden(let value): return value; case .alpha(let value): return value } }
    var isValid: Bool { if case .alpha(let n) = self { return n.isFinite && (0...1).contains(n) }; return true }
}

struct SimulatorViewEditingContext {
    let target: SimulatorViewCaptureTarget
    let ownerID: UUID
    let inspectionID: UUID
    let targetEpoch: UUID
    let captureID: UUID
    let validationOnly: Bool
    /// Retain this even when a completion is stale. Release uses these exact IDs.
    init(target: SimulatorViewCaptureTarget, ownerID: UUID, inspectionID: UUID, targetEpoch: UUID, captureID: UUID, validationOnly: Bool = false) {
        self.target = target; self.ownerID = ownerID; self.inspectionID = inspectionID
        self.targetEpoch = targetEpoch; self.captureID = captureID; self.validationOnly = validationOnly
    }
    init(target: SimulatorViewCaptureTarget, result: SimulatorViewCaptureResult) throws {
        guard let owner = (result.content["ownerID"] as? String).flatMap(UUID.init(uuidString:)),
              let inspection = (result.content["inspectionID"] as? String).flatMap(UUID.init(uuidString:)),
              let epoch = (result.content["targetEpoch"] as? String).flatMap(UUID.init(uuidString:)),
              let capture = (result.content["captureID"] as? String).flatMap(UUID.init(uuidString:)),
              let validationOnly = result.content["validationOnly"] as? Bool,
              let returned = result.content["target"] as? [String: Any],
              NSDictionary(dictionary: returned).isEqual(to: target.json) else {
            throw ToolError("Editable result does not attest the requested target and generation.")
        }
        self.init(target: target, ownerID: owner, inspectionID: inspection, targetEpoch: epoch, captureID: capture, validationOnly: validationOnly)
    }
}

struct SimulatorViewEditIdentity {
    let editToken: UUID
    let expectedParentToken: UUID?
    let expectedWindowToken: UUID
    let expectedClass: String
    init(editToken: UUID, expectedParentToken: UUID?, expectedWindowToken: UUID, expectedClass: String) {
        self.editToken = editToken; self.expectedParentToken = expectedParentToken
        self.expectedWindowToken = expectedWindowToken; self.expectedClass = expectedClass
    }
    /// Use the exact selected snapshot node. The UI envelope's token alone is not graph identity.
    init(node: [String: Any]) throws {
        guard let token = (node["editToken"] as? String).flatMap(UUID.init(uuidString:)),
              let window = (node["windowToken"] as? String).flatMap(UUID.init(uuidString:)),
              let name = node["className"] as? String, !name.isEmpty, name.utf8.count <= 512 else {
            throw ToolError("Selected node has no editable identity.")
        }
        let parent: UUID?
        if node["parentID"] is NSNull { parent = nil }
        else if let value = (node["parentID"] as? String).flatMap(UUID.init(uuidString:)) { parent = value }
        else { throw ToolError("Selected node has invalid parent identity.") }
        self.init(editToken: token, expectedParentToken: parent, expectedWindowToken: window, expectedClass: name)
    }
}

struct SimulatorViewEditableCaptureRequest {
    var inspectionScope: [String: Any]? = nil
    let target: SimulatorViewCaptureTarget
    var ownerID = UUID()
    var inspectionID = UUID()
    var operationID = UUID()
    var sequence: UInt64 = 1
    var replacing: SimulatorViewEditingContext? = nil
    /// Preserve this route immutably through refresh, edit, revert and release.
    var validationOnly = false
}

struct SimulatorViewEditRequest {
    let context: SimulatorViewEditingContext
    let identity: SimulatorViewEditIdentity
    let expected: SimulatorViewEditableValue
    let value: SimulatorViewEditableValue
    var operationID = UUID()
    let sequence: UInt64
}

struct SimulatorViewRevertRequest {
    let context: SimulatorViewEditingContext
    let undoToken: UUID
    var operationID = UUID()
    let sequence: UInt64
}

enum SimulatorViewReleaseReason: String { case close, refresh, expired, cancel, targetChanged }
struct SimulatorViewReleaseRequest {
    let context: SimulatorViewEditingContext
    let reason: SimulatorViewReleaseReason
    var operationID = UUID()
    let sequence: UInt64
}

enum SimulatorViewMutationOutcome: String {
    case notEntered, appliedObserved, enteredUnverified, uncertain, notApplicable
}

struct SimulatorViewMutationResult {
    let status: SimulatorViewCaptureStatus
    let operationID: UUID
    let mutationOutcome: SimulatorViewMutationOutcome
    let before: SimulatorViewEditableValue?
    let requested: SimulatorViewEditableValue?
    let observed: SimulatorViewEditableValue?
    let undoToken: UUID?
    let needsRefresh: Bool
    let cleanup: [String: Any]
    let content: [String: Any]
    init(_ content: [String: Any], operationID: UUID) throws {
        let parsed = try SimulatorViewCaptureResult(content)
        guard let responseID = (content["operationID"] as? String).flatMap(UUID.init(uuidString:)), responseID == operationID,
              let outcome = (content["mutationOutcome"] as? String).flatMap(SimulatorViewMutationOutcome.init(rawValue:)),
              let refresh = content["needsRefresh"] as? NSNumber, CFGetTypeID(refresh) == CFBooleanGetTypeID(),
              let cleanup = content["cleanup"] as? [String: Any] else { throw ToolError("Invalid edit receipt identity or outcome.") }
        func typed(_ key: String) throws -> SimulatorViewEditableValue? {
            guard let raw = content[key], !(raw is NSNull) else { return nil }
            guard let n = raw as? NSNumber else { throw ToolError("Invalid typed edit receipt value.") }
            if CFGetTypeID(n) == CFBooleanGetTypeID() { return .hidden(n.boolValue) }
            guard n.doubleValue.isFinite, (0...1).contains(n.doubleValue) else { throw ToolError("Invalid alpha receipt.") }
            return .alpha(n.doubleValue)
        }
        status = parsed.status; self.operationID = responseID; mutationOutcome = outcome
        before = try typed("before"); requested = try typed("requested"); observed = try typed("observed")
        if let token = content["undoToken"] as? String {
            guard let value = UUID(uuidString: token) else { throw ToolError("Invalid server undo token.") }; undoToken = value
        } else { undoToken = nil }
        needsRefresh = refresh.boolValue; self.cleanup = cleanup; self.content = content
    }
}

private func simulatorViewOperationWire(_ context: SimulatorViewEditingContext, kind: String,
                                        operationID: UUID, sequence: UInt64) -> [String: Any] {
    ["schemaVersion": 2, "kind": kind, "target": context.target.json, "validationOnly": context.validationOnly,
     "ownerID": context.ownerID.uuidString, "inspectionID": context.inspectionID.uuidString,
     "targetEpoch": context.targetEpoch.uuidString, "captureID": context.captureID.uuidString,
     "operationID": operationID.uuidString, "sequence": sequence]
}

private func simulatorViewEditableHelper(_ wire: [String: Any], cancellation: SimulatorViewCaptureCancellation) throws -> [String: Any] {
    guard !Thread.isMainThread else { throw ToolError("UIKit editing must run off the main thread.") }
    let folder = try simulatorViewCaptureFolder()
    let file = folder.appendingPathComponent("request.json")
    // Preserve schema 2 evidence even on success: mutation receipt and safe-entry stack
    // are distinct from target cleanup, and may be required for explicit reconciliation.
    let data = try JSONSerialization.data(withJSONObject: wire)
    guard FileManager.default.createFile(atPath: file.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
        throw ToolError("Cannot create private editable request.")
    }
    do {
        var result = try simulatorViewCaptureHelper(arguments: ["--capture", file.path], cancellation: cancellation, folder: folder)
        result["evidenceDirectory"] = folder.path
        return result
    } catch {
        // A transport error cannot prove the setter was never entered. The durable
        // reservation remains quarantined; do not invent another operation ID.
        return ["schemaVersion": 2, "status": "cleanupFailed", "operationID": wire["operationID"]!,
                "mutationOutcome": "uncertain", "setterEntered": false, "needsRefresh": true,
                "before": NSNull(), "requested": wire["value"] ?? NSNull(), "observed": NSNull(),
                "undoToken": NSNull(), "cleanup": ["verified": false],
                "message": String(describing: error), "evidenceDirectory": folder.path]
    }
}

func simulatorCaptureEditableViews(_ request: SimulatorViewEditableCaptureRequest,
    cancellation: SimulatorViewCaptureCancellation = SimulatorViewCaptureCancellation()) throws -> SimulatorViewCaptureResult {
    if let old = request.replacing, !NSDictionary(dictionary: old.target.json).isEqual(to: request.target.json) {
        throw ToolError("Refresh target lifetime differs from the existing inspection.")
    }
    var wire: [String: Any] = ["schemaVersion": 2, "kind": "capture", "target": request.target.json, "validationOnly": request.replacing?.validationOnly ?? request.validationOnly,
        "ownerID": (request.replacing?.ownerID ?? request.ownerID).uuidString,
        "inspectionID": (request.replacing?.inspectionID ?? request.inspectionID).uuidString,
        "targetEpoch": request.replacing?.targetEpoch.uuidString as Any? ?? NSNull(),
        "replaceCaptureID": request.replacing?.captureID.uuidString as Any? ?? NSNull(),
        "operationID": request.operationID.uuidString, "sequence": request.sequence]
    if let scope = request.inspectionScope { wire["inspectionScope"] = scope }
    var result = try simulatorViewEditableHelper(wire, cancellation: cancellation)
    if result["status"] as? String == "success" {
        do { result["snapshot"] = try simulatorEditableViewHierarchySnapshot(result: result, target: request.target.json) }
        catch { result["status"] = "invalidResponse"; result["message"] = String(describing: error); result["needsRefresh"] = true }
    }
    return try SimulatorViewCaptureResult(result)
}

func simulatorEditView(_ request: SimulatorViewEditRequest,
    cancellation: SimulatorViewCaptureCancellation = SimulatorViewCaptureCancellation()) throws -> SimulatorViewMutationResult {
    guard request.expected.isValid, request.value.isValid, request.expected.property == request.value.property else {
        throw ToolError("Edit requires matching hidden Boolean or finite alpha values in 0...1.")
    }
    var wire = simulatorViewOperationWire(request.context, kind: "edit", operationID: request.operationID, sequence: request.sequence)
    wire.merge(["nodeToken": request.identity.editToken.uuidString,
        "expectedParentToken": request.identity.expectedParentToken?.uuidString as Any? ?? NSNull(),
        "expectedWindowToken": request.identity.expectedWindowToken.uuidString,
        "expectedClass": request.identity.expectedClass, "property": request.value.property,
        "expectedValue": request.expected.json, "value": request.value.json]) { _, new in new }
    return try SimulatorViewMutationResult(simulatorViewEditableHelper(wire, cancellation: cancellation), operationID: request.operationID)
}

func simulatorRevertView(_ request: SimulatorViewRevertRequest,
    cancellation: SimulatorViewCaptureCancellation = SimulatorViewCaptureCancellation()) throws -> SimulatorViewMutationResult {
    var wire = simulatorViewOperationWire(request.context, kind: "revert", operationID: request.operationID, sequence: request.sequence)
    wire["undoToken"] = request.undoToken.uuidString
    return try SimulatorViewMutationResult(simulatorViewEditableHelper(wire, cancellation: cancellation), operationID: request.operationID)
}

/// Explicit release revokes host authority even if target cleanup fails; it never reverses a property.
func simulatorReleaseViews(_ request: SimulatorViewReleaseRequest,
    cancellation: SimulatorViewCaptureCancellation = SimulatorViewCaptureCancellation()) throws -> SimulatorViewMutationResult {
    var wire = simulatorViewOperationWire(request.context, kind: "release", operationID: request.operationID, sequence: request.sequence)
    wire["reason"] = request.reason.rawValue
    return try SimulatorViewMutationResult(simulatorViewEditableHelper(wire, cancellation: cancellation), operationID: request.operationID)
}

/// Called only by the explicit inspector button after verified session release.
func simulatorPrepareSwiftUIRecording(target: SimulatorViewCaptureTarget, scope: SimulatorAXScope,
    cancellation: SimulatorViewCaptureCancellation) throws -> [String: Any] {
    let folder = try simulatorViewCaptureFolder()
    let file = folder.appendingPathComponent("recording-request.json")
    let wire: [String: Any] = ["explicitClick": true, "target": target.json,
        "scope": ["deviceID": scope.deviceID, "bootIdentity": scope.deviceLifetime,
                  "presentation": scope.presentation, "generation": scope.generation, "runtime": scope.runtime]]
    let data = try JSONSerialization.data(withJSONObject: wire)
    guard FileManager.default.createFile(atPath: file.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
        throw ToolError("Cannot create private recording preparation request.")
    }
    var result = try simulatorViewCaptureHelper(arguments: ["--prepare-recording", file.path], cancellation: cancellation, folder: folder)
    result["evidenceDirectory"] = folder.path
    return result
}
