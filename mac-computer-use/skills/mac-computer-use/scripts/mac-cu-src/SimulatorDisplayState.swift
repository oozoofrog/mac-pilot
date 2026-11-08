import Foundation

/// Device buttons and Crown reports do not address a touchscreen, including when every display is asleep.
func simulatorCommandNeedsActiveScreen(_ action: String) -> Bool { action != "button" && action != "crown" }

/// Polls can overlap tool calls and the status board; each devicectl invocation owns its output.
func displays(of id: String, task: SimulatorPreparationTask? = nil) -> [[String: Any]]? {
    let file = FileManager.default.temporaryDirectory.appendingPathComponent("mac-cu-displays-\(id)-\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: file) }
    let arguments = ["devicectl", "device", "info", "displays", "--device", id, "--quiet", "--json-output", file.path]
    let succeeded: Bool
    if let task { succeeded = (try? task.run("/usr/bin/xcrun", arguments, timeout: 5, stream: false)) != nil }
    else { succeeded = shell("/usr/bin/xcrun", arguments).status == 0 }
    guard succeeded, let data = try? Data(contentsOf: file),
          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else { return nil }
    return (json["result"] as? [String: Any])?["displays"] as? [[String: Any]]
}

struct SimulatorDisplayRefresh {
    private var version = 0
    private var pending = false
    mutating func changed() { version += 1 }
    mutating func begin() -> Int? {
        guard !pending else { return nil }
        pending = true
        return version
    }
    mutating func finish(_ ticket: Int) -> Bool {
        pending = false
        return ticket == version
    }
}
