import Foundation
import Darwin

struct ToolError: Error { let message: String; init(_ value: String) { message = value } }
struct SimulatorViewCaptureTarget {
    let pid: Int32
    let start: [UInt64]
    let path: String
    let deviceID: String
}

// The production caller is extracted without rewriting its body. These two
// dependencies expose which route it takes without launching a child or reading
// a real process. The reader itself is tested separately with its real code.
var interpreterCalls = 0
var nativeCalls = 0
struct SimulatorTargetIdentity {
    let pid: Int32
    let start: [UInt64]
    let path: String
    let deviceID: String
    static func read(pid: Int32, deviceID: String) throws -> Self {
        nativeCalls += 1
        return Self(pid: pid, start: [41, 42], path: "/native/target", deviceID: deviceID.uppercased())
    }
}
final class SimulatorViewCaptureCancellation {}
func simulatorViewCaptureFolder() throws -> URL {
    let path = FileManager.default.temporaryDirectory.appendingPathComponent("identity-routing-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: path, withIntermediateDirectories: false)
    return path
}
func simulatorViewCaptureHelper(arguments: [String], cancellation: SimulatorViewCaptureCancellation,
                                folder: URL) throws -> [String: Any] {
    interpreterCalls += 1
    return ["status": "success", "target": ["start": [UInt64(1), UInt64(2)], "path": "/interpreter/target"]]
}
