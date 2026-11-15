import AppKit
import ObjectiveC

// Test-only observation. No backend calls, injection, capture, or global events.
private func trace(_ label: String, _ window: NSWindow? = nil) {
    print("TRACE \(Date().timeIntervalSince1970) \(label) window=\(window?.title ?? "-") active=\(NSApp.isActive) key=\(NSApp.keyWindow?.title ?? "-") main=\(NSApp.mainWindow?.title ?? "-") stack=\(Thread.callStackSymbols.joined(separator: " | "))")
    fflush(stdout)
}
extension NSWindow {
    @objc dynamic func diagnosticMakeKey() { trace("makeKey before", self); diagnosticMakeKey(); trace("makeKey after", self) }
}
func runInspectorHostCheck() -> Never {
    NSApplication.shared.setActivationPolicy(.accessory)
    method_exchangeImplementations(class_getInstanceMethod(NSWindow.self, #selector(NSWindow.makeKey))!, class_getInstanceMethod(NSWindow.self, #selector(NSWindow.diagnosticMakeKey))!)
    var observers: [NSObjectProtocol] = []
    for name in [NSApplication.didBecomeActiveNotification, NSApplication.willBecomeActiveNotification, NSApplication.didResignActiveNotification, NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification, NSWindow.didBecomeMainNotification, NSWindow.didResignMainNotification] {
        observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { n in trace(n.name.rawValue, n.object as? NSWindow) })
    }
    Task { @MainActor in
        do { try await hostWorkflow(); exit(0) }
        catch { fputs("FAIL host \(error)\n", stderr); exit(1) }
    }
    NSApp.run(); exit(1)
}
@MainActor private func hostWorkflow() async throws {
    let session = CGSessionCopyCurrentDictionary() as? [String: Any]
    guard session?["CGSSessionScreenIsLocked"] as? Bool != true, session?["kCGSSessionOnConsoleKey"] as? Bool == true, CGDisplayIsAsleep(CGMainDisplayID()) == 0 else { throw ToolError("locked/asleep") }
    let previous = NSWorkspace.shared.frontmostApplication
    let events: [CGEventType] = [.leftMouseDown,.leftMouseUp,.rightMouseDown,.rightMouseUp,.otherMouseDown,.otherMouseUp,.mouseMoved,.leftMouseDragged,.rightMouseDragged,.otherMouseDragged,.keyDown,.keyUp,.flagsChanged,.scrollWheel]
    func counts() -> [UInt32] { events.map { CGEventSource.counterForEventType(.combinedSessionState,eventType:$0) } }
    let initial = counts(), end = Date().addingTimeInterval(20)
    func guardState(_ admission: Bool = false) throws {
        let front = NSWorkspace.shared.frontmostApplication?.processIdentifier
        guard counts() == initial, Date() < end, NSApp.isActive || (admission && (front == previous?.processIdentifier || front == ProcessInfo.processInfo.processIdentifier)) else { throw ToolError("input/focus/deadline active=\(NSApp.isActive) front=\(String(describing:front)) previous=\(String(describing:previous?.processIdentifier)) self=\(ProcessInfo.processInfo.processIdentifier) inputEqual=\(counts() == initial) beforeEnd=\(Date() < end)") }
    }
    func pause() async throws { try guardState(true); try await Task.sleep(nanoseconds: 20_000_000) }
    let domain = Bundle.main.bundleIdentifier!, defaults = UserDefaults.standard.persistentDomain(forName: Bundle.main.bundleIdentifier!) ?? [:]
    // Inventory and framebuffer read only; never install/launch/attach a guest.
    let id = "64A62D96-12FE-4D9C-81AE-ED9C3A2174F0"
    let device = try bootedDevice(id)
    let lcd = SimulatorWindow(device: device, active: try activeScreen(of: device)); simulatorWindows[id] = lcd
    defer {
        let restore = NSApp.isActive && counts() == initial
        lcd.window.close(); simulatorWindows.removeValue(forKey: id)
        UserDefaults.standard.setPersistentDomain(defaults, forName: domain); UserDefaults.standard.synchronize()
        if restore { previous?.activate(options: []) }
    }
    trace("before bring mini=\(lcd.window.isMiniaturized)", lcd.window)
    bringSimulatorWindowToFront(lcd)
    if !lcd.content.toolsVisible { lcd.toggleToolbox() }
    while !NSApp.isActive || !lcd.window.isKeyWindow { try await pause() }
    func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
    let button = descendants(lcd.toolbox).compactMap { $0 as? NSButton }.first { $0.title == "3D 뷰 검사…" }!
    for phase in ["initial", "stable"] {
        try guardState(); trace("dispatch \(phase)")
        button.sendAction(button.action, to: button.target)
        let c = NSApp.windows.compactMap { $0.windowController as? SimulatorInspectorWindowController }.first { !$0.isClosed }!
        for _ in 0..<25 { try await pause() }
        trace("result \(phase) inspectorKey=\(c.window!.isKeyWindow)")
        guard c.window!.isKeyWindow else { throw ToolError("inspector focus stolen \(phase)") }
        guard c.model.snapshot == nil, !c.model.loading else { throw ToolError("unexpected backend") }
        c.close()
        for _ in 0..<25 { try await pause() }
    }
    print("PASS host diagnostic completed without capture")
}
