import AppKit

final class FixtureLCD: NSView {
    var rotation = 0 { didSet { needsDisplay = true } }
    var device = 0 { didSet { needsDisplay = true } }
    override func draw(_ dirtyRect: NSRect) {
        NSColor(calibratedRed: 0.08, green: 0.16, blue: 0.25, alpha: 1).setFill(); bounds.fill()
        let inset = bounds.insetBy(dx: bounds.width * 0.08, dy: bounds.height * 0.12)
        NSColor(calibratedRed: 0.13, green: 0.32, blue: 0.44, alpha: 1).setFill()
        NSBezierPath(roundedRect: inset, xRadius: 24, yRadius: 24).fill()
        let title = device == 0 ? "9:41" : device == 1 ? "Duo · Cover" : "Duo · Inner"
        (title as NSString).draw(at: NSPoint(x: inset.minX + 18, y: inset.maxY - 65), withAttributes: [.font: NSFont.systemFont(ofSize: 25, weight: .semibold), .foregroundColor: NSColor.white])
        ("Synthetic display  ·  \(rotation)°" as NSString).draw(at: NSPoint(x: inset.minX + 18, y: inset.maxY - 93), withAttributes: [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.white.withAlphaComponent(0.8)])
        for i in 0..<3 {
            NSColor.white.withAlphaComponent(0.13).setFill()
            NSBezierPath(roundedRect: NSRect(x: inset.minX + 18, y: inset.maxY - 155 - CGFloat(i)*62, width: max(20,inset.width - 36), height: 46), xRadius: 12, yRadius: 12).fill()
        }
    }
}

@MainActor final class PreviewController: NSObject, NSWindowDelegate {
    let lcd = FixtureLCD()
    let tools = SimulatorToolboxView(deviceName: "Fixture", isWatch: false)
    var content: SimulatorLCDContentView!
    var window: NSWindow!
    var panel: NSWindow!
    var device = 0
    var mock = PreviewMockState()
    var recording = false
    let status = NSTextField(labelWithString: "Ready")
    let feedback: PreviewFeedback
    init(feedbackDestination: URL? = nil) {
        feedback = PreviewFeedback(destination: feedbackDestination ?? PreviewFeedback.fileURL)
        super.init()
    }
    func start() {
        content = SimulatorLCDContentView(lcd: lcd, tools: tools, appearance: SimulatorDeviceAppearance(typeName: "iPhone"))
        window = SimulatorDeviceWindow(contentRect: NSRect(x: 100,y: 100,width: 500,height: 720), styleMask: [.borderless,.closable,.resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.isOpaque = false; window.backgroundColor = .clear
        window.title = "LCD Design Preview · Mock"; window.contentView = content; window.delegate = self; window.center()
        let chrome = content.chrome
        chrome.onRun = { [weak self] args in self?.run(args) }
        chrome.onHost = { [weak self] key, value in self?.run(["action":key, "value":value]) }
        chrome.onRecord = { [weak self] in guard let self else { return }; self.recording.toggle(); self.content.chrome.updateRecording(self.recording,caption: self.recording ? "중지" : "녹화"); self.run(["action":"record"]) }
        chrome.onTouches = { [weak self] in guard let self else { return }; self.content.chrome.touchesVisible.toggle(); self.content.chrome.updateControls(); self.run(["action":"touch"]) }
        chrome.onKeyboard = { [weak self] in self?.run(["action":"keyboard"]) }
        chrome.onTools = { [weak self] in guard let self else { return }; self.content.animateTools(!self.content.toolsVisible, animated: false) {} }
        chrome.onManage = { [weak self] in self?.run(["action":"manage"]) }
        chrome.onResponse = { [weak self] _ in self?.run(["action":"response"]) }
        chrome.onMenu = { let menu = NSMenu(title: "Mock"); menu.addItem(withTitle: "Mock preview", action: nil, keyEquivalent: ""); return menu }
        tools.onRun = { [weak self] args in self?.run(args) }
        feedback.scenario = { [weak self] in guard let self else { return [:] }; return ["device": ["phone", "duo-cover", "duo-inner"][self.device], "rotation": self.mock.rotation, "foldAngle": self.mock.confirmedAngle, "outcome": ["success", "pending", "failure", "offline"][self.mock.outcome.rawValue], "appearance": self.window.appearance?.name.rawValue ?? "system", "glass": self.content.chrome.rail.usesGlass, "windowSize": [self.window.frame.width,self.window.frame.height]] }
        feedback.onSaved = { [weak self] path in self?.status.stringValue = "의견 저장됨"; print("Feedback saved: \(path)"); fflush(stdout) }
        makePanel(); refresh(); feedback.start(); window.makeKeyAndOrderFront(nil); panel.orderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }
    func makePanel() {
        panel = NSPanel(contentRect: NSRect(x: 0,y: 0,width: 290,height: 248),styleMask: [.titled,.closable],backing: .buffered,defer: false)
        panel.title = "LCD Design Preview · Mock"; panel.isReleasedWhenClosed = false; panel.delegate = self
        let root = NSView(frame: NSRect(x: 0,y: 0,width: 290,height: 248)); panel.contentView = root
        func popup(_ label: String,_ options: [String],_ y: CGFloat,_ action: Selector) {
            let caption = NSTextField(labelWithString: label); caption.frame = NSRect(x: 16,y: y+4,width: 88,height: 20); root.addSubview(caption)
            let field = NSPopUpButton(frame: NSRect(x: 105,y: y,width: 166,height: 26)); field.addItems(withTitles: options); field.target = self; field.action = action; root.addSubview(field)
        }
        popup("Device",["Phone","Duo cover","Duo inner"],202,#selector(selectDevice(_:)))
        popup("Appearance",["System","Light","Dark","Opaque fallback"],166,#selector(selectAppearance(_:)))
        popup("Window",["Regular","Narrow","Wide"],130,#selector(selectSize(_:)))
        popup("Outcome",["Success","Pending","Failure","Offline"],94,#selector(selectOutcome(_:)))
        let rotate = NSButton(title: "Rotate fixture",target: self,action: #selector(rotateFixture)); rotate.frame = NSRect(x: 14,y: 52,width: 120,height: 28); root.addSubview(rotate)
        let fold = NSButton(title: "Fold: 90°",target: self,action: #selector(cycleFold(_:))); fold.frame = NSRect(x: 142,y: 52,width: 130,height: 28); root.addSubview(fold)
        status.frame = NSRect(x: 18,y: 16,width: 255,height: 24); status.lineBreakMode = .byTruncatingTail; root.addSubview(status)
        panel.setFrameOrigin(NSPoint(x: window.frame.maxX + 12,y: window.frame.maxY - panel.frame.height))
    }
    @objc func selectDevice(_ sender: NSPopUpButton) { device = sender.indexOfSelectedItem; lcd.device = device; refresh() }
    @objc func selectAppearance(_ sender: NSPopUpButton) {
        window.appearance = sender.indexOfSelectedItem == 1 ? NSAppearance(named: .aqua) : sender.indexOfSelectedItem == 2 ? NSAppearance(named: .darkAqua) : nil
        let glass = sender.indexOfSelectedItem != 3
        for group in [content.chrome.handle,content.chrome.controls,content.chrome.rail] { group.usesGlass = glass }
    }
    @objc func selectSize(_ sender: NSPopUpButton) { let sizes = [NSSize(width: 500,height: 720),NSSize(width: 340,height: 590),NSSize(width: 760,height: 650)]; window.setContentSize(sizes[sender.indexOfSelectedItem]) }
    @objc func selectOutcome(_ sender: NSPopUpButton) { mock.select(PreviewMockState.Outcome(rawValue: sender.indexOfSelectedItem)!); content.chrome.setBusy(false); content.chrome.rotationFailed(); refresh(); status.stringValue = sender.titleOfSelectedItem ?? "" }
    @objc func rotateFixture() { mock.rotateFixture(); lcd.rotation = mock.rotation; refresh() }
    @objc func cycleFold(_ sender: NSButton) { mock.setAngle(mock.confirmedAngle == 0 ? 90 : mock.confirmedAngle == 90 ? 180 : 0); sender.title = "Fold: \(Int(mock.confirmedAngle))°"; content.chrome.updateAngle(mock.confirmedAngle) }
    func refresh() {
        let size = device == 2 ? NSSize(width: 540,height: 720) : NSSize(width: 320,height: 600)
        content.screen = mock.rotation % 180 == 0 ? size : NSSize(width: size.height,height: size.width)
        content.chrome.updateDevice(name: device == 0 ? "Phone" : device == 1 ? "Duo cover" : "Duo inner", runtime: "Mock", connected: mock.outcome != .offline, foldable: device != 0, isWatch: false, rotation: "rot\(mock.rotation)", primaryDisplay: device != 2)
        content.chrome.updateAngle(mock.confirmedAngle); content.needsLayout = true
    }
    func run(_ args: [String:Any]) {
        let action = args["action"] as? String ?? "action"
        guard let token = mock.request() else { return }
        content.chrome.setBusy(true)
        status.stringValue = "Requested: \(action)"; content.chrome.showFeedback("요청 중 · \(action)")
        if mock.outcome == .pending { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { [weak self] in
            guard let self, let success = self.mock.finish(token, action: action, angle: args["degrees"] as? Double) else { return }
            self.content.chrome.setBusy(false)
            let failed = !success
            self.content.chrome.commandFinished(action: action,failed: failed)
            if action == "rotate" { self.content.chrome.rotationFailed(); if !failed { self.lcd.rotation = self.mock.rotation; self.refresh() } }
            if action == "hinge", !failed { self.content.chrome.updateAngle(self.mock.confirmedAngle) }
            self.status.stringValue = failed ? "Failed: \(action)" : "Confirmed: \(action)"
            self.content.chrome.showFeedback(failed ? "모의 실패 · \(action)" : "모의 확인 · \(action)",failed: failed)
        }
    }
    func windowWillClose(_ notification: Notification) { feedback.stop(); content.chrome.closePopovers(); NSApp.terminate(nil) }
}
@main struct PreviewMain {
    static func main() {
        admitNativeSelfcheck()
        let session = CGSessionCopyCurrentDictionary() as? [String:Any] ?? [:]
        guard session["CGSSessionScreenIsLocked"] as? Bool != true, CGDisplayIsAsleep(CGMainDisplayID()) == 0 else { fputs("Desktop locked or asleep\n",stderr); exit(2) }
        let app = NSApplication.shared; app.setActivationPolicy(.regular)
        let controller = PreviewController()
        controller.start()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            let visible = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] ?? []
            let owned = visible.filter { ($0[kCGWindowOwnerPID as String] as? Int32) == getpid() }
            let ids = owned.compactMap { $0[kCGWindowNumber as String] as? Int }
            guard controller.window.isVisible, controller.panel.isVisible,
                  ids.contains(controller.window.windowNumber), ids.contains(controller.panel.windowNumber) else {
                fputs("Preview windows did not become visible\n",stderr); exit(1)
            }
            print("PREVIEW_READY pid=\(getpid()) lcd=\(controller.window.windowNumber) scenarios=\(controller.panel.windowNumber) visible=true feedback=\(PreviewFeedback.fileURL.path)"); fflush(stdout)
        }
        app.run(); withExtendedLifetime(controller) {}
    }
}
