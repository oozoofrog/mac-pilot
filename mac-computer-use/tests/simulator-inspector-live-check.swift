import AppKit

/// Guarded production LCD integration. Local AppKit dispatch, never global pointer input.
func runSimulatorInspectorLiveCheck() -> Never {
    NSApplication.shared.setActivationPolicy(.accessory)
    Task { @MainActor in
        var status: Int32 = 0
        do { try await axLCDWorkflow() }
        catch { fputs("FAIL LCD: \(error)\n", stderr); status = 1 }
        exit(status)
    }
    NSApplication.shared.run()
    exit(1)
}

@MainActor private func axLCDWorkflow() async throws {
    let env = ProcessInfo.processInfo.environment
    let target = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: env["AX_LIVE_TARGET"]!))) as! [String: Any]
    let id = target["deviceID"] as! String
    let out = URL(fileURLWithPath: env["AX_LIVE_OUTPUT"]!)
    let oracleURL = URL(fileURLWithPath: target["documents"] as! String).appendingPathComponent("ax-oracle.json")
    func oracle() throws -> NSDictionary { try JSONSerialization.jsonObject(with: Data(contentsOf: oracleURL)) as! NSDictionary }
    func save(_ name: String, _ value: Any) throws { try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]).write(to: out.appendingPathComponent(name), options: .atomic) }
    func background<T>(_ work: @escaping () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in handleQueue.async { continuation.resume(with: Result(catching: work)) } }
    }
    let (device, active) = try await background { () -> (NSObject, ActiveScreen?) in
        let device = try bootedDevice(id)
        guard try simulatorFrontPid(device) == target["pid"] as? Int32,
              let boot = SimulatorBootIdentity.current(deviceID: id), boot.key == target["boot"] as? String else { throw ToolError("LCD fixture ownership changed") }
        let life = try SimulatorAXLifetime.current(target["pid"] as! Int32)
        guard life.executable == target["path"] as? String, [life.startSeconds, life.startMicroseconds] == target["start"] as? [UInt64] else { throw ToolError("LCD lifetime changed") }
        return (device, try activeScreen(of: device))
    }
    let previous = NSWorkspace.shared.frontmostApplication
    guard previous?.processIdentifier == target["hostPID"] as? Int32 else { throw ToolError("LCD entry host changed") }
    let types: [CGEventType] = [.leftMouseDown,.leftMouseUp,.rightMouseDown,.rightMouseUp,.mouseMoved,.leftMouseDragged,.rightMouseDragged,.keyDown,.keyUp,.flagsChanged,.scrollWheel,.otherMouseDown,.otherMouseUp,.otherMouseDragged]
    func counters() -> [UInt32] { types.map { CGEventSource.counterForEventType(.combinedSessionState, eventType: $0) } }
    let input = counters()
    let key = "simulatorToolbox.\(id)", pref = UserDefaults.standard.object(forKey: key)
    let owner = SimulatorWindow(device: device, active: active); simulatorWindows[id] = owner
    defer {
        let restore = NSApp.isActive && counters() == input
        owner.window.close(); simulatorWindows.removeValue(forKey: id)
        if let pref { UserDefaults.standard.set(pref, forKey: key) } else { UserDefaults.standard.removeObject(forKey: key) }
        if restore { previous?.activate(options: []) }
    }
    bringSimulatorWindowToFront(owner) // One declared foreground acquisition.
    try await Task.sleep(nanoseconds: 450_000_000)
    func guardFocus() throws {
        guard counters() == input, NSApp.isActive, owner.toolbox.window?.isKeyWindow == true || owner.window.isKeyWindow else { throw ToolError("LCD external input/focus loss; stop without retry") }
    }
    try guardFocus()
    var commands: [[String: Any]] = [], responses: [[String: Any]] = []
    // Same command path and activity accounting as SimulatorWindow.onRun; observation only.
    owner.toolbox.onRun = { arguments in
        do { try guardFocus() } catch { return }
        commands.append(arguments)
        handleQueue.async {
            let previousSession = currentSession; currentSession = nil
            defer { currentSession = previousSession }
            let activity = SimulatorToolActivity(arguments: arguments, source: "직접 조작")
            let answer: [String: Any]
            do { answer = try executeSimulatorCommand(arguments, device: device, activity: activity) }
            catch { answer = ["isError": true, "error": String(describing: error)] }
            DispatchQueue.main.async { responses.append(answer) }
        }
    }
    if !owner.content.toolsVisible { owner.toggleToolbox() }
    try await Task.sleep(nanoseconds: 450_000_000)
    try guardFocus()
    func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
    let browser = descendants(owner.toolbox).compactMap { $0 as? SimulatorElementBrowser }.first!
    let table = descendants(browser).compactMap { $0 as? NSTableView }.first!
    func button(_ title: String) throws -> NSButton {
        guard let b = descendants(browser).compactMap({ $0 as? NSButton }).first(where: { $0.title == title }) else { throw ToolError("Missing control: \(title)") }; return b
    }
    guard commands.isEmpty, table.numberOfRows == 0 else { throw ToolError("Inspector captured automatically") }
    var evidence: [[String: Any]] = [["case": "openWithoutCapture", "commands": commands.count, "rows": table.numberOfRows]]
    var nodes: [[String: Any]] = []
    func waitResponse(_ count: Int) async throws {
        let end = Date().addingTimeInterval(7)
        while responses.count < count || owner.toolbox.busy || owner.toolbox.manualPending {
            try guardFocus(); guard Date() < end else { throw ToolError("LCD response deadline") }
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        try guardFocus()
    }
    func refresh() async throws {
        let count = responses.count
        try button("화면 요소 새로 읽기").performClick(nil)
        try await waitResponse(count + 1)
        let structured = responses.last?["structuredContent"] as? [String: Any]
        let inspection = structured?["inspection"] as? [String: Any]
        guard let snapshot = inspection?["axSnapshot"] as? [String: Any], let rows = snapshot["nodes"] as? [[String: Any]], !rows.isEmpty else { throw ToolError("Normal LCD capture missing: \(responses.last ?? [:])") }
        nodes = rows
        try save("lcd-snapshot.json", snapshot)
    }
    func select(_ name: String) throws {
        let count = commands.count
        guard let row = nodes.firstIndex(where: { $0["identifier"] as? String == "fixture." + name }) else { throw ToolError("LCD fixture row missing \(name)") }
        table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        guard commands.count == count, !owner.view.touching, owner.view.lastFingers == nil else { throw ToolError("Selection dispatched input") }
    }
    func act(_ name: String, _ title: String, counter: String? = nil, text: String? = nil) async throws {
        try guardFocus()
        let before = try oracle(), count = commands.count
        let control = try button(title)
        guard control.isEnabled else { throw ToolError("Disabled required LCD control: \(title)") }
        control.performClick(nil)
        try await waitResponse(count + 1)
        try await Task.sleep(nanoseconds: 250_000_000)
        let after = try oracle()
        guard commands.count == count + 1 else { throw ToolError("Automatic retry or missing dispatch") }
        let result = (responses.last?["structuredContent"] as? [String: Any])?["axResult"] as? [String: Any] ?? [:]
        evidence.append(["case": name, "button": title, "command": commands.last!, "response": responses.last!, "oracleBefore": before, "oracleAfter": after, "inputMethod": "local AppKit performClick"])
        try save("lcd-actions.json", evidence)
        guard result["delivery"] as? String == "dispatched" else { throw ToolError("LCD action not dispatched") }
        if let counter {
            let b = before["counters"] as! [String: Int], a = after["counters"] as! [String: Int]
            var expected = b; expected[counter, default: 0] += 1
            guard a == expected else { throw ToolError("Guest counter mismatch") }
        }
        if let text { guard after["text"] as? String == text, (result["readback"] as? [String: Any])?["value"] as? String == text else { throw ToolError("LCD STRING oracle/readback mismatch") } }
        guard after["secureUnchanged"] as? Bool == true else { throw ToolError("Secure oracle invariant") }
    }
    try await refresh()
    try select("press"); try await act("press", "접근성 동작 실행 (AXPress)", counter: "press")
    for index in 1...2 {
        try await refresh(); try select("custom")
        let custom = descendants(browser).compactMap { $0 as? NSPopUpButton }.first!
        guard custom.indexOfSelectedItem == 0, !(try button("선택한 사용자 동작 실행")).isEnabled, custom.numberOfItems == 3,
              custom.item(at: 1)?.representedObject as? String != custom.item(at: 2)?.representedObject as? String else { throw ToolError("Custom selection/handle guard") }
        custom.selectItem(at: index); custom.sendAction(custom.action, to: custom.target)
        try await act("custom\(index - 1)", "선택한 사용자 동작 실행", counter: index == 1 ? "customA" : "customB")
    }
    try await refresh(); try select("text")
    let draft = descendants(browser).compactMap { $0 as? NSTextField }.first { $0.identifier?.rawValue == "axValueDraft" }!
    guard draft.stringValue == "initial" else { throw ToolError("Unexpected STRING expected value") }
    draft.stringValue = "lcd edited"
    try await act("setString", "값 적용", text: "lcd edited")
    try await act("restoreString", "이 변경 복원", text: "initial")
    try await refresh()
    for name in ["secure", "disabled"] {
        try select(name)
        guard !(try button("값 적용")).isEnabled, !(try button("접근성 동작 실행 (AXPress)")).isEnabled else { throw ToolError("Protected/disabled capability exposed") }
    }
    try select("text")
    let count = commands.count, beforePick = try oracle()
    try button("화면에서 선택").performClick(nil)
    let point = owner.view.convert(CGPoint(x: owner.view.bounds.midX, y: owner.view.bounds.midY), to: nil)
    let event = NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [], timestamp: 0, windowNumber: owner.window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!
    owner.view.mouseDown(with: event)
    guard commands.count == count, table.selectedRow == -1, !owner.view.touching, owner.view.lastFingers == nil, beforePick.isEqual(try oracle()) else { throw ToolError("Point candidate selected/dispatched") }
    try await refresh(); try select("text")
    for (name, window) in [("lcd", owner.window), ("inspection", owner.toolbox.window!)] {
        let capture = Process(); capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        capture.arguments = ["-x", "-o", "-l", String(window.windowNumber), out.appendingPathComponent(name + ".png").path]
        try capture.run(); capture.waitUntilExit()
        guard capture.terminationStatus == 0 else { throw ToolError("LCD screenshot failed") }
    }
    owner.toolbox.invalidateInspection()
    guard !(try button("값 적용")).isEnabled, !(try button("이 변경 복원")).isEnabled else { throw ToolError("Capture invalidation retained authority") }
    try guardFocus()
    try save("lcd-result.json", ["passed": true, "commands": commands, "responses": responses, "pointCandidatesNoHID": true, "selectionNoDispatch": true, "secureDisabledAbsent": true, "captureInvalidation": true, "method": "local AppKit performClick / window-local NSEvent; no physical pointer"])
    print("PASS actual normal-factory LCD refresh, selection, press, duplicate custom handles, STRING set/restore, refusals, point candidates and invalidation")
}
