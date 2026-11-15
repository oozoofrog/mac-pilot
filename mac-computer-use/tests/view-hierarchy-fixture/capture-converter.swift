import Foundation

// Shared by the CLI-only session probe and the focused headless qualification check.
func fixtureConvertCapture(_ raw: [String: Any]) throws -> [String: Any] {
    if raw["schemaVersion"] as? Int == 2 {
        guard let target = raw["target"] as? [String: Any] else { throw ToolError("Missing editable target") }
        return try simulatorEditableViewHierarchySnapshot(result: raw, target: target)
    }
    guard raw["schemaVersion"] as? Int == 1, raw["status"] as? String == "success",
          let hierarchy = raw["hierarchy"] as? [String: Any],
          let groups = hierarchy["topLevelGroups"] as? [String: Any],
          let target = raw["target"] as? [String: Any], let pid = target["pid"] as? Int32,
          let id = raw["captureID"] as? String, let time = raw["captureTime"] as? String else {
        throw ToolError("No successful capture to convert")
    }
    return try simulatorViewHierarchySnapshot(groups: groups, pid: pid,
        captureID: id, capturedAt: time, geometry: raw["geometry"] as? [String: Any])
}
