import AppKit

@MainActor private func toolbarLivePause(_ seconds: Double = 0.1) async { try? await Task.sleep(nanoseconds: UInt64(seconds*1_000_000_000)) }
private func toolbarBackground<T>(_ work: @escaping () throws -> T) async throws -> T {
    try await withCheckedThrowingContinuation { continuation in handleQueue.async { continuation.resume(with: Result(catching: work)) } }
}
private struct ToolbarLiveFailure: Error { let message: String }
@MainActor private func toolbarRequire(_ value: Bool,_ message: String) throws {
    guard value else { throw ToolbarLiveFailure(message: message) }; print("PASS " + message); fflush(stdout)
}
@MainActor private func toolbarLiveRun(_ id: String,output: URL) async throws {
    let device = try await toolbarBackground { try bootedDevice(id) }
    let active = try await toolbarBackground { try activeScreen(of: device) }
    try toolbarRequire(active?.foldable != true,"Owned standard device only; no foldable device is operated")
    let previous = NSWorkspace.shared.frontmostApplication
    let toolboxPreference = "simulatorToolbox.\(id)"
    let originalPreference = UserDefaults.standard.object(forKey: toolboxPreference)
    let open = SimulatorWindow(device: device,active: active); simulatorWindows[id] = open
    defer {
        open.window.close()
        if let originalPreference { UserDefaults.standard.set(originalPreference, forKey: toolboxPreference) } else { UserDefaults.standard.removeObject(forKey: toolboxPreference) }
        previous?.activate(options: [])
    }
    bringSimulatorWindowToFront(open); await toolbarLivePause(0.5)
    func focused() throws { try toolbarRequire(NSApp.isActive && open.window.isKeyWindow,"Foreground guard before device input") }
    try focused()
    try toolbarRequire(open.content.chrome.controls.window === open.window && open.content.chrome.rail.window === open.window,"Production initialization retains both toolbars in LCD owner")
    try toolbarRequire(open.toolbarDocking?.toolbar.isVisible == false,"Inspection starts hidden")
    func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
    let bottom = descendants(open.content.chrome.rail).compactMap { $0 as? NSButton }
    for title in ["입력⌄","위치⌄"] {
        try focused(); bottom.first { $0.title == title }!.performClick(nil); await toolbarLivePause(0.6)
        let popup = NSApp.windows.first { $0.isVisible && $0 !== open.window && $0.isKeyWindow }
        try toolbarRequire(popup != nil,"Production delegate retains editable " + title + " popover")
        let key = NSEvent.keyEvent(with: .keyDown,location: .zero,modifierFlags: [],timestamp: 0,windowNumber: popup!.windowNumber,context: nil,characters: "\u{1b}",charactersIgnoringModifiers: "\u{1b}",isARepeat: false,keyCode: 53)!
        popup!.sendEvent(key); await toolbarLivePause(0.6)
        try toolbarRequire(open.window.isKeyWindow,"Popover Escape restores LCD owner")
    }
    func capture(_ window: NSWindow, _ name: String) throws {
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = ["-x", "-o", "-l", String(window.windowNumber), output.appendingPathComponent(name + ".png").path]
        try process.run(); process.waitUntilExit()
        try toolbarRequire(process.terminationStatus == 0, "Production UI captured: " + name)
    }
    func popup(_ name: String) -> NSPopover { Mirror(reflecting: open.content.chrome).children.first { $0.label == name }!.value as! NSPopover }
    try focused(); bottom.first { $0.title == "환경⌄" }!.performClick(nil)
    for _ in 0..<500 {
        await toolbarLivePause(0.02)
        if descendants(popup("environmentPopover").contentViewController!.view).compactMap({ $0 as? NSButton }).first(where: { $0.title == "다시 확인" })?.isEnabled == true { break }
    }
    let environment = popup("environmentPopover")
    try toolbarRequire(environment.isShown, "Environment opens production controls")
    let environmentRoot = environment.contentViewController!.view
    let settingText = descendants(environmentRoot).compactMap { $0 as? NSTextField }.map(\.stringValue).joined(separator: " | ")
    try toolbarRequire(!settingText.contains("읽는 중"), "Environment read settled without claiming unavailable values")
    print("ENVIRONMENT_STATE " + settingText); fflush(stdout)
    try capture(environmentRoot.window!, "environment")
    // Native action routing, not physical pointer input: switching owners must close the old surface.
    try toolbarRequire(NSApp.isActive && environmentRoot.window!.isKeyWindow, "Foreground guard before switching tools")
    bottom.first { $0.title == "입력⌄" }!.performClick(nil); await toolbarLivePause(0.6)
    print("SWITCH_STATE input=\(popup("input").isShown) environment=\(environment.isShown)"); fflush(stdout)
    let input = popup("input")
    try toolbarRequire(input.isShown && !environment.isShown, "One action switches from environment to input")
    let root = input.contentViewController!.view
    let field = descendants(root).compactMap { $0 as? NSTextField }.first { $0.accessibilityLabel() == "기기로 보낼 글자" }!
    field.stringValue = "unsent draft"
    let keyboard = descendants(root).compactMap { $0 as? NSButton }.first { $0.title.contains("Mac 키보드") }!
    let originalKeyboard = open.view.keyboardEnabled
    try toolbarRequire(NSApp.isActive && root.window!.isKeyWindow, "Foreground guard before host checkbox")
    keyboard.performClick(nil)
    try toolbarRequire(open.window.firstResponder !== open.view && root.window!.isKeyWindow, "Keyboard toggle keeps focus in host input")
    keyboard.performClick(nil)
    try toolbarRequire(open.view.keyboardEnabled == originalKeyboard, "Keyboard preference restored")
    try capture(root.window!, "input")
    let escape = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: root.window!.windowNumber, context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53)!
    NSApp.sendEvent(escape); await toolbarLivePause(0.6)
    try toolbarRequire(!input.isShown && open.window.isKeyWindow && field.stringValue == "unsent draft", "Escape preserves unsent draft and returns focus")
    try focused(); bottom.first { $0.title == "보기⌄" }!.performClick(nil); await toolbarLivePause(0.6)
    let viewSettings = popup("viewPopover")
    try toolbarRequire(viewSettings.isShown, "View opens state controls")
    try capture(viewSettings.contentViewController!.view.window!, "view")
    open.content.chrome.closePopovers(); open.window.makeKey(); await toolbarLivePause(0.1)
    try focused(); bottom.first { $0.title == "검사⌄" }!.performClick(nil); await toolbarLivePause(0.6)
    try toolbarRequire(open.toolbarDocking?.toolbar.isVisible == true && !open.content.chrome.hasOpenPopover, "Inspection opens existing workspace directly")
    let tools = open.toolbox
    for _ in 0..<400 { await toolbarLivePause(0.025); if !tools.busy && !tools.manualPending { break } }
    try toolbarRequire(descendants(tools).contains { $0 is SimulatorElementBrowser && !$0.isHiddenOrHasHiddenAncestor }, "Inspection starts with a zero-input element browser")
    let advanced = descendants(tools).compactMap { $0 as? NSButton }.first { $0.title == "전문 도구…" }!
    advanced.performClick(nil)
    let fields = descendants(tools).compactMap { $0 as? NSTextField }.filter { $0.isEditable && !$0.isHiddenOrHasHiddenAncestor }
    try toolbarRequire(fields.count == 5, "Production inspection retains all five labeled fields")
    try toolbarRequire(NSApp.isActive && tools.window!.isKeyWindow, "Foreground guard before guide capture")
    let captureControl = descendants(tools).compactMap { $0 as? NSPopUpButton }.first { !$0.isHiddenOrHasHiddenAncestor && $0.itemTitles.contains("가이드 캡처") }!
    captureControl.selectItem(at: 2); captureControl.sendAction(captureControl.action!, to: captureControl.target)
    for _ in 0..<400 { await toolbarLivePause(0.025); if !tools.busy && !tools.manualPending { break } }
    try toolbarRequire(!tools.busy && !tools.manualPending, "Guide capture settled")
    tools.selectResults(true); tools.focusInspection(); await toolbarLivePause(0.6)
    try toolbarRequire(descendants(tools).contains { $0 is NSImageView }, "Actual capture image available in persistent result")
    try capture(tools.window!, "inspection-result")
    tools.selectResults(false); await toolbarLivePause(0.1); try capture(tools.window!, "inspection")
    open.toggleToolbox(); open.window.makeKey(); await toolbarLivePause(0.6)
    var emitted = 0
    let nativeRun = open.content.chrome.onRun
    open.content.chrome.onRun = { arguments in emitted += 1; print("DIRECT_ACTION \(arguments)"); fflush(stdout); nativeRun(arguments) }
    let rotation = descendants(open.content.chrome.controls).compactMap { $0 as? NSButton }.first { $0.title == "회전" }!
    for expected in ["rot90","rot180","rot270","rot0"] {
        if ProcessInfo.processInfo.environment["LCD_CHECK_SKIP_ROTATE"] == "1" { break }
        try focused(); let before = emitted; rotation.performClick(nil)
        rotation.performClick(nil)
        for _ in 0..<150 {
            await toolbarLivePause()
            if !open.toolbox.busy && !open.toolbox.manualPending && open.view.rotation == expected && rotation.isEnabled { break }
        }
        try toolbarRequire(emitted == before+1,"Direct rotate emits one command, duplicate is gated")
        if open.view.rotation != expected {
            let feedback = descendants(open.content.chrome.rail).compactMap { $0 as? NSTextField }.first { $0.accessibilityLabel() == "시뮬레이터 조작 결과" }!.stringValue
            print("ROTATION_READBACK actual=\(open.view.rotation) expected=\(expected) feedback=\(feedback)"); fflush(stdout)
            try toolbarRequire(feedback.contains("회전 요청 전달") && !feedback.contains("화면 회전 확인") && !feedback.contains("실패"),"Unchanged rotation reports delivery without claiming screen confirmation")
            print("LIMIT: guest orientation did not change; four live clockwise poses remain unverified.")
            break
        }
        try toolbarRequire(rotation.isEnabled,"Clockwise direct action actual readback " + expected)
    }
    open.content.layoutSubtreeIfNeeded()
    for scroll in descendants(open.content.chrome.rail).compactMap({ $0 as? NSScrollView }) {
        try toolbarRequire((scroll.documentView?.frame.height ?? 0) <= scroll.contentSize.height+0.5,"Actual task row fits the final legacy scroller height")
        print("ROW_GEOMETRY scroll=\(scroll.frame) clip=\(scroll.contentView.frame) clipBounds=\(scroll.contentView.bounds) contentSize=\(scroll.contentSize) document=\(String(describing:scroll.documentView?.frame)) bounds=\(String(describing:scroll.documentView?.bounds)) visible=\(scroll.documentVisibleRect)")
        for button in scroll.documentView?.subviews.compactMap({ $0 as? NSButton }) ?? [] { print("ROW_BUTTON \(button.title) \(button.frame)") }
    }
    let file = output.appendingPathComponent("toolbar-device.png")
    let capture = Process(); capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
    capture.arguments = ["-x","-o","-l",String(open.window.windowNumber),file.path]
    try capture.run(); capture.waitUntilExit()
    print("LIVE_UI " + file.path)
    try toolbarRequire(open.content.body.layer!.backgroundColor!.alpha == 1,"Real LCD remains opaque")
}
func runSimulatorToolbarLiveCheck() -> Never {
    let env = ProcessInfo.processInfo.environment
    guard let id = env["LCD_CHECK_UDID"], UUID(uuidString: id) != nil,let path = env["LCD_CHECK_OUTPUT"] else { exit(64) }
    guard let session = CGSessionCopyCurrentDictionary() as? [String: Any],
          session["CGSSessionScreenIsLocked"] as? Bool != true, CGDisplayIsAsleep(CGMainDisplayID()) == 0 else { exit(2) }
    let app = NSApplication.shared; app.setActivationPolicy(.accessory)
    Task { @MainActor in
        do { try await toolbarLiveRun(id,output: URL(fileURLWithPath: path)); exit(0) }
        catch { print("FAIL toolbar production check: \(error)"); fflush(stdout); exit(1) }
    }
    app.run(); exit(1)
}
