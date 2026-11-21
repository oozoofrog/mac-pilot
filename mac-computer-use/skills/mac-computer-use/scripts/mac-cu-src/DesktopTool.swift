import Foundation

func desktopTool(_ name: String, _ arguments: [String: Any], screenshot: Bool, guides: Bool) throws -> [String: Any] {
    guard let client = currentSession else { throw ToolError("Desktop operations require a client connection.") }
    let app = arguments["app"] as? String ?? ""
    let chain = arguments["chain"] as? String
    if name == "act", arguments["end"] as? Bool == true {
        guard let chain, chain != "begin", !app.isEmpty, arguments["actions"] == nil else {
            throw ToolError("End a chain with app, its chain ID and end:true. Omit actions.")
        }
        return try endDesktopChain(chain, owner: client, app: app)
    }
    let target = try session(for: app)
    if name == "get_app_state" {
        if let chain { try observeDesktopChain(chain, session: target, owner: client) }
        let content = try state(of: target, screenshot: screenshot, guides: guides)
        desktopRecordSnapshot(client, target, observed: true)
        return ["content": content]
    }

    guard let actions = arguments["actions"] as? [[String: Any]], !actions.isEmpty else {
        throw ToolError("act requires a nonempty actions array. To release a chain, use end:true.")
    }
    try guardDesktopAct(chain, session: target, owner: client)
    let mode = modes()["input"] ?? "auto"
    let requested = arguments["foreground"] as? Bool == true
    let beginning = chain == "begin"
    let continuing = chain != nil && !beginning
    if mode == "background", requested || chain != nil {
        throw ToolError("The user selected background-only input. Foreground actions are disabled.")
    }
    if beginning && !requested && mode != "foreground" {
        throw ToolError("Start a foreground chain with foreground:true. Use ordinary background calls otherwise.")
    }
    let popoverHeld = desktopHold?.popover != nil
    if chain != nil || popoverHeld || (requested && mode == "auto") {
        try desktopCheckSnapshot(client, target, actions)
    }
    var admission: DesktopAttempt?
    if mode == "auto", requested, !continuing, !popoverHeld {
        admission = try desktopConsumeAttempt(client, target, actions, receipt: arguments["receipt"] as? String,
                                              expected: arguments["expected"] as? String, observed: arguments["observed"] as? String)
    }
    let attempt = mode == "auto" && !requested && chain == nil && !popoverHeld ? desktopPrepareAttempt(client, target, actions) : nil
    desktopInvalidateAttempts(target)
    var result = try act(actions, session: target, foreground: requested, screenshot: screenshot, guides: guides,
                         verify: arguments["verify"] as? [String: Any], goal: arguments["goal"] as? String,
                         chain: chain, inputMode: mode, admission: admission)
    if result["isError"] as? Bool != true {
        if let receipt = desktopPublishAttempt(attempt) {
            var fields = result["structuredContent"] as? [String: Any] ?? [:]
            fields["receipt"] = receipt
            result["structuredContent"] = fields
            var content = result["content"] as? [[String: Any]] ?? []
            content.append(["type": "text", "text": "Background attempt receipt: " + receipt])
            result["content"] = content
        }
        if arguments["verify"] == nil { desktopRecordSnapshot(client, target, observed: false) }
    }
    return result
}
