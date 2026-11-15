import AppKit
import ApplicationServices
import Foundation
import XPC

func hostState() -> [String: Any] {
    let p = CGEvent(source: nil)?.location ?? .zero
    let app = NSWorkspace.shared.frontmostApplication
    return ["cursor": [p.x, p.y], "bundle": app?.bundleIdentifier ?? "", "pid": app?.processIdentifier ?? 0]
}

var sendBefore: [String: Any] = [:], sendAfter: [String: Any] = [:]
var sendStart: CFAbsoluteTime = 0, sendEnd: CFAbsoluteTime = 0
func observedSend(_ remote: PhysicalHIDLink, _ message: xpc_object_t) -> Bool {
    if sendStart == 0 { sendBefore = hostState(); sendStart = CFAbsoluteTimeGetCurrent() }
    let result = remote.send(message)
    sendEnd = CFAbsoluteTimeGetCurrent(); sendAfter = hostState()
    return result
}

struct SessionStub { let requestCancelled = false }
let currentSession: SessionStub? = nil

@main struct LiveHarness {
    static func main() {
        guard CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--live", getenv("MAC_CU_NATIVE_CHECK_CHILD") == nil,
              let data = CommandLine.arguments[2].data(using: .utf8),
              let args = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = args["device"] as? String, UUID(uuidString: id) != nil else { exit(64) }
        setenv("MAC_CU_NATIVE_CHECK_CHILD", "1", 1)
        do {
            // CoreDevice populates the manager asynchronously.
            _ = try deviceTool(["action": "list"])
            Thread.sleep(forTimeInterval: 3)
            let action = args["action"] as? String ?? ""
            if action == "audit" {
                _ = try deviceTool(["action": "allow", "device": id])
                do { _ = try deviceTool(["action": "screenshot", "device": UUID().uuidString]); throw NSError(domain: "unexpected acceptance", code: 1) }
                catch let error as ToolError { print("other identifier refused: \(error)") }
                _ = try deviceTool(["action": "release"])
                do { _ = try deviceTool(["action": "screenshot", "device": id]); throw NSError(domain: "unexpected acceptance after release", code: 1) }
                catch let error as ToolError { print("released identifier refused: \(error)") }
                print("{\"audit\":\"allow, refusal, release, refusal passed\"}")
                return
            }
            if action != "list" && action != "allow" { _ = try deviceTool(["action": "allow", "device": id]) }
            let start = CFAbsoluteTimeGetCurrent()
            let value = try deviceTool(args)
            let duration = CFAbsoluteTimeGetCurrent() - start
            let output: [String: Any] = ["result": value, "seconds": duration, "before": sendBefore, "after": sendAfter, "hidSeconds": sendStart == 0 ? 0 : sendEnd - sendStart]
            let encoded = try JSONSerialization.data(withJSONObject: output, options: [.sortedKeys])
            print(String(decoding: encoded, as: UTF8.self))
            // A server process outlives the call; give the input link its post-barrier hold before exiting.
            Thread.sleep(forTimeInterval: 0.6)
        } catch { fputs("ERROR: \(error)\n", stderr); exit(1) }
    }
}
