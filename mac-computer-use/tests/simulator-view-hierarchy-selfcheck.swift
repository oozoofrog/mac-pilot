import Foundation

struct ToolError: Error {
    let message: String
    init(_ message: String) { self.message = message }
}

@main
struct SimulatorViewHierarchySelfcheck {
    static func main() throws {
        func capture(_ windows: [Any]) throws -> [String: Any] {
            try simulatorViewHierarchySnapshot(groups: ["com.apple.UIKit.UIWindow": ["debugHierarchyObjects": windows]],
                                               pid: 42, captureID: "fixture", capturedAt: "fixture-time")
        }
        let child: [String: Any] = ["objectID": "child", "className": "UIView", "properties": [
            ["propertyName": "frame", "propertyValue": ["0x1p+1", "0x1p+2", "0x1p+5", "0x1p+6"]],
            ["propertyName": "hidden", "propertyValue": "1"], ["propertyName": "alpha", "propertyValue": "0x1p-1"]]]
        let root: [String: Any] = ["objectID": "window", "className": "UIWindow",
                                  "childGroup": ["debugHierarchyObjects": [child]]]
        let snapshot = try capture([root])
        let roots = snapshot["roots"] as! [[String: Any]]
        let children = roots[0]["children"] as! [[String: Any]]
        assert(children[0]["parentID"] as? String == "window" && children[0]["siblingIndex"] as? Int == 0)
        assert(children[0]["frame"] as? [Double] == [2, 4, 32, 64])
        assert(children[0]["hidden"] as? Bool == true && children[0]["alpha"] as? Double == 0.5)
        assert(children[0]["editToken"] is NSNull && snapshot["editing"] is NSNull)
        assert((children[0]["editableProperties"] as? [String])?.isEmpty == true)
        assert((children[0]["properties"] as? [[String: Any]])?.count == 3)
        assert(children[0]["children"] is NSNull, "Missing children are unknown, not an invented empty subtree")
        assert(snapshot["screenGeometry"] is NSNull, "Superview frame must not become an inferred screen rectangle")
        assert(JSONSerialization.isValidJSONObject(snapshot))
        let empty = try capture([])
        assert((empty["roots"] as? [[String: Any]])?.isEmpty == true)
        do { _ = try capture([root, root]); assertionFailure("Duplicate capture identities must fail") } catch {}
        do {
            _ = try simulatorViewHierarchySnapshot(groups: [:], pid: 42, captureID: "fixture", capturedAt: "fixture-time")
            assertionFailure("Missing window group is not an empty result")
        } catch {}
        let device = "00000000-0000-0000-0000-000000000001"
        let unavailable = try simulatorViews(pid: 42, deviceID: device, query: "")
        assert(unavailable.status == .unavailable && unavailable.content["overlayEnabled"] as? Bool == false)
        let target = SimulatorViewCaptureTarget(pid: 42, start: [100, 0], path: "/unavailable", deviceID: device)
        let disabledCapture = try simulatorCaptureViews(SimulatorViewCaptureRequest(target: target))
        assert(disabledCapture.status == .unavailable)
        let text = simulatorViewsText(groups: ["com.apple.UIKit.UIWindow": ["debugHierarchyObjects": [root]]],
                                      pid: 42, query: "UIView", seconds: 1)
        assert(text.contains("UIView") && text.contains("2,4 32×64") && text.contains("unverified"))
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            defer { done.signal() }
            do {
                // Read-only real helper roundtrip; this host executable cannot pass fixture policy.
                let identity = try simulatorViewCaptureTarget(pid: ProcessInfo.processInfo.processIdentifier, deviceID: device)
                assert(identity.start.count == 2 && identity.start[0] > 0)
                var request = SimulatorViewCaptureRequest(target: identity)
                request.validationOnly = true
                let refused = try simulatorCaptureViews(request)
                assert(refused.status == .unsupported)
            } catch { fatalError("Production helper/resource roundtrip failed: \(error)") }
        }
        assert(done.wait(timeout: .now() + 15) == .success)
        print("PASS view hierarchy fixture: parent/child, numeric properties, unknown geometry, JSON, empty and malformed responses")
    }
}
