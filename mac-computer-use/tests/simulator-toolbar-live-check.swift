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
    let open = SimulatorWindow(device: device,active: active); simulatorWindows[id] = open
    defer { open.window.close() }
    bringSimulatorWindowToFront(open); await toolbarLivePause(0.5)
    func focused() throws { try toolbarRequire(NSApp.isActive && open.window.isKeyWindow,"Foreground guard before device input") }
    try focused()
    try toolbarRequire(open.content.chrome.controls.window === open.window && open.content.chrome.rail.window === open.window,"Production initialization retains both toolbars in LCD owner")
    try toolbarRequire(open.toolbarDocking?.toolbar.isVisible == false,"Inspection starts hidden")
    func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
    let bottom = descendants(open.content.chrome.rail).compactMap { $0 as? NSButton }
    for title in ["입력⌄","위치⌄"] {
        try focused(); bottom.first { $0.title == title }!.performClick(nil); await toolbarLivePause(0.3)
        let popup = NSApp.windows.first { $0.isVisible && $0 !== open.window && $0.isKeyWindow }
        try toolbarRequire(popup != nil,"Production delegate retains editable " + title + " popover")
        let key = NSEvent.keyEvent(with: .keyDown,location: .zero,modifierFlags: [],timestamp: 0,windowNumber: popup!.windowNumber,context: nil,characters: "\u{1b}",charactersIgnoringModifiers: "\u{1b}",isARepeat: false,keyCode: 53)!
        popup!.sendEvent(key); await toolbarLivePause(0.3)
        try toolbarRequire(open.window.isKeyWindow,"Popover Escape restores LCD owner")
    }
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
    let app = NSApplication.shared; app.setActivationPolicy(.accessory)
    Task { @MainActor in
        do { try await toolbarLiveRun(id,output: URL(fileURLWithPath: path)); exit(0) }
        catch { print("FAIL toolbar production check: \(error)"); fflush(stdout); exit(1) }
    }
    app.run(); exit(1)
}
