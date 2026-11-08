import AppKit

/// One focus stop and one AX slider. Tick labels are painted hit regions, not
/// child controls. Values represent a draft; the owner decides how to apply it.
/// Lay out at least `minimumControlSize` to retain the 44-point input targets.
final class SimulatorHingeSlider: NSSlider {
    static let minimumControlSize = NSSize(width: 204, height: 92)
    static let majorAngles: [Double] = [0, 90, 180]

    var onDismiss: (() -> Void)?
    var onPreview: ((Double) -> Void)?
    var onCommit: ((Double) -> Void)?

    private struct PointerAdjustment {
        let originalValue: Double
        let horizontalOffset: CGFloat
    }
    private var pointerAdjustment: PointerAdjustment?
    var isAdjusting: Bool { pointerAdjustment != nil }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configure()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configure()
    }

    private func configure() {
        minValue = 0
        maxValue = 180
        numberOfTickMarks = 3
        allowsTickMarkValuesOnly = false
        altIncrementValue = 10
        isContinuous = true
        focusRingType = .exterior
        setAccessibilityElement(true)
        setAccessibilityLabel("접기 각도")
        setAccessibilityHelp("0~180도. 방향키 1도, Shift-방향키 10도. Home 0도, End 180도. Page Up/Down으로 주요 눈금 선택. 0·90·180도 눈금 클릭 또는 드래그로 1도 조절.")
    }

    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: 264, height: 92) }
    override var acceptsFirstResponder: Bool { isEnabled }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override var doubleValue: Double {
        get { super.doubleValue }
        set {
            let oldValue = super.doubleValue
            super.doubleValue = Self.normalizedAngle(newValue)
            needsDisplay = true
            if oldValue != super.doubleValue {
                NSAccessibility.post(element: self, notification: .valueChanged)
            }
        }
    }

    override var isEnabled: Bool {
        didSet {
            // A pending operation can disable the control during a callback.
            // Preserve the draft but never finish that interrupted gesture.
            if !isEnabled { pointerAdjustment = nil }
            needsDisplay = true
        }
    }

    static func normalizedAngle(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        return min(180, max(0, value.rounded()))
    }

    /// The two input rows never overlap. Free angle mapping deliberately ignores
    /// the large exact-tick targets in the lower row, even while dragging there.
    var trackInteractionRect: NSRect {
        NSRect(x: bounds.minX, y: bounds.minY, width: bounds.width, height: 44)
    }

    private var tickTargetWidth: CGFloat { min(68, bounds.width / 3) }
    private var trackStartX: CGFloat { bounds.minX + tickTargetWidth / 2 }
    private var trackEndX: CGFloat { bounds.maxX - tickTargetWidth / 2 }
    private var trackY: CGFloat { bounds.minY + 22 }

    func point(for angle: Double) -> NSPoint {
        NSPoint(x: trackStartX + CGFloat(Self.normalizedAngle(angle) / 180) * (trackEndX - trackStartX), y: trackY)
    }

    /// A continuous geometric mapping, rounded only to the nearest whole degree.
    /// In particular, 89 and 91 never magnetize to the 90-degree tick.
    func angle(for point: NSPoint) -> Double {
        guard point.x.isFinite, trackEndX > trackStartX else { return 0 }
        return Self.normalizedAngle(Double((point.x - trackStartX) / (trackEndX - trackStartX)) * 180)
    }

    func tickHitRect(for angle: Double) -> NSRect {
        guard Self.majorAngles.contains(angle) else { return .zero }
        return NSRect(x: point(for: angle).x - tickTargetWidth / 2,
                      y: bounds.minY + 44, width: tickTargetWidth, height: 48)
    }

    func exactTick(at point: NSPoint) -> Double? {
        Self.majorAngles.first { tickHitRect(for: $0).contains(point) }
    }

    private var thumbHitRect: NSRect {
        let center = point(for: doubleValue)
        return NSRect(x: center.x - 22, y: center.y - 22, width: 44, height: 44)
    }

    /// These three methods also permit deterministic, window-free input checks.
    /// Points use the control's local, flipped coordinate system.
    @discardableResult
    func beginAdjustment(at point: NSPoint) -> Bool {
        guard isEnabled, pointerAdjustment == nil,
              trackInteractionRect.contains(point) || exactTick(at: point) != nil else { return false }
        let original = doubleValue
        let tick = exactTick(at: point)
        let holdsThumb = tick == nil && thumbHitRect.contains(point)
        let initialValue = tick ?? (holdsThumb ? original : angle(for: point))
        let offset = (tick != nil || holdsThumb) ? point.x - self.point(for: initialValue).x : 0
        pointerAdjustment = PointerAdjustment(originalValue: original, horizontalOffset: offset)
        preview(initialValue)
        needsDisplay = true
        return true
    }

    func continueAdjustment(at point: NSPoint) {
        guard isEnabled, let adjustment = pointerAdjustment else { return }
        // No tick hit testing here: dragging through a tick's entire 44+ point
        // target still reaches each adjacent integer degree.
        preview(angle(for: NSPoint(x: point.x - adjustment.horizontalOffset, y: point.y)))
    }

    func endAdjustment() {
        guard isEnabled, pointerAdjustment != nil else { return }
        pointerAdjustment = nil
        needsDisplay = true
        onCommit?(doubleValue)
    }

    func cancelAdjustment() {
        guard let adjustment = pointerAdjustment else { return }
        pointerAdjustment = nil
        preview(adjustment.originalValue)
        needsDisplay = true
    }

    private func preview(_ value: Double) {
        let value = Self.normalizedAngle(value)
        guard doubleValue != value else { return }
        doubleValue = value
        onPreview?(doubleValue)
    }

    private func applyDiscreteValue(_ value: Double) {
        guard isEnabled, pointerAdjustment == nil else { return }
        let value = Self.normalizedAngle(value)
        guard value != doubleValue else { return }
        preview(value)
        if isEnabled { onCommit?(doubleValue) }
    }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        window?.makeFirstResponder(self)
        beginAdjustment(at: convert(event.locationInWindow, from: nil))
    }

    override func mouseDragged(with event: NSEvent) {
        continueAdjustment(at: convert(event.locationInWindow, from: nil))
    }

    override func mouseUp(with event: NSEvent) {
        guard pointerAdjustment != nil else { return }
        continueAdjustment(at: convert(event.locationInWindow, from: nil))
        endAdjustment()
    }

    override func cancelOperation(_ sender: Any?) {
        if pointerAdjustment != nil { cancelAdjustment() }
        else if let onDismiss { onDismiss() }
        else { super.cancelOperation(sender) }
    }

    override func resignFirstResponder() -> Bool {
        cancelAdjustment()
        needsDisplay = true
        return super.resignFirstResponder()
    }

    override func becomeFirstResponder() -> Bool {
        let result = super.becomeFirstResponder()
        needsDisplay = true
        return result
    }

    override func keyDown(with event: NSEvent) {
        guard isEnabled else { return }
        // Preserve system and owner shortcuts rather than consuming Command-arrow.
        guard event.modifierFlags.intersection([.command, .control, .option]).isEmpty else {
            super.keyDown(with: event)
            return
        }
        let step: Double = event.modifierFlags.contains(.shift) ? 10 : 1
        switch event.keyCode {
        case 53: cancelOperation(nil)
        case 36, 49: onCommit?(doubleValue) // Return/Space retries the exact retained draft.
        case 123, 125: applyDiscreteValue(doubleValue - step) // Left, Down
        case 124, 126: applyDiscreteValue(doubleValue + step) // Right, Up
        case 115: applyDiscreteValue(0) // Home
        case 119: applyDiscreteValue(180) // End
        case 116: applyDiscreteValue(Self.majorAngles.first { $0 > doubleValue } ?? 180)
        case 121: applyDiscreteValue(Self.majorAngles.last { $0 < doubleValue } ?? 0)
        default: super.keyDown(with: event) // Includes Tab and Escape.
        }
    }

    override func accessibilityRole() -> NSAccessibility.Role? { .slider }
    override func accessibilityOrientation() -> NSAccessibilityOrientation { .horizontal }
    override func accessibilityChildren() -> [Any]? { [] }
    override func accessibilityValue() -> Any? { NSNumber(value: doubleValue) }
    override func accessibilityMinValue() -> Any? { NSNumber(value: 0) }
    override func accessibilityMaxValue() -> Any? { NSNumber(value: 180) }
    override func accessibilityValueDescription() -> String? {
        let state: String
        switch doubleValue {
        case 0: state = " · 접힘"
        case 90: state = " · 직각"
        case 180: state = " · 펼침"
        default: state = ""
        }
        return "\(Int(doubleValue))도\(state)"
    }

    override func setAccessibilityValue(_ accessibilityValue: Any?) {
        guard let number = accessibilityValue as? NSNumber, number.doubleValue.isFinite else { return }
        if Self.normalizedAngle(number.doubleValue) == doubleValue { if isEnabled { onCommit?(doubleValue) } }
        else { applyDiscreteValue(number.doubleValue) }
    }

    override func accessibilityPerformPress() -> Bool {
        guard isEnabled else { return false }; onCommit?(doubleValue); return true
    }

    override func accessibilityPerformIncrement() -> Bool {
        guard isEnabled else { return false }
        applyDiscreteValue(doubleValue + 1)
        return true
    }

    override func accessibilityPerformDecrement() -> Bool {
        guard isEnabled else { return false }
        applyDiscreteValue(doubleValue - 1)
        return true
    }

    override func drawFocusRingMask() {
        NSBezierPath(roundedRect: bounds.insetBy(dx: 3, dy: 3), xRadius: 9, yRadius: 9).fill()
    }

    override var focusRingMaskBounds: NSRect { bounds }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        // Resolve semantic colors at draw time, including inactive/dark/high
        // contrast appearances. No translucent material or color-only selection.
        let foreground = isEnabled ? NSColor.labelColor : NSColor.disabledControlTextColor
        let secondary = isEnabled ? NSColor.secondaryLabelColor : NSColor.disabledControlTextColor
        let accent = isEnabled ? NSColor.controlAccentColor : NSColor.disabledControlTextColor
        let track = NSRect(x: trackStartX, y: trackY - 2, width: max(0, trackEndX - trackStartX), height: 4)
        NSColor.separatorColor.setFill()
        NSBezierPath(roundedRect: track, xRadius: 2, yRadius: 2).fill()
        let fill = NSRect(x: trackStartX, y: track.minY, width: max(0, point(for: doubleValue).x - trackStartX), height: 4)
        accent.setFill()
        NSBezierPath(roundedRect: fill, xRadius: 2, yRadius: 2).fill()

        for (index, angle) in Self.majorAngles.enumerated() {
            let selected = doubleValue == angle
            let rect = tickHitRect(for: angle)
            let x = point(for: angle).x
            let tick = NSBezierPath()
            tick.move(to: NSPoint(x: x, y: bounds.minY + 36))
            tick.line(to: NSPoint(x: x, y: bounds.minY + 43))
            tick.lineWidth = selected ? 2 : 1
            (selected ? accent : secondary).setStroke()
            tick.stroke()
            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = .center
            var attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 13, weight: selected ? .bold : .medium),
                .foregroundColor: selected ? accent : foreground,
                .paragraphStyle: paragraph
            ]
            if selected { attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue }
            ("\(Int(angle))°" as NSString).draw(in: NSRect(x: rect.minX, y: rect.minY + 5, width: rect.width, height: 20), withAttributes: attributes)
            attributes[.font] = NSFont.systemFont(ofSize: 10)
            attributes[.foregroundColor] = secondary
            attributes.removeValue(forKey: .underlineStyle)
            (["접기", "직각", "펼치기"][index] as NSString).draw(in: NSRect(x: rect.minX, y: rect.minY + 27, width: rect.width, height: 16), withAttributes: attributes)
        }

        let center = point(for: doubleValue)
        let knob = NSBezierPath(ovalIn: NSRect(x: center.x - 10, y: center.y - 10, width: 20, height: 20))
        NSColor.controlBackgroundColor.setFill()
        knob.fill()
        (pointerAdjustment != nil ? accent : foreground).setStroke()
        knob.lineWidth = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast ? 2 : 1
        knob.stroke()

        if window?.firstResponder === self {
            NSColor.keyboardFocusIndicatorColor.setStroke()
            let focus = NSBezierPath(roundedRect: bounds.insetBy(dx: 3, dy: 3), xRadius: 9, yRadius: 9)
            focus.lineWidth = 2
            focus.stroke()
        }
    }
}
