import Foundation

private var activePhysicalTest: PhysicalXCTestSession?

@discardableResult
func endPhysicalXCTest(owner: UUID) -> Bool {
    guard let runner = activePhysicalTest, runner.owner == owner else { return false }
    let exitedCleanly = runner.stop()
    activePhysicalTest = nil
    return exitedCleanly
}

func physicalAgentDeviceTool(_ args: [String: Any]) throws -> [String: Any] {
    let action = args["action"] as? String ?? ""
    let id = (args["device"] as? String).flatMap(UUID.init(uuidString:))
    guard let client = currentSession else { throw ToolError("A physical device operation requires an MCP connection.") }
    if !PhysicalXCTestSession.actions.contains(action) {
        if let runner = activePhysicalTest,
           action == "release" || (action == "allow" && id != runner.device) {
            guard runner.owner == client.activityID else { throw ToolError("Another connection owns the XCTest session.") }
            if action == "release" { endPhysicalXCTest(owner: client.activityID) }
            else { throw ToolError("Stop the active XCTest session before selecting a different device.") }
        }
        let result = try deviceTool(args)
        if action == "allow" { client.physicalTestAllowed = id }
        if action == "release" { client.physicalTestAllowed = nil }
        return result
    }
    guard let id, client.physicalTestAllowed == id else { throw ToolError("Use device allow with this UUID in this MCP connection first.") }
    let payload: [String: Any]
    if action == "xctestStart" {
        guard activePhysicalTest == nil else { throw ToolError("A MacPilot XCTest session already exists. Its owner must stop it first.") }
        let selected = try physicalDeviceTool.checkXCTestAccess(id)
        let target = args["app"] as? String
        if args["app"] != nil {
            guard let target, target.utf8.count <= 255,
                  target.range(of: #"^[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+$"#, options: .regularExpression) != nil else {
                throw ToolError("app must be a bundle identifier.")
            }
        }
        let runner = try PhysicalXCTestSession(owner: client.activityID, selection: selected, target: target)
        activePhysicalTest = runner
        client.physicalTestEnd = nil
        runner.scheduleReaping { [weak client] reason in
            guard activePhysicalTest === runner else { return }
            client?.physicalTestEnd = (id, reason)
            endPhysicalXCTest(owner: runner.owner)
        }
        payload = ["state": "starting"]
    } else {
        guard let runner = activePhysicalTest, runner.device == id, runner.owner == client.activityID else {
            if action == "xctestStatus", let ended = client.physicalTestEnd, ended.device == id { throw ToolError(ended.reason) }
            throw ToolError("No XCTest session owned by this connection on this device.")
        }
        switch action {
        case "xctestStop":
            payload = ["state": "stopped", "confirmedRunnerExit": endPhysicalXCTest(owner: client.activityID)]
        case "xctestStatus": payload = try runner.status()
        default:
            try physicalDeviceTool.checkXCTestAccess(id)
            let operation = String(action.dropFirst("xctest".count)).lowercased()
            if ["wait", "tap", "type"].contains(operation) {
                guard (args["target"] == nil) != (args["label"] == nil),
                      let target = (args["target"] ?? args["label"]) as? String, !target.isEmpty, target.utf8.count <= 256 else {
                    throw ToolError("Pass either target (exact identifier) or label (exact label), up to 256 UTF-8 bytes.")
                }
            }
            if operation == "type" {
                guard let text = args["text"] as? String, !text.isEmpty, text.count <= 200, text.utf8.count <= 2048 else {
                    throw ToolError("Pass 1 to 200 characters, up to 2048 UTF-8 bytes.")
                }
            }
            payload = try runner.command(operation, args: args, cancelled: { client.requestCancelled })
        }
    }
    let data = try JSONSerialization.data(withJSONObject: payload)
    return ["content": [["type": "text", "text": String(decoding: data, as: UTF8.self)]], "structuredContent": payload]
}
