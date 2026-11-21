import AppKit

@main final class StatusFixture: NSObject, NSApplicationDelegate {
    let popover = NSPopover()
    var item: NSStatusItem!
    let button = NSButton(title: "Confirm fixture", target: nil, action: nil)
    static func main() {
        admitNativeSelfcheck()
        let app = NSApplication.shared
        let delegate = StatusFixture()
        app.setActivationPolicy(.accessory)
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
    func applicationDidFinishLaunching(_ note: Notification) {
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.title = "MP check"
        item.button?.setAccessibilityIdentifier("fixture.status")
        item.button?.target = self
        item.button?.action = #selector(toggle)
        let controller = NSViewController()
        controller.view = NSView(frame: NSRect(x: 0, y: 0, width: 240, height: 100))
        button.frame = NSRect(x: 30, y: 30, width: 170, height: 32)
        button.target = self
        button.action = #selector(confirm)
        button.setAccessibilityIdentifier("fixture.confirm")
        controller.view.addSubview(button)
        popover.contentViewController = controller
        popover.behavior = .transient
        let directory = URL(fileURLWithPath: ProcessInfo.processInfo.environment["MAC_CU_STATUS_CHECK"]!)
        try! String(getpid()).write(to: directory.appendingPathComponent("ready"), atomically: true, encoding: .utf8)
        Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in
            if FileManager.default.fileExists(atPath: directory.appendingPathComponent("done").path) { NSApp.terminate(nil) }
        }
    }
    @objc func toggle() {
        guard let anchor = item.button else { return }
        if popover.isShown { popover.performClose(nil); return }
        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
    }
    @objc func confirm() { button.title = "Confirmed fixture" }
}
