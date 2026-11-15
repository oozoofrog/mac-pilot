import AppKit
import SwiftUI

struct SimulatorToolboxMotion {
    let delay: Double
    let duration: Double
    let bounce: Double

    init(row: Int, column: Int) {
        delay = Double((row * 2 + column) % 7) * 0.01
        duration = 0.44 + Double((row + column * 2) % 5) * 0.02
        bounce = 0.04 + Double((row + column) % 3) * 0.02
    }
}

func simulatorToolboxFrame(row: Int, column: Int, columns: Int, span: Int, in size: CGSize,
                           lcd: CGRect, expanded: Bool) -> CGRect {
    let heights: [CGFloat] = [44, 60, 44, 44, 44, 44, 64, 44]
    let scale = min(1, max(0, size.height) / simulatorToolboxHeight)
    let gap = 24 * scale
    let width = max(1, size.width - simulatorToolboxGap)
    let cell = max(1, (width - gap * CGFloat(columns - 1)) / CGFloat(columns))
    let top = heights.prefix(row).reduce(6, +) + CGFloat(row) * 24
    let x = CGFloat(column) * (cell + gap)
    let frame = CGRect(x: x, y: size.height - (top + heights[row]) * scale,
                       width: min(width - x, cell * CGFloat(span) + gap * CGFloat(span - 1)), height: heights[row] * scale)
    if expanded { return frame.offsetBy(dx: simulatorToolboxGap, dy: 0) }
    let closedHeight = min(size.height * 0.82, max(1, lcd.height))
    let verticalScale = closedHeight / max(1, size.height)
    // Keep the whole ordered grid behind the LCD edge, including a glass rim/shadow allowance.
    return CGRect(x: min(0, lcd.maxX) - 2 * simulatorToolboxRim - width * 0.82 + frame.minX * 0.82,
                  y: lcd.midY - closedHeight / 2 + frame.minY * verticalScale,
                  width: frame.width * 0.82, height: frame.height * verticalScale)
}

struct SimulatorToolActivity {
    let id = UUID()
    let connection: UUID?
    let request: String?
    let action: String
    let inspectionRead: Bool
    let mutatesDevice: Bool
    let control: String
    let source: String
    let summary: String
    let started = Date()

    var title: String {
        ["button.home": "홈", "button.lock": "잠금", "button.side": "측면 버튼", "button.siri": "Siri", "rotate": "회전",
         "hinge": "접기", "crown": "Crown", "type": "글자 입력", "paste": "붙여넣기", "key": "키 전송",
         "gesture": "제스처", "describe": "화면 요소", "wait": "요소 대기", "tap": "탭", "press": "접근성 실행",
         "views": "UIView 검사", "screenshot": "캡처", "window": "LCD 창"][control] ?? action
    }

    init(arguments: [String: Any], source: String, connection: UUID? = nil, request: String? = nil) {
        self.connection = connection
        self.request = request
        let action = arguments["action"] as? String ?? ""
        self.action = action
        inspectionRead = action == "axSnapshot" || (action == "describe" && arguments["inspection"] as? Bool == true)
        mutatesDevice = ["rotate", "button", "gesture", "tap", "swipe", "press", "key", "type", "paste", "crown"].contains(action) ||
            (action == "hinge" && (arguments["degrees"] != nil || arguments["state"] != nil))
        control = (arguments["button"] as? String).map { "\(action).\($0)" } ?? action
        self.source = source
        if let selected = arguments["inspectionElement"] as? [String: Any] {
            let name = ["label", "value", "identifier"].compactMap { selected[$0] as? String }.first { !$0.isEmpty } ?? "이름 없는 요소"
            summary = "선택: " + name
            return
        }
        summary = arguments.keys.sorted().filter { !["device", "action", "inspection", "inspectionPid", "inspectionElement", "inspectionScope"].contains($0) }.map { key in
            if key == "ax" { return "capture/node bound AX operation" }
            if key == "text" { return "글자 \((arguments[key] as? String ?? "").count)자" }
            if key == "frames" { return "접점 프레임 \((arguments[key] as? [Any] ?? []).count)개" }
            return "\(key)=\(String(describing: arguments[key]!).prefix(80))"
        }.joined(separator: " · ")
    }
}

/// Parallel contacts for the coordinate form. The backend performs the same HID validation as MCP calls.
func simulatorToolboxContacts(from: CGPoint, to: CGPoint?, fingers: Int, seconds: Double, screen: CGSize) throws -> [[String: Any]] {
    guard (1...3).contains(fingers), seconds.isFinite, seconds >= 0.02, seconds <= 10 else {
        throw NSError(domain: "SimulatorToolbox", code: 1, userInfo: [NSLocalizedDescriptionKey: "손가락은 1~3개, 시간은 0.02~10초로 입력하세요."])
    }
    func touches(_ at: CGPoint, phase: String) throws -> [[String: Any]] {
        try (0..<fingers).map { i in
            let x = at.x + CGFloat(i) * 24
            guard x.isFinite, at.y.isFinite, x >= 0, x < screen.width, at.y >= 0, at.y < screen.height else {
                throw NSError(domain: "SimulatorToolbox", code: 2, userInfo: [NSLocalizedDescriptionKey: "모든 접점이 LCD 화면 안에 있어야 합니다. 손가락 사이 간격은 24pt입니다."])
            }
            return ["id": i + 1, "phase": phase, "x": x, "y": at.y]
        }
    }
    var frames: [[String: Any]] = [["time": 0.0, "touches": try touches(from, phase: "down")]]
    if let to { frames.append(["time": seconds * 0.9, "touches": try touches(to, phase: "move")]) }
    frames.append(["time": seconds, "touches": try touches(to ?? from, phase: "up")])
    return frames
}

func simulatorToolboxViewRequest(_ input: String) -> [String: Any] {
    let parts = input.split(separator: ">", maxSplits: 1, omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
    if parts.count == 2 { return ["action": "views", "app": parts[0], "query": parts[1]] }
    return ["action": "views", "query": input]
}

final class SimulatorToolboxView: NSView {
    var onRun: ([String: Any]) -> Void = { _ in }
    var onPresentReport: ((NSPopover, NSView, NSView) -> Void)?
    var onShowPersistentResult: () -> Void = {}
    private let section = NSSegmentedControl(labels: ["화면 요소", "뷰 구조", "결과"], trackingMode: .selectOne, target: nil, action: nil)
    private var resultsSelected = false
    private var reportBody: NSScrollView!
    private let reportRoot = NSView(frame: CGRect(x: 0, y: 0, width: 380, height: 500))
    private let continueResult = NSButton(title: "검사 도구에서 계속 보기", target: nil, action: nil)
    private let retryButton = NSButton(title: "같은 입력으로 재시도", target: nil, action: nil)
    private let pasteRecovery = NSButton(title: "같은 글자 붙여넣기…", target: nil, action: nil)
    private var inspectionLabels: [NSControl: NSTextField] = [:]
    var onAvailabilityChanged: (Bool) -> Void = { _ in }
    var onOpen3D: () -> Void = {}
    var confirmAction: (String) -> Bool = SimulatorToolboxView.confirm
    private(set) var screenSize = CGSize(width: 1, height: 1)
    private(set) var busy = false
    private(set) var manualPending = false
    private var current: UUID?
    private var lastManual: [String: Any]?
    private var actions: [NSControl: () throws -> [String: Any]] = [:]
    private var actionNames: [NSControl: String] = [:]
    private var history: [String] = []
    private struct Component {
        let glass: SimulatorGlassView
        let control: NSControl
        let row: Int
        let column: Int
        let columns: Int
        let span: Int
    }
    private var components: [Component] = []
    private var inspectionEscapeMonitor: Any?
    var onCloseInspection: () -> Void = {}
    private let basicInspection = NSButton(title: "‹ 화면 요소 목록", target: nil, action: nil)
    var onInspectionSelection: (CGRect?) -> Void = { _ in }
    var onInspectionPickMode: (Bool) -> Void = { _ in }
    private let viewHierarchy = SimulatorViewHierarchyBrowser(frame: .zero)
    private var hierarchySelected = false
    private let browser = SimulatorElementBrowser(frame: .zero)
    private var advancedInspection = false
    private var inspectionGeometry = ""
    private var inspectionReadGeometry: String?
    private var inspectionScope: [String: Any]?
    private var inspectionPresentation = false
    private let isWatch: Bool
    private let angle = NSSlider(value: 180, minValue: 0, maxValue: 180, target: nil, action: nil)
    private let angleLabel = NSTextField(labelWithString: "접기 각도")
    private var angleGlass: SimulatorGlassView?
    private var orientationControl: NSPopUpButton?
    let report = NSPopover()
    private let status = NSButton(title: "활동 · 대기", target: nil, action: nil)
    private let argumentsLabel = NSTextField(wrappingLabelWithString: "")
    private let result = NSTextView()
    private let recent = NSTextField(wrappingLabelWithString: "")
    private let images = NSStackView()
    private var expanded = false
    private var transitioning = false
    private var animationVersion = 0
    private var animationTargets: [CGRect] = []
    private var animationRequested = false
    private var animationCompleted = false
    private var settlement: DispatchWorkItem?
    private var transitionCompletion: (() -> Void)?
    var retractionLCD = CGRect(x: -simulatorToolboxWidth, y: 0, width: simulatorToolboxWidth, height: simulatorToolboxHeight) {
        didSet { if oldValue != retractionLCD { needsLayout = true } }
    }
    private var acceptsInput: Bool { expanded && !transitioning && !isHiddenOrHasHiddenAncestor }
    var glassSpacing: CGFloat { 18 * min(1, max(0, bounds.height) / simulatorToolboxHeight) }
    var visibleGlassFrames: [CGRect] { components.filter { !$0.glass.isHidden }.map { $0.glass.frame } }
    var clippedGlassFrames: [CGRect] { visibleGlassFrames.map { $0.intersection(bounds) }.filter { !$0.isEmpty } }
    var glassIsRetracted: Bool {
        visibleGlassFrames.allSatisfy {
            $0.maxX + simulatorToolboxRim <= min(0, retractionLCD.maxX) &&
            $0.insetBy(dx: -simulatorToolboxRim, dy: -simulatorToolboxRim).intersection(bounds).isEmpty
        }
    }

    init(deviceName: String, isWatch: Bool) {
        self.isWatch = isWatch
        super.init(frame: CGRect(x: 0, y: 0, width: simulatorToolboxWidth + simulatorToolboxGap, height: simulatorToolboxHeight))
        clipsToBounds = true
        setAccessibilityElement(false)
        setAccessibilityLabel(deviceName + " 도구")
        for (column, item) in [("홈", "home"), ("잠금", "lock"), ("Siri", "siri")].enumerated() {
            add(button(item.0), name: "button." + item.1, row: 0, column: column, columns: 3) { ["action": "button", "button": item.1] }
        }
        if isWatch {
            for (column, item) in [("Crown 위로", -60.0), ("Crown 아래로", 60.0)].enumerated() {
                add(button(item.0), name: "crown", row: 1, column: column) { ["action": "crown", "amount": item.1] }
            }
        } else {
            let orientation = NSPopUpButton()
            orientation.addItems(withTitles: ["세로", "가로 왼쪽", "가로 오른쪽", "거꾸로"])
            orientation.isBordered = false
            orientationControl = orientation
            orientation.setAccessibilityLabel("방향 · 선택 즉시 회전")
            add(orientation, name: "rotate", row: 1, column: 0) {
                ["action": "rotate", "orientation": ["portrait", "landscape-left", "landscape-right", "upside-down"][orientation.indexOfSelectedItem]]
            }
            angle.isContinuous = false
            angle.setAccessibilityLabel("접기 각도 · 놓으면 적용")
            let slider = angle
            add(angle, name: "hinge", row: 1, column: 1) { ["action": "hinge", "degrees": slider.doubleValue] }
            angleGlass = components.last?.glass
            angleLabel.font = .systemFont(ofSize: 11)
            angleGlass?.content.addSubview(angleLabel)
            angleGlass?.isHidden = true
        }
        let text = field("기기로 보낼 글자 ⏎")
        add(text, name: "type", row: 2, column: 0, columns: 3, span: 2) { ["action": "type", "text": text.stringValue] }
        add(button("붙여넣기…"), name: "paste", row: 2, column: 2, columns: 3) {
            ["action": "paste", "text": NSPasteboard.general.string(forType: .string) ?? ""]
        }
        let key = field("키 · Return, cmd+a ⏎")
        add(key, name: "key", row: 3, column: 0) { ["action": "key", "key": key.stringValue] }
        for (row, column, name, title) in [(3, 1, "describe", "화면 요소 검색 ⏎"), (4, 0, "wait", "기다릴 요소 ⏎"),
                                          (4, 1, "tap", "탭할 요소 ⏎"), (5, 0, "press", "접근성 실행 ⏎"), (5, 1, "views", "UIView · 앱ID > 클래스 ⏎")] {
            let input = field(title)
            add(input, name: name, row: row, column: column) {
                if name == "views" { return simulatorToolboxViewRequest(input.stringValue) }
                var value: [String: Any] = ["action": name]
                value[["describe", "views"].contains(name) ? "query" : "target"] = input.stringValue
                if name == "wait" { value["timeout"] = 10 }
                return value
            }
        }
        for index in 0..<3 {
            let pad = SimulatorGesturePad(fingers: index + 1)
            pad.onError = { [weak self] in self?.fail($0) }
            add(pad, name: "gesture", row: 6, column: index, columns: 3) { ["action": "gesture", "frames": pad.frames] }
        }
        let capture = NSPopUpButton(frame: .zero, pullsDown: true)
        capture.addItems(withTitles: ["캡처", "화면 캡처", "가이드 캡처"])
        capture.isBordered = false
        capture.setAccessibilityLabel("캡처 · 메뉴에서 바로 실행")
        add(capture, name: "screenshot", row: 7, column: 0) { ["action": "screenshot", "guides": capture.indexOfSelectedItem == 2] }
        status.target = self
        status.action = #selector(showReport(_:))
        status.isBordered = false
        status.setAccessibilityLabel("활동과 도구 응답")
        addComponent(status, name: "report", row: 7, column: 1)
        configureReport()
        updateInteraction()
    }
    required init?(coder: NSCoder) { fatalError() }
    deinit { if let inspectionEscapeMonitor { NSEvent.removeMonitor(inspectionEscapeMonitor) } }

    private func button(_ title: String) -> NSButton {
        let control = NSButton(title: title, target: nil, action: nil)
        control.isBordered = false
        control.font = .systemFont(ofSize: 12, weight: .medium)
        return control
    }
    private func field(_ title: String) -> NSTextField {
        let control = NSTextField(string: "")
        control.placeholderString = title
        control.setAccessibilityLabel(title)
        control.isBordered = false
        control.drawsBackground = false
        control.font = .systemFont(ofSize: 12)
        control.lineBreakMode = .byTruncatingTail
        (control.cell as? NSTextFieldCell)?.sendsActionOnEndEditing = false
        return control
    }
    private func add(_ control: NSControl, name: String, row: Int, column: Int, columns: Int = 2, span: Int = 1,
                     build: @escaping () throws -> [String: Any]) {
        control.target = self
        control.action = #selector(execute(_:))
        actions[control] = build
        addComponent(control, name: name, row: row, column: column, columns: columns, span: span)
    }
    private func addComponent(_ control: NSControl, name: String, row: Int, column: Int, columns: Int = 2, span: Int = 1) {
        let content = NSView()
        content.addSubview(control)
        let glass = SimulatorGlassView(content: content)
        glass.layoutContent = { [weak self, weak control] bounds in
            guard let self, let control else { return }
            self.layout(control, in: bounds)
            self.finishTransitionIfReady()
        }
        glass.setAccessibilityElement(false)
        addSubview(glass)
        actionNames[control] = name
        components.append(Component(glass: glass, control: control, row: row, column: column, columns: columns, span: span))
    }

    /// Reuse the original inspection controls and drafts, with one window owner.
    func useInspectionPresentation() {
        inspectionPresentation = true
        if inspectionEscapeMonitor == nil {
            inspectionEscapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, self.acceptsInput, event.keyCode == 53, event.window === self.window else { return event }
                let responder = self.window?.firstResponder as? NSView
                let editorOwner = (responder as? NSTextView)?.delegate as? NSView
                guard responder?.isDescendant(of: self) == true || editorOwner?.isDescendant(of: self) == true else { return event }
                if self.browser.isPicking { self.browser.endPick(); self.focusInspection() }
                else { self.onCloseInspection() }
                return nil
            }
        }
        addSubview(browser); addSubview(viewHierarchy); viewHierarchy.isHidden = true
        viewHierarchy.setAvailability(false, reason: "뷰 구조 캡처를 사용할 수 없습니다. 앱 정지 후 복구를 확인할 수 없어 실행하지 않습니다.")
        basicInspection.target = self; basicInspection.action = #selector(showBasicInspection); addSubview(basicInspection)
        browser.onSelection = { [weak self] in self?.onInspectionSelection($0) }
        browser.onPickMode = { [weak self] in self?.onInspectionPickMode($0) }
        browser.onPress = { [weak self] row, pid in self?.submit(["action": "press", "inspectionElement": row, "inspectionPid": pid]) }
        browser.onAXAction = { [weak self] in self?.submit(["action": "axAction", "ax": $0]) }
        browser.onOpen3D = { [weak self] in self?.onOpen3D() }
        browser.onRefresh = { [weak self] in self?.refreshInspection() }
        browser.onTap = { [weak self] row, pid in
            self?.submit(["action": "tap", "inspectionElement": row, "inspectionPid": pid])
        }
        browser.onAdvanced = { [weak self] advanced in
            guard let self else { return }
            self.advancedInspection = advanced
            self.selectResults(false)
        }
        section.target = self; section.action = #selector(changeSection); section.selectedSegment = 0
        section.setAccessibilityLabel("검사 작업 영역"); addSubview(section)
        for item in components {
            item.glass.usesGlass = false
            if ["button.home","button.lock","button.siri","rotate","hinge","type","paste","key","crown"].contains(actionNames[item.control] ?? "") {
                item.glass.isHidden = true
            }
        }
        for item in components where !item.glass.isHidden {
            if let field = item.control as? NSTextField {
                let title = actionNames[field] == "views" ? "UIView 검사 · 앱 복구 확인 전 사용 불가" : (field.placeholderString ?? "").replacingOccurrences(of: " ⏎", with: "")
                let label = NSTextField(labelWithString: title)
                label.font = .systemFont(ofSize: 11, weight: .medium)
                item.glass.content.addSubview(label); inspectionLabels[field] = label
                field.isBordered = true; field.drawsBackground = true
            }
        }
        selectResults(false)
        needsLayout = true
    }
    @objc private func showBasicInspection() { advancedInspection = false; selectResults(false) }
    @objc private func changeSection() {
        if section.selectedSegment == 1 {
            selectResults(false); hierarchySelected = true; browser.suspendSelection(); onInspectionSelection(nil)
            browser.isHidden = true; viewHierarchy.isHidden = false; basicInspection.isHidden = true
            for item in components { item.glass.isHidden = true }
            section.selectedSegment = 1; viewHierarchy.focusTree(); needsLayout = true
        } else { selectResults(section.selectedSegment == 2) }
    }
    func selectResults(_ selected: Bool) {
        guard inspectionPresentation else { return }
        report.close(); resultsSelected = selected; hierarchySelected = false; viewHierarchy.isHidden = true; section.selectedSegment = selected ? 2 : 0
        browser.suspendSelection(); onInspectionSelection(nil)
        if selected { reportBody.removeFromSuperview(); addSubview(reportBody); continueResult.isHidden = true }
        else { reportBody.removeFromSuperview(); reportRoot.addSubview(reportBody); reportBody.frame = reportRoot.bounds; continueResult.isHidden = false }
        for item in components {
            let retained = !["button.home","button.lock","button.siri","rotate","hinge","type","paste","key","crown"].contains(actionNames[item.control] ?? "")
            item.glass.isHidden = selected || !retained || !advancedInspection
        }
        basicInspection.isHidden = selected || !advancedInspection
        browser.isHidden = selected || advancedInspection
        needsLayout = true; layoutSubtreeIfNeeded(); updateInteraction()
    }
    func pickInspection(at point: CGPoint) { browser.pick(at: point) }
    func endInspectionPick() { browser.endPick() }
    func invalidateInspection() { browser.cancelRead(); inspectionReadGeometry = nil; browser.invalidate(); viewHierarchy.invalidate() }
    func cancelPendingAXRead() { browser.cancelRead(); inspectionReadGeometry = nil }
    func refreshInspection() {
        guard inspectionPresentation, acceptsInput, !busy, !manualPending else { return }
        submit(["action": "axSnapshot", "inspection": true])
    }
    func focusInspection() {
        if hierarchySelected { window?.makeKey(); viewHierarchy.focusTree(); return }
        if !resultsSelected && !advancedInspection { window?.makeKey(); browser.focusList(); return }
        let first: NSView? = resultsSelected ? result : components.first { !$0.glass.isHidden && $0.control is NSTextField }?.control
        window?.makeKey(); if let first { window?.makeFirstResponder(first) }
    }
    @objc private func continueInInspection() { report.close(); onShowPersistentResult() }

    func setFloatingPresentation(_ visible: Bool) {
        if !visible { viewHierarchy.invalidate() }
        expanded = visible
        if !visible { browser.cancelRead(); inspectionReadGeometry = nil }
        isHidden = !visible
        transitioning = false
        animationVersion += 1
        settlement?.cancel(); settlement = nil
        transitionCompletion = nil
        report.close()
        clipsToBounds = true
        needsLayout = true
        updateInteraction()
        // AX capture requires an explicit refresh; opening inspection only presents controls.
    }

    func updateScreen(_ size: CGSize, name: String, foldable: Bool, rotation: String = "rot0", screenID: String = "", guestRotation: String = "") {
        let geometry = "\(name)|\(screenID)|\(size)|\(rotation)|\(guestRotation)"
        if geometry != inspectionGeometry { viewHierarchy.invalidate(); browser.invalidate(); inspectionGeometry = geometry }
        viewHierarchy.setContext(name + " · \(Int(size.width))×\(Int(size.height))pt")
        browser.setContext(name + " · \(Int(size.width))×\(Int(size.height))pt")
        screenSize = size
        angleGlass?.isHidden = inspectionPresentation || !foldable
        for item in components { (item.control as? SimulatorGesturePad)?.screenSize = size }
        if let orientationControl, !orientationControl.isHighlighted {
            let selected = ["rot0": 0, "rot180": 3, "rot90": foldable ? 1 : 2, "rot270": foldable ? 2 : 1][rotation] ?? 0
            orientationControl.selectItem(at: selected)
        }
        needsLayout = true
    }
    func updateAngle(_ degrees: Double) {
        guard !angle.isHighlighted, !manualPending else { return }
        angle.doubleValue = degrees
        angleLabel.stringValue = "접기 · \(Int(degrees))°"
    }

    private func frames() -> [CGRect] {
        if inspectionPresentation {
            let fields = components.filter { !$0.glass.isHidden && $0.control is NSTextField }
            let pads = components.filter { $0.control is SimulatorGesturePad }
            return components.map { item in
                let width = max(1,bounds.width-24)
                if let index = fields.firstIndex(where: { $0.control === item.control }) {
                    return CGRect(x: 12,y: bounds.height-132-CGFloat(index)*58,width: width,height: 54)
                }
                if let index = pads.firstIndex(where: { $0.control === item.control }) {
                    return CGRect(x: 12+CGFloat(index)*(width/3),y: bounds.height-438,width: width/3-8,height: 64)
                }
                let isCapture = actionNames[item.control] == "screenshot"
                return CGRect(x: isCapture ? 12 : 20 + width/2, y: bounds.height-494, width: width/2-8, height: 44)
            }
        }
        return components.map { item in
            simulatorToolboxFrame(row: item.row, column: item.column, columns: item.columns, span: item.span,
                                  in: bounds.size, lcd: retractionLCD, expanded: expanded)
        }
    }
    override func layout() {
        super.layout()
        guard bounds.width >= 72, bounds.height > 0 else { return }
        if inspectionPresentation {
            basicInspection.frame = CGRect(x: 12, y: bounds.height - 72, width: bounds.width - 24, height: 26)
            viewHierarchy.frame = CGRect(x: 0, y: 0, width: bounds.width, height: max(1, bounds.height - 44))
            browser.frame = CGRect(x: 0, y: 0, width: bounds.width, height: max(1, bounds.height - 44))
            section.frame = CGRect(x: 12, y: bounds.height - 38, width: max(1, bounds.width - 24), height: 28)
            if resultsSelected { reportBody.frame = CGRect(x: 12, y: 12, width: max(1, bounds.width - 24), height: max(1, bounds.height - 58)) }
        }
        let targets = frames()
        if transitioning && targets != animationTargets { animateFrames(targets) }
        for (index, item) in components.enumerated() {
            if !transitioning { item.glass.frame = targets[index] }
            item.glass.layoutSubtreeIfNeeded()
        }
        updateInteraction()
    }
    private func layout(_ control: NSControl, in bounds: CGRect) {
        let height = max(0, min(bounds.height - 8, control is SimulatorGesturePad ? 48 : 26))
        let inset: CGFloat = control is SimulatorGesturePad ? 4 : 10
        control.frame = CGRect(x: inset, y: (bounds.height - height) / 2, width: max(0, bounds.width - 2 * inset), height: height)
        control.needsDisplay = true
        if let label = inspectionLabels[control] {
            label.frame = CGRect(x: 10, y: bounds.height - 19, width: max(0, bounds.width - 20), height: 17)
            control.frame = CGRect(x: 10, y: 4, width: max(0, bounds.width - 20), height: 26)
        }
        if control === angle {
            let sliderHeight = min(24, max(0, (bounds.height - 6) / 2))
            let labelHeight = min(18, max(0, bounds.height - sliderHeight - 6))
            angle.controlSize = bounds.height < 52 ? .small : .regular
            angle.frame = CGRect(x: 10, y: 2, width: max(0, bounds.width - 20), height: sliderHeight)
            angleLabel.frame = CGRect(x: 12, y: bounds.height - 2 - labelHeight, width: max(0, bounds.width - 24), height: labelHeight)
        }
    }
    override func resizeSubviews(withOldSize oldSize: NSSize) {
        super.resizeSubviews(withOldSize: oldSize)
        needsLayout = true
    }
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard acceptsInput, bounds.contains(convert(point, from: superview)) else { return nil }
        return super.hitTest(point)
    }

    private func updateInteraction() {
        onAvailabilityChanged(busy || manualPending)
        for item in components {
            let visible = acceptsInput && !item.glass.isHidden && bounds.contains(item.glass.frame)
            item.glass.setAccessibilityHidden(!visible)
            item.control.setAccessibilityHidden(!visible)
            item.control.refusesFirstResponder = !visible
            let safeInspectionControl = !inspectionPresentation || actionNames[item.control] != "views"
            item.control.isEnabled = safeInspectionControl && visible && (actions[item.control] == nil || item.control is NSTextField || (!busy && !manualPending))
        }
    }

    func animateExpansion(_ open: Bool, animated: Bool, completion: @escaping () -> Void) {
        layoutSubtreeIfNeeded()
        expanded = open
        transitioning = true
        animationRequested = animated
        transitionCompletion = completion
        clipsToBounds = true
        report.close()
        updateInteraction()
        animateFrames(frames())
    }

    private func finishTransitionIfReady() {
        guard transitioning, animationCompleted, expanded || glassIsRetracted else { return }
        transitioning = false
        settlement?.cancel(); settlement = nil
        clipsToBounds = !expanded
        needsLayout = true
        updateInteraction()
        let completion = transitionCompletion
        transitionCompletion = nil
        completion?()
    }

    private func animateFrames(_ targets: [CGRect]) {
        settlement?.cancel()
        settlement = nil
        animationVersion += 1
        let version = animationVersion
        animationTargets = targets
        animationCompleted = false
        var remaining = components.count
        let finished = { [weak self] in
            guard let self, self.animationVersion == version else { return }
            remaining -= 1
            guard remaining == 0 else { return }
            self.animationCompleted = true
            // The AppKit bridge has no completion criterion parameter; check live rim bounds before hiding.
            self.finishTransitionIfReady()
        }
        let animate = animationRequested && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if #available(macOS 15, *), animate {
            // The native bridge can drop completion for a property retargeted during its initial
            // delay, leaving subpixel residuals forever. Settle once after the spring's response
            // envelope; generation checks and cancellation preserve every live reversal.
            let work = DispatchWorkItem { [weak self] in
                guard let self, self.animationVersion == version, self.transitioning else { return }
                for (i, item) in self.components.enumerated() { item.glass.frame = targets[i] }
                self.animationCompleted = true
                self.finishTransitionIfReady()
            }
            settlement = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.85, execute: work)
        }
        for (index, item) in components.enumerated() {
            if #available(macOS 15, *), animate, !item.glass.isHidden {
                let motion = SimulatorToolboxMotion(row: item.row, column: item.column)
                // Retarget the live native spring; assigning an endpoint first discards its position and velocity.
                NSAnimationContext.animate(.spring(duration: motion.duration, bounce: motion.bounce).delay(motion.delay)) {
                    item.glass.frame = targets[index]
                } completion: { finished() }
            } else {
                item.glass.frame = targets[index]
                item.glass.layoutSubtreeIfNeeded()
                finished()
            }
        }
    }

    func start(_ activity: SimulatorToolActivity) {
        if activity.inspectionRead && inspectionReadGeometry != nil { browser.beginRead() } else if activity.action != "axAction" { browser.invalidate() }
        viewHierarchy.invalidate()
        current = activity.id
        busy = true
        result.string = "응답 대기 중…"
        clearImages(); retryButton.isHidden = true; pasteRecovery.isHidden = true; status.menu = nil
        status.title = "사용 중 · " + activity.title
        argumentsLabel.stringValue = activity.source + " · " + activity.summary
        for item in components where actions[item.control] != nil {
            item.glass.tint = actionNames[item.control] == activity.action || actionNames[item.control] == activity.control ? .controlAccentColor : nil
        }
        updateInteraction()
    }
    @discardableResult func finish(_ activity: SimulatorToolActivity, response: [String: Any]) -> Bool {
        if current == nil { start(activity) }
        guard current == activity.id else { return false }
        busy = false
        if activity.source == "직접 조작" { manualPending = false }
        let failed = response["isError"] as? Bool == true
        if activity.inspectionRead, inspectionReadGeometry != nil {
            let data = (response["structuredContent"] as? [String: Any])?["inspection"] as? [String: Any]
            let message = (response["content"] as? [[String: Any]])?.compactMap { $0["text"] as? String }.joined(separator: "\n")
            inspectionScope = inspectionReadGeometry == inspectionGeometry && !failed ? data?["scope"] as? [String: Any] : nil
            browser.finishRead(inspectionReadGeometry == inspectionGeometry && !failed && inspectionScope != nil && (activity.action != "axSnapshot" || data?["axSnapshot"] is [String: Any]) ? data : nil,
                               error: failed ? message : inspectionScope == nil && inspectionReadGeometry == inspectionGeometry ? "대상 화면 정보를 확인하지 못했습니다. 새로 읽으세요." : "화면이 바뀌었습니다. 새로 읽으세요.")
            inspectionReadGeometry = nil
        }
        if activity.action == "axAction" { browser.finishAXAction(response) }
        if inspectionPresentation && !activity.inspectionRead && activity.action != "axAction" {
            let message = (response["content"] as? [[String: Any]])?.compactMap { $0["text"] as? String }.joined(separator: "\n") ?? ""
            browser.completeAction(failed: failed, message: message)
        }
        let state = failed ? "실패" : "응답 완료"
        status.title = state + " · " + activity.title
        history.insert(state + " · " + activity.source + " · " + activity.title, at: 0)
        history = Array(history.prefix(8))
        recent.stringValue = "최근 활동\n" + history.joined(separator: "\n")
        let content = response["content"] as? [[String: Any]] ?? []
        result.string = activity.action == "window" && !failed ? "LCD 창 열림" : content.compactMap { $0["text"] as? String }.joined(separator: "\n")
        clearImages()
        var imageLabel = "캡처 결과"
        for item in content {
            if let text = item["text"] as? String { imageLabel = String(text.suffix(300)); continue }
            guard item["type"] as? String == "image" else { continue }
            guard let encoded = item["data"] as? String, let data = Data(base64Encoded: encoded), let image = NSImage(data: data) else { continue }
            let picture = NSImageView()
            picture.image = image
            picture.imageScaling = .scaleProportionallyUpOrDown
            picture.setAccessibilityLabel(imageLabel)
            let caption = NSTextField(wrappingLabelWithString: imageLabel); caption.font = .systemFont(ofSize: 11)
            images.addArrangedSubview(caption)
            picture.heightAnchor.constraint(equalToConstant: 180).isActive = true
            images.addArrangedSubview(picture)
            picture.widthAnchor.constraint(equalTo: images.widthAnchor).isActive = true
        }
        for item in components {
            item.glass.tint = failed && item.control === status ? .systemRed : nil
        }
        updateInteraction()
        let menu = NSMenu()
        if failed && activity.source == "직접 조작" && lastManual != nil {
            let retry = NSMenuItem(title: "같은 입력으로 재시도", action: #selector(retryLast), keyEquivalent: "")
            retry.target = self
            menu.addItem(retry)
            if lastManual?["action"] as? String == "type" {
                let paste = NSMenuItem(title: "같은 글자 붙여넣기…", action: #selector(recoverTextInput), keyEquivalent: "")
                paste.target = self
                menu.addItem(paste)
            }
        }
        status.menu = menu
        retryButton.isHidden = !(failed && activity.source == "직접 조작" && lastManual != nil)
        pasteRecovery.isHidden = retryButton.isHidden || lastManual?["action"] as? String != "type"
        NSAccessibility.post(element: status, notification: .valueChanged)
        return true
    }
    func submitFromChrome(_ arguments: [String: Any]) { submit(arguments, fromChrome: true) }
    func showResponse() { showReport(status) }
    func showResponse(from anchor: NSView) {
        if report.isShown { report.close() }
        else {
            if resultsSelected { selectResults(false) }
            reportBody.frame = reportRoot.bounds
            if let screen = anchor.window?.screen { report.contentSize = CGSize(width: min(380, screen.visibleFrame.width-32), height: min(500, screen.visibleFrame.height-48)) }
            report.animates = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            if let onPresentReport { onPresentReport(report, anchor, result) }
            else { report.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .maxX) }
        }
    }
    private func submit(_ input: [String: Any], fromChrome: Bool = false) {
        var arguments = input
        if arguments["inspectionElement"] != nil && arguments["inspectionScope"] == nil { arguments["inspectionScope"] = inspectionScope }
        guard (fromChrome || acceptsInput), !busy, !manualPending else { return }
        if arguments["action"] as? String == "axSnapshot" || (arguments["action"] as? String == "describe" && arguments["inspection"] as? Bool == true) {
            inspectionReadGeometry = inspectionGeometry; browser.beginRead()
        }
        lastManual = arguments
        manualPending = true
        status.title = "대기 중 · 직접 조작"
        updateInteraction()
        onRun(arguments)
    }
    @objc private func execute(_ sender: NSControl) {
        guard acceptsInput, sender.isEnabled, !busy, !manualPending else { return }
        do {
            guard let arguments = try actions[sender]?() else { return }
            if let action = arguments["action"] as? String, ["views", "paste"].contains(action), !confirmAction(action) { return }
            submit(arguments)
        } catch { fail(error) }
    }
    private func fail(_ error: Error) {
        status.title = "입력 오류"
        result.string = error.localizedDescription
        argumentsLabel.stringValue = "미전송 · 입력 내용을 확인하세요"
        clearImages(); lastManual = nil; retryButton.isHidden = true; pasteRecovery.isHidden = true
        status.menu = nil
        if inspectionPresentation { selectResults(true) }
    }
    private func clearImages() { for child in images.arrangedSubviews { images.removeArrangedSubview(child); child.removeFromSuperview() } }
    @objc private func retryLast() { if let lastManual { submit(lastManual, fromChrome: true) } }
    @objc private func recoverTextInput() {
        guard !busy, !manualPending, let text = lastManual?["text"] as? String, !text.isEmpty, confirmAction("paste") else { return }
        submit(["action": "paste", "text": text], fromChrome: true)
    }
    @objc private func showReport(_ sender: NSButton) {
        guard sender.isEnabled else { return }
        if inspectionPresentation { selectResults(true); focusInspection() }
        else { showResponse(from: sender) }
    }
    private func configureReport() {
        retryButton.target = self; retryButton.action = #selector(retryLast); retryButton.isHidden = true
        pasteRecovery.target = self; pasteRecovery.action = #selector(recoverTextInput); pasteRecovery.isHidden = true
        continueResult.target = self; continueResult.action = #selector(continueInInspection)
        let stack = NSStackView(views: [continueResult, argumentsLabel, retryButton, pasteRecovery])
        result.string = "아직 응답이 없습니다. 검사나 기기 조작 후 여기에서 확인하세요."
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        result.isEditable = false
        result.isSelectable = true
        result.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        result.isVerticallyResizable = true
        result.isHorizontallyResizable = false
        result.textContainer?.widthTracksTextView = true
        result.setAccessibilityLabel("도구 응답")
        let textScroll = NSScrollView()
        textScroll.hasVerticalScroller = true
        textScroll.documentView = result
        textScroll.heightAnchor.constraint(equalToConstant: 220).isActive = true
        stack.addArrangedSubview(textScroll)
        images.orientation = .vertical
        images.alignment = .leading
        stack.addArrangedSubview(images)
        recent.font = .systemFont(ofSize: 11)
        stack.addArrangedSubview(recent)
        let scroll = NSScrollView(frame: CGRect(x: 0, y: 0, width: 380, height: 500))
        scroll.hasVerticalScroller = true
        scroll.documentView = stack
        stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([stack.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor, constant: -24),
                                     stack.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor, constant: 12),
                                     stack.topAnchor.constraint(equalTo: scroll.contentView.topAnchor, constant: 12)])
        for child in stack.arrangedSubviews { child.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
        let controller = NSViewController()
        reportBody = scroll
        scroll.autoresizingMask = [.width, .height]
        reportRoot.addSubview(scroll)
        controller.view = reportRoot
        report.contentViewController = controller
        report.behavior = .transient
    }
    private static func confirm(_ action: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = action == "views" ? "전면 앱을 잠시 정지하고 검사할까요?" : "기기에 붙여넣을까요?"
        alert.informativeText = action == "views" ? "UIView 검사 동안 앱이 약 20초간 멈춥니다." : "Mac과 부팅된 다른 기기의 클립보드에도 전달됩니다. iOS에서 붙여넣기 허용이 필요할 수 있습니다."
        alert.addButton(withTitle: "실행")
        alert.addButton(withTitle: "취소")
        return alert.runModal() == .alertFirstButtonReturn
    }
}

/// Browsing is read-only. Only the explicit tap button sends input to the guest.
final class SimulatorElementBrowser: NSView, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    var onSelection: (CGRect?) -> Void = { _ in }
    var onPickMode: (Bool) -> Void = { _ in }
    var onPress: ([String: Any], Int) -> Void = { _, _ in }
    var onRefresh: () -> Void = {}
    var onTap: ([String: Any], Int) -> Void = { _, _ in }
    var onAdvanced: (Bool) -> Void = { _ in }
    var onAXAction: ([String: Any]) -> Void = { _ in }
    var onOpen3D: () -> Void = {}
    private var axExpiry: DispatchWorkItem?
    private var axSnapshot: SimulatorAXUISnapshot?
    private var axNode: SimulatorAXUINode?
    private var axBinding: (capture: String, node: String)?
    private var axReceipt: String?
    private var axExpected: SimulatorAXScalar?
    private let valueDraft = NSTextField(string: "")
    private let axApply = NSButton(title: "값 적용", target: nil, action: nil)
    private let axRestore = NSButton(title: "이 변경 복원", target: nil, action: nil)
    private let axIncrement = NSButton(title: "증가", target: nil, action: nil)
    private let axDecrement = NSButton(title: "감소", target: nil, action: nil)
    private let axCustom = NSPopUpButton()
    private let axRunCustom = NSButton(title: "선택한 사용자 동작 실행", target: nil, action: nil)
    private let open3D = NSButton(title: "3D 뷰 검사…", target: nil, action: nil)
    private let target = NSTextField(wrappingLabelWithString: "현재 LCD · 전면 앱")
    private let state = NSTextField(wrappingLabelWithString: "화면 요소를 읽으려면 새로 읽기를 누르세요.")
    private let filter = NSSearchField()
    private let refresh = NSButton(title: "화면 요소 새로 읽기", target: nil, action: nil)
    private let pickButton = NSButton(title: "화면에서 선택", target: nil, action: nil)
    private let press = NSButton(title: "접근성 동작 실행 (AXPress)", target: nil, action: nil)
    private var picking = false
    var isPicking: Bool { picking }
    private let tap = NSButton(title: "선택한 위치 탭", target: nil, action: nil)
    private let advanced = NSButton(title: "전문 도구…", target: nil, action: nil)
    private let details = NSTextField(wrappingLabelWithString: "목록에서 요소를 선택하세요. 선택만으로 기기를 조작하지 않습니다.")
    private let table = NSTableView()
    private let scroll = NSScrollView()
    private var elements: [[String: Any]] = []
    private var visible: [[String: Any]] = []
    private var pid = 0
    private var fresh = false
    private var pending = false
    private var context = "현재 LCD"
    private let stack = NSStackView()
    override init(frame: NSRect) {
        super.init(frame: frame)
        refresh.target = self; refresh.action = #selector(readElements)
        tap.target = self; tap.action = #selector(tapSelection); tap.isEnabled = false
        pickButton.target = self; pickButton.action = #selector(togglePick); pickButton.isEnabled = false
        press.target = self; press.action = #selector(pressSelection); press.isEnabled = false
        advanced.target = self; advanced.action = #selector(toggleAdvanced)
        for (button, action) in [(axApply, #selector(applyAXValue)), (axRestore, #selector(restoreAXValue)), (axIncrement, #selector(incrementAX)), (axDecrement, #selector(decrementAX)), (axRunCustom, #selector(customAX)), (open3D, #selector(openAX3D))] { button.target = self; button.action = action }
        valueDraft.identifier = NSUserInterfaceItemIdentifier("axValueDraft")
        valueDraft.placeholderString = "적용할 값"
        axCustom.target = self; axCustom.action = #selector(selectCustomAX)
        disableAXControls()
        filter.placeholderString = "목록 필터 (선택 사항)"; filter.delegate = self
        filter.setAccessibilityLabel("읽은 화면 요소 필터")
        table.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("element")))
        table.headerView = nil; table.rowHeight = 46; table.delegate = self; table.dataSource = self
        table.allowsEmptySelection = true; table.setAccessibilityLabel("화면 요소 · 방향키로 선택")
        scroll.documentView = table; scroll.hasVerticalScroller = true
        let buttons = NSStackView(views: [refresh, pickButton]); buttons.spacing = 8
        let detailScroll = NSScrollView(); detailScroll.hasVerticalScroller = true
        detailScroll.documentView = details
        details.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([details.widthAnchor.constraint(equalTo: detailScroll.contentView.widthAnchor),
            details.leadingAnchor.constraint(equalTo: detailScroll.contentView.leadingAnchor),
            details.topAnchor.constraint(equalTo: detailScroll.contentView.topAnchor),
            detailScroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 40)])
        let detailHeight = detailScroll.heightAnchor.constraint(equalToConstant: 100); detailHeight.priority = .defaultHigh; detailHeight.isActive = true
        let execution = NSStackView(views: [tap, press]); execution.orientation = .vertical; execution.alignment = .leading; execution.spacing = 6
        let editStack = NSStackView(views: [execution, NSStackView(views: [axIncrement, axDecrement]), axCustom, axRunCustom, valueDraft, NSStackView(views: [axApply, axRestore]), open3D, advanced])
        editStack.orientation = .vertical; editStack.alignment = .leading; editStack.spacing = 6
        let edits = NSScrollView(); edits.hasVerticalScroller = true; edits.documentView = editStack
        editStack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([editStack.widthAnchor.constraint(equalTo: edits.contentView.widthAnchor), editStack.topAnchor.constraint(equalTo: edits.contentView.topAnchor), editStack.leadingAnchor.constraint(equalTo: edits.contentView.leadingAnchor), edits.heightAnchor.constraint(greaterThanOrEqualToConstant: 80)])
        let editHeight = edits.heightAnchor.constraint(equalToConstant: 160); editHeight.priority = .defaultHigh; editHeight.isActive = true
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 10
        for view in [target, buttons, filter, state, scroll, detailScroll, edits] { stack.addArrangedSubview(view) }
        addSubview(stack); stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),
            scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 100)])
        for view in [target, filter, state, scroll, detailScroll, edits] { view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
        target.font = .systemFont(ofSize: 13, weight: .semibold)
        for label in [target, state] { label.setContentCompressionResistancePriority(.required, for: .vertical) }
        filter.setContentCompressionResistancePriority(.required, for: .vertical)
        state.font = .systemFont(ofSize: 11); details.font = .systemFont(ofSize: 11)
        details.maximumNumberOfLines = 0
    }
    required init?(coder: NSCoder) { fatalError() }
    func suspendSelection() { endPick(); table.deselectAll(nil); onSelection(nil) }
    func endPick() {
        guard picking else { return }
        picking = false; pickButton.title = "화면에서 선택"; onPickMode(false)
    }
    @objc private func togglePick() {
        if picking { endPick(); return }
        guard fresh else { return }
        picking = true; pickButton.title = "화면 선택 종료 (Esc)"; onPickMode(true)
        state.stringValue = "LCD에서 위치를 고르세요. 터치를 보내지 않습니다. Esc로 종료합니다."
    }
    func pick(at point: CGPoint) {
        guard fresh, picking else { return }
        visible = elements.filter { row in
            CGRect(x: (row["x"] as? NSNumber)?.doubleValue ?? 0, y: (row["y"] as? NSNumber)?.doubleValue ?? 0,
                   width: (row["width"] as? NSNumber)?.doubleValue ?? 0, height: (row["height"] as? NSNumber)?.doubleValue ?? 0).contains(point)
        }.sorted { (($0["depth"] as? Int) ?? 0) > (($1["depth"] as? Int) ?? 0) }
        table.deselectAll(nil); table.reloadData()
        state.stringValue = visible.isEmpty ? "이 위치에 읽은 AX 요소가 없습니다. 새로 읽거나 다른 위치를 고르세요." : "이 위치의 AX 프레임 후보 \(visible.count)개 · 목록에서 직접 선택하세요."
        onSelection(nil) // Candidates always await an explicit list selection.
    }
    func completeAction(failed: Bool, message: String) {
        invalidate(failed ? "실행 실패 · " + message : "실행 완료 · 화면 요소를 새로 읽어 다음 대상을 선택하세요.")
    }
    func cancelRead() { pending = false; refresh.isEnabled = true; invalidate() }
    func focusList() { window?.makeFirstResponder(table) }
    func setContext(_ value: String) { guard context != value else { return }; context = value; target.stringValue = value + " · 전면 앱" }
    func invalidate(_ message: String = "화면이 바뀌었을 수 있습니다. 새로 읽고 선택하세요.") {
        axExpiry?.cancel(); axExpiry = nil
        pending = false; disableAXControls(); axBinding = nil; axReceipt = nil; axNode = nil
        fresh = false; endPick(); onSelection(nil); pickButton.isEnabled = false; press.isEnabled = false; table.deselectAll(nil); tap.isEnabled = false
        details.stringValue = "선택을 해제했습니다. 새로 읽고 목록에서 선택하세요."
        state.stringValue = message
    }
    func beginRead() { invalidate("화면 요소 읽는 중…"); pending = true; refresh.isEnabled = false }
    func finishRead(_ data: [String: Any]?, error: String?) {
        pending = false; refresh.isEnabled = true
        guard let data, let rows = data["elements"] as? [[String: Any]], let pid = (data["pid"] as? NSNumber)?.intValue else {
            elements = []; applyFilter(); invalidate(error ?? "요소를 읽지 못했습니다. 연결과 권한을 확인하고 다시 읽으세요."); return
        }
        axSnapshot = nil
        if let wire = data["axSnapshot"] as? [String: Any] {
            do { axSnapshot = try SimulatorAXUISnapshot(wire) }
            catch { elements = []; applyFilter(); invalidate("AX snapshot validation failed"); return }
        }
        self.pid = pid; elements = rows.filter { $0["offScreen"] as? Bool != true }
        target.stringValue = context + " · " + (data["app"] as? String ?? "전면 앱") + " · " + DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium) + "에 읽음"
        fresh = true; pickButton.isEnabled = true; applyFilter()
        if let snapshot = axSnapshot, let expiry = snapshot.expiresMonotonicNS {
            let work = DispatchWorkItem { [weak self] in
                guard let self, self.axSnapshot?.captureID == snapshot.captureID else { return }
                self.invalidate("expiredCapture · 캡처 보관 시간이 지났습니다. 새로 읽으세요.")
            }
            axExpiry = work
            DispatchQueue.main.asyncAfter(deadline: DispatchTime(uptimeNanoseconds: expiry), execute: work)
        }
    }
    private func name(_ row: [String: Any]) -> String {
        for key in ["label", "value", "identifier"] { if let value = row[key] as? String, !value.isEmpty { return value } }
        return "이름 없는 요소"
    }
    private func applyFilter() {
        disableAXControls(); axBinding = nil; axReceipt = nil; axNode = nil
        let query = filter.stringValue
        visible = elements
        if !query.isEmpty { visible = elements.filter { row in ["label", "value", "identifier", "role"].contains { (row[$0] as? String ?? "").localizedCaseInsensitiveContains(query) } } }
        table.deselectAll(nil); table.reloadData(); tap.isEnabled = false; press.isEnabled = false; onSelection(nil)
        state.stringValue = !fresh ? "이 목록은 이전 화면입니다. 새로 읽은 뒤 선택하세요." : elements.isEmpty ? "이 화면에서 접근성 요소를 얻지 못했습니다. 새로 읽거나 LCD를 직접 조작하세요." : visible.isEmpty ? "필터에 맞는 요소가 없습니다. 필터를 지워 보세요." : "화면 요소 \(visible.count)개 · 선택 후 위치를 확인하세요."
    }
    func controlTextDidChange(_ obj: Notification) { applyFilter() }
    func numberOfRows(in tableView: NSTableView) -> Int { visible.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let item = visible[row]
        let text = NSTextField(wrappingLabelWithString: String(repeating: "  ", count: min(6, item["depth"] as? Int ?? 0)) + name(item) + "\n" + (item["role"] as? String ?? "") + (item["inside"] as? Bool == true ? " · 화면 안" : " · 일부만 보임"))
        text.font = .systemFont(ofSize: 12); text.maximumNumberOfLines = 2
        return text
    }
    func tableViewSelectionDidChange(_ notification: Notification) {
        let index = table.selectedRow
        guard visible.indices.contains(index) else { disableAXControls(); axBinding = nil; axReceipt = nil; axNode = nil; tap.isEnabled = false; press.isEnabled = false; onSelection(nil); return }
        let row = visible[index]
        disableAXControls(); axBinding = nil; axReceipt = nil; axNode = nil
        let x = (row["x"] as? NSNumber)?.doubleValue ?? 0, y = (row["y"] as? NSNumber)?.doubleValue ?? 0
        let w = (row["width"] as? NSNumber)?.doubleValue ?? 0, h = (row["height"] as? NSNumber)?.doubleValue ?? 0
        details.stringValue = "✓ 선택: " + name(row) + "\n중심 \(Int(x+w/2)), \(Int(y+h/2))pt · 크기 \(Int(w))×\(Int(h))pt\n탭하면 현재 기기 화면을 조작합니다."
        let enabled = row["enabled"] as? Bool
        let actions = row["actions"] as? [String] ?? []
        details.stringValue += "\nID: " + (row["identifier"] as? String ?? "") + " · 값: " + (row["value"] as? String ?? "")
        details.stringValue += "\n활성: " + (enabled.map { $0 ? "예" : "아니요" } ?? "제공되지 않음")
        let unique = elements.filter { NSDictionary(dictionary: $0).isEqual(to: row) }.count == 1
        press.isEnabled = fresh && unique && !pending && enabled != false && actions.contains("AXPress")
        tap.isEnabled = fresh && unique && !pending && enabled != false && row["inside"] as? Bool == true && w > 0 && h > 0
        if !unique { details.stringValue += "\n동일한 속성의 요소가 여러 개여서 실행할 수 없습니다." }
        else if enabled == false { details.stringValue += "\n기기에서 비활성 상태로 제공한 요소입니다." }
        else if row["inside"] as? Bool != true { details.stringValue += "\n일부만 보이는 요소는 위치 탭을 보내지 않습니다." }
        if !actions.contains("AXPress") { details.stringValue += "\n이 요소는 AXPress를 제공하지 않습니다." }
        if let snapshot = axSnapshot, let id = row["nodeID"] as? String, let node = snapshot.nodes[id] {
            axNode = node; axExpected = node.value; axCustom.removeAllItems()
            axCustom.addItem(withTitle: "사용자 동작 선택…")
            axCustom.lastItem?.isEnabled = false
            for item in node.custom {
                axCustom.addItem(withTitle: item.name.text + " · " + item.handle)
                axCustom.lastItem?.representedObject = item.handle
            }
            axCustom.selectItem(at: 0)
            valueDraft.stringValue = node.value?.text ?? "값 제공 안 됨"
            valueDraft.isEnabled = fresh && node.operations.contains("setValue") && node.value != nil
            press.isEnabled = fresh && !pending && node.operations.contains("press")
            tap.isEnabled = false // Typed AX selection never grants HID authority.
            axIncrement.isEnabled = fresh && !pending && node.operations.contains("increment")
            axDecrement.isEnabled = fresh && !pending && node.operations.contains("decrement")
            axCustom.isEnabled = fresh && !pending && node.operations.contains("custom") && !node.custom.isEmpty
            axApply.isEnabled = fresh && !pending && valueDraft.isEnabled
            details.stringValue = snapshot.summary + "\nNode: " + node.id + "\nParent: " + (node.parent ?? "root") + "\nOrdered children: " + node.children.joined(separator: ", ")
            for key in node.fields.keys.sorted() { let field = node.fields[key]!; details.stringValue += "\n\(key): [\(field.status)] \(field.text)" }
            details.stringValue += "\n" + node.reasons.joined(separator: "\n")
            if node.value == nil { details.stringValue += "\n값 초안 사용 불가 · 값을 제공하지 않거나 보호 상태가 확인되지 않았습니다." }
        }
        onSelection(fresh ? CGRect(x: x, y: y, width: w, height: h) : nil)
        NSAccessibility.post(element: details, notification: .valueChanged)
    }
    @objc private func readElements() { onRefresh() }
    @objc private func pressSelection() {
        guard fresh, press.isEnabled, visible.indices.contains(table.selectedRow) else { return }
        if axSnapshot != nil { sendAX("press"); return }
        let row = visible[table.selectedRow]; invalidate("접근성 동작 실행 중…"); onPress(row, pid)
    }
    @objc private func tapSelection() {
        guard fresh, tap.isEnabled, visible.indices.contains(table.selectedRow) else { return }
        let row = visible[table.selectedRow]; invalidate("선택한 위치 탭 실행 중…"); onTap(row, pid)
    }
    private func disableAXControls() {
        for control in [axApply, axRestore, axIncrement, axDecrement, axRunCustom] { control.isEnabled = false }
        valueDraft.isEnabled = false; axCustom.isEnabled = false
    }
    private func sendAX(_ operation: String, extra: [String: Any] = [:]) {
        guard fresh, !pending, let snapshot = axSnapshot, let node = axNode,
              operation == "restore" ? axReceipt != nil : node.operations.contains(operation) else { return }
        var wire: [String: Any] = ["captureID": snapshot.captureID, "nodeID": node.id, "operation": operation]
        wire.merge(extra) { _, new in new }
        guard (try? SimulatorAXEnvelope(wire)) != nil else { state.stringValue = "값의 자료형 또는 동작 입력이 유효하지 않습니다."; return }
        axBinding = (snapshot.captureID, node.id); pending = true; disableAXControls(); press.isEnabled = false; tap.isEnabled = false
        state.stringValue = "AX 동작 응답 대기 중…"; onAXAction(wire)
    }
    func finishAXAction(_ response: [String: Any]) {
        guard let binding = axBinding, let snapshot = axSnapshot, let node = axNode,
              binding.capture == snapshot.captureID, binding.node == node.id else { return }
        pending = false
        let structured = response["structuredContent"] as? [String: Any]
        let result = structured?["axResult"] as? [String: Any]
        if let result {
            guard let returned = structured?["axBinding"] as? [String: Any], returned["captureID"] as? String == binding.capture, returned["nodeID"] as? String == binding.node else { return }
            state.stringValue = "AX: \(result["state"] ?? "unknown") · delivery: \(result["delivery"] ?? "unknown") · readback: \(result["readback"] ?? "unavailable")"
            axReceipt = result["restoreReceipt"] as? String
            if let wire = result["readback"] as? [String: Any] { axExpected = try? SimulatorAXScalar(wire) }
            axRestore.isEnabled = axReceipt != nil
        } else {
            state.stringValue = "AX 오류 · " + ((response["content"] as? [[String: Any]])?.compactMap { $0["text"] as? String }.joined(separator: "\n") ?? "응답 없음")
        }
        // No implicit retry or retarget after failure/staleness/uncertainty. Draft remains bound to this selection.
        fresh = false; axBinding = nil; refresh.isEnabled = true
    }
    @objc private func applyAXValue() {
        guard let expected = axExpected else { return }
        do { let value = try expected.draft(valueDraft.stringValue); sendAX("setValue", extra: ["expected": expected.wire, "value": value.wire]) }
        catch { state.stringValue = "자료형이 맞지 않습니다. boolean은 true 또는 false, number는 유한 수를 입력하세요." }
    }
    @objc private func restoreAXValue() {
        guard let receipt = axReceipt else { return }
        // Explicit receipt-bound restore is the sole action permitted after a delivered setter readback.
        fresh = true; sendAX("restore", extra: ["handle": receipt]); axReceipt = nil
    }
    @objc private func incrementAX() { sendAX("increment") }
    @objc private func decrementAX() { sendAX("decrement") }
    @objc private func selectCustomAX() {
        axRunCustom.isEnabled = fresh && !pending && axCustom.isEnabled &&
            axNode?.custom.contains(where: { $0.handle == axCustom.selectedItem?.representedObject as? String }) == true
    }
    @objc private func customAX() {
        guard axRunCustom.isEnabled, let node = axNode, let handle = axCustom.selectedItem?.representedObject as? String,
              node.custom.contains(where: { $0.handle == handle }) else { return }
        sendAX("custom", extra: ["handle": handle])
    }
    @objc private func openAX3D() { onOpen3D() }
    @objc private func toggleAdvanced() { onAdvanced(true) }
}

/// UIKit snapshots remain separate from AX elements and never enable guest actions.
final class SimulatorViewHierarchyBrowser: NSView, NSOutlineViewDataSource, NSOutlineViewDelegate {
    private final class Node: NSObject {
        let data: [String: Any]
        let children: [Node]
        init(_ data: [String: Any]) { self.data = data; children = (data["children"] as? [[String: Any]] ?? []).map(Node.init) }
    }
    var onCapture: () -> Void = {}
    private let capture = NSButton(title: "뷰 구조 캡처…", target: nil, action: nil)
    private let state = NSTextField(wrappingLabelWithString: "뷰 구조는 앱 내부의 UIKit 뷰 관계입니다. AX 요소 목록과 다르며 자동으로 캡처하지 않습니다.")
    private let target = NSTextField(wrappingLabelWithString: "현재 LCD · 전면 앱")
    private let properties = NSTextView()
    private let tree = NSOutlineView()
    private var roots: [Node] = []
    private var snapshot: [String: Any]?
    private var context = "현재 LCD"
    private var isStale = false
    override init(frame: NSRect) {
        super.init(frame: frame)
        capture.target = self; capture.action = #selector(captureViews)
        capture.isEnabled = false
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("view"))
        tree.addTableColumn(column); tree.outlineTableColumn = column; tree.headerView = nil
        tree.rowHeight = 26; tree.delegate = self; tree.dataSource = self
        tree.setAccessibilityLabel("캡처한 UIKit 뷰 구조 · 좌우 방향키로 펼치기와 접기")
        let scroll = NSScrollView(); scroll.documentView = tree; scroll.hasVerticalScroller = true
        properties.isEditable = false; properties.isSelectable = true; properties.font = .systemFont(ofSize: 12)
        properties.isVerticallyResizable = true; properties.isHorizontallyResizable = false
        properties.textContainer?.widthTracksTextView = true; properties.setAccessibilityLabel("선택한 뷰의 캡처 속성")
        let detail = NSScrollView(); detail.documentView = properties; detail.hasVerticalScroller = true
        detail.heightAnchor.constraint(equalToConstant: 170).isActive = true
        let stack = NSStackView(views: [target, capture, state, scroll, detail])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 10
        addSubview(stack); stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12), stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 12), stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),
            scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 80)])
        for view in [target, state, scroll, detail] { view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
        target.font = .systemFont(ofSize: 13, weight: .semibold); state.font = .systemFont(ofSize: 11)
        properties.string = "캡처 후 뷰를 선택하면 클래스·부모·형제 순서·제공된 속성을 확인할 수 있습니다."
    }
    required init?(coder: NSCoder) { fatalError() }
    func setContext(_ value: String) { guard context != value else { return }; context = value; target.stringValue = value + " · 전면 앱" }
    func setAvailability(_ allowed: Bool, reason: String) { capture.isEnabled = allowed; if !allowed { state.stringValue = reason } }
    func focusTree() { window?.makeFirstResponder(tree) }
    func beginCapture() { capture.isEnabled = false; invalidate(); state.stringValue = "뷰 구조 캡처 중 · 앱이 잠시 멈출 수 있습니다…" }
    func invalidate() {
        isStale = true
        if snapshot != nil { state.stringValue = "이전 캡처 · 현재 화면과 다를 수 있습니다. 새 캡처로 확인하세요." }
    }
    func finishCapture(_ snapshot: [String: Any]?, error: String?) {
        guard let snapshot, let data = snapshot["roots"] as? [[String: Any]] else {
            state.stringValue = "캡처 실패 · " + (error ?? "유효한 뷰 구조 응답이 없습니다."); return
        }
        self.snapshot = snapshot; roots = data.map(Node.init); isStale = false
        target.stringValue = context + " · pid " + String(describing: snapshot["pid"] ?? "?")
        state.stringValue = (snapshot["capturedAt"] as? String ?? "캡처 시점 미제공") + " · " + (roots.isEmpty ? "캡처한 창이 없습니다." : "캡처 당시 구조 · 현재 화면과 다를 수 있습니다.")
        tree.reloadData(); tree.expandItem(nil, expandChildren: false)
        properties.string = "뷰를 선택하세요. 화면 좌표 변환이 제공되지 않은 뷰는 LCD 강조를 표시하지 않습니다."
    }
    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int { (item as? Node)?.children.count ?? roots.count }
    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool { !(item as! Node).children.isEmpty }
    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any { ((item as? Node)?.children ?? roots)[index] }
    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        let row = (item as! Node).data
        let label = NSTextField(labelWithString: (row["className"] as? String ?? "클래스 미제공") + " · " + (row["id"] as? String ?? "ID 미제공"))
        label.font = .systemFont(ofSize: 12); return label
    }
    func outlineViewSelectionDidChange(_ notification: Notification) {
        guard let node = tree.item(atRow: tree.selectedRow) as? Node else { return }
        let row = node.data
        func value(_ key: String) -> String { guard let value = row[key], !(value is NSNull) else { return "제공되지 않음" }; return String(describing: value) }
        properties.string = "✓ " + value("className") + "\n캡처 내 ID: " + value("id") + "\n부모: " + value("parentID") + "\n형제 순서: " + value("siblingIndex")
        properties.string += "\nframe (superview points): " + value("frame") + "\nhidden: " + value("hidden") + " · alpha: " + value("alpha")
        properties.string += "\nAX ID: " + value("accessibilityIdentifier") + "\nAX label: " + value("accessibilityLabel")
        properties.string += "\nLCD 강조 불가 · 화면 좌표와 transform이 확인되지 않았습니다." + (isStale ? "\n이전 캡처입니다." : "")
        NSAccessibility.post(element: properties, notification: .valueChanged)
    }
    @objc private func captureViews() { onCapture() }
}
