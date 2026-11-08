import AppKit

@main struct SimulatorToolbarDockingSelfcheck {
    static func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
    static func main() {
        admitNativeSelfcheck()
        _ = NSApplication.shared
        let suite = "mac-cu.toolbar-check." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        func fixture(_ id: String) -> (NSWindow,SimulatorLCDContentView,SimulatorToolbarDocking) {
            let tools = SimulatorToolboxView(deviceName: id,isWatch: false)
            tools.useInspectionPresentation()
            let content = SimulatorLCDContentView(lcd: NSView(),tools: tools,appearance: SimulatorDeviceAppearance(typeName: "iPhone"))
            content.screen = CGSize(width: 320,height: 480)
            let window = SimulatorDeviceWindow(contentRect: CGRect(x: 80,y: 100,width: 500,height: 700),styleMask: [.borderless,.resizable],backing: .buffered,defer: false)
            window.isReleasedWhenClosed = false; window.contentView = content
            content.layoutSubtreeIfNeeded()
            let docking = SimulatorToolbarDocking(ownerID: id,name: id,device: window,chrome: content.chrome,tools: tools,defaults: defaults,compactControls: true)
            return (window,content,docking)
        }
        let (owner,content,docking) = fixture("A")
        let (other,otherContent,otherDocking) = fixture("B")
        defer { docking.close(); owner.close(); otherDocking.close(); other.close() }
        assert(docking.modules.map(\.key) == ["advanced"] && docking.panels.isEmpty)
        assert(content.chrome.controls.window === owner && content.chrome.rail.window === owner)
        assert(!content.chrome.usesFloatingModules,"Primary control ownership stays in the LCD window")
        let input = descendants(content.tools).compactMap { $0 as? NSTextField }.first { $0.placeholderString == "화면 요소 검색 ⏎" }!
        input.stringValue = "preserved draft"
        let target = input.target as AnyObject?, action = input.action
        var cleanup = 0; docking.onInputCleanup = { cleanup += 1 }
        docking.setAdvancedVisible(true); docking.detach("advanced")
        let panel = docking.panels["advanced"]!
        assert(input.window === panel && input.stringValue == "preserved draft")
        assert(input.target as AnyObject? === target && input.action == action)
        let frame = content.tools.frame
        content.frame.size = CGSize(width: 600,height: 650); content.layoutSubtreeIfNeeded()
        assert(content.tools.frame == frame,"LCD layout cannot overwrite detached inspection")
        assert(content.chrome.controls.window === owner && otherContent.chrome.controls.window === other)
        assert(otherDocking.panels.isEmpty)
        let oldFrame = panel.frame
        owner.setFrameOrigin(CGPoint(x: 120,y: 80)); docking.deviceDidMove()
        assert(panel.frame == oldFrame)
        docking.attach("advanced")
        assert(docking.panels.isEmpty && input.window === docking.toolbar && input.stringValue == "preserved draft")
        docking.detach("advanced")
        assert(!docking.windowShouldClose(docking.panels["advanced"]!) && docking.panels.isEmpty)
        docking.setFocused(true); assert(!docking.toolbar.isVisible)
        docking.setFocused(false); docking.suspend(); docking.resume()
        assert(!docking.toolbar.isVisible,"Invisible owner must not spawn inspection windows")
        docking.resetLayout(); assert(docking.panels.isEmpty && cleanup > 0)
        docking.close(); assert(!docking.toolbar.isVisible)
        let display = CGRect(x: -1600,y: 80,width: 1600,height: 900)
        assert(display.contains(simulatorRestoredPanelFrame(CGRect(x: 9000,y: -8000,width: 2200,height: 1800),screens: [display],fallback: display)))
        print("PASS inspection docking: one primary owner, reused inspector/drafts/actions, detach/rejoin, layout isolation, per-device ownership, focus/suspend/close and screen recovery. No foreground input.")
    }
}
