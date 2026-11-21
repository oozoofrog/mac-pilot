import AppKit

func checkStatusPopover() -> Never {
    DispatchQueue.global().async {
        do {
            let directory = URL(fileURLWithPath: ProcessInfo.processInfo.environment["MAC_CU_STATUS_CHECK"]!)
            let pid = try String(contentsOf: directory.appendingPathComponent("ready"), encoding: .utf8)
            guard AXIsProcessTrusted(), CGPreflightScreenCaptureAccess() else {
                throw ToolError("The check requires Accessibility and Screen Recording.")
            }
            let fixtureName = ProcessInfo.processInfo.environment["MAC_CU_STATUS_EXECUTABLE"]!
            currentSession = AgentSession(fd: -1)
            let session = try session(for: fixtureName)
            guard session.pid == pid_t(pid) else { throw ToolError("Resolved a different process.") }
            func tool(_ name: String, _ fields: [String: Any] = [:]) throws -> [[String: Any]] {
                let response = callTool(name, fields.merging(["app": fixtureName]) { _, app in app })
                let content = response["content"] as? [[String: Any]] ?? []
                guard response["isError"] as? Bool != true else { throw ToolError(content.first?["text"] as? String ?? "Tool error") }
                return content
            }
            func click(_ identifier: String, foreground: Bool = false) throws -> String {
                guard let index = session.elements.firstIndex(where: { string($0, kAXIdentifierAttribute) == identifier }) else {
                    throw ToolError("Missing element: " + identifier)
                }
                return try tool("act", ["foreground": foreground, "actions": [["type": "click", "element": index]]]).first?["text"] as? String ?? ""
            }
            let closed = try tool("get_app_state").first?["text"] as? String ?? ""
            guard closed.contains("has no window"), closed.contains("fixture.status") else { throw ToolError(closed) }
            let prior = frontmostPID()
            let open = try click("fixture.status", foreground: true)
            guard open.contains("Popover"), open.contains("fixture.confirm") else { throw ToolError(open) }
            let picture = try tool("get_app_state", ["screenshot": true, "guides": true])
            guard let encoded = picture.last?["data"] as? String, let jpeg = Data(base64Encoded: encoded),
                  let image = NSBitmapImageRep(data: jpeg), let window = frontWindow(of: session), let bounds = frame(window),
                  image.pixelsWide == Int(bounds.width), image.pixelsHigh == Int(bounds.height) else {
                throw ToolError("Missing or mismatched popover screenshot: " + picture.compactMap { $0["text"] as? String }.joined(separator: "\n"))
            }
            try jpeg.write(to: directory.appendingPathComponent("popover.jpg"))
            _ = try click("fixture.confirm")
            let changed = try tool("get_app_state").first?["text"] as? String ?? ""
            guard changed.contains("Confirmed fixture") else { throw ToolError(changed) }
            let dismissed = try click("fixture.status")
            guard dismissed.contains("has no window"), !dismissed.contains("fixture.confirm") else { throw ToolError(dismissed) }
            guard frontmostPID() == prior else { throw ToolError("Previous foreground app was not restored.") }
            print("PASS windowless status item, popover tree, screenshot, button action and dismissal")
            exit(0)
        } catch {
            print("FAIL", error)
            exit(1)
        }
    }
    RunLoop.main.run()
    exit(1)
}
