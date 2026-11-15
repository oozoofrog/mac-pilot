import Foundation
import CoreFoundation

/// Typed, bounded host scope. Equality never substitutes for a fresh native observation.
struct SimulatorViewInspectionScope: Equatable {
    let deviceID: String, bootIdentity: String, displayID: String, presentation: String, runtime: String
    let generation: UInt64
    init(_ wire: [String: Any]) throws {
        guard Set(wire.keys) == Set(["deviceID", "bootIdentity", "displayID", "presentation", "generation", "runtime"]),
              let n = wire["generation"] as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(),
              !String(cString: n.objCType).contains("f"), !String(cString: n.objCType).contains("d"),
              !n.stringValue.hasPrefix("-"), let generation = UInt64(n.stringValue) else {
            throw ToolError("Invalid inspection scope generation or fields.")
        }
        func text(_ key: String) throws -> String {
            guard let value = wire[key] as? String, !value.isEmpty, value.utf8.count <= 1024 else {
                throw ToolError("Invalid inspection scope identity.")
            }
            return value
        }
        deviceID = try text("deviceID"); bootIdentity = try text("bootIdentity"); displayID = try text("displayID")
        presentation = try text("presentation"); runtime = try text("runtime"); self.generation = generation
    }
}

/// Converts a DebugHierarchy response, not an accessibility tree. Addresses are scoped to this capture.
/// The caller must establish target lifetime and complete a safe detach before publishing the result.
func simulatorViewHierarchySnapshot(groups: [String: Any], pid: Int32, captureID: String,
                                    capturedAt: String, geometry: [String: Any]? = nil) throws -> [String: Any] {
    guard pid > 0, !captureID.isEmpty, !capturedAt.isEmpty,
          let windowGroup = groups["com.apple.UIKit.UIWindow"] as? [String: Any],
          let windows = windowGroup["debugHierarchyObjects"] as? [Any] else {
        throw ToolError("View hierarchy response has no recognizable window group.")
    }
    let geometryNodes = geometry?["nodes"] as? [String: Any] ?? [:]
    // Validate the complete wire budget before decoding even the PNG header. ImageIO is
    // deliberately not used here: the renderer owns pixel decoding and its allocation.
    let maxEncoded = 4 * 1024 * 1024, maxTotalEncoded = 16 * 1024 * 1024
    let maxDecoded = 128 * 1024 * 1024
    var candidates: [(String, [String: Any])] = []
    var scanned = Set<String>()
    func scan(_ raw: Any, depth: Int) throws {
        guard depth <= 512, scanned.count < 20_000, let object = raw as? [String: Any],
              let id = object["objectID"] as? String, !id.isEmpty, scanned.insert(id).inserted else {
            throw ToolError("View hierarchy response contains invalid or duplicate nodes.")
        }
        let images = (object["properties"] as? [[String: Any]] ?? []).filter { $0["propertyName"] as? String == "snapshotImage" }
        guard images.count <= 1 else { throw ToolError("Duplicate snapshotImage property.") }
        if let image = images.first { candidates.append((id, image)) }
        if let group = object["childGroup"] {
            guard let group = group as? [String: Any], let children = group["debugHierarchyObjects"] as? [Any] else {
                throw ToolError("View hierarchy response contains an invalid child group.")
            }
            for child in children { try scan(child, depth: depth + 1) }
        }
    }
    for window in windows { try scan(window, depth: 0) }
    var totalEncoded = 0
    var budgetsOK = candidates.count <= 64
    for (_, property) in candidates {
        if let value = property["propertyValue"] as? [String: Any], let data = value["imageData"] as? String {
            let length = data.utf8.count
            let (next, overflow) = totalEncoded.addingReportingOverflow(length)
            if overflow || length > maxEncoded || next > maxTotalEncoded { budgetsOK = false }
            else { totalEncoded = next }
        }
    }
    var assets: [String: [String: Any]] = [:]
    var nodeAssets: [String: String] = [:]
    var textureReasons: [String: String] = [:]
    var totalDecoded = 0
    for (id, property) in candidates {
        guard budgetsOK else { textureReasons[id] = "Texture wire budget exceeded."; continue }
        guard property["propertyFormat"] as? String == "image", property["propertyRuntimeType"] as? String == "UIImage",
              let status = property["fetchStatus"] as? NSNumber, CFGetTypeID(status) != CFBooleanGetTypeID(), status.doubleValue == 4,
              let value = property["propertyValue"] as? [String: Any], let data = value["imageData"] as? String,
              let metadata = value["metadata"] as? [String: Any],
              let widthNumber = metadata["width"] as? NSNumber, CFGetTypeID(widthNumber) != CFBooleanGetTypeID(),
              let heightNumber = metadata["height"] as? NSNumber, CFGetTypeID(heightNumber) != CFBooleanGetTypeID(),
              case let pointWidth = widthNumber.doubleValue, case let pointHeight = heightNumber.doubleValue,
              pointWidth.isFinite, pointHeight.isFinite, pointWidth > 0, pointHeight > 0 else {
            textureReasons[id] = "Image property or point dimensions unavailable."; continue
        }
        let bytes = data.utf8
        var padding = 0, valid = bytes.count >= 44 && bytes.count % 4 == 0
        for byte in bytes {
            if byte == 61 { padding += 1; if padding > 2 { valid = false } }
            else if padding != 0 || !((65...90).contains(byte) || (97...122).contains(byte) || (48...57).contains(byte) || byte == 43 || byte == 47) { valid = false }
        }
        // Decode only the fixed-size PNG header, not the image. Check its IHDR CRC too.
        let tail = String(data.suffix(4))
        guard valid, let tailBytes = Data(base64Encoded: tail), tailBytes.base64EncodedString() == tail,
              let header = Data(base64Encoded: String(data.prefix(44))), header.count == 33,
              Array(header.prefix(8)) == [137, 80, 78, 71, 13, 10, 26, 10],
              Array(header[8..<16]) == [0, 0, 0, 13, 73, 72, 68, 82] else {
            textureReasons[id] = "Invalid base64 or PNG IHDR."; continue
        }
        func word(_ offset: Int) -> Int { header[offset..<(offset + 4)].reduce(0) { ($0 << 8) | Int($1) } }
        var crc: UInt32 = 0xffffffff
        for byte in header[12..<29] {
            crc ^= UInt32(byte)
            for _ in 0..<8 { crc = (crc >> 1) ^ ((crc & 1) == 1 ? 0xedb88320 : 0) }
        }
        let bitDepth = Int(header[24]), colorType = Int(header[25])
        let validDepths: [Int: [Int]] = [0: [1, 2, 4, 8, 16], 2: [8, 16], 3: [1, 2, 4, 8], 4: [8, 16], 6: [8, 16]]
        guard UInt32(word(29)) == (crc ^ 0xffffffff),
              validDepths[colorType]?.contains(bitDepth) == true, header[26] == 0, header[27] == 0, header[28] <= 1 else {
            textureReasons[id] = "Invalid PNG IHDR fields or checksum."; continue
        }
        let width = word(16), height = word(20)
        guard width > 0, height > 0, width <= 4096, height <= 4096 else {
            textureReasons[id] = "PNG dimensions exceed the texture budget."; continue
        }
        let (pixels, overflow1) = width.multipliedReportingOverflow(by: height)
        let (decoded, overflow2) = pixels.multipliedReportingOverflow(by: 4)
        let (next, overflow3) = totalDecoded.addingReportingOverflow(decoded)
        guard !overflow1, !overflow2, !overflow3, next <= maxDecoded else {
            textureReasons[id] = "Decoded texture budget exceeded."; continue
        }
        totalDecoded = next
        let assetID = UUID().uuidString
        assets[assetID] = ["format": "png", "encoding": "base64", "data": data,
                           "pixelWidth": width, "pixelHeight": height, "pointWidth": pointWidth, "pointHeight": pointHeight,
                           "sourceProperty": "snapshotImage", "descendantContent": "unknown", "captureID": captureID, "nodeID": id]
        nodeAssets[id] = assetID
    }
    var ids = Set<String>()
    var count = 0
    func number(_ raw: Any?) -> Double? {
        let value: Double?
        if let string = raw as? String { value = Double(string) }
        else if let number = raw as? NSNumber { value = number.doubleValue }
        else { value = nil }
        guard let value, value.isFinite else { return nil }
        return value
    }
    func parse(_ raw: Any, parent: String?, order: Int, depth: Int) throws -> [String: Any] {
        count += 1
        guard depth <= 512, count <= 20_000, let object = raw as? [String: Any],
              let id = object["objectID"] as? String, !id.isEmpty,
              ids.insert(id).inserted, let name = object["className"] as? String, !name.isEmpty else {
            throw ToolError("View hierarchy response contains invalid or duplicate nodes.")
        }
        let properties = object["properties"] as? [[String: Any]] ?? []
        func value(_ key: String) -> Any? {
            properties.first { $0["propertyName"] as? String == key }?["propertyValue"]
        }
        let frame: [Double]?
        if let rawFrame = value("frame") as? [Any], rawFrame.count == 4 {
            let values = rawFrame.compactMap { number($0) }
            frame = values.count == 4 ? values : nil
        } else { frame = nil }
        let hidden: Bool?
        if let n = number(value("hidden")), n == 0 || n == 1 { hidden = n == 1 }
        else { hidden = nil }
        var children: [[String: Any]]?
        if let group = object["childGroup"] {
            guard let group = group as? [String: Any], let rawChildren = group["debugHierarchyObjects"] as? [Any] else {
                throw ToolError("View hierarchy response contains an invalid child group.")
            }
            children = try rawChildren.enumerated().map { try parse($0.element, parent: id, order: $0.offset, depth: depth + 1) }
        }
        let safeProperties = properties.map { property -> [String: Any] in
            guard property["propertyName"] as? String == "snapshotImage" else { return property }
            guard var value = property["propertyValue"] as? [String: Any] else {
                var copy = property; copy["propertyValue"] = NSNull(); return copy
            }
            value.removeValue(forKey: "imageData")
            var copy = property; copy["propertyValue"] = value; return copy
        }
        return ["id": id, "className": name, "parentID": parent as Any? ?? NSNull(), "siblingIndex": order,
                "properties": safeProperties,
                "assetID": nodeAssets[id] as Any? ?? NSNull(),
                "textureUnavailableReason": nodeAssets[id] == nil ? (textureReasons[id] ?? "No captured snapshotImage.") : NSNull(),
                "editToken": NSNull(), "editableProperties": [String](),
                "geometry": geometryNodes[id] ?? NSNull(),
                "frame": frame as Any? ?? NSNull(), "frameCoordinateSpace": "superview points",
                "hidden": hidden as Any? ?? NSNull(), "alpha": number(value("alpha")) as Any? ?? NSNull(),
                "accessibilityIdentifier": value("accessibilityIdentifier") as? String as Any? ?? NSNull(),
                "accessibilityLabel": value("accessibilityLabel") as? String as Any? ?? NSNull(),
                "children": children as Any? ?? NSNull()]
    }
    let roots = try windows.enumerated().map { try parse($0.element, parent: nil, order: $0.offset, depth: 0) }
    return ["captureID": captureID, "capturedAt": capturedAt, "pid": pid, "roots": roots,
            "identityScope": "capture and process lifetime only", "processLifetime": NSNull(),
            "appIdentity": NSNull(), "screenGeometry": NSNull(), "screenshot": NSNull(), "assets": assets,
            "capabilities": ["textures": !assets.isEmpty, "editableProperties": [String](), "reasons": ["Editing is not qualified."]],
            "editing": NSNull(),
            "coordinateLimit": "Frame is in superview points; transforms and screen conversion are unavailable."]
}

/// Editable node identity comes only from the owned registry traversal, never an
/// address join against a separately collected DBGTargetHub hierarchy.
func simulatorEditableViewHierarchySnapshot(result: [String: Any], target: [String: Any]) throws -> [String: Any] {
    guard result["status"] as? String == "success",
          let captureID = result["captureID"] as? String, UUID(uuidString: captureID) != nil,
          let capturedAt = result["captureTime"] as? String,
          let returnedTarget = result["target"] as? [String: Any], NSDictionary(dictionary: returnedTarget).isEqual(to: target),
          var editing = result["editing"] as? [String: Any], editing["registryState"] as? String == "active",
          let expires = editing["expiresAt"] as? NSNumber, CFGetTypeID(expires) != CFBooleanGetTypeID(), expires.doubleValue.isFinite,
          let raw = result["editableNodes"] as? [[String: Any]], !raw.isEmpty, raw.count <= 20_000,
          let cleanup = result["cleanup"] as? [String: Any], cleanup["childrenReaped"] as? Bool == true,
          cleanup["detach"] as? String == "success",
          let recovery = cleanup["recovery"] as? [String: Any], recovery["verified"] as? Bool == true else {
        throw ToolError("Editable capture lacks owned identity or verified cleanup.")
    }
    for key in ["inspectionID", "ownerID", "targetEpoch"] {
        guard let value = editing[key] as? String, UUID(uuidString: value) != nil,
              value == result[key] as? String else { throw ToolError("Editable capture context differs.") }
    }
    var nodes: [String: [String: Any]] = [:]
    var children: [String: [String]] = [:]
    var roots: [String] = []
    for node in raw {
        guard let id = node["editToken"] as? String, UUID(uuidString: id) != nil, node["id"] as? String == id,
              nodes[id] == nil, let name = node["className"] as? String, !name.isEmpty, name.utf8.count <= 512,
              let window = node["windowToken"] as? String, UUID(uuidString: window) != nil,
              let hidden = node["hidden"] as? NSNumber, CFGetTypeID(hidden) == CFBooleanGetTypeID(),
              let alpha = node["alpha"] as? NSNumber, CFGetTypeID(alpha) != CFBooleanGetTypeID(),
              alpha.doubleValue.isFinite, (0...1).contains(alpha.doubleValue),
              let order = node["siblingIndex"] as? NSNumber, CFGetTypeID(order) != CFBooleanGetTypeID(),
              order.doubleValue >= 0, order.doubleValue <= 20_000, order.doubleValue.rounded() == order.doubleValue else {
            throw ToolError("Invalid editable node identity or value.")
        }
        nodes[id] = node
        if node["parentToken"] is NSNull { roots.append(id) }
        else if let parent = node["parentToken"] as? String, UUID(uuidString: parent) != nil {
            children[parent, default: []].append(id)
        } else { throw ToolError("Invalid editable node parent.") }
    }
    for (id, node) in nodes {
        guard let window = node["windowToken"] as? String, nodes[window] != nil,
              node["parentToken"] is NSNull || (node["parentToken"] as? String).flatMap({ nodes[$0] }) != nil else {
            throw ToolError("Editable node graph is incomplete: \(id)")
        }
    }
    var assets: [String: [String: Any]] = [:]
    var nodeAssets: [String: String] = [:]
    var textureReasons: [String: String] = [:]
    let textureState = result["textureCapture"] as? [String: Any]
    var textureReason = textureState?["reason"] as? String ?? "No matching texture was returned by the collector."
    if let hierarchy = result["hierarchy"] as? [String: Any], let groups = hierarchy["topLevelGroups"] as? [String: Any],
       let joins = result["textureJoins"] as? [String: [String: Any]], joins.count <= 20_000,
       joins.values.compactMap({ $0["nodeToken"] as? String }).count == joins.count,
       Set(joins.values.compactMap { $0["nodeToken"] as? String }).count == joins.count,
       textureState?["sameOperationIdentity"] as? Bool == true, let pid = target["pid"] as? NSNumber {
        do {
            // Reuse every existing wire/PNG/aggregate check. These are same-expression
            // joins made while all captured views were strongly held, then graph-checked.
            let textures = try simulatorViewHierarchySnapshot(groups: groups, pid: pid.int32Value,
                                                              captureID: captureID, capturedAt: capturedAt)
            let decodedAssets = textures["assets"] as? [String: [String: Any]] ?? [:]
            var seenTokens = Set<String>()
            func join(_ raw: [String: Any]) {
                if let address = raw["id"] as? String, let binding = joins[address],
                   let token = binding["nodeToken"] as? String, let node = nodes[token],
                   node["className"] as? String == binding["className"] as? String,
                   raw["className"] as? String == binding["className"] as? String,
                   (raw["parentID"] as? String) == (binding["parentAddress"] as? String),
                   seenTokens.insert(token).inserted {
                    let expectedParent = node["parentToken"] as? String
                    let joinedParent = (binding["parentAddress"] as? String).flatMap { joins[$0]?["nodeToken"] as? String }
                    if expectedParent == joinedParent {
                        if let assetID = raw["assetID"] as? String, var asset = decodedAssets[assetID] {
                            asset["nodeID"] = token
                            asset["identityJoin"] = "same operation; retained live view and verified class/parent graph"
                            assets[assetID] = asset; nodeAssets[token] = assetID
                        } else { textureReasons[token] = raw["textureUnavailableReason"] as? String }
                    } else { textureReasons[token] = "Texture parent identity does not match the editable node." }
                }
                for child in raw["children"] as? [[String: Any]] ?? [] { join(child) }
            }
            for root in textures["roots"] as? [[String: Any]] ?? [] { join(root) }
        } catch {
            textureReason = "Texture hierarchy was rejected: \(error)"
        }
    }
    var swiftUI: [String: Any]?
    if let rawSection = result["swiftUI"] {
        guard var section = rawSection as? [String: Any], section["schemaVersion"] as? Int == 1,
              section["captureID"] as? String == captureID,
              let scope = section["inspectionScope"] as? [String: Any],
              let returnedScope = result["inspectionScope"] as? [String: Any],
              NSDictionary(dictionary: scope).isEqual(to: returnedScope),
              scope["deviceID"] as? String == target["deviceID"] as? String,
              var hosts = section["hosts"] as? [[String: Any]], hosts.count <= 64 else {
            throw ToolError("Invalid SwiftUI capture or inspection scope.")
        }
        guard try SimulatorViewInspectionScope(scope) == SimulatorViewInspectionScope(returnedScope) else {
            throw ToolError("Inspection scope differs.")
        }
        var hostIDs = Set<String>(), graphIDs = Set<String>()
        var graphCount = 0
        for index in hosts.indices {
            var host = hosts[index]
            guard let token = host["hostingNodeID"] as? String, let node = nodes[token], hostIDs.insert(token).inserted,
                  host["sceneID"] as? String == node["sceneID"] as? String,
                  let graph = host["nodes"] as? [[String: Any]],
                  let status = host["status"] as? String, ["available", "empty", "unavailable", "error", "overbudget"].contains(status),
                  (status == "available") == !graph.isEmpty,
                  var rendering = host["rendering"] as? [String: Any],
                  rendering["representation"] as? String == "hostingSubtreeComposite" else {
                throw ToolError("Invalid SwiftUI hosting association or outcome.")
            }
            graphCount += graph.count
            guard graphCount <= 4096 else { throw ToolError("SwiftUI node budget exceeded.") }
            let prefix = "swiftui:\(captureID):\(token):"
            var localIDs = Set<String>()
            for (ordinal, item) in graph.enumerated() {
                guard let id = item["id"] as? String, id == prefix + String(ordinal), graphIDs.insert(id).inserted,
                      item["editToken"] == nil, item["editableProperties"] == nil,
                      let properties = item["properties"] as? [[String: Any]], properties.count <= 64,
                      let child = item["childOrdinal"] as? Int, child >= 0,
                      item["parentID"] is NSNull || (item["parentID"] as? String).map({ localIDs.contains($0) }) == true else {
                    throw ToolError("Invalid SwiftUI topology or authority.")
                }
                var propertyIDs = Set<UInt32>()
                for property in properties {
                    guard let number = property["id"] as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
                          number.doubleValue >= 0, number.doubleValue <= Double(UInt32.max),
                          number.doubleValue.rounded() == number.doubleValue,
                          propertyIDs.insert(number.uint32Value).inserted, property["attribute"] is [String: Any] else {
                        throw ToolError("Invalid SwiftUI property ID or attribute.")
                    }
                }
                localIDs.insert(id)
            }
            if rendering["status"] as? String == "available" {
                guard rendering["drawHierarchyReturned"] as? Bool == true,
                      let data = rendering["data"] as? String,
                      let width = rendering["pointWidth"] as? Double, let height = rendering["pointHeight"] as? Double else {
                    throw ToolError("SwiftUI composite lacks a successful draw receipt.")
                }
                let property: [String: Any] = ["propertyName": "snapshotImage", "propertyFormat": "image",
                    "propertyRuntimeType": "UIImage", "fetchStatus": 4,
                    "propertyValue": ["imageData": data, "metadata": ["width": width, "height": height]]]
                let object: [String: Any] = ["objectID": token, "className": node["className"]!, "properties": [property]]
                let decoded = try simulatorViewHierarchySnapshot(groups: ["com.apple.UIKit.UIWindow": ["debugHierarchyObjects": [object]]],
                    pid: (target["pid"] as? NSNumber)?.int32Value ?? 0, captureID: captureID, capturedAt: capturedAt)
                guard let pair = (decoded["assets"] as? [String: [String: Any]])?.first else {
                    throw ToolError("SwiftUI composite PNG rejected.")
                }
                var candidate = assets
                if let old = nodeAssets[token] { candidate.removeValue(forKey: old) }
                var asset = pair.value
                asset["representation"] = "hostingSubtreeComposite"; asset["descendantContent"] = "all"
                asset["sourceProperty"] = "drawHierarchy(afterScreenUpdates:false)"
                candidate[pair.key] = asset
                let encoded = candidate.values.reduce(0) { $0 + (($1["data"] as? String)?.utf8.count ?? 0) }
                let pixels = candidate.values.reduce(0) { $0 + ($1["pixelWidth"] as? Int ?? 0) * ($1["pixelHeight"] as? Int ?? 0) * 4 }
                if candidate.count <= 64 && encoded <= 16 * 1024 * 1024 && pixels <= 128 * 1024 * 1024 {
                    assets = candidate; nodeAssets[token] = pair.key; rendering["assetID"] = pair.key
                } else {
                    rendering["status"] = "overbudget"; rendering["reason"] = "Shared texture budget exceeded."
                }
            }
            rendering.removeValue(forKey: "data"); rendering.removeValue(forKey: "pointWidth"); rendering.removeValue(forKey: "pointHeight")
            host["rendering"] = rendering; hosts[index] = host
        }
        section["hosts"] = hosts; swiftUI = section
    } else if result["swiftUIRaw"] != nil || result["inspectionScope"] != nil {
        throw ToolError("SwiftUI section was not normalized.")
    }
    var visited = Set<String>()
    func build(_ id: String, window: String, depth: Int) throws -> [String: Any] {
        guard depth <= 512, visited.insert(id).inserted, var node = nodes[id], node["windowToken"] as? String == window else {
            throw ToolError("Editable graph has a cycle, depth overflow, or changed window.")
        }
        let ids = (children[id] ?? []).sorted { (nodes[$0]?["siblingIndex"] as? Int ?? 0) < (nodes[$1]?["siblingIndex"] as? Int ?? 0) }
        node["parentID"] = node.removeValue(forKey: "parentToken")
        node["children"] = try ids.map { try build($0, window: window, depth: depth + 1) }
        node["editableProperties"] = ["hidden", "alpha"]
        node["properties"] = [["propertyName": "hidden", "propertyValue": node["hidden"]!],
                              ["propertyName": "alpha", "propertyValue": node["alpha"]!]]
        node["assetID"] = nodeAssets[id] as Any? ?? NSNull()
        node["textureUnavailableReason"] = nodeAssets[id] == nil ? (textureReasons[id] ?? textureReason) : NSNull()
        node["frameCoordinateSpace"] = "superview points"
        node["accessibilityIdentifier"] = NSNull(); node["accessibilityLabel"] = NSNull()
        return node
    }
    roots.sort { (nodes[$0]?["siblingIndex"] as? Int ?? 0) < (nodes[$1]?["siblingIndex"] as? Int ?? 0) }
    let tree = try roots.map { try build($0, window: $0, depth: 0) }
    guard visited.count == nodes.count else { throw ToolError("Editable capture has unreachable nodes.") }
    let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    editing["expiresAt"] = formatter.string(from: Date(timeIntervalSince1970: expires.doubleValue))
    let hasSwiftUIHostingView = nodes.values.contains {
        let name = $0["className"] as? String ?? ""
        return name.hasPrefix("_TtGC7SwiftUI14_UIHostingView") || name.hasPrefix("SwiftUI._UIHostingView<")
    }
    let renderingLimitations = hasSwiftUIHostingView && swiftUI == nil
        ? ["SwiftUI 텍스트·도형이 텍스처에서 누락될 수 있습니다. 트리는 UIKit 뷰 계층입니다."] : []
    var snapshot: [String: Any] = ["captureID": captureID, "capturedAt": capturedAt, "processLifetime": target, "roots": tree,
            "assets": assets, "editing": editing, "screenGeometry": NSNull(),
            "capabilities": ["textures": !assets.isEmpty, "editableProperties": ["hidden", "alpha"],
                             "renderingLimitations": renderingLimitations,
                             "reasons": renderingLimitations + (assets.isEmpty ? [textureReason] : [])],
            "verified": false, "overlayEnabled": false]
    if let swiftUI { snapshot["swiftUI"] = swiftUI; snapshot["inspectionScope"] = swiftUI["inspectionScope"] }
    return snapshot
}
