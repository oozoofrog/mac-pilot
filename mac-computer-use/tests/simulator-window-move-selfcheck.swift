import AppKit

private final class MovementLCD: NSView {
    var inputEvents = 0
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { inputEvents += 1 }
    override func mouseDragged(with event: NSEvent) { inputEvents += 1 }
    override func mouseUp(with event: NSEvent) { inputEvents += 1 }
}

@main struct SimulatorWindowMoveSelfcheck {
    @MainActor static func run() async {
        let session = CGSessionCopyCurrentDictionary() as? [String: Any] ?? [:]
        guard session["CGSSessionScreenIsLocked"] as? Bool != true,
              CGDisplayIsAsleep(CGMainDisplayID()) == 0, CGDisplayIsActive(CGMainDisplayID()) != 0 else {
            fputs("ENVIRONMENT: unlocked active desktop required.\n", stderr); exit(2)
        }
        let previous = NSWorkspace.shared.frontmostApplication
        defer { previous?.activate(options: []) }
        let lcd = MovementLCD(frame: CGRect(x: 0, y: 0, width: 320, height: 480))
        let tools = SimulatorToolboxView(deviceName: "Move fixture", isWatch: false)
        let content = SimulatorLCDContentView(lcd: lcd, tools: tools, appearance: SimulatorDeviceAppearance(typeName: "iPhone"))
        content.screen = CGSize(width: 320, height: 480); content.externalToolbar = false
        let window = SimulatorDeviceWindow(contentRect: CGRect(x: 0, y: 0, width: 600, height: 600),
            styleMask: [.borderless, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = content
        window.center(); window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        defer { content.chrome.grip.cancelDrag(); window.close() }
        for _ in 0..<100 {
            if NSApp.isActive && window.isKeyWindow { break }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        content.needsLayout = true; content.layoutSubtreeIfNeeded()
        let grip = content.chrome.grip
        var starts = 0, ends = 0
        grip.onManipulate = { starts += 1 }
        grip.onEndManipulate = { ends += 1 }
        let initial = window.frame
        func event(_ type: NSEvent.EventType, screen: CGPoint) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: window.convertPoint(fromScreen: screen), modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, eventNumber: 1, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1)!
        }
        func send(_ type: NSEvent.EventType, screen: CGPoint) {
            guard NSApp.isActive && window.isKeyWindow else { fatalError("Foreground lost; no further mouse input sent") }
            window.sendEvent(event(type, screen: screen))
        }
        func near(_ a: CGPoint, _ b: CGPoint) -> Bool { abs(a.x - b.x) < 0.01 && abs(a.y - b.y) < 0.01 }
        func point(_ x: CGFloat) -> CGPoint { window.convertPoint(toScreen: grip.convert(CGPoint(x: x, y: grip.bounds.midY), to: nil)) }
        func drag(_ x: CGFloat) {
            let origin = window.frame.origin, anchor = point(x)
            send(.leftMouseDown, screen: anchor)
            assert(window.interactiveMove)
            send(.leftMouseDragged, screen: CGPoint(x: anchor.x + 64, y: anchor.y + 32))
            assert(near(window.frame.origin, CGPoint(x: origin.x + 64, y: origin.y + 32)), "The real borderless window must move from event coordinates")
            send(.leftMouseDragged, screen: CGPoint(x: anchor.x + 20, y: anchor.y - 45))
            assert(near(window.frame.origin, CGPoint(x: origin.x + 20, y: origin.y - 45)), "Repeated drags use the initial screen anchor, even after the window moves")
            send(.leftMouseUp, screen: CGPoint(x: anchor.x + 20, y: anchor.y - 45))
            assert(!window.interactiveMove)
        }
        drag(24) // Visible movement caption.
        drag(max(70, grip.bounds.midX)) // Device/status label.
        assert(starts == 2 && ends == 2 && lcd.inputEvents == 0)
        let stopped = window.frame
        grip.mouseDragged(with: event(.leftMouseDragged, screen: CGPoint(x: stopped.midX + 100, y: stopped.midY)))
        grip.cancelDrag()
        assert(window.frame == stopped && ends == 2, "Late drag and duplicate cancellation must be inert")
        let anchor = point(24)
        send(.leftMouseDown, screen: anchor); grip.cancelDrag()
        let cancelled = window.frame
        send(.leftMouseDragged, screen: CGPoint(x: anchor.x + 80, y: anchor.y + 80))
        send(.leftMouseUp, screen: anchor)
        assert(window.frame == cancelled && starts == 3 && ends == 3)
        send(.leftMouseDown, screen: point(24))
        let parent = grip.superview!, frame = grip.frame
        grip.removeFromSuperview()
        assert(!window.interactiveMove && ends == 4, "Detaching a held grip must release its original window and drag state")
        parent.addSubview(grip); grip.frame = frame; grip.layoutSubtreeIfNeeded()
        let lcdPoint = window.convertPoint(toScreen: lcd.convert(CGPoint(x: lcd.bounds.midX, y: lcd.bounds.midY), to: nil))
        let beforeLCD = window.frame
        send(.leftMouseDown, screen: lcdPoint)
        send(.leftMouseDragged, screen: CGPoint(x: lcdPoint.x + 15, y: lcdPoint.y + 10))
        send(.leftMouseUp, screen: CGPoint(x: lcdPoint.x + 15, y: lcdPoint.y + 10))
        assert(window.frame == beforeLCD && lcd.inputEvents == 3, "LCD dragging must stay guest input rather than window movement")
        content.focused = true; content.needsLayout = true; content.layoutSubtreeIfNeeded()
        drag(24)
        assert(starts == 5 && ends == 5 && lcd.inputEvents == 3, "Movement remains available in focus mode without LCD input")
        content.focused = false; content.externalToolbar = true; content.needsLayout = true; content.layoutSubtreeIfNeeded()
        drag(24)
        assert(starts == 6 && ends == 6 && lcd.inputEvents == 3, "External toolbar path retains window movement")
        window.setFrame(initial, display: true)
        print("PASS actual borderless window movement: caption/name hit delivery, repeated screen-coordinate drag/readback, mouse-up, cancellation/late events, detachment, focus mode and independent LCD input. AppKit events were local; no global pointer or simulator HID was sent.")
    }
    static func main() {
        admitNativeSelfcheck()
        let app = NSApplication.shared; app.setActivationPolicy(.accessory)
        Task { @MainActor in await run(); exit(0) }
        app.run()
    }
}
