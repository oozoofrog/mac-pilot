import AppKit

/// Borderless LCDs still participate in activation, key delivery, Dock restore and window cycling.
final class SimulatorDeviceWindow: NSWindow {
    var interactiveMove = false
    override init(contentRect: NSRect, styleMask: NSWindow.StyleMask, backing: NSWindow.BackingStoreType, defer flag: Bool) {
        super.init(contentRect: contentRect, styleMask: styleMask, backing: backing, defer: flag)
        isMovable = true
        isMovableByWindowBackground = false
    }
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        // Keep interactive moves free of AppKit's borderless screen correction.
        interactiveMove ? frameRect : super.constrainFrameRect(frameRect, to: screen)
    }
}

final class SimulatorMoveGrip: NSView {
    let label = NSTextField(labelWithString: "")
    private let movement = NSTextField(labelWithString: "⠿ 이동")
    var onManipulate: () -> Void = {}
    var onEndManipulate: () -> Void = {}
    private var start: (point: CGPoint, origin: CGPoint)?
    private weak var movingWindow: NSWindow?
    private var cursorPushed = false
    override init(frame: NSRect) {
        super.init(frame: frame)
        label.font = .systemFont(ofSize: 12, weight: .semibold)
        label.lineBreakMode = .byTruncatingMiddle
        addSubview(label)
        movement.font = .systemFont(ofSize: 11, weight: .medium)
        movement.textColor = .secondaryLabelColor
        movement.setAccessibilityElement(false)
        addSubview(movement)
        toolTip = "기기 이동 · 드래그"
        setAccessibilityElement(true)
        setAccessibilityRole(.handle)
        setAccessibilityLabel("기기 이동 손잡이")
        setAccessibilityHelp("드래그로 창 이동. 기기 메뉴에서 크기와 위치를 조절할 수 있습니다.")
    }
    required init?(coder: NSCoder) { fatalError() }
    override func layout() {
        super.layout()
        movement.frame = CGRect(x: 10, y: 10, width: 44, height: max(0, bounds.height - 20))
        label.frame = CGRect(x: 60, y: 10, width: max(0, bounds.width - 70), height: max(0, bounds.height - 20))
    }
    override func hitTest(_ point: NSPoint) -> NSView? { bounds.contains(convert(point, from: superview)) ? self : nil }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        cancelDrag()
        movingWindow = window
        start = (window.convertPoint(toScreen: event.locationInWindow), window.frame.origin)
        (window as? SimulatorDeviceWindow)?.interactiveMove = true
        onManipulate()
        window.isMovable = true // Borderless windows do not inherit the titled-window default.
        window.makeKeyAndOrderFront(nil)
        guard start != nil else { return }
        NSCursor.closedHand.push()
        cursorPushed = true
    }
    override func mouseDragged(with event: NSEvent) {
        guard let window = movingWindow, window === self.window, let start else { return }
        // Use the event's screen position, not the global mouse cursor. This also
        // handles process-targeted events without depending on WindowServer tracking.
        let point = window.convertPoint(toScreen: event.locationInWindow)
        window.setFrameOrigin(CGPoint(x: start.origin.x + point.x - start.point.x,
                                      y: start.origin.y + point.y - start.point.y))
    }
    override func mouseUp(with event: NSEvent) { cancelDrag() }
    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if start != nil && newWindow !== movingWindow { cancelDrag() }
        super.viewWillMove(toWindow: newWindow)
    }
    func cancelDrag() {
        guard start != nil else { return }
        start = nil
        (movingWindow as? SimulatorDeviceWindow)?.interactiveMove = false
        movingWindow = nil
        if cursorPushed { NSCursor.pop(); cursorPushed = false }
        onEndManipulate()
    }
}

final class SimulatorResizeGrip: NSView {
    var onManipulate: () -> Void = {}
    var onEndManipulate: () -> Void = {}
    private var start: (point: CGPoint, frame: CGRect)?
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 12
        toolTip = "기기 크기 조절 · 드래그 (기기 메뉴에서도 조절 가능)"
        setAccessibilityElement(true)
        setAccessibilityRole(.handle)
        setAccessibilityLabel("기기 크기 조절")
    }
    required init?(coder: NSCoder) { fatalError() }
    override func draw(_ dirtyRect: NSRect) {
        let contrast = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
        NSColor.controlBackgroundColor.withAlphaComponent(NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency ? 1 : 0.82).setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 2), xRadius: 12, yRadius: 12).fill()
        NSColor.labelColor.setStroke()
        let path = NSBezierPath()
        path.lineWidth = contrast ? 2.5 : 2
        path.lineCapStyle = .round
        let c = CGPoint(x: bounds.midX, y: bounds.midY)
        path.move(to: CGPoint(x: c.x - 6, y: c.y - 6)); path.line(to: CGPoint(x: c.x + 6, y: c.y + 6))
        path.move(to: CGPoint(x: c.x, y: c.y + 6)); path.line(to: CGPoint(x: c.x + 6, y: c.y + 6)); path.line(to: CGPoint(x: c.x + 6, y: c.y))
        path.move(to: CGPoint(x: c.x - 6, y: c.y)); path.line(to: CGPoint(x: c.x - 6, y: c.y - 6)); path.line(to: CGPoint(x: c.x, y: c.y - 6))
        path.stroke()
    }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .crosshair) }
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        onManipulate()
        window.makeKeyAndOrderFront(nil)
        start = (NSEvent.mouseLocation, window.frame)
    }
    override func mouseDragged(with event: NSEvent) {
        guard let window, let start else { return }
        let cursor = NSEvent.mouseLocation
        let size = CGSize(width: max(window.contentMinSize.width, start.frame.width + cursor.x - start.point.x),
                          height: max(window.contentMinSize.height, start.frame.height - cursor.y + start.point.y))
        let frame = CGRect(x: start.frame.minX, y: start.frame.maxY - size.height, width: size.width, height: size.height)
        window.setFrame(simulatorConstrainedFrame(frame, to: window.screen?.visibleFrame ?? frame), display: true)
    }
    func cancelDrag() {
        guard start != nil else { return }
        start = nil
        onEndManipulate()
    }
    override func mouseUp(with event: NSEvent) { cancelDrag() }
}

/// Keyboard traversal remains in the host controls; it never reaches the guest LCD.
final class SimulatorToolbarButton: NSButton {
    override var acceptsFirstResponder: Bool { isEnabled }
    override func keyDown(with event: NSEvent) {
        if [123,124,125,126,115,119].contains(event.keyCode), let parent = superview {
            let peers = parent.subviews.compactMap { $0 as? NSButton }.filter { !$0.isHidden && $0.isEnabled }
            guard let index = peers.firstIndex(of: self), !peers.isEmpty else { return }
            let next = event.keyCode == 115 ? 0 : event.keyCode == 119 ? peers.count - 1
                : (index + ([124,125].contains(event.keyCode) ? 1 : peers.count - 1)) % peers.count
            peers[next].scrollToVisible(peers[next].bounds)
            window?.makeFirstResponder(peers[next]); return
        }
        if event.keyCode == 36 { performClick(nil); return }
        super.keyDown(with: event)
    }
}
private final class SimulatorToolbarColumn: NSView { override var isFlipped: Bool { true } }
private final class SimulatorMenuCommand: NSObject {
    let perform: () -> Void
    init(_ perform: @escaping () -> Void) { self.perform = perform }
    @objc func invoke() { perform() }
}

/// The right action column and bottom task row are sibling surfaces outside the LCD.
final class SimulatorDeviceChrome: NSObject, NSPopoverDelegate, NSTextFieldDelegate {
    let grip = SimulatorMoveGrip()
    let resize = SimulatorResizeGrip()
    let handle = SimulatorGlassView(content: NSView())
    let controls = SimulatorGlassView(content: NSView())
    let rail = SimulatorGlassView(content: NSView())
    let information = SimulatorGlassView(content: NSView(), interactive: false)
    let folding = SimulatorGlassView(content: NSView())
    let activity = SimulatorGlassView(content: NSView(), interactive: false)
    private(set) var usesFloatingModules = false
    private let menuButton = SimulatorToolbarButton()
    private var primary: [NSButton] = []
    private var auxiliary: [NSButton] = []
    private let fold = SimulatorToolbarButton()
    let angle = SimulatorHingeSlider(frame: .zero)
    private let angleLabel = NSTextField(labelWithString: "실제 각도 읽는 중…")
    private let draftLabel = NSTextField(labelWithString: "눈금 클릭 · 드래그로 세부 조절")
    private let feedback = NSTextField(labelWithString: "준비됨")
    private let responseButton = SimulatorToolbarButton()
    private let rightScroll = NSScrollView()
    private let rightDocument = SimulatorToolbarColumn()
    private let bottomScroll = NSScrollView()
    private let bottomDocument = NSView()
    private let hinge = NSPopover()
    private let input = NSPopover()
    private let location = NSPopover()
    private var popoverOpeners: [ObjectIdentifier:NSView] = [:]
    private weak var activePopover: NSPopover?
    private var foldable = false
    private var connected = false
    private var watch = false
    private var name = "Simulator"
    private var rotationCommandActive = false
    private var requestedAngle: Double?
    private var angleDeadline: DispatchWorkItem?
    private var confirmedAngle: Double?
    private var angleFailed = false
    private var busy = false
    private var hostBusy = false
    private var recording = false
    private let textDraft = NSTextField(string: "")
    private let keyDraft = NSTextField(string: "")
    private let latitude = NSTextField(string: "")
    private let longitude = NSTextField(string: "")
    var visibleActionCount: Int { primary.filter { !$0.isHidden }.count }
    var toolsVisible = false
    var touchesVisible = true
    var keyboardEnabled = true
    var onRun: ([String: Any]) -> Void = { _ in }
    var onMenu: () -> NSMenu = { NSMenu() }
    var onTools: () -> Void = {}
    var onKeyboard: () -> Void = {}
    var onTouches: () -> Void = {}
    var onResponse: (NSView) -> Void = { _ in }
    var onHost: (String, String) -> Void = { _,_ in }
    var onRecord: () -> Void = {}
    var onManage: () -> Void = {}
    var onCleanup: () -> Void = {}
    private var unavailable: Bool { busy || hostBusy || !connected }

    override init() {
        super.init()
        handle.content.addSubview(grip)
        configure(menuButton, title: "기기 메뉴", symbol: "ellipsis.circle", action: #selector(openMenu))
        menuButton.title = ""; handle.content.addSubview(menuButton)
        handle.layoutContent = { [weak self] bounds in
            self?.grip.frame = CGRect(x: 0, y: 0, width: max(0, bounds.width - 44), height: bounds.height)
            self?.menuButton.frame = CGRect(x: bounds.width - 44, y: 2, width: 42, height: bounds.height - 4)
        }
        configure(fold, title: "접기", symbol: "rectangle.split.2x1", action: #selector(showHinge))
        primary = [make("홈", "house", #selector(home)), make("회전", "rotate.right", #selector(rotate)), fold,
                   make("캡처", "camera", #selector(capture)), make("녹화", "record.circle", #selector(record)),
                   make("잠금", "lock", #selector(lock)), make("더보기", "ellipsis", #selector(more))]
        rightScroll.drawsBackground = false; rightScroll.hasVerticalScroller = true; rightScroll.autohidesScrollers = true
        rightScroll.documentView = rightDocument; controls.content.addSubview(rightScroll)
        for button in primary { rightDocument.addSubview(button) }
        controls.content.setAccessibilityRole(.toolbar)
        controls.setAccessibilityLabel("기기 동작 툴바")
        controls.layoutContent = { [weak self] bounds in
            guard let self else { return }
            let visible = self.primary.filter { !$0.isHidden }
            self.rightScroll.frame = bounds.insetBy(dx: 2, dy: 4)
            let total = CGFloat(visible.count)*44
            self.rightScroll.hasVerticalScroller = total > self.rightScroll.bounds.height
            self.rightDocument.frame = CGRect(x: 0,y: 0,width: max(1,bounds.width-4),height: total)
            self.rightScroll.tile()
            self.rightDocument.frame.size.width = self.rightScroll.contentSize.width
            let height: CGFloat = 44
            for (i, button) in visible.enumerated() {
                button.frame = CGRect(x: 4, y: CGFloat(i)*height, width: self.rightDocument.bounds.width-8, height: height)
            }
        }
        auxiliary = [make("입력⌄", "keyboard", #selector(showInput)), make("터치 ✓", "hand.point.up.left", #selector(touches)),
                     make("환경⌄", "slider.horizontal.3", #selector(environment)), make("위치⌄", "location", #selector(showLocation)),
                     make("검사⌄", "viewfinder", #selector(inspection)), make("보기⌄", "macwindow", #selector(viewMenu))]
        auxiliary[1].setButtonType(.toggle)
        bottomScroll.drawsBackground = false; bottomScroll.hasHorizontalScroller = true; bottomScroll.hasVerticalScroller = false
        bottomScroll.autohidesScrollers = true; bottomScroll.horizontalScrollElasticity = .allowed
        bottomScroll.documentView = bottomDocument
        for button in auxiliary { button.imagePosition = .imageLeading; bottomDocument.addSubview(button) }
        rail.content.addSubview(bottomScroll)
        feedback.font = .systemFont(ofSize: 11, weight: .medium)
        feedback.lineBreakMode = .byTruncatingMiddle
        feedback.setAccessibilityLabel("시뮬레이터 조작 결과")
        rail.content.addSubview(feedback)
        configure(responseButton, title: "응답", symbol: "text.bubble", action: #selector(response))
        responseButton.imagePosition = .imageLeading
        rail.content.addSubview(responseButton)
        rail.content.setAccessibilityRole(.toolbar)
        rail.setAccessibilityLabel("시뮬레이터 작업 툴바")
        rail.layoutContent = { [weak self] bounds in
            guard let self else { return }
            let needsScroll = bounds.width-8 < 360
            self.bottomScroll.hasHorizontalScroller = needsScroll
            let scroller: CGFloat = needsScroll && self.bottomScroll.scrollerStyle == .legacy ? NSScroller.scrollerWidth(for: .regular, scrollerStyle: .legacy) : 0
            self.bottomScroll.frame = CGRect(x: 4,y: 24,width: max(0,bounds.width-8),height: 44+scroller)
            self.bottomScroll.tile()
            let oldX = self.bottomScroll.contentView.bounds.origin.x
            let width: CGFloat = 360
            self.bottomDocument.frame = CGRect(x: 0,y: 0,width: width,height: 44)
            self.bottomScroll.tile()
            for (i, button) in self.auxiliary.enumerated() {
                button.frame = CGRect(x: CGFloat(i)*60,y: 0,width: 60,height: 44)
            }
            self.bottomScroll.contentView.scroll(to: CGPoint(x: min(max(0,oldX),max(0,width-self.bottomScroll.contentSize.width)),y: 0))
            self.bottomScroll.reflectScrolledClipView(self.bottomScroll.contentView)
            self.feedback.frame = CGRect(x: 12, y: 4, width: max(0,bounds.width-82), height: 18)
            self.responseButton.frame = CGRect(x: bounds.width-68, y: 0, width: 64, height: 24)
        }
        configureHinge(); configureInput(); configureLocation()
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(accessibilityChanged), name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
        accessibilityChanged(); updateControls()
    }
    deinit { angleDeadline?.cancel(); NSWorkspace.shared.notificationCenter.removeObserver(self) }
    private func configure(_ button: NSButton, title: String, symbol: String, action: Selector) {
        button.title = title
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?.withSymbolConfiguration(.init(pointSize: 17, weight: .medium))
        button.font = .systemFont(ofSize: 11, weight: .medium)
        button.contentTintColor = .labelColor; button.imagePosition = .imageAbove
        button.isBordered = false; button.focusRingType = .exterior
        button.target = self; button.action = action; button.toolTip = title; button.setAccessibilityLabel(title.replacingOccurrences(of: "⌄", with: " 메뉴"))
    }
    private func make(_ title: String, _ symbol: String, _ action: Selector) -> NSButton {
        let button = SimulatorToolbarButton(); configure(button, title: title, symbol: symbol, action: action); return button
    }
    func updateDevice(name: String, runtime: String, connected: Bool, foldable: Bool, isWatch: Bool, rotation: String, primaryDisplay: Bool = true) {
        self.name = name; self.connected = connected; self.foldable = foldable; watch = isWatch
        grip.label.stringValue = "\(name) · \(connected ? "연결됨" : "화면 대기") · \(runtime)"
        grip.setAccessibilityValue(grip.label.stringValue); grip.toolTip = grip.label.stringValue + " · 드래그로 이동"
        fold.isHidden = !foldable || usesFloatingModules
        primary[1].isHidden = isWatch
        if !connected { closePopovers() }
        controls.needsLayout = true; updateControls()
    }
    func updateAngle(_ degrees: Double) {
        confirmedAngle = degrees
        fold.title = "접기"; fold.setAccessibilityLabel("접기 · 실제 각도 \(Int(degrees.rounded()))도")
        angleLabel.stringValue = "확인값 \(Int(degrees.rounded()))°"
        if let requestedAngle, abs(requestedAngle - degrees) < 0.6 {
            self.requestedAngle = nil; angleDeadline?.cancel(); angleDeadline = nil; angleFailed = false; draftLabel.stringValue = "✓ 적용 확인됨"
        }
        if requestedAngle == nil && !angleFailed && !angle.isAdjusting { angle.doubleValue = degrees }
    }
    func setBusy(_ value: Bool) { busy = value; updateControls() }
    func setHostBusy(_ value: Bool) { hostBusy = value; updateControls() }
    func updateRecording(_ active: Bool, caption: String) {
        recording = active; primary[4].title = caption
        primary[4].image = NSImage(systemSymbolName: active ? "stop.circle.fill" : "record.circle", accessibilityDescription: nil)
        primary[4].setAccessibilityLabel(caption); primary[4].contentTintColor = active ? .systemRed : .labelColor
        updateControls()
    }
    func showFeedback(_ message: String, failed: Bool = false) {
        feedback.stringValue = (failed ? "! " : "") + message; feedback.toolTip = message
        feedback.textColor = failed ? .systemRed : .labelColor
        NSAccessibility.post(element: feedback, notification: .valueChanged)
    }
    func commandFinished(action: String, failed: Bool) {
        if action == "rotate" && failed { rotationFailed() }
        if action == "hinge" {
            angleFailed = failed
            draftLabel.stringValue = failed ? "! 적용 실패 · 선택값 유지, 다시 선택해 재시도" : requestedAngle == nil ? "✓ 적용 확인됨" : "실제 각도 확인 중…"
            if failed { requestedAngle = nil; angleDeadline?.cancel(); angleDeadline = nil }
        }
    }
    func updateControls() {
        for button in primary { button.isEnabled = !unavailable }
        primary[1].isEnabled = !unavailable && !rotationCommandActive
        primary[4].isEnabled = recording || !unavailable
        primary[6].isEnabled = true
        angle.isEnabled = foldable && !unavailable
        auxiliary[0].isEnabled = !unavailable; auxiliary[2].isEnabled = !unavailable; auxiliary[3].isEnabled = !unavailable
        auxiliary[1].state = touchesVisible ? .on : .off
        auxiliary[1].title = touchesVisible ? "터치 ✓" : "터치"
        auxiliary[1].contentTintColor = touchesVisible ? .controlAccentColor : .labelColor
    }
    func closePopovers() { hinge.close(); input.close(); location.close() }
    @objc private func accessibilityChanged() {
        for popover in [hinge,input,location] { popover.animates = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
    }
    private func present(_ popover: NSPopover, from button: NSView, first: NSView, edge: NSRectEdge = .maxY) {
        if popover.isShown { popover.close(); return }
        activePopover = nil; closePopovers(); onCleanup(); popoverOpeners[ObjectIdentifier(popover)] = button; activePopover = popover
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: edge)
        button.setAccessibilityExpanded(true)
        first.window?.makeFirstResponder(first)
    }
    func popoverDidClose(_ notification: Notification) {
        guard let popover = notification.object as? NSPopover,let opener = popoverOpeners.removeValue(forKey: ObjectIdentifier(popover)) else { return }
        opener.setAccessibilityExpanded(false)
        guard activePopover === popover else { return }
        activePopover = nil
        if NSApp.isActive { opener.window?.makeKey(); opener.window?.makeFirstResponder(opener) }
    }
    private func setup(_ popover: NSPopover, root: NSView) {
        let controller = NSViewController(); controller.view = root
        popover.contentViewController = controller; popover.behavior = .transient; popover.delegate = self
    }
    private func configureHinge() {
        let root = NSView(frame: CGRect(x: 0,y: 0,width: 300,height: 156))
        angleLabel.frame = CGRect(x: 12,y: 124,width: 276,height: 22)
        angle.frame = CGRect(x: 12,y: 30,width: 276,height: 96)
        draftLabel.frame = CGRect(x: 12,y: 4,width: 276,height: 26); draftLabel.font = .systemFont(ofSize: 11)
        root.addSubview(angleLabel); root.addSubview(angle); root.addSubview(draftLabel)
        angle.onDismiss = { [weak self] in self?.hinge.close() }
        angle.onPreview = { [weak self] degrees in self?.draftLabel.stringValue = "선택값 \(Int(degrees))° · 놓으면 적용" }
        angle.onCommit = { [weak self] degrees in
            guard let self, !self.unavailable else { return }
            self.requestedAngle = degrees; self.angleFailed = false
            self.draftLabel.stringValue = "\(Int(degrees))° 적용 중…"
            self.angleDeadline?.cancel()
            let deadline = DispatchWorkItem { [weak self] in
                guard let self,self.requestedAngle != nil else { return }
                self.requestedAngle = nil; self.angleFailed = true
                self.draftLabel.stringValue = "! 각도 확인 실패 · 선택값 유지"
                self.showFeedback("접기 각도를 확인하지 못했습니다",failed: true)
            }
            self.angleDeadline = deadline
            DispatchQueue.main.asyncAfter(deadline: .now()+12,execute: deadline)
            self.run(["action":"hinge","degrees":degrees])
        }
        setup(hinge, root: root)
    }
    private func formField(_ field: NSTextField, label: String, y: CGFloat, in root: NSView) {
        let title = NSTextField(labelWithString: label); title.frame = CGRect(x: 12,y: y+30,width: root.bounds.width-24,height: 20)
        field.delegate = self
        field.frame = CGRect(x: 12,y: y,width: root.bounds.width-24,height: 28); field.setAccessibilityLabel(label)
        root.addSubview(title); root.addSubview(field)
    }
    private func formButton(_ title: String, selector: Selector, y: CGFloat, in root: NSView) {
        let button = NSButton(title: title, target: self, action: selector)
        button.frame = CGRect(x: 12,y: y,width: root.bounds.width-24,height: 30); root.addSubview(button)
    }
    private func configureInput() {
        let root = NSView(frame: CGRect(x: 0,y: 0,width: 300,height: 288))
        formButton("Mac 키보드 전달 켜기/끄기", selector: #selector(keyboard), y: 246, in: root)
        formField(textDraft,label: "기기로 보낼 글자",y: 188,in: root)
        textDraft.target = self; textDraft.action = #selector(sendText)
        formButton("텍스트 전송",selector: #selector(sendText),y: 152,in: root)
        formButton("Mac 클립보드 붙여넣기…",selector: #selector(paste),y: 116,in: root)
        formField(keyDraft,label: "키 조합 · Return, cmd+a",y: 52,in: root)
        keyDraft.target = self; keyDraft.action = #selector(sendKey)
        formButton("키 전송",selector: #selector(sendKey),y: 12,in: root)
        setup(input,root: root)
    }
    private func configureLocation() {
        let root = NSView(frame: CGRect(x: 0,y: 0,width: 300,height: 208))
        formField(latitude,label: "위도 (−90…90)",y: 140,in: root)
        formField(longitude,label: "경도 (−180…180)",y: 80,in: root)
        formButton("좌표 적용",selector: #selector(applyLocation),y: 42,in: root)
        formButton("위치 시뮬레이션 중지",selector: #selector(clearLocation),y: 8,in: root)
        setup(location,root: root)
    }
    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) { activePopover?.close(); return true }
        return false
    }
    private func run(_ arguments: [String: Any]) { if !unavailable { onRun(arguments) } }
    private func item(_ menu: NSMenu, _ title: String, enabled: Bool = true, _ work: @escaping () -> Void) {
        let command = SimulatorMenuCommand(work)
        let item = NSMenuItem(title: title, action: #selector(SimulatorMenuCommand.invoke), keyEquivalent: "")
        item.target = command; item.representedObject = command; item.isEnabled = enabled; menu.addItem(item)
    }
    private func unsupported(_ menu: NSMenu, _ title: String, _ reason: String) {
        let item = NSMenuItem(title: title + " — " + reason, action: nil, keyEquivalent: ""); item.isEnabled = false; menu.addItem(item)
    }
    private func pop(_ menu: NSMenu, from button: NSView) {
        menu.autoenablesItems = false; closePopovers(); onCleanup()
        menu.popUp(positioning: nil, at: CGPoint(x: 0,y: button.bounds.maxY), in: button)
    }
    @objc private func openMenu() { pop(onMenu(), from: menuButton) }
    @objc private func home() { run(["action":"button","button":"home"]) }
    @objc private func lock() { run(["action":"button","button":"lock"]) }
    @objc private func capture() { run(["action":"screenshot"]) }
    @objc private func record() { closePopovers(); onCleanup(); onRecord() }
    @objc private func keyboard() { onKeyboard() }
    @objc private func touches() { onTouches() }
    @objc private func response() { closePopovers(); onCleanup(); onResponse(responseButton) }
    @objc private func showHinge() { if foldable && !unavailable { present(hinge, from: fold, first: angle, edge: .minX) } }
    @objc private func showInput() { if !unavailable { present(input,from: auxiliary[0],first: textDraft) } }
    @objc private func showLocation() { if !unavailable { present(location,from: auxiliary[3],first: latitude) } }
    @objc private func sendText() { if !textDraft.stringValue.isEmpty { run(["action":"type","text":textDraft.stringValue]) } }
    @objc private func sendKey() { if !keyDraft.stringValue.isEmpty { run(["action":"key","key":keyDraft.stringValue]) } }
    @objc private func paste() {
        guard !unavailable else { return }
        let alert = NSAlert(); alert.messageText = name + "에 붙여넣을까요?"
        alert.informativeText = "Mac과 부팅된 다른 기기의 클립보드에도 전달됩니다. iOS에서 허용이 필요할 수 있습니다."
        alert.addButton(withTitle: "취소"); alert.addButton(withTitle: "붙여넣기")
        if alert.runModal() == .alertSecondButtonReturn { run(["action":"paste","text":NSPasteboard.general.string(forType: .string) ?? ""]) }
    }
    @objc private func applyLocation() {
        guard !unavailable, let lat = Double(latitude.stringValue), let lon = Double(longitude.stringValue), lat.isFinite,lon.isFinite,(-90...90).contains(lat),(-180...180).contains(lon) else {
            showFeedback("위도와 경도를 범위 안의 숫자로 입력하세요",failed: true); return
        }
        onHost("location", "\(lat),\(lon)")
    }
    @objc private func clearLocation() { if !unavailable { onHost("location-clear", "") } }
    @objc private func rotate() {
        guard !unavailable, !rotationCommandActive else { return }
        rotationCommandActive = true; updateControls()
        run(["action":"rotate", "direction":"clockwise"])
    }
    func rotationFailed() { rotationCommandActive = false; updateControls() }
    /// Delivery, screen change and actual device pose are distinct. A cover that remains portrait
    /// is not a failed command, nor proof of the requested pose. Absolute commands share this path.
    func finishRotationFeedback(_ response: [String: Any]) {
        rotationCommandActive = false; updateControls()
        let result = (response["structuredContent"] as? [String: Any])?["rotation"] as? [String: Any]
        let target = (result?["requestedOrientation"] as? String).flatMap { SimulatorOrientation(rawValue: $0) }?.title ?? ""
        if result?["presentationConfirmed"] as? Bool == true {
            let guest = result?["confirmationPending"] as? Bool == true ? " · 앱 방향 확인 중" : result?["screenConfirmed"] as? Bool == true ? " · 앱 방향 확인"
                : result?["screenOrientation"] == nil || result?["screenChanged"] as? Bool == true ? " · 앱 목표 방향 미확인" : " · 앱 방향 유지"
            showFeedback("✓ 기기 화면 회전 · " + target + guest)
        }
        else if result?["presentationOrientation"] != nil { showFeedback("회전 요청 전달 · 기기 화면 표시 확인 불가") }
        else if result?["screenConfirmed"] as? Bool == true { showFeedback("✓ 화면 회전 확인 · " + target) }
        else if result?["screenOrientation"] != nil {
            showFeedback("회전 요청 전달 · " + target + (result?["screenChanged"] as? Bool == true ? " · 목표 방향 확인 불가" : " · 화면 방향 유지"))
        }
        else { showFeedback("회전 요청 전달 · 화면 방향 확인 불가") }
        if result?["assumedPortrait"] as? Bool == true {
            showFeedback(feedback.stringValue + " · 세로 기준 첫 요청")
        }
    }
    @objc private func environment() {
        let menu = NSMenu(title: "환경")
        for (title,value) in [("라이트로 변경","light"),("다크로 변경","dark")] { item(menu,title,enabled: !unavailable) { [weak self] in self?.onHost("appearance",value) } }
        for (title,value) in [("대비 높이기 켜기","enabled"),("대비 높이기 끄기","disabled")] { item(menu,title,enabled: !unavailable) { [weak self] in self?.onHost("increase_contrast",value) } }
        let sizes = NSMenu(title: "글자 크기")
        for (title,value) in [("작게","small"),("기본","large"),("크게","extra-large"),("접근성 크게","accessibility-large")] { item(sizes,title,enabled: !unavailable) { [weak self] in self?.onHost("content_size",value) } }
        let size = NSMenuItem(title: "글자 크기",action: nil,keyEquivalent: ""); size.submenu = sizes; menu.addItem(size)
        pop(menu,from: auxiliary[2])
    }
    @objc private func inspection() {
        let menu = NSMenu(title: "검사")
        item(menu,"화면 요소 · UIView · 다중 터치…") { [weak self] in self?.onTools() }
        item(menu,"가이드 캡처",enabled: !unavailable) { [weak self] in self?.run(["action":"screenshot","guides":true]) }
        item(menu,"활동과 결과") { [weak self] in guard let self else { return }; self.onResponse(self.auxiliary[4]) }
        pop(menu,from: auxiliary[4])
    }
    @objc private func viewMenu() { pop(onMenu(),from: auxiliary[5]) }
    @objc private func more() {
        let menu = NSMenu(title: "기기 더보기")
        for (title,button) in [("Siri","siri"),("측면 버튼","side")] { item(menu,title,enabled: !unavailable) { [weak self] in self?.run(["action":"button","button":button]) } }
        if watch {
            for (title,value) in [("Crown 위로",-60.0),("Crown 아래로",60.0)] { item(menu,title,enabled: !unavailable) { [weak self] in self?.run(["action":"crown","amount":value]) } }
        } else {
            for (title,value) in [("세로","portrait"),("가로 오른쪽","landscape-right"),("거꾸로","upside-down"),("가로 왼쪽","landscape-left")] { item(menu,title,enabled: !unavailable) { [weak self] in self?.run(["action":"rotate","orientation":value]) } }
        }
        menu.addItem(.separator())
        item(menu,"시뮬레이터 관리…") { [weak self] in self?.onManage() }
        pop(menu,from: primary[6])
    }
    /// Legacy layouts remain readable for saved detached panels; production uses embedded bars.
    func enableFloatingModules() { usesFloatingModules = true; fold.isHidden = true }
}

/// Multi-screen backend responses put a label immediately before each image.
func simulatorActiveCaptureData(_ items: [[String: Any]]) -> Data? {
    var first: Data?
    var active = false
    for item in items {
        if let text = item["text"] as? String { active = text.contains("(on:") }
        if let encoded = item["data"] as? String, let image = Data(base64Encoded: encoded) {
            if active { return image }
            if first == nil { first = image }
        }
    }
    return first
}
