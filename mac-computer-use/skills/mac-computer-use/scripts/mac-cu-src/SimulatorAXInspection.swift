import AppKit

/// One executor for translator, tokens, lazy requests and retained sessions. Completion never uses it.
enum SimulatorAXExecutor {
    static let queue = DispatchQueue(label: "mac-cu.simulator-ax.owner", autoreleaseFrequency: .workItem)
    private static let key = DispatchSpecificKey<Bool>()
    private static let installed: Void = queue.setSpecific(key: key, value: true)
    static func sync<T>(_ body: () throws -> T) rethrows -> T {
        _ = installed
        if DispatchQueue.getSpecific(key: key) == true { return try body() }
        return try queue.sync(execute: body)
    }
}

final class SimulatorAXBudget {
    let deadline: DispatchTime
    private let lock = NSLock()
    private var stopped = false
    init(seconds: Double = 5) { deadline = .now() + min(60, max(0, seconds.isFinite ? seconds : 0)) }
    func cancel() { lock.lock(); stopped = true; lock.unlock() }
    var cancelled: Bool { lock.lock(); defer { lock.unlock() }; return stopped }
    func check() throws {
        if cancelled { throw ToolError("AX operation cancelled") }
        if DispatchTime.now() >= deadline { throw ToolError("AX whole-operation deadline exceeded") }
    }
}

/// Callback owns only this terminal cell, never the session, token, device or bridge.
final class SimulatorAXReply {
    private let lock = NSLock()
    private let done = DispatchSemaphore(value: 0)
    private var terminal = false
    private var response: AnyObject?
    func finish(_ answer: AnyObject?) {
        lock.lock(); defer { lock.unlock() }
        guard !terminal else { return }
        terminal = true; response = answer; done.signal()
    }
    func wait(_ budget: SimulatorAXBudget) -> AnyObject? {
        while !budget.cancelled && DispatchTime.now() < budget.deadline {
            if done.wait(timeout: min(budget.deadline, .now() + .milliseconds(10))) == .success { break }
        }
        lock.lock(); defer { lock.unlock() }
        if budget.cancelled || DispatchTime.now() >= budget.deadline { terminal = true; response = nil }
        terminal = true
        let answer = response; response = nil
        return answer
    }
}

enum SimulatorAXFailure: Error { case targetChanged, staleCapture, expiredCapture }

struct SimulatorAXLifetime: Equatable {
    let pid: Int32
    let startSeconds: UInt64
    let startMicroseconds: UInt64
    let executable: String
    static func current(_ pid: Int32) throws -> Self {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { throw ToolError("AX target lifetime unavailable") }
        var path = [CChar](repeating: 0, count: 4096)
        guard proc_pidpath(pid, &path, UInt32(path.count)) > 0 else { throw ToolError("AX executable unavailable") }
        return Self(pid: pid, startSeconds: info.pbi_start_tvsec, startMicroseconds: info.pbi_start_tvusec, executable: String(cString: path))
    }
    var dictionary: [String: Any] { ["pid": pid, "startSeconds": startSeconds, "startMicroseconds": startMicroseconds, "executable": executable] }
}

struct SimulatorAXScope: Equatable {
    let deviceID: String
    let deviceLifetime: String
    let presentation: String
    let generation: UInt64
    let runtime: String
    /// AXP namespace; nil is not zero. Legacy front-app reads separately use established display zero.
    let qualifiedAXPDisplay: UInt32?
    var dictionary: [String: Any] {
        var d: [String: Any] = ["deviceID": deviceID, "deviceLifetime": deviceLifetime, "presentation": presentation, "generation": generation, "runtime": runtime]
        if let qualifiedAXPDisplay { d["axpDisplay"] = qualifiedAXPDisplay }
        return d
    }
}

enum SimulatorAXValue: Equatable {
    case string(String), number(Double), boolean(Bool)
    init?(_ object: Any?) {
        if let n = object as? NSNumber {
            if CFGetTypeID(n) == CFBooleanGetTypeID() { self = .boolean(n.boolValue) }
            else { guard n.doubleValue.isFinite else { return nil }; self = .number(n.doubleValue) }
        } else if let s = object as? String, s.utf16.count <= 65536 { self = .string(s) }
        else { return nil }
    }
    var object: Any { switch self { case .string(let s): return s; case .number(let n): return n; case .boolean(let b): return b } }
    var kind: String { switch self { case .string: return "string"; case .number: return "number"; case .boolean: return "boolean" } }
    var dictionary: [String: Any] { ["type": kind, "value": object] }
}

struct SimulatorAXDetail {
    let status: String
    let value: Any?
    let diagnostic: String
    init(_ result: SAXResult) {
        switch result.status {
        case .SAXOK: status = "available"
        case .SAXNil: status = "nil"
        case .SAXRedacted: status = "redacted"
        case .SAXUnsupportedABI, .SAXUnsupportedSelector, .SAXUnsupportedCapability: status = "unsupported"
        default: status = "failed"
        }
        // Snapshots must never retain opaque wrappers, parent/child arrays or custom actions.
        let object = result.objectValue
        value = (object is String || object is NSNumber || object is NSValue || object is [String]) ? object : nil
        diagnostic = result.diagnostic
    }
    var dictionary: [String: Any] {
        var d: [String: Any] = ["status": status, "diagnostic": diagnostic]
        if let v = value as? String { d["value"] = v }
        else if let v = value as? NSNumber { d["value"] = v }
        else if let v = value as? [String] { d["value"] = v }
        else if let v = value as? NSValue {
            if String(cString: v.objCType).contains("CGPoint") { d["value"] = NSStringFromPoint(v.pointValue) }
            else { d["value"] = NSStringFromRect(v.rectValue) }
        }
        return d
    }
}

struct SimulatorAXNode {
    let nodeID: String
    let parentID: String?
    let childIDs: [String]
    let row: SimulatorElement
    let sourceFrame: CGRect
    let details: [String: SimulatorAXDetail]
    let typedValue: SimulatorAXValue?
    let customHandles: [String]
    let customNames: [String: SimulatorAXDetail]
    let capabilities: SimulatorAXCapabilities
    var dictionary: [String: Any] {
        var d = row.inspectionData
        d["nodeID"] = nodeID; d["parentID"] = parentID ?? NSNull(); d["childIDs"] = childIDs
        d["sourceFrame"] = ["x": sourceFrame.minX, "y": sourceFrame.minY, "width": sourceFrame.width, "height": sourceFrame.height]
        d["fields"] = details.mapValues(\.dictionary)
        d["capabilities"] = capabilities.dictionary
        d["customActionHandles"] = customHandles
        d["customActions"] = customHandles.map { ["handle": $0, "name": customNames[$0]!.dictionary] as [String: Any] }
        if let typedValue { d["typedValue"] = typedValue.dictionary }
        return d
    }
}

struct SimulatorAXSnapshot {
    let captureID: String
    let target: SimulatorAXLifetime
    let scope: SimulatorAXScope
    let started: UInt64
    let finished: UInt64
    let nodes: [SimulatorAXNode]
    let truncations: [String]
    let qualificationFingerprint: [String: String]
    var retentionSeconds: Double = 15
    var dictionary: [String: Any] {
        ["captureID": captureID, "target": target.dictionary, "scope": scope.dictionary,
         "startedMonotonicNS": started, "finishedMonotonicNS": finished, "expiresMonotonicNS": finished + UInt64(retentionSeconds * 1_000_000_000), "truncations": truncations,
         "nodes": nodes.map { node -> [String: Any] in var d = node.dictionary; d["captureID"] = captureID; return d },
         "qualificationFingerprint": qualificationFingerprint,
         "identityQualification": "retained capture objects; no identity guarantee across guest destruction"]
    }
}

/// Internal evidence profiles. No transport parser can construct or enable these.
struct SimulatorAXQualification {
    var fingerprint: [String: String] = [:]
    var reason = "Unqualified runtime or native provenance"
    var verifiedRuntime: String?
    var verifiedExecutable: String?
    var semanticActions = false
    var exactGuestIdentity = false
    var clearProtection = false
    var pointMapping = false
    var valueDomain: ((SimulatorAXValue) -> Bool)?
}

/// Immutable capture evidence. Backend preflight is authoritative after capture.
struct SimulatorAXCapabilities {
    let operations: [String]
    let reasons: [String]
    var dictionary: [String: Any] { ["operations": operations, "reasons": reasons] }
}

/// Closed, internal product policy. The runtime string encodes identifier AND build, never name.
enum SimulatorAXProductProfile {
    static let runtime = "com.apple.CoreSimulator.SimRuntime.iOS-27-2|24B114"
    static let axpImage = "/System/Library/PrivateFrameworks/AccessibilityPlatformTranslation.framework/AccessibilityPlatformTranslation"
    static let coreImage = "/Library/Developer/PrivateFrameworks/CoreSimulator.framework/CoreSimulator"
    static func canonicalImage(_ path: String) -> String {
        // A dyld-cache executable has no file on disk. Resolve its explicit symlink
        // and existing parent directories without requiring the leaf to exist.
        var url = URL(fileURLWithPath: path).standardizedFileURL
        for _ in 0..<8 {
            guard let target = try? FileManager.default.destinationOfSymbolicLink(atPath: url.path) else {
                return url.deletingLastPathComponent().resolvingSymlinksInPath().appendingPathComponent(url.lastPathComponent).path
            }
            url = (target.hasPrefix("/") ? URL(fileURLWithPath: target) : url.deletingLastPathComponent().appendingPathComponent(target)).standardizedFileURL
        }
        return "" // Cyclic or excessive symlink traversal cannot qualify.
    }
    static func select(runtime actual: String, executable: String, metadata: [String: String]) -> SimulatorAXQualification {
        let expected = ["architecture": "arm64", "hostBuild": "26B123", "xcodeVersion": "27.2", "xcodeBuild": "27B48",
                        "axpImage": canonicalImage(axpImage), "axpID": "com.apple.accessibility.AccessibilityPlatformTranslation", "axpVersion": "591.4.5",
                        "coreImage": canonicalImage(coreImage), "coreID": "com.apple.CoreSimulator", "coreVersion": "1174.20",
                        "receiverImages": "verified"]
        var q = SimulatorAXQualification()
        guard actual == runtime else { q.reason = "Runtime identifier/build is not qualified"; return q }
        guard metadata == expected, executable.hasPrefix("/"), !executable.contains("\0"), executable.utf8.count < 4096 else {
            q.reason = "Host, selected Xcode or loaded framework provenance is unavailable or unqualified"; return q
        }
        q.fingerprint = metadata.merging(["runtime": actual]) { _, new in new }
        q.verifiedRuntime = actual; q.verifiedExecutable = executable
        q.semanticActions = true; q.exactGuestIdentity = true; q.clearProtection = true
        q.valueDomain = { if case .string(let s) = $0 { return s.utf16.count < 128 }; return false }
        q.reason = "Qualified short-lived retained-wrapper actions; point mapping unavailable"
        return q
    }
    static func capabilities(_ node: SimulatorAXNode, qualification q: SimulatorAXQualification, runtime: String,
                             executable: String, complete: Bool) -> SimulatorAXCapabilities {
        func deny(_ reason: String) -> SimulatorAXCapabilities { SimulatorAXCapabilities(operations: [], reasons: [reason]) }
        guard q.semanticActions, q.exactGuestIdentity, q.verifiedRuntime == runtime, q.verifiedExecutable == executable else { return deny(q.reason) }
        guard node.details["role"]?.status == "available", !node.row.role.isEmpty else { return deny("Node role is unavailable") }
        guard complete else { return deny("Capture traversal is incomplete or truncated") }
        guard q.clearProtection, node.details["protection"]?.status == "available",
              (node.details["protection"]?.value as? NSNumber)?.boolValue == false else { return deny("Guest protection is unknown or protected") }
        guard let subrole = node.details["subrole"], ["available", "nil"].contains(subrole.status),
              subrole.value as? String != "AXSecureTextField" else { return deny("Secure or unknown subrole") }
        guard node.details["enabled"]?.status == "available", node.row.enabled == true else { return deny("Node is disabled or enabled state is unknown") }
        var ops: [String] = []
        if node.details["actions"]?.status == "available" {
            for (advertised, operation) in [("AXPress", "press"), ("AXIncrement", "increment"), ("AXDecrement", "decrement")] where node.row.supportedActions.contains(advertised) { ops.append(operation) }
        }
        if !node.customHandles.isEmpty { ops.append("custom") }
        var reasons: [String] = []
        if let value = node.typedValue, q.valueDomain?(value) == true,
           node.details["valueSettable"]?.status == "available", (node.details["valueSettable"]?.value as? NSNumber)?.boolValue == true { ops.append("setValue") }
        else { reasons.append("Value is outside the qualified domain or is not currently settable") }
        if ops.isEmpty { reasons.append("No supported operation is currently available") }
        return SimulatorAXCapabilities(operations: ops, reasons: reasons)
    }
}

/// Injectable only within this module/headless executable. No user request supplies closures or objects.
struct SimulatorAXBackend {
    let begin: (SimulatorAXBudget) -> Void
    let root: () throws -> NSObject
    let current: () throws -> (SimulatorAXLifetime, SimulatorAXScope)
    let read: (SAXField, NSObject, SAXProtection) throws -> SAXResult
    let dispatch: (SAXAction, NSObject) -> SAXResult
    let settable: (NSObject, SAXProtection) -> SAXResult
    let setValue: (Any, NSObject, SAXProtection) -> SAXResult
    let custom: (NSAccessibilityCustomAction, NSObject) -> SAXResult
    let point: (CGPoint) throws -> NSObject
    let release: () -> Void
    let normalize: (CGRect, Int, Int32) -> CGRect
    let screen: CGSize
    let qualification: SimulatorAXQualification
}

enum SimulatorAXOperation {
    case press, increment, decrement, customAction(String)
    case setValue(expected: SimulatorAXValue, new: SimulatorAXValue)
    case restore(receipt: String)
}
struct SimulatorAXActionRequest { let captureID: String; let nodeID: String; let operation: SimulatorAXOperation }
struct SimulatorAXActionResult {
    let state: String
    let delivery: String
    let readback: SimulatorAXValue?
    let receipt: String?
    var dictionary: [String: Any] {
        var d: [String: Any] = ["state": state, "delivery": delivery]
        if let readback { d["readback"] = readback.dictionary }; if let receipt { d["restoreReceipt"] = receipt }; return d
    }
}

final class SimulatorAXInspectionService {
    static let shared = SimulatorAXInspectionService()
    private struct Session {
        let snapshot: SimulatorAXSnapshot
        let backend: SimulatorAXBackend
        let expires: DispatchTime
        let objects: [NSObject]
        let custom: [String: NSAccessibilityCustomAction]
    }
    private struct Receipt { let capture: String; let node: String; let before: SimulatorAXValue; let after: SimulatorAXValue }
    private let retentionSeconds: Double
    init(retentionSeconds: Double = 15) { self.retentionSeconds = min(15, max(0.001, retentionSeconds)) }
    private var sessions: [String: Session] = [:]
    private var receipts: [String: Receipt] = [:]
    func invalidate(_ captureID: String) {
        SimulatorAXExecutor.sync {
            sessions.removeValue(forKey: captureID)?.backend.release()
            receipts = receipts.filter { $0.value.capture != captureID }
        }
    }
    func withLegacyObjects<T>(_ captureID: String, budget: SimulatorAXBudget, _ body: ([NSObject]) throws -> T) throws -> T {
        try SimulatorAXExecutor.sync {
            let s = try current(captureID, budget)
            let result = try body(s.objects)
            try budget.check()
            return result
        }
    }
    func invalidateAll() { SimulatorAXExecutor.sync { for id in Array(sessions.keys) { invalidate(id) } } }
    func capture(backend: SimulatorAXBackend, budget: SimulatorAXBudget = SimulatorAXBudget(), maxNodes: Int = 600, maxDepth: Int = 40) throws -> SimulatorAXSnapshot {
        try SimulatorAXExecutor.sync {
            let started = DispatchTime.now().uptimeNanoseconds
            var retained = false
            defer { if !retained { backend.release(); invalidateAll() } }
            backend.begin(budget)
            try budget.check()
            let (target, scope) = try backend.current()
            // Refresh revokes prior authority for this device, even if the new read fails.
            for (id, s) in sessions where s.snapshot.scope.deviceID == scope.deviceID { invalidate(id) }
            let root = try backend.root()
            let id = UUID().uuidString
            var nodes: [SimulatorAXNode] = [], objects: [NSObject] = [], seen = Set<ObjectIdentifier>()
            var custom: [String: NSAccessibilityCustomAction] = [:], truncations: [String] = []
            let protection: SAXProtection = backend.qualification.clearProtection ? .clear : .unknown
            func visit(_ object: NSObject, _ parent: String?, _ depth: Int) throws -> String? {
                try budget.check()
                guard nodes.count < min(1024, max(1, maxNodes)), depth < min(64, max(1, maxDepth)) else { truncations.append("node/depth limit"); return nil }
                guard seen.insert(ObjectIdentifier(object)).inserted else { truncations.append("cycle/shared wrapper"); return nil }
                let nodeID = UUID().uuidString, index = nodes.count
                var details: [String: SimulatorAXDetail] = [:]
                let fields: [(String, SAXField)] = [("role", .role), ("label", .label), ("identifier", .identifier), ("subrole", .subrole), ("value", .value), ("help", .help), ("enabled", .enabled), ("protection", .protectedContent), ("actions", .actions), ("frame", .frame), ("activationPoint", .activationPoint), ("parent", .parent), ("children", .children), ("customActions", .customActions)]
                var values: [String: Any] = [:]
                for (name, field) in fields {
                    try budget.check()
                    let safeValue = field != .value || ((details["subrole"]?.status == "nil" || details["subrole"]?.status == "available") && details["subrole"]?.value as? String != "AXSecureTextField")
                    let result = try backend.read(field, object, safeValue ? protection : .unknown)
                    if result.status == .SAXLimitExceeded { truncations.append("field collection/value limit") }
                    if field == .children && result.status != .SAXOK && result.status != .SAXNil { truncations.append("children unavailable") }
                    if result.status == .SAXException { throw ToolError("AX transport exception; capture invalidated") }
                    details[name] = SimulatorAXDetail(result)
                    if result.status == .SAXOK { values[name] = result.objectValue }
                    try budget.check()
                }
                if backend.qualification.semanticActions, protection == .clear,
                   (details["subrole"]?.status == "nil" || details["subrole"]?.status == "available"),
                   details["subrole"]?.value as? String != "AXSecureTextField" {
                    try budget.check()
                    details["valueSettable"] = SimulatorAXDetail(backend.settable(object, protection))
                    try budget.check()
                }
                let frame = (values["frame"] as? NSValue)?.rectValue ?? .zero
                let role = values["role"] as? String ?? ""
                let value = SimulatorAXValue(values["value"])
                var handles: [String] = [], names: [String: SimulatorAXDetail] = [:]
                for action in values["customActions"] as? [NSAccessibilityCustomAction] ?? [] {
                    guard custom.count < 1024 else { truncations.append("custom-action limit"); break }
                    let handle = UUID().uuidString; custom[handle] = action; handles.append(handle)
                    names[handle] = SimulatorAXDetail(SimulatorAXAdapter.customActionName(action))
                }
                var row = SimulatorElement(role: role.hasPrefix("AX") ? String(role.dropFirst(2)) : role, label: values["label"] as? String ?? "", identifier: values["identifier"] as? String ?? "", value: value.map { String(describing: $0.object) } ?? "", frame: backend.normalize(frame, depth, target.pid), depth: depth, screen: backend.screen)
                row.supportedActions = values["actions"] as? [String] ?? []; row.enabled = (values["enabled"] as? NSNumber)?.boolValue
                func node(_ children: [String]) -> SimulatorAXNode { SimulatorAXNode(nodeID: nodeID, parentID: parent, childIDs: children, row: row, sourceFrame: frame, details: details, typedValue: value, customHandles: handles, customNames: names, capabilities: SimulatorAXCapabilities(operations: [], reasons: ["Capture pending"])) }
                nodes.append(node([])); objects.append(object)
                var children: [String] = []
                for child in values["children"] as? [NSObject] ?? [] { if let id = try visit(child, nodeID, depth + 1) { children.append(id) } }
                nodes[index] = node(children)
                return nodeID
            }
            _ = try visit(root, nil, 0)
            try budget.check()
            let (nowTarget, nowScope) = try backend.current()
            guard target == nowTarget, scope == nowScope else { throw SimulatorAXFailure.targetChanged }
            guard sessions.count < 4 else { throw ToolError("AX retained-session limit") }
            for i in nodes.indices {
                let n = nodes[i]
                let caps = SimulatorAXProductProfile.capabilities(n, qualification: backend.qualification,
                    runtime: scope.runtime, executable: target.executable, complete: truncations.isEmpty)
                nodes[i] = SimulatorAXNode(nodeID: n.nodeID, parentID: n.parentID, childIDs: n.childIDs, row: n.row,
                    sourceFrame: n.sourceFrame, details: n.details, typedValue: n.typedValue,
                    customHandles: n.customHandles, customNames: n.customNames, capabilities: caps)
            }
            let snapshot = SimulatorAXSnapshot(captureID: id, target: target, scope: scope, started: started, finished: DispatchTime.now().uptimeNanoseconds, nodes: nodes, truncations: Array(Set(truncations)).sorted(), qualificationFingerprint: backend.qualification.fingerprint, retentionSeconds: retentionSeconds)
            sessions[id] = Session(snapshot: snapshot, backend: backend, expires: .now() + retentionSeconds, objects: objects, custom: custom)
            retained = true
            SimulatorAXExecutor.queue.asyncAfter(deadline: .now() + retentionSeconds) { [weak self] in self?.invalidate(id) }
            return snapshot
        }
    }
    private func current(_ id: String, _ budget: SimulatorAXBudget) throws -> Session {
        try budget.check()
        guard let s = sessions[id] else { throw SimulatorAXFailure.staleCapture }
        do {
            s.backend.begin(budget)
            guard DispatchTime.now() < s.expires else { throw SimulatorAXFailure.expiredCapture }
            let (target, scope) = try s.backend.current()
            guard target == s.snapshot.target, scope == s.snapshot.scope else { throw SimulatorAXFailure.targetChanged }
            try budget.check(); return s
        } catch { invalidate(id); throw error }
    }
    func point(captureID: String, point: CGPoint, budget: SimulatorAXBudget = SimulatorAXBudget()) throws -> [String: Any] {
        try SimulatorAXExecutor.sync {
            let s = try current(captureID, budget)
            guard s.backend.qualification.verifiedRuntime == s.snapshot.scope.runtime, s.backend.qualification.verifiedExecutable == s.snapshot.target.executable, s.backend.qualification.pointMapping, s.snapshot.scope.qualifiedAXPDisplay != nil else {
                return ["state": "unsupported", "reason": "No qualified presentation-to-AXP display mapping", "rectangleCandidates": "separate fallback"]
            }
            do {
                let hit = try s.backend.point(point); _ = try current(captureID, budget)
                let matches = s.objects.indices.filter { s.objects[$0] === hit }
                guard matches.count == 1 else { return ["state": "unsupported", "reason": "Hit wrapper has no unique capture binding"] }
                return ["state": "available", "nodeID": s.snapshot.nodes[matches[0]].nodeID, "captureID": captureID]
            } catch { invalidate(captureID); throw error }
        }
    }
    func action(_ request: SimulatorAXActionRequest, budget: SimulatorAXBudget = SimulatorAXBudget()) throws -> SimulatorAXActionResult {
        try SimulatorAXExecutor.sync {
            let s = try current(request.captureID, budget)
            guard s.backend.qualification.verifiedRuntime == s.snapshot.scope.runtime,
                  s.backend.qualification.verifiedExecutable == s.snapshot.target.executable,
                  s.backend.qualification.semanticActions, s.backend.qualification.exactGuestIdentity,
                  s.snapshot.truncations.isEmpty,
                  let index = s.snapshot.nodes.firstIndex(where: { $0.nodeID == request.nodeID }) else {
                return SimulatorAXActionResult(state: "unsupported", delivery: "notEntered", readback: nil, receipt: nil)
            }
            let object = s.objects[index], node = s.snapshot.nodes[index]
            let protection: SAXProtection = s.backend.qualification.clearProtection ? .clear : .unknown
            func read(_ field: SAXField) throws -> SAXResult { try budget.check(); let r = try s.backend.read(field, object, protection); try budget.check(); if r.status == .SAXException { throw ToolError("AX exception") }; return r }
            // Resolve the exact retained object uniquely in a fresh bounded traversal; IDs alone grant nothing.
            var seen = Set<ObjectIdentifier>(), matches = 0, count = 0
            func resolve(_ o: NSObject, _ depth: Int) throws {
                try budget.check(); count += 1
                guard count <= 1024, depth < 64, seen.insert(ObjectIdentifier(o)).inserted else { throw ToolError("AX ambiguous or truncated current traversal") }
                if o === object { matches += 1 }
                let r = try s.backend.read(.children, o, protection)
                guard r.status == .SAXOK || r.status == .SAXNil else { throw ToolError("AX current traversal failed") }
                for child in r.objectValue as? [NSObject] ?? [] { try resolve(child, depth + 1) }
            }
            do {
                try resolve(s.backend.root(), 0)
                guard matches == 1 else { throw ToolError("AX stale or ambiguous target") }
                guard (try read(.enabled).objectValue as? NSNumber)?.boolValue == true else { throw ToolError("AX disabled") }
                let actions = try read(.actions).objectValue as? [String] ?? []
                guard protection == .clear, (try read(.protectedContent).objectValue as? NSNumber)?.boolValue == false else { throw ToolError("AX protection unknown or protected") }
                let subrole = try read(.subrole)
                guard subrole.status == .SAXOK || subrole.status == .SAXNil, subrole.objectValue as? String != "AXSecureTextField" else { throw ToolError("AX secure or unknown subrole") }
                let before = SimulatorAXValue(try read(.value).objectValue)
                var expected: SimulatorAXValue?, new: SimulatorAXValue?
                var operation = request.operation
                if case .restore(let handle) = operation {
                    guard let r = receipts.removeValue(forKey: handle), r.capture == request.captureID, r.node == request.nodeID else { throw ToolError("AX invalid restore receipt") }
                    operation = .setValue(expected: r.after, new: r.before)
                }
                switch operation {
                case .setValue(let old, let value):
                    guard protection == .clear, let domain = s.backend.qualification.valueDomain, old.kind == value.kind, domain(old), domain(value), before == old,
                          SimulatorAXAdapterValueGuards.valid(value), SimulatorAXAdapterValueGuards.valid(old) else { throw ToolError("AX value type/domain/expected mismatch") }
                    guard (try read(.protectedContent).objectValue as? NSNumber)?.boolValue == false else { throw ToolError("AX protected") }
                    if old == value { return SimulatorAXActionResult(state: "noChange", delivery: "notEntered", readback: old, receipt: nil) }
                    let settable = s.backend.settable(object, protection)
                    guard settable.status == .SAXOK, (settable.objectValue as? NSNumber)?.boolValue == true else { throw ToolError("AX value not settable") }
                    expected = old; new = value
                case .press: guard actions.contains("AXPress") else { throw ToolError("AXPress unavailable") }
                case .increment: guard actions.contains("AXIncrement") else { throw ToolError("AXIncrement unavailable") }
                case .decrement: guard actions.contains("AXDecrement") else { throw ToolError("AXDecrement unavailable") }
                case .customAction(let handle): guard node.customHandles.contains(handle), s.custom[handle] != nil else { throw ToolError("AX stale custom action") }
                case .restore: throw ToolError("AX restore invalid")
                }
                _ = try current(request.captureID, budget)
                if let expected {
                    guard SimulatorAXValue(try read(.value).objectValue) == expected else { throw ToolError("AX expected value changed before write") }
                }
                let result: SAXResult
                switch operation {
                case .press: result = s.backend.dispatch(.press, object)
                case .increment: result = s.backend.dispatch(.increment, object)
                case .decrement: result = s.backend.dispatch(.decrement, object)
                case .customAction(let handle): result = s.backend.custom(s.custom[handle]!, object)
                case .setValue: result = s.backend.setValue(new!.object, object, protection)
                case .restore: fatalError("unreachable")
                }
                if result.status == .SAXException || result.mutationOutcome == .uncertain || budget.cancelled || DispatchTime.now() >= budget.deadline {
                    invalidate(request.captureID)
                    return SimulatorAXActionResult(state: "outcomeUncertain", delivery: "uncertain", readback: nil, receipt: nil)
                }
                guard result.mutationOutcome == .dispatched else { return SimulatorAXActionResult(state: "rejected", delivery: "notDispatched", readback: nil, receipt: nil) }
                do {
                    _ = try current(request.captureID, budget)
                    let valueReadback = try read(.value)
                    let after = valueReadback.status == .SAXOK ? SimulatorAXValue(valueReadback.objectValue) : nil
                    if new != nil && after == nil { throw ToolError("AX setter readback unavailable; delivery uncertain") }
                    _ = try current(request.captureID, budget)
                    var receipt: String?
                    if let new, after == new, let expected {
                        let id = UUID().uuidString; receipts[id] = Receipt(capture: request.captureID, node: request.nodeID, before: expected, after: new); receipt = id
                    }
                    // A receipt permits explicit restore only while this exact session and current expected value remain valid.
                    let state = new != nil ? (after == new ? "postconditionObserved" : (after == before ? "noChange" : "postconditionMismatch")) : (after == nil ? "deliveredNoReadback" : "deliveredReadback")
                    return SimulatorAXActionResult(state: state, delivery: "dispatched", readback: after, receipt: receipt)
                } catch {
                    invalidate(request.captureID)
                    return SimulatorAXActionResult(state: "outcomeUncertain", delivery: "dispatched", readback: nil, receipt: nil)
                }
            } catch { invalidate(request.captureID); throw error }
        }
    }
}
private enum SimulatorAXAdapterValueGuards {
    static func valid(_ value: SimulatorAXValue) -> Bool { SimulatorAXValue(value.object) == value }
}
