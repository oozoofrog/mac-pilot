import AppKit

func desktopCheckMode(_ mode: String) throws {
    guard saveModes(["input": mode, "show": "off"]), modes()["input"] == mode else {
        throw ToolError("Failed to set isolated test input mode: " + mode)
    }
}

func checkDesktopChain(_ target: Session, _ app: String, _ directory: URL, _ previous: pid_t) throws {
    let owner = currentSession
    let rival = AgentSession(fd: -2)
    func require(_ condition: Bool, _ message: String) throws {
        if !condition { throw ToolError(message) }
    }
    func request(_ tool: String, _ fields: [String: Any] = [:], reject: Bool = false) throws -> [String: Any] {
        let response = handleQueue.sync { callTool(tool, fields.merging(["app": app]) { _, name in name }) }
        let text = (response["content"] as? [[String: Any]])?.first?["text"] as? String ?? ""
        try require((response["isError"] as? Bool == true) == reject, "\(tool) expected rejection=\(reject): \(text)")
        return response
    }
    func read(_ chain: String? = nil) throws -> String {
        let response = try request("get_app_state", chain.map { ["chain": $0] } ?? [:])
        return (response["content"] as? [[String: Any]])?.first?["text"] as? String ?? ""
    }
    func click(_ id: String) throws -> [[String: Any]] {
        guard let index = target.elements.firstIndex(where: { string($0, kAXIdentifierAttribute) == id }) else {
            throw ToolError("Missing form control: " + id)
        }
        return [["type": "click", "element": index]]
    }
    func token(_ name: String, from response: [String: Any]) throws -> String {
        guard let value = (response["structuredContent"] as? [String: Any])?[name] as? String, !value.isEmpty else {
            throw ToolError("Missing structured field " + name)
        }
        return value
    }
    func focus(_ pid: pid_t) throws {
        try require(frontmostPID() == pid, "Unexpected focus change; stopping desktop check.")
    }

    try Data().write(to: directory.appendingPathComponent("form"))
    var initial = ""
    for _ in 0..<15 {
        initial = try read()
        if initial.contains("fixture.always") { break }
        usleep(100_000)
    }
    try require(initial.contains("fixture.foreground"), initial)
    try focus(previous)
    _ = try request("act", ["foreground": true, "actions": try click("fixture.always")], reject: true)
    try focus(previous)
    _ = try request("act", ["actions": try click("fixture.always")])
    try require(try read().contains("fixture.always 1"), "Expected one successful background click.")
    try focus(previous)

    let attempt = try request("act", ["actions": try click("fixture.foreground")])
    let receipt = try token("receipt", from: attempt)
    var retry: [String: Any] = ["foreground": true, "receipt": receipt, "expected": "counter increments",
                                 "observed": "counter remains zero", "chain": "begin",
                                 "actions": try click("fixture.foreground")]
    _ = try request("act", retry, reject: true)
    try require(try read().contains("fixture.foreground 0"), "Background-only attempt changed the foreground-only control.")
    retry["actions"] = try click("fixture.always")
    _ = try request("act", retry, reject: true)
    try focus(previous)
    retry["actions"] = try click("fixture.foreground")
    try desktopCheckMode("background")
    _ = try request("act", retry, reject: true)
    try desktopCheckMode("auto")
    try focus(previous)
    let begun = try request("act", retry)
    let chain = try token("chain", from: begun)
    try focus(target.pid)
    try require(try read(chain).contains("fixture.foreground 1"), "Retry must commit exactly once.")
    let actions = try click("fixture.always")
    currentSession = rival
    defer { currentSession = owner }
    _ = try request("act", ["chain": chain, "actions": actions], reject: true)
    _ = try request("act", ["chain": chain, "end": true], reject: true)
    _ = try read()
    currentSession = owner
    _ = try request("act", ["chain": chain, "actions": actions], reject: true)
    for count in 2...3 {
        try focus(target.pid)
        _ = try read(chain)
        _ = try request("act", ["chain": chain, "actions": try click("fixture.always")])
        try require(try read(chain).contains("fixture.always " + String(count)), "Wrong chained action count.")
    }
    try focus(target.pid)
    _ = try request("act", ["chain": chain, "actions": try click("fixture.showSheet")])
    try require(try read(chain).contains("fixture.closeSheet"), "The target's attached sheet did not open.")
    _ = try request("act", ["chain": chain, "actions": try click("fixture.closeSheet")])
    _ = try read(chain)
    guard let index = try click("fixture.always").first?["element"] as? Int,
          let button = frame(target.elements[index]), let window = frontWindow(of: target).flatMap(frame) else {
        throw ToolError("Missing fixture click coordinates.")
    }
    let point: [String: Any] = ["type": "click_at", "x": (button.midX - window.minX) * target.screenshotScale,
                                "y": (button.midY - window.minY) * target.screenshotScale]
    _ = try request("act", ["chain": chain, "actions": [point]])
    try require(try read(chain).contains("fixture.always 4"), "HID click missed its intended form button.")
    _ = try request("act", ["chain": chain, "end": true])
    try focus(previous)
    _ = try request("act", ["chain": chain, "end": true])
    _ = try request("act", ["chain": chain, "actions": actions], reject: true)
    retry["actions"] = try click("fixture.foreground")
    _ = try request("act", retry, reject: true)
    try focus(previous)
    try desktopCheckMode("foreground")
    func begin() throws -> String {
        _ = try read()
        return try token("chain", from: request("act", ["chain": "begin", "actions": [["type": "wait", "seconds": 0]]]))
    }
    let partial = try begin()
    let valid = try click("fixture.always")
    let failure = try request("act", ["chain": partial, "actions": valid + [["type": "invalid-fixture-action"]] + valid], reject: true)
    let progress = failure["structuredContent"] as? [String: Int]
    try require(progress?["completed"] == 1 && progress?["skipped"] == 1 && progress?["failedStep"] == 2,
                "Partial failure must report completed, failed and skipped actions.")
    try focus(previous)
    try require(try read().contains("fixture.always 5"), "Partial failure duplicated an effect.")
    let stopped = try begin()
    try desktopCheckMode("background")
    _ = try request("act", ["chain": stopped, "actions": valid], reject: true)
    try focus(previous)
    try desktopCheckMode("foreground")
    let idle = try begin()
    for _ in 0..<3 {
        Thread.sleep(forTimeInterval: 8)
        try focus(target.pid)
        _ = try read(idle)
    }
    Thread.sleep(forTimeInterval: 7)
    try focus(previous)
    _ = try request("get_app_state", ["chain": idle], reject: true)
    try checkDesktopDisconnect(app: app, target: target.pid, previous: previous)
    currentSession = owner
    let interrupted = try begin()
    let switchURL = directory.appendingPathComponent("sibling")
    DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(250)) { try? Data().write(to: switchURL) }
    let rejected = try request("act", ["chain": interrupted, "actions": [["type": "wait", "seconds": 1]] + valid], reject: true)
    let outcome = rejected["structuredContent"] as? [String: Any]
    try require(outcome?["completed"] as? Int == 0 && outcome?["skipped"] as? Int == 1, "The pending click must be stopped when the user changes windows.")
    try focus(target.pid)
    try require(try read().contains("User-selected sibling"), "The user's sibling window must stay selected.")
    print("PASS related sheet, real pointer click, partial result, mode revocation, idle timer, and sibling intervention")
    print("PASS background-only effect, admission, observation, wrong operation, modes, three-act chain, client ownership, stale snapshot, release, idempotence and stale tokens")
}
