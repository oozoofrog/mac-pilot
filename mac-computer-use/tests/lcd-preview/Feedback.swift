import AppKit
import Darwin

/// A local note identifies the AppKit event target and its ancestors. It never
/// captures pixels, field values, clipboard contents, or events from other apps.
@MainActor final class PreviewFeedback: NSObject {
    private let destination: URL
    init(destination: URL? = nil) { self.destination = destination ?? Self.fileURL; super.init() }
    private var monitor: Any?
    private var popover: NSPopover?
    private var draft: NSTextView?
    private var context: [String: Any] = [:]
    var scenario: () -> [String: Any] = { [:] }
    var onSaved: (String) -> Void = { _ in }
    static let fileURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/LCD Design Preview/feedback.jsonl")

    func start() {
        monitor = NSEvent.addLocalMonitorForEvents(matching: .rightMouseDown) { [weak self] event in
            guard let self else { return event }
            guard let window = event.window, window !== self.popover?.contentViewController?.view.window,
                  let root = window.contentView, window.isVisible else { return event }
            let point = event.locationInWindow
            let parentPoint = root.superview?.convert(point, from: nil) ?? root.convert(point, from: nil)
            guard root.bounds.contains(root.convert(point, from: nil)) else { return event }
            let target = previewHitTarget(root: root, pointInParent: parentPoint) ?? root
            self.open(target: target, root: root, point: point, window: window)
            return nil
        }
    }
    func stop() { if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }; popover?.close() }
    private func open(target: NSView, root: NSView, point: NSPoint, window: NSWindow) {
        popover?.close()
        let chain = previewViewChain(target: target, root: root)
        let local = target.convert(point, from: nil)
        context = ["windowTitle": window.title, "windowClass": NSStringFromClass(type(of: window)), "pointInWindow": [point.x,point.y],
                   "pointInTarget": [local.x,local.y], "viewChainTargetFirst": chain,
                   "scenario": scenario()]
        let popup = NSPopover(); popup.behavior = .transient; popup.animates = false
        let controller = NSViewController(); let body = NSView(frame: NSRect(x: 0,y: 0,width: 330,height: 210))
        controller.view = body; popup.contentViewController = controller
        let label = NSTextField(wrappingLabelWithString: "개선 의견 · \(String(describing: type(of: target)))")
        label.frame = NSRect(x: 12,y: 177,width: 306,height: 24); body.addSubview(label)
        let scroll = NSScrollView(frame: NSRect(x: 12,y: 60,width: 306,height: 110))
        scroll.hasVerticalScroller = true; scroll.borderType = .bezelBorder
        let editor = NSTextView(frame: scroll.bounds); editor.isRichText = false; editor.font = .systemFont(ofSize: 13)
        editor.setAccessibilityLabel("개선 의견"); scroll.documentView = editor; body.addSubview(scroll); draft = editor
        let save = NSButton(title: "의견 저장",target: self,action: #selector(saveNote)); save.frame = NSRect(x: 218,y: 18,width: 100,height: 30); body.addSubview(save)
        let hint = NSTextField(labelWithString: "대상 뷰와 의견을 로컬에 저장")
        hint.textColor = .secondaryLabelColor; hint.font = .systemFont(ofSize: 11); hint.frame = NSRect(x: 14,y: 22,width: 200,height: 20); body.addSubview(hint)
        popover = popup
        popup.show(relativeTo: NSRect(x: local.x,y: local.y,width: 1,height: 1), of: target, preferredEdge: .maxY)
        editor.window?.makeFirstResponder(editor)
    }
    @objc private func saveNote() {
        guard let text = draft?.string.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return }
        var record = context
        record["comment"] = text
        record["createdAt"] = ISO8601DateFormatter().string(from: Date())
        record["schema"] = 1
        do {
            try appendPreviewFeedback(record, to: destination)
            popover?.close(); onSaved(destination.path)
        } catch {
            let alert = NSAlert(error: error); alert.messageText = "의견을 저장하지 못했습니다"; alert.runModal()
        }
    }
}
