import Foundation

struct ToolError: Error {
    let message: String
    init(_ message: String) { self.message = message }
}

@main struct TextureSelfcheck {
    static func main() throws {
        func snapshot(_ groups: [String: Any]) throws -> [String: Any] {
            try simulatorViewHierarchySnapshot(groups: groups, pid: 42, captureID: "capture", capturedAt: "time")
        }
        var png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+/a6cAAAAASUVORK5CYII=")!
        func headerSize(_ width: Int, _ height: Int, _ image: inout Data) {
            for (offset, value) in [(16, width), (20, height)] {
                for i in 0..<4 { image[offset + i] = UInt8(truncatingIfNeeded: value >> (24 - 8 * i)) }
            }
            var crc: UInt32 = 0xffffffff
            for byte in image[12..<29] {
                crc ^= UInt32(byte)
                for _ in 0..<8 { crc = (crc >> 1) ^ ((crc & 1) == 1 ? 0xedb88320 : 0) }
            }
            crc ^= 0xffffffff
            for i in 0..<4 { image[29 + i] = UInt8(truncatingIfNeeded: crc >> (24 - 8 * i)) }
        }
        // Header-only budget test: IDAT remains 1x1 and is never decoded by this backend.
        headerSize(1206, 2622, &png)
        let data = png.base64EncodedString()
        if CommandLine.arguments.count > 1 {
            let url = URL(fileURLWithPath: CommandLine.arguments[1])
            let response = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
            let recorded = try snapshot(response["topLevelGroups"] as! [String: Any])
            let assets = recorded["assets"] as! [String: [String: Any]]
            assert(assets.count == 14, "All 14 observed images fit the product limits")
            assert(assets.values.contains { $0["pixelWidth"] as? Int == 1206 && $0["pixelHeight"] as? Int == 2622 })
            assert(assets.values.allSatisfy { $0["captureID"] as? String == "capture" && $0["descendantContent"] as? String == "unknown" })
        }
        func image(_ id: String, _ data: String, _ width: Any = 1) -> [String: Any] {
            ["objectID": id, "className": "UIView", "properties": [["propertyName": "snapshotImage", "propertyFormat": "image", "propertyRuntimeType": "UIImage", "fetchStatus": 4, "propertyValue": ["imageData": data, "metadata": ["width": width, "height": 1]]]]]
        }
        func group(_ nodes: [[String: Any]]) -> [String: Any] {
            ["com.apple.UIKit.UIWindow": ["debugHierarchyObjects": nodes]]
        }
        let pair = try snapshot(group([image("a", data), image("b", data)]))
        assert((pair["assets"] as! [String: Any]).count == 2, "Identical node textures are allowed")
        let roots = pair["roots"] as! [[String: Any]]
        assert(roots[0]["assetID"] as! String != roots[1]["assetID"] as! String)
        let properties = roots[0]["properties"] as! [[String: Any]]
        assert((properties[0]["propertyValue"] as! [String: Any])["imageData"] == nil)
        for bad in ["!" + data.dropFirst(), String(repeating: "A", count: 4 * 1024 * 1024 + 4), "AAAA"] {
            let result = try snapshot(group([image("a", String(bad))]))
            assert((result["assets"] as! [String: Any]).isEmpty)
            assert((result["roots"] as! [[String: Any]])[0]["textureUnavailableReason"] is String)
        }
        let booleanSize = try snapshot(group([image("a", data, true)]))
        assert((booleanSize["assets"] as! [String: Any]).isEmpty)
        let many = (0..<65).map { image("node\($0)", data) }
        let overCount = try snapshot(group(many))
        assert((overCount["assets"] as! [String: Any]).isEmpty)
        let overDecoded = try snapshot(group((0..<11).map { image("large\($0)", data) }))
        assert((overDecoded["assets"] as! [String: Any]).count == 10, "Decoded RGBA aggregate must remain under 128 MiB")
        var badCRC = Data(base64Encoded: data)!
        badCRC[29] ^= 1
        let badHeader = try snapshot(group([image("a", badCRC.base64EncodedString())]))
        assert((badHeader["assets"] as! [String: Any]).isEmpty)
        var tooWide = Data(base64Encoded: data)!
        headerSize(4097, 1, &tooWide)
        let overWidth = try snapshot(group([image("a", tooWide.base64EncodedString())]))
        assert((overWidth["assets"] as! [String: Any]).isEmpty)
        do { _ = try snapshot(group([image("a", data), image("a", data)])); fatalError("duplicate node accepted") } catch {}
        var duplicate = image("a", data)
        let prop = (duplicate["properties"] as! [[String: Any]])[0]
        duplicate["properties"] = [prop, prop]
        do { _ = try snapshot(group([duplicate])); fatalError("duplicate image property accepted") } catch {}
        print("PASS texture provenance, duplicate images, bounds and malformed inputs" + (CommandLine.arguments.count > 1 ? "; recorded 14 textures and root dimensions" : ""))
    }
}
