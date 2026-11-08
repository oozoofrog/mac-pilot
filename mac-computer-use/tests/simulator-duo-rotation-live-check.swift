import AppKit
import XPC

private struct DuoRotationFailure: Error { let message: String }
private func duoWork<T>(_ work: @escaping () throws -> T) async throws -> T {
    try await withCheckedThrowingContinuation { continuation in
        handleQueue.async { continuation.resume(with: Result(catching: work)) }
    }
}
@MainActor private func duoPause() async { try? await Task.sleep(nanoseconds: 100_000_000) }
@MainActor private func duoRequire(_ value: Bool, _ message: String) throws {
    guard value else { throw DuoRotationFailure(message: message) }
    print("PASS " + message); fflush(stdout)
}
@MainActor private func duoDescendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(duoDescendants) }

@MainActor private func duoRotationRun(id: String, output: URL) async throws {
    let desktop = CGSessionCopyCurrentDictionary() as? [String: Any] ?? [:]
    try duoRequire(desktop["CGSSessionScreenIsLocked"] as? Bool != true && CGDisplayIsAsleep(CGMainDisplayID()) == 0, "Unlocked awake desktop")
    // Every guest/host combination, including host rot0 with a rotated guest.
    for guest in ["rot0", "rot90", "rot180", "rot270"] {
        for host in ["rot0", "rot90", "rot180", "rot270"] {
            let shown = ActiveScreen(id: "fixture", name: "fixture", target: 7, unrotated: CGSize(width: 466, height: 678),
                                     rotation: host, framebufferRotation: guest)
            var raw = shown; raw.rotation = guest; raw.framebufferRotation = nil
            let rectangle = CGRect(x: 31, y: 57, width: 93, height: 137)
            try duoRequire(shown.presentingGuestFrame(raw.shown(rectangle)) == shown.shown(rectangle),
                           "Guest/host AX transform composition \(guest) → \(host)")
            for point in [CGPoint(x: 17, y: 37), CGPoint(x: 249, y: 379)] {
                let transformed = shown.shown(CGRect(origin: point, size: .zero)).origin
                let restored = shown.normalized(transformed)
                try duoRequire(abs(restored.x * 466 - point.x) < 0.001 && abs(restored.y * 678 - point.y) < 0.001,
                               "Digitizer transform inverse \(guest) → \(host)")
            }
        }
    }
    let device = try await duoWork { try bootedDevice(id) }
    let initial = try await duoWork { try activeScreen(of: device) }
    try duoRequire(initial?.foldable == true, "Explicit claimed device has two integrated displays")
    let angle = try await duoWork { try hingeAngle(of: device) }
    let initialApp = try await duoWork { try simulatorFrontPid(device) }
    print("ORIGINAL guestPID=\(initialApp) hinge=\(angle)"); fflush(stdout)
    func command(_ arguments: [String: Any]) async throws -> [String: Any] {
        let result = try await duoWork {
            try executeSimulatorCommand(arguments, device: device, activity: SimulatorToolActivity(arguments: arguments, source: "Duo regression"))
        }
        if let degrees = arguments["degrees"] as? Double {
            var verified = false
            for _ in 0..<40 {
                let value = try await duoWork { try hingeAngle(of: device) }
                let raw = try await duoWork { displays(of: id).flatMap(SimulatorRotationObservation.read) }
                if simulatorHingeAlreadySatisfied(target: degrees, angle: value, primary: raw?.primary) { verified = true; break }
                await duoPause()
            }
            try duoRequire(verified, "Observed requested hinge and active display after delivered response")
        } else if let target = (arguments["orientation"] as? String).flatMap(SimulatorOrientation.init(rawValue:)) {
            var verified = false
            for _ in 0..<40 {
                let raw = try await duoWork { displays(of: id).flatMap(SimulatorRotationObservation.read) }
                if raw?.primary == true || raw?.inferredOrientation == target { verified = true; break }
                await duoPause()
            }
            try duoRequire(verified, "Observed guest response separately from local delivery")
        }
        return result
    }
    func observation() async throws -> SimulatorRotationObservation {
        try await duoWork {
            guard let value = displays(of: id).flatMap(SimulatorRotationObservation.read) else {
                throw DuoRotationFailure(message: "Active display unavailable")
            }
            return value
        }
    }
    // Establish the original physical pose on the inner display before any rotation.
    // Closed-cover orientation get/info values are not authoritative.
    var originalPose: SimulatorOrientation?
    var pendingFailure: Error?
    var open: SimulatorWindow?
    do {
        _ = try await command(["action":"hinge", "degrees":180.0])
        let unfolded = try await observation()
        try duoRequire(!unfolded.primary && unfolded.inferredOrientation != nil, "Original pose observed on unfolded inner LCD")
        originalPose = unfolded.inferredOrientation!
        let restoration: [String: Any] = ["orientation": originalPose!.rawValue, "degrees": angle]
        try JSONSerialization.data(withJSONObject: restoration, options: [.prettyPrinted]).write(to: output.appendingPathComponent("restore.json"))
        _ = try await command(["action":"rotate", "orientation":"portrait"])
        _ = try await command(["action":"hinge", "degrees":0.0])
        let closed = try await duoWork { try activeScreen(of: device) }
        var lcd = SimulatorWindow(device: device, active: closed); open = lcd; simulatorWindows[id] = lcd
        bringSimulatorWindowToFront(lcd)
        for _ in 0..<5 { await duoPause() }
        var button = duoDescendants(lcd.content.chrome.controls).compactMap { $0 as? NSButton }.first { $0.title == "회전" }!
        var feedback = duoDescendants(lcd.content.chrome.rail).compactMap { $0 as? NSTextField }.first { $0.accessibilityLabel() == "시뮬레이터 조작 결과" }!
        var emitted = 0
        func observeActions() {
            let native = lcd.content.chrome.onRun
            lcd.content.chrome.onRun = { arguments in
                emitted += 1
                print("TOOLBAR_ACTION \(arguments)"); fflush(stdout)
                native(arguments)
            }
        }
        observeActions()
        func click(_ target: SimulatorOrientation, closed: Bool) async throws {
            try duoRequire(NSApp.isActive && lcd.window.isKeyWindow, "Foreground guard before actual AppKit rotation action")
            try duoRequire(button.isEnabled, "Rotation button ready")
            let count = emitted
            lcd.content.layoutSubtreeIfNeeded()
            let point = button.convert(CGPoint(x: button.bounds.midX, y: button.bounds.midY), to: nil)
            let hit = lcd.content.hitTest(lcd.content.convert(point, from: nil))
            try duoRequire(hit === button || hit?.isDescendant(of: button) == true, "Actual rotation hit region reaches button")
            func event(_ type: NSEvent.EventType) -> NSEvent {
                NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: lcd.window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1)!
            }
            let beforeSize = lcd.view.shownPoints
            let beforeRotation = lcd.view.rotation
            let captureName = "\(closed ? "closed" : "open")-\(target.rawValue)"
            _ = shell("/usr/sbin/screencapture", ["-x", "-o", "-l", String(lcd.window.windowNumber), output.appendingPathComponent(captureName + "-before.png").path], timeout: 5)
            NSApp.postEvent(event(.leftMouseUp), atStart: true)
            lcd.window.sendEvent(event(.leftMouseDown))
            button.performClick(nil) // Duplicate admission only; first activation uses event hit routing.
            try duoRequire(emitted == count + 1 && !button.isEnabled, "Duplicate click admits exactly one command")
            for _ in 0..<150 {
                await duoPause()
                if button.isEnabled && !lcd.toolbox.busy && !lcd.toolbox.manualPending { break }
            }
            try duoRequire(button.isEnabled && !lcd.toolbox.busy && !lcd.toolbox.manualPending, "Production toolbar command completes")
            let reference = try await duoWork { simulatorRotationStates[id]?.reference }
            var observed = try await observation()
            if !closed {
                for _ in 0..<40 where observed.inferredOrientation != target {
                    await duoPause(); observed = try await observation()
                }
            }
            for _ in 0..<40 where lcd.active?.guestRotation != observed.rotation { await duoPause() }
            try duoRequire(lcd.active?.guestRotation == observed.rotation, "Async presentation catches up to genuine guest readback")
            print("ROTATION_RESULT requested=\(target.rawValue) cached=\(reference?.rawValue ?? "none") display=\(observed.display) rotation=\(observed.rotation) feedback=\(feedback.stringValue)"); fflush(stdout)
            try duoRequire(reference == target, "Serialized backend advances to " + target.rawValue)
            lcd.content.layoutSubtreeIfNeeded()
            _ = shell("/usr/sbin/screencapture", ["-x", "-o", "-l", String(lcd.window.windowNumber), output.appendingPathComponent(captureName + "-after.png").path], timeout: 5)
            print("VISIBLE before=\(beforeRotation) \(beforeSize) after=\(lcd.view.rotation) \(lcd.view.shownPoints) hit=\(point) frame=\(lcd.window.frame)"); fflush(stdout)
            try duoRequire(lcd.view.rotation != beforeRotation && lcd.view.shownPoints == CGSize(width: beforeSize.height, height: beforeSize.width), "Visible framebuffer layer and LCD aspect turn one quarter clockwise")
            let rotationFeedback = feedback.stringValue
            let presented = lcd.active!
            try duoRequire(presented.rotation == target.screenRotation(inner: !closed), "Presented physical pose equals requested target")
            let rawPoint = CGPoint(x: presented.unrotated.width * 0.23, y: presented.unrotated.height * 0.37)
            let box = presented.shown(CGRect(origin: rawPoint, size: .zero))
            let normalized = presented.normalized(box.origin)
            try duoRequire(abs(normalized.x - 0.23) < 0.00001 && abs(normalized.y - 0.37) < 0.00001,
                           "Presented pointer maps back to original digitizer location")
            let local = CGPoint(x: lcd.view.bounds.midX + (box.minX - presented.points.width/2) * lcd.view.scale,
                                y: lcd.view.bounds.midY - (box.minY - presented.points.height/2) * lcd.view.scale)
            let pointer = NSEvent.mouseEvent(with: .mouseMoved, location: lcd.view.convert(local, to: nil), modifierFlags: [],
                timestamp: 0, windowNumber: lcd.window.windowNumber, context: nil, eventNumber: 2, clickCount: 0, pressure: 0)!
            let mapped = lcd.view.screenPoint(pointer, clamp: true)!
            try duoRequire(hypot(mapped.x - box.minX, mapped.y - box.minY) < 0.001, "Actual view event coordinates match presented screen")
            lcd.preparePreview(); lcd.updatePreview()
            try duoRequire(lcd.previewView?.rotation == presented.rotation && lcd.previewView?.shownPoints == presented.points,
                           "Live preview shares presentation and dimensions")
            let capture = try await command(["action":"screenshot", "guides":true])
            let images = (capture["content"] as? [[String: Any]] ?? []).compactMap { item -> NSBitmapImageRep? in
                guard item["type"] as? String == "image", let data = item["data"] as? String,
                      let decoded = Data(base64Encoded: data) else { return nil }
                return NSBitmapImageRep(data: decoded)
            }
            try duoRequire(images.contains { $0.pixelsWide == Int(presented.points.width) && $0.pixelsHigh == Int(presented.points.height) },
                           "Real screenshot with AX guides matches visible presentation dimensions")
            let axPair = try await duoWork { () -> ([SimulatorElement], [SimulatorElement]) in
                var raw = presented; raw.rotation = presented.guestRotation; raw.framebufferRotation = nil
                return (try simulatorElements(device, screen: raw), try simulatorElements(device, screen: presented))
            }
            try duoRequire(axPair.0.count == axPair.1.count && !axPair.0.isEmpty, "Current guest accessibility tree retained")
            for (raw, shown) in zip(axPair.0, axPair.1) {
                let expected = presented.presentingGuestFrame(raw.frame)
                try duoRequire(abs(expected.minX - shown.frame.minX) < 1 && abs(expected.minY - shown.frame.minY) < 1
                    && abs(expected.width - shown.frame.width) < 1 && abs(expected.height - shown.frame.height) < 1,
                    "AX frame tracks presented screenshot coordinates")
            }
            if closed {
                try duoRequire(observed.primary && observed.rotation == "rot0", "Closed cover framebuffer stays rot0")
                try duoRequire(rotationFeedback.contains("기기 화면 회전") && (rotationFeedback.contains("앱 방향 유지") || rotationFeedback.contains("앱 방향 확인 중")) && !rotationFeedback.contains("실패"), "Cover reports visible host turn separately from unchanged guest")
            } else {
                try duoRequire(!observed.primary && observed.inferredOrientation == target, "Actual inner framebuffer confirms " + target.rawValue)
                try duoRequire(rotationFeedback.contains("기기 화면 회전") && rotationFeedback.contains("앱 방향 확인"), "Production UI distinguishes host presentation and guest readback")
            }
        }
        for (index, target) in [SimulatorOrientation.landscapeRight, .upsideDown, .landscapeLeft, .portrait].enumerated() {
            try await click(target, closed: true)
            if index == 0 {
                lcd.window.close()
                let active = try await duoWork { try activeScreen(of: device) }
                lcd = SimulatorWindow(device: device, active: active); open = lcd; simulatorWindows[id] = lcd
                button = duoDescendants(lcd.content.chrome.controls).compactMap { $0 as? NSButton }.first { $0.title == "회전" }!
                feedback = duoDescendants(lcd.content.chrome.rail).compactMap { $0 as? NSTextField }.first { $0.accessibilityLabel() == "시뮬레이터 조작 결과" }!
                observeActions(); bringSimulatorWindowToFront(lcd)
                for _ in 0..<5 { await duoPause() }
                print("LCD_REOPEN between first and second closed rotation"); fflush(stdout)
            }
        }
        _ = try await command(["action":"hinge", "degrees":180.0])
        let revealed = try await observation()
        try duoRequire(!revealed.primary && revealed.inferredOrientation == .portrait, "Opening after four closed requests reveals final portrait pose")
        for target in [SimulatorOrientation.landscapeRight, .upsideDown, .landscapeLeft, .portrait] { try await click(target, closed: false) }
        // Absolute reverse turns use the same presentation as the clockwise button.
        for target in [SimulatorOrientation.landscapeLeft, .upsideDown, .landscapeRight, .portrait] {
            _ = try await command(["action":"rotate", "orientation":target.rawValue])
            for _ in 0..<5 { await duoPause() }
            try duoRequire(lcd.view.rotation == target.screenRotation(inner: true), "Reverse absolute rotation visibly applies " + target.rawValue)
        }
        _ = try await command(["action":"rotate", "orientation":"landscape-right"])
        for hinge in [0.0, 90.0, 180.0, 0.0] {
            _ = try await command(["action":"hinge", "degrees":hinge])
            for _ in 0..<5 { await duoPause() }
            let shown = lcd.active!
            try duoRequire(shown.rotation == SimulatorOrientation.landscapeRight.screenRotation(inner: !shown.primary),
                           "Hinge transition preserves positioned host pose at \(hinge) degrees")
        }
        let preserved = lcd.view.rotation
        let transportFailed = try await duoWork { () -> Bool in
            let link = try hidLink(for: device)
            link.closed = true
            xpc_connection_cancel(link.connection)
            do {
                try link.deviceControl("orientation-picker-control", "enum", "portrait")
                return false
            } catch { return true }
        }
        try duoRequire(transportFailed, "Closed HID transport throws rather than reporting local delivery")
        let afterFailure = try await duoWork { try activeScreen(of: device) }
        try duoRequire(afterFailure?.rotation == preserved, "Failed transport preserves presented pose")
        _ = try await duoWork { try hidLink(for: device) }
        let afterReconnect = try await duoWork { try activeScreen(of: device) }
        lcd.show(afterReconnect)
        try duoRequire(lcd.view.rotation == preserved, "Input reconnection preserves visible pose")
        let finalApp = try await duoWork { try simulatorFrontPid(device) }
        try duoRequire(finalApp == initialApp, "Original guest application preserved; no substitute rotation-supporting app")
        let capture = shell("/usr/sbin/screencapture", ["-x", "-o", "-l", String(lcd.window.windowNumber), output.appendingPathComponent("duo-unfolded.png").path], timeout: 5)
        try duoRequire(capture.status == 0, "Actual Duo toolbar screenshot captured")
        try duoRequire(lcd.content.chrome.controls.window === lcd.window && lcd.content.chrome.rail.window === lcd.window && lcd.content.body.layer!.backgroundColor!.alpha == 1, "Compact glass toolbars and opaque LCD retain production ownership")
    } catch { pendingFailure = error }
    // Restoration also runs after a caught assertion/focus failure. The Python parent
    // owns a second restoration route if this process is killed by its watchdog.
    do {
        if let originalPose {
            _ = try await command(["action":"hinge", "degrees":180.0])
            _ = try await command(["action":"rotate", "orientation":originalPose.rawValue])
            let restoredPose = try await observation()
            try duoRequire(restoredPose.inferredOrientation == originalPose, "Original unfolded pose restored before folding")
        }
        _ = try await command(["action":"hinge", "degrees":angle])
        let restoredAngle = try await duoWork { try hingeAngle(of: device) }
        try duoRequire(abs(restoredAngle - angle) < 0.7, "Original hinge angle restored")
        try Data("restored".utf8).write(to: output.appendingPathComponent("restored.txt"))
    } catch { pendingFailure = error }
    open?.window.close(); simulatorWindows[id] = nil
    if let pendingFailure { throw pendingFailure }
}
func runSimulatorDuoRotationLiveCheck() -> Never {
    let env = ProcessInfo.processInfo.environment
    guard let id = env["LCD_CHECK_UDID"], UUID(uuidString: id) != nil, let path = env["LCD_CHECK_OUTPUT"] else { exit(64) }
    let app = NSApplication.shared; app.setActivationPolicy(.accessory)
    Task { @MainActor in
        do { try await duoRotationRun(id: id, output: URL(fileURLWithPath: path)); exit(0) }
        catch { print("FAIL Duo rotation: \(error)"); fflush(stdout); exit(1) }
    }
    app.run(); exit(1)
}
