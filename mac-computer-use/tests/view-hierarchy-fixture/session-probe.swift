import AppKit

// Called only by native_check_support's explicit, inherited-entry guarded dispatch.
func fixtureSessionProbe() -> Never {
    DispatchQueue.global().async {
    do {
        let env = ProcessInfo.processInfo.environment
        if let file = env["FIXTURE_OPERATION_REQUEST"] {
            let result = try residentProductOperation(file)
            print(String(data: try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]), encoding: .utf8)!)
        } else if let file = env["FIXTURE_CAPTURE_RESULT"] {
            let raw = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: file))) as! [String: Any]
            let snapshot = try fixtureConvertCapture(raw)
            print(String(data: try JSONSerialization.data(withJSONObject: snapshot, options: [.sortedKeys]), encoding: .utf8)!)
        } else {
            guard let id = env["FIXTURE_DEVICE"] else { throw ToolError("Missing selected device") }
            let device = try bootedDevice(id)
            let pid = try simulatorFrontPid(device)
            let target = try simulatorViewCaptureTarget(pid: pid, deviceID: id)
            let path = URL(fileURLWithPath: target.path)
            let info = NSDictionary(contentsOf: path.deletingLastPathComponent().appendingPathComponent("Info.plist"))
            guard let bundle = info?["CFBundleIdentifier"] as? String, let display = displays(of: id), !display.isEmpty,
                  let host = NSWorkspace.shared.frontmostApplication else { throw ToolError("Unknown foreground/display") }
            let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
            let result: [String: Any] = ["deviceID": id, "frontBundle": bundle, "frontPID": pid,
                "frontPath": target.path, "frontStart": target.start,
                "displays": display, "hostPID": host.processIdentifier,
                "hostBundle": host.bundleIdentifier ?? "", "hostWindows": windows.filter { ($0[kCGWindowOwnerPID as String] as? Int32) == host.processIdentifier }.map { window in
                    window.filter { [kCGWindowNumber as String, kCGWindowBounds as String, kCGWindowLayer as String].contains($0.key) }
                },
                "desktopUnlocked": (CGSessionCopyCurrentDictionary() as? [String: Any])?["CGSSessionScreenIsLocked"] as? Bool != true]
            print(String(data: try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]), encoding: .utf8)!)
        }
        exit(0)
    } catch { fputs("\(error)\n", stderr); exit(1) }
    }
    dispatchMain()
}
