import Foundation
import CoreFoundation
import simd

// Immutable capture values. Raw dictionaries are consumed only at this boundary.
indirect enum InspectorValue {
    case null, bool(Bool), number(Double), integer(String), string(String), array([InspectorValue]), object([String: InspectorValue])
    init(_ raw: Any) throws {
        switch raw {
        case is NSNull: self = .null
        case let n as NSNumber:
            if CFGetTypeID(n) == CFBooleanGetTypeID() { self = .bool(n.boolValue) }
            else if !["f", "d"].contains(String(cString: n.objCType)) { self = .integer(n.stringValue) }
            else { guard n.doubleValue.isFinite else { throw InspectorFailure.invalid("Nonfinite property") }; self = .number(n.doubleValue) }
        case let s as String: self = .string(s)
        case let a as [Any]: self = .array(try a.map(InspectorValue.init))
        case let d as [String: Any]: self = .object(try d.mapValues(InspectorValue.init))
        default: throw InspectorFailure.invalid("Invalid property type")
        }
    }
    var text: String {
        switch self {
        case .null: return "Unavailable"
        case .bool(let b): return String(b)
        case .number(let n): return String(n)
        case .integer(let n): return n
        case .string(let s): return s
        case .array(let a): return a.map(\.text).joined(separator: ", ")
        case .object(let d): return d.keys.sorted().map { "\($0): \(d[$0]!.text)" }.joined(separator: "; ")
        }
    }
}
extension InspectorValue {
    func displayText(limit: Int = 2000) -> String {
        var output = "", remaining = max(0, limit)
        func append(_ text: String) { let piece = String(text.prefix(remaining)); output += piece; remaining -= piece.count }
        func visit(_ value: InspectorValue) {
            guard remaining > 0 else { return }
            switch value {
            case .array(let values):
                for v in values { guard remaining > 0 else { break }; visit(v); append(", ") }
            case .object(let values):
                for key in values.keys.sorted() { guard remaining > 0 else { break }; append(key); append(": "); visit(values[key]!); append("; ") }
            default: append(value.text)
            }
        }
        visit(self); return output + (remaining == 0 ? "…" : "")
    }
}

// SwiftUI IDs have no membership in the UIKit registry or geometry map.
enum InspectorNodeKind { case uiKit, swiftUI }
struct InspectorSwiftUIProperty {
    let id: UInt32
    let attribute: InspectorValue
    let original: InspectorValue
}
struct InspectorSwiftUINode {
    let id: String, parentID: String, hostingNodeID: String
    let childOrdinal: Int, depth: Int
    let properties: [InspectorSwiftUIProperty]
    let children: [String]
    var typeName: String {
        for p in properties where p.id == 0 {
            if case .object(let a) = p.attribute {
                if case .string(let t) = a["type"] { return t }
                if case .string(let t) = a["readableType"] { return t }
            }
        }
        return "타입 정보 없음"
    }
}
struct InspectorSwiftUIHost {
    let hostingNodeID: String, sceneID: String, status: String, reason: String?
    let graphStatus: InspectorValue, rendering: InspectorValue
    let roots: [String]
    let compositeAssetID: String?
    var message: String {
        let state: String
        switch status {
        case "available": state = "선언형 계층 수집됨"
        case "empty": state = "기록된 계층 없음 · 실행 중인 앱의 SwiftUI 기록 준비 필요"
        case "overbudget": state = "계층 한도 초과"
        case "error": state = "계층 수집 실패"
        default: state = "계층 사용 불가 · 앱의 SwiftUI 기록 준비 상태 확인 필요"
        }
        return "SwiftUI: " + state + (reason.map { " · " + String($0.prefix(1000)) } ?? "")
    }
}
struct InspectorSwiftUIGraph {
    let scope: InspectorValue
    let processLifetime: InspectorValue
    let nodes: [String: InspectorSwiftUINode]
    let hosts: [String: InspectorSwiftUIHost]
    let order: [String]
    static func integer(_ raw: Any?) -> Int? {
        guard let n = raw as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(),
              !["f", "d"].contains(String(cString: n.objCType)), n.doubleValue >= 0,
              n.doubleValue < Double(Int.max) else { return nil }
        return n.intValue
    }
    static func parse(_ raw: Any, snapshot: [String: Any], capture: String,
                      context: SimulatorInspectorContext, uiKit: [String: InspectorNode],
                      assets: [String: InspectorAsset]) throws -> Self {
        func fail(_ reason: String) -> InspectorFailure { .invalid("SwiftUI: " + reason) }
        // Validate JSON costs iteratively before recursive typed decoding.
        var stack: [(Any, Int)] = [(raw, 0)], count = 0, strings = 0
        while let (value, depth) = stack.popLast() {
            count += 1
            guard count <= 200_000, depth <= 128 else { throw fail("metadata budget exceeded") }
            if let text = value as? String {
                strings += text.utf8.count
                guard text.utf8.count <= 256 * 1024, strings <= 8 * 1024 * 1024 else { throw fail("string budget exceeded") }
            } else if let d = value as? [String: Any] {
                guard d.count <= 8192 else { throw fail("object budget exceeded") }
                for (k, v) in d { stack.append((k, depth + 1)); stack.append((v, depth + 1)) }
            } else if let a = value as? [Any] {
                guard a.count <= 8192 else { throw fail("array budget exceeded") }
                for v in a { stack.append((v, depth + 1)) }
            }
        }
        guard let d = raw as? [String: Any], integer(d["schemaVersion"]) == 1,
              d["captureID"] as? String == capture,
              let scope = snapshot["inspectionScope"] as? [String: Any],
              let joined = d["inspectionScope"] as? [String: Any], NSDictionary(dictionary: scope).isEqual(to: joined),
              scope["deviceID"] as? String == context.deviceID,
              scope["displayID"] as? String == context.displayID,
              integer(scope["generation"]) != nil,
              let lifetime = snapshot["processLifetime"] as? [String: Any], !lifetime.isEmpty,
              let rawHosts = d["hosts"] as? [[String: Any]], rawHosts.count <= 64 else { throw fail("capture/scope/lifetime mismatch") }
        for key in ["bootIdentity", "presentation", "runtime"] {
            guard let value = scope[key] as? String, !value.isEmpty else { throw fail("missing scope " + key) }
        }
        var nodes: [String: InspectorSwiftUINode] = [:], hosts: [String: InspectorSwiftUIHost] = [:], order: [String] = []
        let states = ["available", "empty", "unavailable", "error", "overbudget"]
        var attributes = 0
        func validateAttribute(_ raw: [String: Any], depth: Int = 0) throws {
            attributes += 1
            guard attributes <= 32768, depth <= 64 else { throw fail("attribute budget exceeded") }
            for key in ["type", "readableType", "name"] where raw[key] != nil {
                guard raw[key] is String else { throw fail("invalid attribute " + key) }
            }
            if let flags = raw["flags"] { guard let n = integer(flags), n <= Int(UInt32.max) else { throw fail("invalid flags") } }
            if let children = raw["subattributes"] {
                guard let children = children as? [[String: Any]] else { throw fail("invalid subattributes") }
                for child in children { try validateAttribute(child, depth: depth + 1) }
            }
        }
        for h in rawHosts {
            guard let host = h["hostingNodeID"] as? String, let ui = uiKit[host], hosts[host] == nil,
                  let scene = h["sceneID"] as? String, !scene.isEmpty, ui.sceneID == scene,
                  let status = h["status"] as? String, states.contains(status), h["graphStatus"] != nil,
                  h["reason"] is String || h["reason"] is NSNull,
                  let rawNodes = h["nodes"] as? [[String: Any]], rawNodes.count + nodes.count <= 4096,
                  (status == "available" ? !rawNodes.isEmpty : rawNodes.isEmpty),
                  let rendering = h["rendering"] as? [String: Any],
                  let renderStatus = rendering["status"] as? String, states.filter({ $0 != "empty" }).contains(renderStatus),
                  rendering["representation"] as? String == "hostingSubtreeComposite",
                  rendering["reason"] is String || rendering["reason"] is NSNull else { throw fail("invalid host/status") }
            var roots: [String] = [], children: [String: [String]] = [:], active: [String] = []
            for (index, n) in rawNodes.enumerated() {
                let expectedID = "swiftui:\(capture):\(host):\(index)"
                guard let id = n["id"] as? String, id == expectedID, uiKit[id] == nil, nodes[id] == nil,
                      let ordinal = integer(n["childOrdinal"]),
                      let properties = n["properties"] as? [[String: Any]], properties.count <= 64 else { throw fail("invalid node identity/properties") }
                let parent: String
                let depth: Int
                if n["parentID"] is NSNull { active = []; parent = host; depth = ui.depth + 1; guard ordinal == roots.count else { throw fail("root ordinal") }; roots.append(id) }
                else if let p = n["parentID"] as? String, let prior = nodes[p], prior.hostingNodeID == host {
                    guard let ancestor = active.firstIndex(of: p) else { throw fail("non-preorder serialized children") }
                    active = Array(active.prefix(ancestor + 1))
                    parent = p; depth = prior.depth + 1
                    guard ordinal == children[p, default: []].count else { throw fail("child ordinal") }
                    children[p, default: []].append(id)
                } else { throw fail("parent outside graph or forward/cyclic edge") }
                guard depth - ui.depth - 1 <= 64 else { throw fail("graph depth exceeded") }
                var ids = Set<UInt32>(), props: [InspectorSwiftUIProperty] = []
                for p in properties {
                    guard let number = integer(p["id"]), number <= Int(UInt32.max), ids.insert(UInt32(number)).inserted,
                          let a = p["attribute"] as? [String: Any] else { throw fail("invalid property ID/attribute") }
                    try validateAttribute(a)
                    props.append(.init(id: UInt32(number), attribute: try InspectorValue(a), original: try InspectorValue(p)))
                }
                nodes[id] = .init(id: id, parentID: parent, hostingNodeID: host, childOrdinal: ordinal, depth: depth, properties: props, children: [])
                active.append(id); order.append(id)
            }
            for n in rawNodes {
                let id = n["id"] as! String, old = nodes[id]!
                nodes[id] = .init(id: id, parentID: old.parentID, hostingNodeID: host, childOrdinal: old.childOrdinal, depth: old.depth, properties: old.properties, children: children[id] ?? [])
            }
            guard rendering["assetID"] is String || rendering["assetID"] is NSNull,
                  rendering["drawHierarchyReturned"] is NSNull || (rendering["drawHierarchyReturned"] as? NSNumber).map({ CFGetTypeID($0) == CFBooleanGetTypeID() }) == true else { throw fail("invalid rendering metadata") }
            let asset = rendering["assetID"] as? String
            if renderStatus == "available" {
                guard let asset, ui.assetID == asset, let a = assets[asset], a.nodeID == host,
                      a.representation == .hostingSubtreeComposite,
                      (rendering["drawHierarchyReturned"] as? NSNumber).map({ CFGetTypeID($0) == CFBooleanGetTypeID() && $0.boolValue }) == true else { throw fail("invalid composite asset join") }
            } else { guard rendering["assetID"] is NSNull else { throw fail("failed rendering has asset") } }
            hosts[host] = .init(hostingNodeID: host, sceneID: scene, status: status, reason: h["reason"] as? String,
                                graphStatus: try InspectorValue(h["graphStatus"]!), rendering: try InspectorValue(rendering), roots: roots, compositeAssetID: asset)
        }
        let joinedAssets = Set(hosts.values.compactMap(\.compositeAssetID))
        guard assets.values.filter({ $0.representation == .hostingSubtreeComposite }).allSatisfy({ joinedAssets.contains($0.id) }) else { throw fail("unjoined composite") }
        return .init(scope: try InspectorValue(scope), processLifetime: try InspectorValue(lifetime), nodes: nodes, hosts: hosts, order: order)
    }
}

enum InspectorFailure: Error, LocalizedError {
    case invalid(String)
    var errorDescription: String? { if case .invalid(let s) = self { return s }; return nil }
}
struct SimulatorInspectorContext: Equatable {
    let deviceID: String
    let displayID: String
    let targetID: String
    let targetLabel: String
    let presentationRevision: UInt64
}
/// The host binds the current app only after an explicit capture request and lifetime preflight.
struct SimulatorInspectorCapture {
    let context: SimulatorInspectorContext
    let payload: [String: Any]
}
struct InspectorProperty {
    let name: String
    let value: InspectorValue
    let fetchStatus: InspectorValue
    let format: String?
}
enum InspectorRepresentation { case uiKitSelf, hostingSubtreeComposite }
struct InspectorAsset {
    let representation: InspectorRepresentation
    let id: String, nodeID: String, provenance: String
    let data: Data
    let width: Int, height: Int
    static let maxEncoded = 4 * 1024 * 1024
    static func parse(_ id: String, _ d: [String: Any], captureID: String) throws -> InspectorAsset {
        guard d["format"] as? String == "png", d["encoding"] as? String == "base64",
              d["captureID"] as? String == captureID, let node = d["nodeID"] as? String,
              let text = d["data"] as? String, text.utf8.count <= ((maxEncoded + 2) / 3) * 4,
              let bytes = Data(base64Encoded: text), bytes.count <= maxEncoded, bytes.count >= 33,
              Array(bytes.prefix(8)) == [137,80,78,71,13,10,26,10],
              Array(bytes[8..<16]) == [0,0,0,13,73,72,68,82] else { throw InspectorFailure.invalid("Invalid PNG envelope: \(id)") }
        func uint(_ offset: Int) -> Int { bytes[offset..<offset+4].reduce(0) { ($0 << 8) | Int($1) } }
        let w = uint(16), h = uint(20)
        guard w > 0, h > 0, w <= 4096, h <= 4096,
              d["pixelWidth"] as? Int == w, d["pixelHeight"] as? Int == h,
              bytes[24] == 8, [0,2,3,4,6].contains(bytes[25]), bytes[26] == 0, bytes[27] == 0, bytes[28] <= 1 else {
            throw InspectorFailure.invalid("Unsupported PNG dimensions/format: \(id)")
        }
        let representation: InspectorRepresentation
        if let raw = d["representation"] as? String {
            guard raw == "hostingSubtreeComposite", d["descendantContent"] as? String == "all" else { throw InspectorFailure.invalid("Unknown texture representation") }
            representation = .hostingSubtreeComposite
        } else { representation = .uiKitSelf }
        return .init(representation: representation, id: id, nodeID: node, provenance: "\(d["sourceProperty"] as? String ?? "unknown") · descendants: \(d["descendantContent"] as? String ?? "unknown") · clipping unverified", data: bytes, width: w, height: h)
    }
}
struct InspectorNode {
    let id: String, className: String, parentID: String?, label: String
    let sceneID: String?
    let depth: Int, siblingIndex: Int
    let children: [String], corners: [SIMD2<Float>], windowID: String?, screenID: String?
    let properties: [InspectorProperty]
    let hidden: Bool?, alpha: Double?
    let assetID: String?, unavailableReason: String?, editToken: String?
    let editable: Set<String>
}
struct InspectorEditing {
    let inspectionID: String, ownerID: String, targetEpoch: String, registryState: String
    let expiresAt: Date
}
struct SimulatorInspectorSnapshot {
    let swiftUI: InspectorSwiftUIGraph?
    let captureID: String, capturedAt: String
    let context: SimulatorInspectorContext
    let nodes: [String: InspectorNode], roots: [String], order: [String]
    let assets: [String: InspectorAsset], editable: Set<String>, editing: InspectorEditing?
    let renderingLimitations: [String]
    static func date(_ text: String) -> Date? {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.date(from: text) ?? ISO8601DateFormatter().date(from: text)
    }
    static func parse(_ envelope: [String: Any], context: SimulatorInspectorContext) throws -> Self {
        let s = (envelope["content"] as? [String: Any])?["snapshot"] as? [String: Any] ?? envelope["snapshot"] as? [String: Any] ?? envelope
        guard let capture = s["captureID"] as? String, !capture.isEmpty,
              let time = s["capturedAt"] as? String, let rawRoots = s["roots"] as? [[String: Any]] else { throw InspectorFailure.invalid("Missing capture identity/roots") }
        var nodes: [String: InspectorNode] = [:], order: [String] = []
        func parseNode(_ raw: [String: Any], parent: String?, depth: Int) throws -> String {
            guard depth <= 128, order.count < 10000, let id = raw["id"] as? String, !id.isEmpty,
                  !id.hasPrefix("swiftui:"), !order.contains(id), let name = raw["className"] as? String,
                  (raw["parentID"] as? String) == parent else { throw InspectorFailure.invalid("Duplicate, cyclic, invalid or excessive hierarchy") }
            order.append(id)
            let geometry = raw["geometry"] as? [String: Any]
            var corners: [SIMD2<Float>] = []
            if let g = geometry, let rawCorners = g["corners"] as? [[Double]], !rawCorners.isEmpty {
                guard g["coordinateSpace"] as? String == "UIScreen.fixedCoordinateSpace points", rawCorners.count == 4,
                      rawCorners.allSatisfy({ $0.count == 2 && $0.allSatisfy { $0.isFinite && abs($0) < 10_000_000 } }) else { throw InspectorFailure.invalid("Invalid fixed-space corners") }
                corners = rawCorners.map { SIMD2(Float($0[0]), Float($0[1])) }
            }
            if let c = raw["children"], !(c is NSNull), !(c is [[String: Any]]) { throw InspectorFailure.invalid("Invalid children") }
            let children = try (raw["children"] as? [[String: Any]] ?? []).map { try parseNode($0, parent: id, depth: depth + 1) }
            let props = try (raw["properties"] as? [[String: Any]] ?? []).map { p -> InspectorProperty in
                .init(name: p["propertyName"] as? String ?? "Unknown", value: try InspectorValue(p["propertyValue"] ?? NSNull()), fetchStatus: try InspectorValue(p["fetchStatus"] ?? NSNull()), format: p["propertyFormat"] as? String)
            }
            let alpha = (raw["alpha"] as? NSNumber)?.doubleValue
            guard alpha == nil || (alpha!.isFinite && (0...1).contains(alpha!)) else { throw InspectorFailure.invalid("Invalid alpha") }
            let hiddenNumber = raw["hidden"] as? NSNumber
            let hidden = hiddenNumber.flatMap { CFGetTypeID($0) == CFBooleanGetTypeID() ? $0.boolValue : nil }
            nodes[id] = .init(id: id, className: name, parentID: parent, label: raw["accessibilityIdentifier"] as? String ?? raw["accessibilityLabel"] as? String ?? "", sceneID: raw["sceneID"] as? String, depth: depth, siblingIndex: raw["siblingIndex"] as? Int ?? 0, children: children, corners: corners, windowID: geometry?["windowID"] as? String, screenID: (geometry?["screen"] as? [String: Any])?["id"] as? String, properties: props, hidden: hidden, alpha: alpha, assetID: raw["assetID"] as? String, unavailableReason: raw["textureUnavailableReason"] as? String, editToken: raw["editToken"] as? String, editable: Set(raw["editableProperties"] as? [String] ?? []))
            return id
        }
        let roots = try rawRoots.map { try parseNode($0, parent: nil, depth: 0) }
        let rawAssets = s["assets"] as? [String: [String: Any]] ?? [:]
        guard rawAssets.count <= 64 else { throw InspectorFailure.invalid("Too many textures") }
        var assets: [String: InspectorAsset] = [:], encoded = 0, decoded = 0
        for (id, raw) in rawAssets {
            let a = try InspectorAsset.parse(id, raw, captureID: capture)
            guard nodes[a.nodeID]?.assetID == id else { throw InspectorFailure.invalid("Unknown or mismatched asset node") }
            encoded += a.data.count; decoded += a.width * a.height * 4
            guard encoded <= 16 * 1024 * 1024, decoded <= 128 * 1024 * 1024 else { throw InspectorFailure.invalid("Texture aggregate budget exceeded") }
            assets[id] = a
        }
        for node in nodes.values where node.assetID != nil {
            guard assets[node.assetID!]?.nodeID == node.id else { throw InspectorFailure.invalid("Missing asset join") }
        }
        var editing: InspectorEditing?
        if let e = s["editing"] as? [String: Any], let inspection = e["inspectionID"] as? String,
           let owner = e["ownerID"] as? String, let epoch = e["targetEpoch"] as? String,
           let state = e["registryState"] as? String, let expiry = e["expiresAt"] as? String, let date = date(expiry),
           !inspection.isEmpty, !owner.isEmpty, !epoch.isEmpty {
            editing = .init(inspectionID: inspection, ownerID: owner, targetEpoch: epoch, registryState: state, expiresAt: date)
        }
        let swiftUI = try s["swiftUI"].map { try InspectorSwiftUIGraph.parse($0, snapshot: s, capture: capture, context: context, uiKit: nodes, assets: assets) }
        guard swiftUI != nil || assets.values.allSatisfy({ $0.representation == .uiKitSelf }) else { throw InspectorFailure.invalid("Composite requires SwiftUI host join") }
        let capabilities = s["capabilities"] as? [String: Any] ?? [:]
        return .init(swiftUI: swiftUI, captureID: capture, capturedAt: time, context: context, nodes: nodes, roots: roots, order: order, assets: assets, editable: Set(capabilities["editableProperties"] as? [String] ?? []), editing: editing, renderingLimitations: capabilities["renderingLimitations"] as? [String] ?? [])
    }
    func kind(_ id: String) -> InspectorNodeKind? { nodes[id] != nil ? .uiKit : swiftUI?.nodes[id] != nil ? .swiftUI : nil }
    func children(_ id: String) -> [String] { nodes[id].map { $0.children + (swiftUI?.hosts[id]?.roots ?? []) } ?? swiftUI?.nodes[id]?.children ?? [] }
    func parent(_ id: String) -> String? { nodes[id]?.parentID ?? swiftUI?.nodes[id]?.parentID }
    func title(_ id: String) -> String {
        if let n = nodes[id] { return "UIKit · " + n.className + " " + n.label }
        return "SwiftUI · " + String((swiftUI?.nodes[id]?.typeName ?? "").prefix(500))
    }
    // Ancestor composites include nested hosts and representables. Geometry stays available for selection.
    func paintsTexture(_ id: String) -> Bool {
        var next = nodes[id]?.parentID
        while let p = next {
            if swiftUI?.hosts[p]?.compositeAssetID != nil { return false }
            next = nodes[p]?.parentID
        }
        return nodes[id] != nil
    }
    func visibleIDs(query: String) -> Set<String> {
        guard !query.isEmpty else { return Set(order + (swiftUI?.order ?? [])) }
        var ids = Set<String>()
        func include(_ id: String) { var next: String? = id; while let n = next { ids.insert(n); next = parent(n) } }
        for n in nodes.values where (n.className + " " + n.label + " " + n.id).localizedCaseInsensitiveContains(query) { include(n.id) }
        func contains(_ value: InspectorValue) -> Bool {
            switch value {
            case .array(let a): return a.contains(where: contains)
            case .object(let d): return d.contains { $0.key.localizedCaseInsensitiveContains(query) || contains($0.value) }
            default: return value.text.localizedCaseInsensitiveContains(query)
            }
        }
        for n in swiftUI?.nodes.values ?? Dictionary<String, InspectorSwiftUINode>().values {
            if n.id.localizedCaseInsensitiveContains(query) || n.properties.contains(where: { contains($0.original) }) { include(n.id) }
        }
        return ids
    }

}

enum InspectorEditValue: Equatable {
    case hidden(Bool), alpha(Double)
    var property: String { if case .hidden = self { return "hidden" }; return "alpha" }
    var raw: Any { switch self { case .hidden(let b): return b; case .alpha(let a): return a } }
    var valid: Bool { if case .alpha(let a) = self { return a.isFinite && (0...1).contains(a) }; return true }
}
struct InspectorCommand {
    let operationID: UUID, captureID: String, inspection: InspectorEditing, editToken: String
    let property: String, expected: InspectorEditValue, requested: InspectorEditValue
    var envelope: [String: Any] { ["operationID": operationID.uuidString, "captureID": captureID, "inspectionID": inspection.inspectionID, "ownerID": inspection.ownerID, "targetEpoch": inspection.targetEpoch, "editToken": editToken, "property": property, "expected": expected.raw, "value": requested.raw] }
}
struct InspectorReceipt {
    let operationID: String, status: String, outcome: String, cleanup: InspectorValue
    let before: InspectorValue, requested: InspectorValue, observed: InspectorValue
    let undoToken: String?, needsRefresh: Bool
    init(_ d: [String: Any]) throws {
        guard let op = d["operationID"] as? String, let status = d["status"] as? String else { throw InspectorFailure.invalid("Missing mutation receipt") }
        operationID = op; self.status = status; outcome = d["mutationOutcome"] as? String ?? "uncertain"
        cleanup = try InspectorValue(d["cleanup"] ?? NSNull()); before = try InspectorValue(d["before"] ?? NSNull())
        requested = try InspectorValue(d["requested"] ?? NSNull()); observed = try InspectorValue(d["observed"] ?? NSNull())
        undoToken = d["undoToken"] as? String; needsRefresh = d["needsRefresh"] as? Bool ?? true
    }
}
// Main-thread state machine, also exercised without AppKit lifecycle.
final class SimulatorInspectorModel {
    private(set) var context: SimulatorInspectorContext
    private(set) var snapshot: SimulatorInspectorSnapshot?
    private(set) var selection: String?
    private(set) var generation: UInt64 = 0
    private(set) var pending: UUID?
    private(set) var stale = true
    private(set) var loading = false
    private(set) var receipt: InspectorReceipt?
    private(set) var receiptNode: String?
    private var forwardEditConsumed = false
    private var pendingNode: String?
    private var consumedSwiftUICaptures = Set<String>()
    var draft: (nodeID: String, value: InspectorEditValue)?
    init(context: SimulatorInspectorContext) { self.context = context }
    func invalidate(context: SimulatorInspectorContext? = nil) {
        generation &+= 1; pending = nil; loading = false; stale = true; selection = nil; receipt = nil; receiptNode = nil
        draft = nil; pendingNode = nil
        if let context { self.context = context }
    }
    var canPrepareRecording: Bool {
        !stale && !loading && pending == nil && snapshot?.swiftUI?.hosts.values.contains {
            ($0.status == "empty" || $0.status == "unavailable") && $0.reason == "SwiftUI recording preparation required"
        } == true
    }
    func beginCapture() -> UInt64? { guard pending == nil else { return nil }; invalidate(); loading = true; return generation }
    @discardableResult func accept(_ snapshot: SimulatorInspectorSnapshot, generation: UInt64) -> Bool {
        guard self.generation == generation, snapshot.context == context, loading else { return false }
        if snapshot.swiftUI != nil {
            guard consumedSwiftUICaptures.count < 4096, consumedSwiftUICaptures.insert(snapshot.captureID).inserted else { return false }
        }
        self.snapshot = snapshot; forwardEditConsumed = false; loading = false; stale = false; selection = nil; draft = nil; return true
    }
    @discardableResult func acceptBoundCapture(_ snapshot: SimulatorInspectorSnapshot, generation: UInt64) -> Bool {
        guard self.generation == generation, loading,
              snapshot.context.deviceID == context.deviceID, snapshot.context.displayID == context.displayID,
              snapshot.context.presentationRevision == context.presentationRevision else { return false }
        context = snapshot.context
        return accept(snapshot, generation: generation)
    }
    func select(_ id: String?) {
        selection = id.flatMap { id in
            guard let s = snapshot, s.kind(id) != nil else { return nil }
            if s.kind(id) == .swiftUI && (stale || loading || s.context != context) { return nil }
            return id
        }
        if selection.flatMap({ snapshot?.kind($0) }) == .swiftUI { draft = nil }
    }
    func canEdit(_ property: String, now: Date = Date()) -> Bool {
        guard !forwardEditConsumed, !stale, !loading, pending == nil, let s = snapshot, s.context == context,
              let e = s.editing, e.expiresAt > now, ["active", "ready"].contains(e.registryState),
              let id = selection, let n = s.nodes[id], let token = n.editToken, !token.isEmpty, !token.hasPrefix("swiftui:"),
              s.editable.contains(property), n.editable.contains(property) else { return false }
        return property == "hidden" ? n.hidden != nil : property == "alpha" && n.alpha != nil
    }
    func beginEdit(now: Date = Date()) -> InspectorCommand? {
        guard let d = draft, d.nodeID == selection, d.value.valid, canEdit(d.value.property, now: now),
              let s = snapshot, let n = s.nodes[d.nodeID], let e = s.editing, let token = n.editToken else { return nil }
        let expected: InspectorEditValue
        switch d.value { case .hidden: expected = .hidden(n.hidden!); case .alpha: expected = .alpha(n.alpha!) }
        let op = UUID(); pending = op; pendingNode = n.id; forwardEditConsumed = true
        return .init(operationID: op, captureID: s.captureID, inspection: e, editToken: token, property: d.value.property, expected: expected, requested: d.value)
    }
    func canRevert(now: Date = Date()) -> Bool {
        guard !stale, !loading, pending == nil, selection == receiptNode, receipt?.undoToken != nil,
              let s = snapshot, s.context == context, let e = s.editing, e.expiresAt > now,
              ["active", "ready"].contains(e.registryState) else { return false }; return true
    }
    func beginRevert() -> UUID? { guard canRevert() else { return nil }; let op = UUID(); pending = op; pendingNode = selection; return op }
    @discardableResult func complete(_ receipt: InspectorReceipt, generation: UInt64, nodeID: String) -> Bool {
        guard self.generation == generation, pending?.uuidString == receipt.operationID, pendingNode == nodeID, snapshot?.nodes[nodeID] != nil else { return false }
        pending = nil; pendingNode = nil; self.receipt = receipt; receiptNode = nodeID
        // Any mutation requires fresh observations before another forward edit. Undo remains server-guarded.
        return true
    }
    func failOperation(generation: UInt64) { if self.generation == generation { pending = nil; pendingNode = nil } }
}

struct InspectorCamera {
    var yaw: Float = 0.25, pitch: Float = -0.12, zoom: Float = 1, explosion: Float = 12
    func matrix(nodes: [InspectorNode], aspect: Float) -> simd_float4x4 {
        let points = nodes.flatMap(\.corners)
        let lo = points.reduce(SIMD2<Float>(repeating: .greatestFiniteMagnitude)) { simd_min($0, $1) }
        let hi = points.reduce(SIMD2<Float>(repeating: -.greatestFiniteMagnitude)) { simd_max($0, $1) }
        let center = points.isEmpty ? SIMD2<Float>.zero : (lo + hi) / 2
        let span = points.isEmpty ? Float(800) : max(1, max(hi.x-lo.x, hi.y-lo.y))
        let depth = Float(nodes.map(\.depth).max() ?? 0) * explosion
        let distance = (span + depth) * 1.8 / max(0.1, min(zoom, 8))
        let near: Float = 0.1, far = max(10000, distance + span * 20 + depth * 10), f: Float = 2.41421356
        let projection = simd_float4x4(columns: (SIMD4(f/max(0.01,aspect),0,0,0), SIMD4(0,f,0,0), SIMD4(0,0,far/(near-far),-1), SIMD4(0,0,near*far/(near-far),0)))
        let rotation = simd_float4x4(simd_quatf(angle: pitch, axis: SIMD3(1,0,0))) * simd_float4x4(simd_quatf(angle: yaw, axis: SIMD3(0,1,0)))
        var translation = matrix_identity_float4x4; translation.columns.3 = SIMD4(-center.x, center.y, -depth/2, 1)
        var view = matrix_identity_float4x4; view.columns.3.z = -distance
        return projection * view * rotation * translation
    }
    func clipCorners(_ node: InspectorNode, matrix: simd_float4x4) -> [SIMD4<Float>] {
        node.corners.map { matrix * SIMD4($0.x, -$0.y, Float(node.depth) * explosion, 1) }
    }
    // Clip in homogeneous Metal volume before both polygon picking and screen projection.
    static func clipped(_ input: [SIMD4<Float>]) -> [SIMD4<Float>] {
        let planes: [(SIMD4<Float>) -> Float] = [{ $0.x+$0.w }, { $0.w-$0.x }, { $0.y+$0.w }, { $0.w-$0.y }, { $0.z }, { $0.w-$0.z }]
        var polygon = input
        for plane in planes {
            let previous = polygon; polygon = []; guard !previous.isEmpty else { break }
            var a = previous.last!, da = plane(a)
            for b in previous {
                let db = plane(b)
                if (da >= 0) != (db >= 0) { polygon.append(a + (b-a) * (da/(da-db))) }
                if db >= 0 { polygon.append(b) }; a = b; da = db
            }
        }
        return polygon
    }
    func projected(_ node: InspectorNode, matrix: simd_float4x4, size: SIMD2<Float>) -> [SIMD2<Float>] {
        Self.clipped(clipCorners(node, matrix: matrix)).compactMap { p in
            guard p.w > 0 else { return nil }; return SIMD2((p.x/p.w+1)*size.x/2, (1-p.y/p.w)*size.y/2)
        }
    }
    static func contains(_ point: SIMD2<Float>, polygon: [SIMD2<Float>]) -> Bool {
        guard polygon.count >= 3 else { return false }; var inside = false; var a = polygon.last!
        for b in polygon {
            if (a.y > point.y) != (b.y > point.y), point.x < (b.x-a.x)*(point.y-a.y)/(b.y-a.y)+a.x { inside.toggle() }; a = b
        }; return inside
    }
    func ordered(_ nodes: [InspectorNode], matrix: simd_float4x4) -> [InspectorNode] {
        func z(_ n: InspectorNode) -> Float { let p = clipCorners(n, matrix: matrix); return p.isEmpty ? 0 : p.reduce(Float(0)) { $0 + $1.z / max(0.0001,$1.w) } / Float(p.count) }
        return nodes.enumerated().sorted {
            let a = z($0.element), b = z($1.element)
            return a == b ? $0.offset < $1.offset : a > b
        }.map(\.element)
    }
}
