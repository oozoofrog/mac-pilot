import AppKit

/// One material per component, batched by the shared native container.
class SimulatorGlassView: NSView {
    enum Attachment { case none, top, right, bottom }
    let content: NSView
    private let materialContent = NSView()
    private let effect: NSView
    private let solid = NSView()
    private var solidMode = false
    var layoutContent: ((CGRect) -> Void)?
    var cornerRadius: CGFloat = 22 { didSet { updateStyle() } }
    var usesGlass = true { didSet { updateStyle() } }
    var drawsBorder = true { didSet { updateStyle() } }
    var tint: NSColor? { didSet { updateStyle() } }
    var attachment: Attachment = .none { didSet { if attachment != oldValue { needsLayout = true } } }
    // Bury the joining cap inside the common enclosure instead of leaving two
    // tangent capsules for the container to connect with a pinched neck.
    var materialFrame: CGRect {
        let overlap = cornerRadius + 4
        switch attachment {
        case .none: return bounds
        case .top: return CGRect(x: 0, y: -overlap, width: bounds.width, height: bounds.height + overlap)
        case .right: return CGRect(x: -overlap, y: 0, width: bounds.width + overlap, height: bounds.height)
        case .bottom: return CGRect(x: 0, y: 0, width: bounds.width, height: bounds.height + overlap)
        }
    }
    func containsVisiblePoint(_ point: CGPoint) -> Bool {
        bounds.contains(point) && NSBezierPath(roundedRect: materialFrame, xRadius: cornerRadius, yRadius: cornerRadius).contains(point)
    }

    init(content: NSView, interactive: Bool = true) {
        self.content = content
        materialContent.addSubview(content)
        if #available(macOS 26, *) {
            let glass = NSGlassEffectView()
            glass.style = .regular
            if #available(macOS 27, *) { glass.effectIsInteractive = interactive }
            glass.contentView = materialContent
            effect = glass
        } else {
            let material = NSVisualEffectView()
            material.material = .hudWindow
            material.blendingMode = .behindWindow
            material.state = .followsWindowActiveState
            material.addSubview(materialContent)
            effect = material
        }
        super.init(frame: .zero)
        wantsLayer = true
        clipsToBounds = false
        addSubview(effect)
        solid.wantsLayer = true
        addSubview(solid)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(updateStyle), name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
        setAccessibilityElement(false)
        updateStyle()
    }
    required init?(coder: NSCoder) { fatalError() }
    deinit { NSWorkspace.shared.notificationCenter.removeObserver(self) }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); updateStyle() }
    @objc private func updateStyle() {
        let radius = min(cornerRadius, min(bounds.width, bounds.height) / 2)
        let opaque = !usesGlass || NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
        let owningWindow = window
        let responder = owningWindow?.firstResponder as? NSView
        let focusOwner = ((responder as? NSTextView)?.delegate as? NSView) ?? responder
        let restore = solidMode != opaque && (focusOwner.map { $0 === content || $0.isDescendant(of: content) } ?? false)
        defer { if restore, let responder { owningWindow?.makeFirstResponder(responder) } }
        effect.isHidden = opaque
        solid.isHidden = !opaque
        if solidMode != opaque {
            solidMode = opaque
            if #available(macOS 26, *), let glass = effect as? NSGlassEffectView {
                glass.contentView = opaque ? nil : materialContent
            }
            if opaque { solid.addSubview(materialContent) }
            else if #available(macOS 26, *), effect is NSGlassEffectView {}
            else { effect.addSubview(materialContent) }
        }
        effectiveAppearance.performAsCurrentDrawingAppearance {
        solid.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        solid.layer?.cornerRadius = radius
        layer?.cornerRadius = attachment == .none ? radius : 0
        layer?.borderWidth = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast ? 2 : (drawsBorder ? 0.5 : 0)
        layer?.borderColor = NSColor.labelColor.withAlphaComponent(NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast ? 0.8 : 0.18).cgColor
        }
        if attachment != .none {
            // Setting a layer corner radius can re-enable AppKit clipping.
            // The material owns its outer corners; the wrapper must let the
            // joining cap reach underneath the body in solid fallback too.
            clipsToBounds = false
            layer?.masksToBounds = false
        }
        if #available(macOS 26, *), let glass = effect as? NSGlassEffectView {
            glass.cornerRadius = radius
            glass.tintColor = tint
        } else {
            effect.wantsLayer = true
            effect.layer?.cornerRadius = radius
            effect.layer?.masksToBounds = true
        }
    }
    override func resizeSubviews(withOldSize oldSize: NSSize) {
        super.resizeSubviews(withOldSize: oldSize)
        needsLayout = true
    }
    override func layout() {
        super.layout()
        let surface = materialFrame
        effect.frame = surface
        solid.frame = surface
        materialContent.frame = CGRect(origin: .zero, size: surface.size)
        content.frame = CGRect(x: -surface.minX, y: -surface.minY, width: bounds.width, height: bounds.height)
        updateStyle()
        layoutContent?(bounds)
    }
}

final class SimulatorLCDContentView: NSView {
    let lcd: NSView
    let tools: SimulatorToolboxView
    let deviceAppearance: SimulatorDeviceAppearance
    let body: SimulatorDeviceBodyView
    let chrome = SimulatorDeviceChrome()
    private let canvas = NSView()
    private let container: NSView
    private var transitioning = false
    private var turn: SimulatorContainerTurn?
    private var turnPrepared = false
    fileprivate(set) var rotationPresentationAngle: CGFloat = 0
    var rotationPresentationDidEnd: (() -> Void)?
    var rotationPresentationActive: Bool { turn?.active == true || turnPrepared }
    private(set) var rotationChromeSuppressed = false
    private var chromeVisibilityGeneration: UInt64 = 0
    var reduceMotionOverride: Bool?
    fileprivate func suppressRotationChrome(_ hidden: Bool, animated: Bool = false) {
        chromeVisibilityGeneration &+= 1
        let generation = chromeVisibilityGeneration
        let groups: [NSView] = [chrome.handle, chrome.controls, chrome.rail, chrome.resize]
        if hidden {
            rotationChromeSuppressed = true
            chrome.presentationSuppressed = true
            if let responder = window?.firstResponder as? NSView,
               groups.contains(where: { responder === $0 || responder.isDescendant(of:$0) }) {
                window?.makeFirstResponder(nil)
            }
            for group in groups {
                group.layer?.removeAnimation(forKey:"opacity")
                group.alphaValue = 0
                group.setAccessibilityHidden(true)
            }
        } else {
            let finish = { [weak self] in
                guard let self, self.chromeVisibilityGeneration == generation else { return }
                self.rotationChromeSuppressed = false
                self.chrome.presentationSuppressed = false
                for group in groups { group.alphaValue = 1; group.setAccessibilityHidden(false) }
            }
            if animated {
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.12
                    context.timingFunction = CAMediaTimingFunction(name:.easeOut)
                    for group in groups { group.animator().alphaValue = 1 }
                } completionHandler: { finish() }
            } else { finish() }
        }
    }

    func prepareRotationPresentation() {
        chrome.closePopovers()
        if turn == nil { turn = SimulatorContainerTurn(self) }
        turnPrepared = turn?.prepare() == true
        if !turnPrepared { suppressRotationChrome(false) }
    }
    func animateRotationPresentation(signedQuarterTurns: Int) {
        guard turnPrepared else { return }
        turnPrepared = false
        turn?.start(signedQuarterTurns: signedQuarterTurns, reduceMotion: reduceMotionOverride ?? NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
    }
    func cancelRotationPresentation() { turnPrepared = false; turn?.cancel(); suppressRotationChrome(false) }

    var screen = CGSize(width: 1, height: 1)
    var screenCornerFraction: CGFloat = 0.08
    var externalToolbar = false
    var toolsVisible = false
    var focused = false
    var lcdSizeLimit: CGSize?
    var opaqueFrames: [CGRect] {
        var frames = [body.frame]
        if NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency {
            frames += [chrome.handle.frame] + (focused || externalToolbar ? [] : [chrome.controls.frame, chrome.rail.frame])
            frames += !externalToolbar && !tools.isHidden ? tools.clippedGlassFrames.map { tools.convert($0, to: self) } : []
        }
        return frames
    }

    init(lcd: NSView, tools: SimulatorToolboxView, appearance: SimulatorDeviceAppearance) {
        self.lcd = lcd
        self.tools = tools
        self.deviceAppearance = appearance
        body = SimulatorDeviceBodyView()
        body.content.addSubview(lcd)
        if #available(macOS 26, *) {
            let glass = NSGlassEffectContainerView()
            glass.spacing = 12
            glass.contentView = canvas
            container = glass
        } else { container = canvas }
        super.init(frame: lcd.frame)
        clipsToBounds = false
        addSubview(container)
        canvas.addSubview(tools)
        for view in [chrome.handle, chrome.controls, chrome.rail, body, chrome.resize] { canvas.addSubview(view) }
        tools.isHidden = true
        NSWorkspace.shared.notificationCenter.addObserver(self,selector:#selector(motionPreferenceChanged),name:NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,object:nil)
    }
    deinit { NSWorkspace.shared.notificationCenter.removeObserver(self) }
    @objc private func motionPreferenceChanged() {
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion { cancelRotationPresentation() }
    }
    required init?(coder: NSCoder) { fatalError() }

    func animateTools(_ expanded: Bool, animated: Bool = true, completion: @escaping () -> Void) {
        if externalToolbar || tools.superview !== canvas {
            toolsVisible = expanded
            completion()
            return
        }
        if let responder = window?.firstResponder as? NSView,
           responder.isDescendant(of: tools) || responder === tools || responder === window?.fieldEditor(false, for: nil) {
            window?.makeFirstResponder(lcd)
        }
        toolsVisible = expanded
        tools.isHidden = false
        transitioning = true
        needsLayout = true
        layoutSubtreeIfNeeded()
        tools.animateExpansion(expanded, animated: animated) { [weak self] in
            guard let self, self.toolsVisible == expanded else { return }
            self.transitioning = false
            self.tools.isHidden = !expanded
            completion()
        }
    }

    /// Ignore the transparent envelope; visible components alone can receive pointer events.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let p = convert(point, from: superview)
        guard !rotationPresentationActive, bounds.contains(p) else { return nil }
        let children: [NSView] = externalToolbar ? [chrome.resize, chrome.handle, body] : [chrome.resize, chrome.handle, chrome.controls, chrome.rail, body, tools]
        for child in children where !child.isHidden && child.isDescendant(of: self) {
            if rotationChromeSuppressed && child !== body { continue }
            let local = child.convert(p, from: self)
            if child === tools {
                guard tools.clippedGlassFrames.contains(where: { $0.contains(local) }) else { continue }
            } else {
                if let glass = child as? SimulatorGlassView {
                    guard glass.containsVisiblePoint(local) else { continue }
                } else {
                    let radius = child.layer?.cornerRadius ?? 0
                    guard NSBezierPath(roundedRect: child.bounds, xRadius: radius, yRadius: radius).contains(local) else { continue }
                }
            }
            return child.hitTest(child.superview!.convert(p, from: self))
        }
        return nil
    }
    override func resizeSubviews(withOldSize oldSize: NSSize) {
        super.resizeSubviews(withOldSize: oldSize)
        needsLayout = true
    }
    override func layout() {
        super.layout()
        container.frame = bounds
        canvas.frame = bounds
        let geometry = simulatorDeviceLayout(in: bounds.size, screen: screen, bezel: deviceAppearance.bezel, toolsVisible: !externalToolbar && tools.superview === canvas && (toolsVisible || transitioning), focused: focused, lcdSizeLimit: lcdSizeLimit, externalToolbar: externalToolbar, actionCount: chrome.visibleActionCount)
        body.frame = geometry.body
        body.cornerRadius = min(geometry.lcd.width, geometry.lcd.height) * screenCornerFraction + deviceAppearance.bezel
        let attached = !externalToolbar && !toolsVisible && !transitioning
        for group in [chrome.handle, chrome.controls, chrome.rail] { group.drawsBorder = !attached }
        chrome.handle.attachment = attached ? .top : .none
        chrome.controls.attachment = attached ? .right : .none
        chrome.rail.attachment = attached ? .bottom : .none
        body.usesGlass = chrome.handle.usesGlass
        chrome.handle.frame = geometry.handle
        if !externalToolbar {
            chrome.controls.frame = geometry.controls
            chrome.controls.isHidden = focused
            chrome.rail.frame = geometry.rail
            chrome.rail.isHidden = focused
        }
        chrome.resize.frame = geometry.resize
        chrome.resize.isHidden = focused
        lcd.wantsLayer = true
        lcd.layer?.cornerRadius = min(geometry.lcd.width, geometry.lcd.height) * screenCornerFraction
        lcd.layer?.masksToBounds = true
        body.layoutSubtreeIfNeeded()
        lcd.frame = CGRect(origin: CGPoint(x: deviceAppearance.bezel, y: deviceAppearance.bezel), size: geometry.lcd.size)
        if !externalToolbar && tools.superview === canvas {
            tools.frame = geometry.tools
            tools.retractionLCD = tools.convert(geometry.lcd, from: self)
        }
        if #available(macOS 26, *), let glass = container as? NSGlassEffectContainerView { glass.spacing = attached ? 12 : 0 }
    }
}

/// A shared glass enclosure with an opaque interior, never a translucent LCD.
/// The enclosure and toolbars merge in their common NSGlassEffectContainerView;
/// placing the LCD inside the effect's contentView keeps it above that material.
final class SimulatorDeviceBodyView: SimulatorGlassView {
    private let interior = NSView()
    private let orientationMark = NSView()
    var orientationQuarterTurns = 0 { didSet { needsLayout = true } }

    init(frame: CGRect = .zero) {
        super.init(content: NSView(), interactive: false)
        self.frame = frame
        drawsBorder = false
        interior.wantsLayer = true
        interior.layer?.backgroundColor = NSColor(white: 0.075, alpha: 1).cgColor
        content.addSubview(interior)
        orientationMark.wantsLayer = true
        orientationMark.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.72).cgColor
        orientationMark.layer?.cornerRadius = 1.5
        orientationMark.setAccessibilityElement(false)
        content.addSubview(orientationMark)

        // Retain opaque coverage for capture/occlusion and fallback modes.
        layer?.backgroundColor = NSColor(white: 0.075, alpha: 1).cgColor
    }
    required init?(coder: NSCoder) { fatalError() }
    override func layout() {
        super.layout()
        interior.frame = bounds.insetBy(dx: 3, dy: 3)
        interior.layer?.cornerRadius = max(0, cornerRadius - 3)
        effectiveAppearance.performAsCurrentDrawingAppearance { orientationMark.layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.75).cgColor }
        switch (orientationQuarterTurns % 4 + 4) % 4 {
        case 1: orientationMark.frame = CGRect(x:bounds.maxX-4,y:bounds.midY-9,width:3,height:18)
        case 2: orientationMark.frame = CGRect(x:bounds.midX-9,y:1,width:18,height:3)
        case 3: orientationMark.frame = CGRect(x:1,y:bounds.midY-9,width:3,height:18)
        default: orientationMark.frame = CGRect(x:bounds.midX-9,y:bounds.maxY-4,width:18,height:3)
        }

    }
}

/// A presentation-only turn of the body within the common glass hierarchy. Model geometry,
/// capture and guest AX commit immediately; moving pixels never become input coordinates.
/// Attached controls retain their layout space while suppressed. One window covers swept corners.
private final class SimulatorContainerTurn {
    weak var content: SimulatorLCDContentView?
    private let stage = NSView()
    private let outgoing = CALayer()
    private let incoming = CALayer()
    private var timer: Timer?
    private var finalFrame: CGRect = .zero
    private var finalSize: CGSize = .zero
    private var imageSize: CGSize = .zero
    private var originalBody: CGRect = .zero
    private var originCenter: CGPoint = .zero
    private var targetCenter: CGPoint = .zero
    private var currentCenter: CGPoint = .zero
    private var fromScale: CGFloat = 1
    private var targetScale: CGFloat = 1
    private var currentScale: CGFloat = 1
    private var fromAngle: CGFloat = 0
    private var targetAngle: CGFloat = 0
    private(set) var angle: CGFloat = 0
    private var start: TimeInterval = 0
    private var reduced = false
    private var duration: TimeInterval = 0.46
    private var staging = false
    var active: Bool { timer != nil || staging }

    init(_ content: SimulatorLCDContentView) {
        self.content = content
        stage.wantsLayer = true
        stage.layer?.addSublayer(outgoing)
        stage.layer?.addSublayer(incoming)
        outgoing.contentsGravity = .resize
        incoming.contentsGravity = .resize
    }
    deinit { timer?.invalidate() }

    private func snapshot(_ content: NSView) -> CGImage? {
        content.layoutSubtreeIfNeeded()
        guard let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds) else { return nil }
        content.cacheDisplay(in: content.bounds, to: bitmap)
        return bitmap.cgImage
    }
    /// Called before changing model geometry, on the main thread after successful delivery.
    func prepare() -> Bool {
        guard let content, let window = content.window, window.isVisible else { return false }
        content.suppressRotationChrome(true)
        if active {
            // Keep the sampled angle/scale and the original united image. No queued animations.
            tick()
            if !active { return prepare() }
            timer?.invalidate(); timer = nil
            restore()
            fromAngle = angle; fromScale = currentScale; originCenter = currentCenter
            return true
        }
        guard let image = snapshot(content.body) else { return false }
        outgoing.contents = image
        imageSize = content.body.bounds.size
        originalBody = content.body.bounds
        originCenter = window.convertPoint(toScreen: content.body.convert(CGPoint(x:originalBody.midX,y:originalBody.midY),to:nil))
        currentCenter = originCenter
        angle = 0; fromAngle = 0; targetAngle = 0
        currentScale = 1; fromScale = 1
        return true
    }
    func start(signedQuarterTurns: Int, reduceMotion: Bool) {
        guard let content, let window = content.window, outgoing.contents != nil else { return }
        finalFrame = window.frame; finalSize = content.bounds.size
        let body = content.body.convert(content.body.bounds,to: content)
        targetCenter = window.convertPoint(toScreen: content.convert(CGPoint(x: body.midX,y: body.midY),to: nil))
        targetAngle += -CGFloat(signedQuarterTurns) * .pi / 2
        // Discard complete revolutions under a burst, retaining the latest direction and pose.
        while targetAngle - angle > 2 * .pi { targetAngle -= 2 * .pi }
        while targetAngle - angle < -2 * .pi { targetAngle += 2 * .pi }
        let odd = Int((targetAngle / (.pi / 2)).rounded()).magnitude % 2 == 1
        targetScale = min(body.width / max(1, odd ? originalBody.height : originalBody.width),
                          body.height / max(1, odd ? originalBody.width : originalBody.height))
        incoming.contents = snapshot(content.body)
        reduced = reduceMotion
        duration = reduced ? 0.14 : 0.46
        let radius = hypot(max(originalBody.midX,imageSize.width-originalBody.midX),
                           max(originalBody.midY,imageSize.height-originalBody.midY)) * max(fromScale,targetScale)
        let sweep = CGRect(x: min(originCenter.x,targetCenter.x)-radius,y: min(originCenter.y,targetCenter.y)-radius,
                           width: abs(targetCenter.x-originCenter.x)+radius*2,height: abs(targetCenter.y-originCenter.y)+radius*2)
        let visible = window.screen?.visibleFrame ?? sweep
        let envelope = reduced ? finalFrame.union(CGRect(x: originCenter.x-originalBody.midX,y: originCenter.y-originalBody.midY,width:imageSize.width,height:imageSize.height)) : sweep.union(finalFrame)
        let fitted = envelope.intersection(visible)
        staging = true
        window.contentView = stage
        window.setFrame(fitted, display: false)
        stage.frame = CGRect(origin: .zero,size: window.contentRect(forFrameRect:fitted).size)
        stage.addSubview(content)
        content.frame = CGRect(origin: CGPoint(x: finalFrame.minX-fitted.minX,y: finalFrame.minY-fitted.minY),size: finalSize)
        content.isHidden = true
        content.setAccessibilityHidden(true)
        CATransaction.begin(); CATransaction.setDisableActions(true)
        outgoing.bounds = CGRect(origin:.zero,size:imageSize)
        outgoing.anchorPoint = CGPoint(x:originalBody.midX/imageSize.width,y:originalBody.midY/imageSize.height)
        incoming.frame = content.body.convert(content.body.bounds,to:content).offsetBy(dx:content.frame.minX,dy:content.frame.minY)
        incoming.opacity = 0
        CATransaction.commit()
        start = ProcessInfo.processInfo.systemUptime
        timer = Timer(timeInterval:1.0/60,repeats:true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(timer!,forMode:.common)
        tick()
    }
    private func tick() {
        guard let content, let window = stage.window else { cancel(); return }
        let p = min(1,max(0,(ProcessInfo.processInfo.systemUptime-start)/duration))
        let movement = reduced ? p : min(1,p/0.8)
        let t = CGFloat(movement*movement*(3-2*movement))
        angle = fromAngle + (targetAngle-fromAngle)*t
        currentScale = fromScale + (targetScale-fromScale)*t
        currentCenter = CGPoint(x:originCenter.x+(targetCenter.x-originCenter.x)*t,y:originCenter.y+(targetCenter.y-originCenter.y)*t)
        let pivot = stage.convert(window.convertPoint(fromScreen:currentCenter),from:nil)
        // Only the swept middle may need shrinking near a display edge. Endpoints match
        // their actual model frames; no offscreen corners or sudden endpoint resizing.
        let a = reduced ? 0 : angle
        let c = abs(cos(a)), s = abs(sin(a))
        let extentX = (imageSize.width*c+imageSize.height*s)*currentScale/2
        let extentY = (imageSize.width*s+imageSize.height*c)*currentScale/2
        let fit = min(1,stage.bounds.width/max(1,extentX*2),stage.bounds.height/max(1,extentY*2))
        let scale = currentScale * (1-(1-fit)*sin(.pi*t))
        CATransaction.begin(); CATransaction.setDisableActions(true)
        outgoing.position = pivot
        outgoing.setAffineTransform(CGAffineTransform(rotationAngle:a).scaledBy(x:scale,y:scale))
        // Only the body/LCD/physical-top mark enter the rotation images. Chrome is
        // suppressed without changing geometry and returns after the last stable layout.
        let blend = reduced ? CGFloat(p) : max(0,(CGFloat(p)-0.8)/0.2)
        outgoing.opacity = Float(1-blend); incoming.opacity = Float(blend)
        CATransaction.commit()
        content.rotationPresentationAngle = angle
        if p >= 1 { cancel(restoreChromeAnimated:true) }
    }
    private func restore() {
        guard let content, let window = stage.window else { return }
        content.removeFromSuperview()
        window.contentView = content
        window.setFrame(finalFrame,display:false)
        content.frame = CGRect(origin:.zero,size:finalSize)
        content.isHidden = false
        content.setAccessibilityHidden(false)
        content.needsLayout = true
        content.layoutSubtreeIfNeeded()
        staging = false
    }
    func cancel(restoreChromeAnimated: Bool = false) {
        timer?.invalidate(); timer = nil
        restore()
        staging = false
        outgoing.contents = nil; incoming.contents = nil
        content?.suppressRotationChrome(false,animated:restoreChromeAnimated)
        content?.rotationPresentationDidEnd?()
    }
}
