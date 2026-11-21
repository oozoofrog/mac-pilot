import AppKit

@main final class StatusFixture: NSObject, NSApplicationDelegate {
    let popover = NSPopover()
    var item: NSStatusItem!
    let button = NSButton(title: "Confirm fixture", target: nil, action: nil)
    private var form: NSWindow?
    private var sheet: NSWindow?
    private var sibling: NSWindow?
    private var clicks = 0
    private var foregroundClicks = 0

    private func showForm() {
        let window = NSWindow(contentRect: NSRect(x: 120, y: 180, width: 340, height: 230),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Desktop act check"
        window.isReleasedWhenClosed = false
        for (index, id) in ["fixture.always", "fixture.foreground"].enumerated() {
            let control = NSButton(title: id + " 0", target: self, action: #selector(increment(_:)))
            control.setAccessibilityIdentifier(id)
            control.frame = NSRect(x: 24, y: 18 + 54 * index, width: 250, height: 38)
            window.contentView?.addSubview(control)
        }
        let show = NSButton(title: "Show form sheet", target: self, action: #selector(showSheet))
        show.setAccessibilityIdentifier("fixture.showSheet")
        show.frame = NSRect(x: 24, y: 130, width: 250, height: 36)
        window.contentView?.addSubview(show)
        form = window
        window.orderBack(nil)
    }

    @objc private func showSheet() {
        guard let form, sheet == nil else { return }
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 280, height: 86),
                            styleMask: [.titled], backing: .buffered, defer: false)
        panel.title = "Fixture detail"
        let close = NSButton(title: "Finish detail", target: self, action: #selector(closeSheet))
        close.setAccessibilityIdentifier("fixture.closeSheet")
        close.frame = NSRect(x: 60, y: 22, width: 160, height: 36)
        panel.contentView?.addSubview(close)
        sheet = panel
        form.beginSheet(panel) { _ in self.sheet = nil }
    }

    @objc private func closeSheet() {
        if let sheet { form?.endSheet(sheet) }
    }

    private func selectSibling() {
        let window = NSWindow(contentRect: NSRect(x: 490, y: 180, width: 230, height: 140),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.title = "User-selected sibling"
        window.isReleasedWhenClosed = false
        sibling = window
        window.makeKeyAndOrderFront(nil)
    }

    @objc private func increment(_ sender: NSButton) {
        if sender.accessibilityIdentifier() == "fixture.always" {
            clicks += 1
            sender.title = "fixture.always " + String(clicks)
        } else if NSApp.isActive {
            foregroundClicks += 1
            sender.title = "fixture.foreground " + String(foregroundClicks)
        }
    }

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
            if self.form == nil && FileManager.default.fileExists(atPath: directory.appendingPathComponent("form").path) {
                self.showForm()
            }
            if self.sibling == nil && NSApp.isActive && FileManager.default.fileExists(atPath: directory.appendingPathComponent("sibling").path) {
                self.selectSibling()
            }
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
