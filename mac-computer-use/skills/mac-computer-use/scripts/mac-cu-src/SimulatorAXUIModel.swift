import Foundation
import CoreFoundation

/// Closed wire types shared by LCD and command routing. No selector or expression input.
enum SimulatorAXWireError: Error { case invalidEnvelope }
enum SimulatorAXScalar: Equatable {
    case string(String), number(Double), boolean(Bool)
    init(_ wire: [String: Any]) throws {
        guard Set(wire.keys) == ["type", "value"], let type = wire["type"] as? String else { throw SimulatorAXWireError.invalidEnvelope }
        switch type {
        case "string":
            guard let s = wire["value"] as? String, s.utf16.count <= 65536 else { throw SimulatorAXWireError.invalidEnvelope }; self = .string(s)
        case "number":
            guard let n = wire["value"] as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(), n.doubleValue.isFinite else { throw SimulatorAXWireError.invalidEnvelope }
            let encoding = String(cString: n.objCType)
            if ["c", "s", "i", "l", "q"].contains(encoding), Double(exactly: n.int64Value) == nil { throw SimulatorAXWireError.invalidEnvelope }
            if ["C", "S", "I", "L", "Q"].contains(encoding), Double(exactly: n.uint64Value) == nil { throw SimulatorAXWireError.invalidEnvelope }
            self = .number(n.doubleValue)
        case "boolean":
            guard let n = wire["value"] as? NSNumber, CFGetTypeID(n) == CFBooleanGetTypeID() else { throw SimulatorAXWireError.invalidEnvelope }; self = .boolean(n.boolValue)
        default: throw SimulatorAXWireError.invalidEnvelope
        }
    }
    var wire: [String: Any] {
        switch self { case .string(let s): return ["type": "string", "value": s]; case .number(let n): return ["type": "number", "value": n]; case .boolean(let b): return ["type": "boolean", "value": b] }
    }
    var text: String { switch self { case .string(let s): return s; case .number(let n): return String(n); case .boolean(let b): return b ? "true" : "false" } }
    func draft(_ text: String) throws -> Self {
        switch self {
        case .string: return try Self(["type": "string", "value": text])
        case .number: guard let n = Double(text), n.isFinite, text == text.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { throw SimulatorAXWireError.invalidEnvelope }; return .number(n)
        case .boolean: guard text == "true" || text == "false" else { throw SimulatorAXWireError.invalidEnvelope }; return .boolean(text == "true")
        }
    }
}
struct SimulatorAXEnvelope {
    let captureID: String
    let nodeID: String
    let operation: String
    let expected: SimulatorAXScalar?
    let value: SimulatorAXScalar?
    let handle: String?
    init(_ wire: [String: Any]) throws {
        guard let capture = wire["captureID"] as? String, !capture.isEmpty,
              let node = wire["nodeID"] as? String, !node.isEmpty,
              let op = wire["operation"] as? String else { throw SimulatorAXWireError.invalidEnvelope }
        var keys: Set<String> = ["captureID", "nodeID", "operation"]
        var old: SimulatorAXScalar?, new: SimulatorAXScalar?, token: String?
        switch op {
        case "press", "increment", "decrement": break
        case "custom", "restore":
            keys.insert("handle"); guard let h = wire["handle"] as? String, !h.isEmpty else { throw SimulatorAXWireError.invalidEnvelope }; token = h
        case "setValue":
            keys.formUnion(["expected", "value"])
            guard let e = wire["expected"] as? [String: Any], let v = wire["value"] as? [String: Any] else { throw SimulatorAXWireError.invalidEnvelope }
            old = try SimulatorAXScalar(e); new = try SimulatorAXScalar(v)
            guard e["type"] as? String == v["type"] as? String else { throw SimulatorAXWireError.invalidEnvelope }
        default: throw SimulatorAXWireError.invalidEnvelope
        }
        guard Set(wire.keys) == keys else { throw SimulatorAXWireError.invalidEnvelope }
        captureID = capture; nodeID = node; operation = op; expected = old; value = new; handle = token
    }
}
struct SimulatorAXUIField {
    let status: String
    let text: String
    init(_ wire: [String: Any]) throws {
        guard let status = wire["status"] as? String, ["available", "nil", "unsupported", "failed", "redacted"].contains(status) else { throw SimulatorAXWireError.invalidEnvelope }
        self.status = status
        text = status == "available" ? wire["value"].map { String(describing: $0) } ?? "" : wire["diagnostic"] as? String ?? ""
    }
}
struct SimulatorAXUINode {
    let id: String
    let parent: String?
    let children: [String]
    let fields: [String: SimulatorAXUIField]
    let value: SimulatorAXScalar?
    let custom: [(handle: String, name: SimulatorAXUIField)]
    let operations: Set<String>
    let reasons: [String]
    init(_ row: [String: Any]) throws {
        guard let id = row["nodeID"] as? String, !id.isEmpty, let children = row["childIDs"] as? [String], let fields = row["fields"] as? [String: [String: Any]] else { throw SimulatorAXWireError.invalidEnvelope }
        self.id = id; parent = row["parentID"] as? String; self.children = children
        self.fields = try fields.mapValues(SimulatorAXUIField.init)
        value = try (row["typedValue"] as? [String: Any]).map(SimulatorAXScalar.init)
        custom = try (row["customActions"] as? [[String: Any]] ?? []).map {
            guard let h = $0["handle"] as? String, let name = $0["name"] as? [String: Any] else { throw SimulatorAXWireError.invalidEnvelope }
            return (h, try SimulatorAXUIField(name))
        }
        let caps = row["capabilities"] as? [String: Any] ?? [:]
        operations = Set(caps["operations"] as? [String] ?? [])
        reasons = caps["reasons"] as? [String] ?? ["Guest action qualification unavailable"]
    }
}
struct SimulatorAXUISnapshot {
    let captureID: String
    let nodes: [String: SimulatorAXUINode]
    let summary: String
    let expiresMonotonicNS: UInt64?
    init(_ wire: [String: Any]) throws {
        guard let id = wire["captureID"] as? String, !id.isEmpty, let rows = wire["nodes"] as? [[String: Any]], let target = wire["target"] as? [String: Any], let scope = wire["scope"] as? [String: Any] else { throw SimulatorAXWireError.invalidEnvelope }
        var nodes: [String: SimulatorAXUINode] = [:]
        for row in rows { let node = try SimulatorAXUINode(row); guard nodes[node.id] == nil else { throw SimulatorAXWireError.invalidEnvelope }; nodes[node.id] = node }
        for node in nodes.values {
            guard node.parent.map({ nodes[$0] != nil }) ?? true, Set(node.children).count == node.children.count,
                  node.children.allSatisfy({ nodes[$0]?.parent == node.id }) else { throw SimulatorAXWireError.invalidEnvelope }
        }
        captureID = id; self.nodes = nodes
        expiresMonotonicNS = (wire["expiresMonotonicNS"] as? NSNumber)?.uint64Value
        summary = "Capture: \(id)\nTarget: \(target)\nScope: \(scope)\nQualification: \(wire["qualificationFingerprint"] ?? [:])\nRead: \(wire["startedMonotonicNS"] ?? "?")…\(wire["finishedMonotonicNS"] ?? "?") ns\n\(wire["identityQualification"] ?? "")\n\(wire["truncations"] ?? [])"
    }
}

/// Rich snapshot additions must not alter the legacy tap equality contract.
func simulatorAXLegacyRow(_ row: [String: Any]) -> [String: Any] {
    let additions: Set<String> = ["captureID", "nodeID", "parentID", "childIDs", "sourceFrame", "fields", "customActionHandles", "customActions", "typedValue", "capabilities"]
    return row.filter { !additions.contains($0.key) }
}
