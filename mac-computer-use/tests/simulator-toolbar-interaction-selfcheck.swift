import AppKit

private final class ToolbarFixtureLCD: NSView {
    var events = 0
    override var acceptsFirstResponder: Bool { true }
    override func mouseDown(with event: NSEvent) { events += 1 }
    override func keyDown(with event: NSEvent) { events += 1 }
    override func draw(_ rect: NSRect) {
        NSColor(calibratedRed: 0.12,green: 0.21,blue: 0.34,alpha: 1).setFill(); bounds.fill()
        let text = "모의 LCD\n게스트 입력 분리 검사"
        (text as NSString).draw(in: bounds.insetBy(dx: 24,dy: 100),withAttributes: [.font:NSFont.systemFont(ofSize: 22),.foregroundColor:NSColor.white])
    }
}
@main struct SimulatorToolbarInteractionSelfcheck {
    static func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
    @MainActor static func pause() async { try? await Task.sleep(nanoseconds: 100_000_000) }
    @MainActor static func run() async {
        let session = CGSessionCopyCurrentDictionary() as? [String:Any] ?? [:]
        guard session["CGSSessionScreenIsLocked"] as? Bool != true,CGDisplayIsAsleep(CGMainDisplayID()) == 0 else { exit(2) }
        let previous = NSWorkspace.shared.frontmostApplication
        defer { previous?.activate(options: []) }
        let lcd = ToolbarFixtureLCD()
        let tools = SimulatorToolboxView(deviceName: "Toolbar fixture",isWatch: false)
        let content = SimulatorLCDContentView(lcd: lcd,tools: tools,appearance: SimulatorDeviceAppearance(typeName: "iPhone"))
        content.screen = CGSize(width: 320,height: 520)
        let window = SimulatorDeviceWindow(contentRect: CGRect(x: 100,y: 100,width: 500,height: 760),styleMask: [.borderless,.closable,.resizable],backing: .buffered,defer: false)
        window.isReleasedWhenClosed = false; window.isOpaque = false; window.backgroundColor = .clear
        window.contentView = content; window.center(); window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        defer { content.chrome.closePopovers(); window.close() }
        await pause()
        func guardFocus() { precondition(NSApp.isActive && window.isKeyWindow,"Foreground lost; no further fixture input") }
        guardFocus()
        print("STEP visible window"); fflush(stdout)
        let chrome = content.chrome
        chrome.updateDevice(name: "Toolbar fixture",runtime: "mock iOS",connected: true,foldable: true,isWatch: false,rotation: "rot0")
        chrome.updateAngle(90)
        content.needsLayout = true; content.layoutSubtreeIfNeeded()
        let rowScroll = descendants(chrome.rail).compactMap { $0 as? NSScrollView }.first!
        precondition(rowScroll.contentView.bounds.origin.y == 0,"Horizontal task row must not retain a vertical clipping offset")
        let buttons = descendants(chrome.controls).compactMap { $0 as? NSButton }
        let fold = buttons.first { $0.title == "접기" }!
        var commands: [[String:Any]] = []
        chrome.onRun = { commands.append($0) }
        print("STEP open hinge"); fflush(stdout)
        fold.performClick(nil); await pause()
        print("STEP hinge opened"); fflush(stdout)
        let popup = chrome.angle.window!
        precondition(popup.isVisible && popup.firstResponder === chrome.angle,"Fold popover enters the single slider")
        func event(_ type: NSEvent.EventType, local: CGPoint) -> NSEvent {
            NSEvent.mouseEvent(with: type,location: chrome.angle.convert(local,to: nil),modifierFlags: [],timestamp: 0,windowNumber: popup.windowNumber,context: nil,eventNumber: 1,clickCount: 1,pressure: type == .leftMouseUp ? 0 : 1)!
        }
        for value in [0.0,90,180] {
            precondition(NSApp.isActive && popup.isVisible,"Popup lost; no further fixture input")
            let rect = chrome.angle.tickHitRect(for: value), point = CGPoint(x: rect.midX,y: rect.midY)
            print("STEP tick \(value)"); fflush(stdout)
            popup.sendEvent(event(.leftMouseDown,local: point)); popup.sendEvent(event(.leftMouseUp,local: point))
            precondition(commands.last?["degrees"] as? Double == value)
            chrome.commandFinished(action: "hinge",failed: false); chrome.updateAngle(value)
        }
        print("STEP ticks passed"); fflush(stdout)
        chrome.angle.doubleValue = 90
        popup.sendEvent(event(.leftMouseDown,local: chrome.angle.point(for: 90)))
        popup.sendEvent(event(.leftMouseDragged,local: chrome.angle.point(for: 89)))
        chrome.updateAngle(90)
        precondition(chrome.angle.doubleValue == 89,"Polling must not overwrite an active drag")
        popup.sendEvent(event(.leftMouseUp,local: chrome.angle.point(for: 89)))
        precondition(commands.last?["degrees"] as? Double == 89)
        chrome.commandFinished(action: "hinge",failed: true); chrome.updateAngle(90)
        precondition(chrome.angle.doubleValue == 89)
        let failedCount = commands.count
        let retry = NSEvent.keyEvent(with: .keyDown,location: .zero,modifierFlags: [],timestamp: 0,windowNumber: popup.windowNumber,context: nil,characters: "\r",charactersIgnoringModifiers: "\r",isARepeat: false,keyCode: 36)!
        chrome.angle.keyDown(with: retry)
        precondition(commands.count == failedCount+1 && commands.last?["degrees"] as? Double == 89)
        chrome.commandFinished(action: "hinge",failed: true)
        chrome.angle.setAccessibilityValue(NSNumber(value: 89))
        precondition(commands.count == failedCount+2 && commands.last?["degrees"] as? Double == 89)
        let escape = NSEvent.keyEvent(with: .keyDown,location: .zero,modifierFlags: [],timestamp: 0,windowNumber: popup.windowNumber,context: nil,characters: "\u{1b}",charactersIgnoringModifiers: "\u{1b}",isARepeat: false,keyCode: 53)!
        print("STEP escape"); fflush(stdout)
        popup.sendEvent(escape); print("STEP escape returned"); fflush(stdout); await pause()
        precondition(!popup.isVisible,"Escape must dismiss the transient popover")
        for _ in 0..<10 { if window.firstResponder === fold { break }; await pause() }
        precondition(window.firstResponder === fold,"Dismissal returns focus to the fold opener")
        guardFocus()
        let bottom = descendants(chrome.rail).compactMap { $0 as? NSButton }.first { $0.title == "입력⌄" }!
        print("STEP input"); fflush(stdout)
        bottom.performClick(nil); await pause()
        let inputWindow = NSApp.windows.first { $0.isVisible && $0 !== window && $0.contentView.map { descendants($0).contains { $0 is NSTextField && ($0 as? NSTextField)?.accessibilityLabel() == "기기로 보낼 글자" } } == true }!
        precondition(inputWindow.firstResponder is NSTextView,"Input popover focuses its text editor")
        chrome.closePopovers(); await pause(); guardFocus()
        for appearance in [NSAppearance.Name.aqua,.darkAqua] {
            window.appearance = NSAppearance(named: appearance); content.layoutSubtreeIfNeeded()
            precondition(content.body.layer!.backgroundColor!.alpha == 1)
        }
        print("FOCUS before fallback accepted=\(window.makeFirstResponder(bottom)) responder=\(String(describing: window.firstResponder))"); fflush(stdout)
        let original = chrome.rail.content
        chrome.rail.usesGlass = false; chrome.rail.layoutSubtreeIfNeeded()
        print("FOCUS after fallback responder=\(String(describing: window.firstResponder)) bottom=\(bottom)"); fflush(stdout)
        precondition(chrome.rail.content === original && window.firstResponder === bottom,"Solid fallback retains controls/focus")
        chrome.rail.usesGlass = true; chrome.rail.layoutSubtreeIfNeeded()
        precondition(window.firstResponder === bottom)
        precondition(lcd.events == 0,"All toolbar interactions stay outside guest input")
        lcd.needsDisplay = true; lcd.displayIfNeeded()
        for _ in 0..<10 { await pause() }
        if let path = ProcessInfo.processInfo.environment["MAC_CU_TOOLBAR_CHECK_OUTPUT"] {
            let capture = Process(); capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            capture.arguments = ["-x","-o","-l",String(window.windowNumber),path]
            try? capture.run(); capture.waitUntilExit()
        }
        print("PASS rendered mock LCD: exact tick AppKit hits, free89 drag/readback protection, failed draft, popover keyboard entry/Escape/focus return, input editor, light/dark opaque content, solid-fallback control/focus retention, zero guest input. Physical pointer/VoiceOver unverified.")
    }
    static func main() {
        admitNativeSelfcheck(); let app = NSApplication.shared; app.setActivationPolicy(.accessory)
        Task { @MainActor in await run(); exit(0) }; app.run()
    }
}
