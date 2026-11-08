import AppKit

@main
struct SimulatorDeviceChromeSelfcheck {
    static func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
    static func main() {
        admitNativeSelfcheck()
        _ = NSApplication.shared
        let chrome = SimulatorDeviceChrome()
        let tools = SimulatorToolboxView(deviceName: "Fixture", isWatch: false)
        let lcd = NSView(frame: CGRect(x: 0, y: 0, width: 400, height: 600))
        let content = SimulatorLCDContentView(lcd: lcd, tools: tools, appearance: SimulatorDeviceAppearance(typeName: "iPhone"))
        let window = SimulatorDeviceWindow(contentRect: CGRect(x: 0, y: 0, width: 750, height: 800),
                                           styleMask: [.borderless, .resizable, .miniaturizable, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.isOpaque = false; window.backgroundColor = .clear
        window.contentView = content
        content.screen = CGSize(width: 466, height: 678)
        content.needsLayout = true; content.layoutSubtreeIfNeeded()
        assert(window.canBecomeKey && window.canBecomeMain && !window.styleMask.contains(.titled))
        assert(window.isMovable && !window.isMovableByWindowBackground, "Borderless dragging requires explicit movability without LCD background dragging")
        window.interactiveMove = true
        let unbounded = CGRect(x: -9000, y: 9000, width: 750, height: 800)
        assert(window.constrainFrameRect(unbounded, to: NSScreen.main) == unbounded, "Do not apply AppKit screen correction in the native drag lifecycle")
        window.interactiveMove = false
        assert(window.standardWindowButton(.closeButton) == nil && window.standardWindowButton(.miniaturizeButton) == nil)
        assert(window.alphaValue == 1)
        assert(content.body.layer!.backgroundColor!.alpha == 1)
        assert(content.hitTest(CGPoint(x: 1, y: 1)) == nil, "Transparent margins must not produce an AppKit hit target")
        let center = lcd.convert(CGPoint(x: lcd.bounds.midX, y: lcd.bounds.midY), to: content)
        assert(content.hitTest(center) === lcd)
        let grip = content.chrome.grip
        let gripCenter = grip.convert(CGPoint(x: grip.bounds.midX, y: grip.bounds.midY), to: content)
        assert(content.hitTest(gripCenter) === grip, "Handle labels must remain draggable and never become LCD input")
        for point in [CGPoint(x: 12, y: 20), CGPoint(x: grip.bounds.width - 4, y: 20)] {
            assert(content.hitTest(grip.convert(point, to: content)) === grip, "Raised handle must route caption and label hits to the grip")
        }
        let resize = content.chrome.resize
        let resizeCenter = resize.convert(CGPoint(x: resize.bounds.midX, y: resize.bounds.midY), to: content)
        assert(content.hitTest(resizeCenter) === resize)
        assert(!content.body.frame.intersects(content.chrome.resize.frame), "Resize target must stay outside LCD")
        content.focused = true
        content.needsLayout = true; content.layoutSubtreeIfNeeded()
        assert(content.chrome.controls.isHidden && content.chrome.rail.isHidden && content.chrome.resize.isHidden)
        assert(!content.chrome.handle.isHidden && content.hitTest(grip.convert(CGPoint(x: 20, y: 20), to: content)) === grip)
        assert(content.hitTest(resizeCenter) !== resize, "Focus mode must remove hidden resize hit targets even when LCD occupies the old position")

        var requests: [[String: Any]] = []
        chrome.onRun = { requests.append($0) }
        chrome.updateDevice(name: "Fixture",runtime: "iOS 27.2",connected: true,foldable: false,isWatch: false,rotation: "rot0")
        let buttons = descendants(chrome.controls).compactMap { $0 as? NSButton }
        let fold = buttons.first { $0.title == "접기" }!
        assert(fold.isHidden && buttons.count == 7)
        chrome.updateDevice(name: "Fixture",runtime: "iOS 27.2",connected: true,foldable: true,isWatch: false,rotation: "rot0")
        chrome.updateAngle(130)
        assert(!fold.isHidden && fold.accessibilityLabel()!.contains("130"))
        chrome.controls.frame = CGRect(x: 0,y: 0,width: 84,height: 364)
        chrome.controls.layoutSubtreeIfNeeded()
        chrome.rail.frame = CGRect(x: 0,y: 0,width: 304,height: 96)
        for style in [NSScroller.Style.legacy,.overlay] {
            for scroll in descendants(chrome.controls).compactMap({ $0 as? NSScrollView }) + descendants(chrome.rail).compactMap({ $0 as? NSScrollView }) { scroll.scrollerStyle = style }
            chrome.controls.needsLayout = true; chrome.rail.needsLayout = true
            chrome.controls.layoutSubtreeIfNeeded(); chrome.rail.layoutSubtreeIfNeeded()
            for button in buttons { assert(button.frame.width >= 44 && button.frame.height >= 44) }
            let bottom = descendants(chrome.rail).compactMap { $0 as? SimulatorToolbarButton }
            assert(bottom.count == 6 && bottom.allSatisfy { $0.imagePosition == .imageOnly && $0.accessibilityLabel() != nil && $0.toolTip != nil })
            for scroll in descendants(chrome.rail).compactMap({ $0 as? NSScrollView }) {
                assert((scroll.documentView?.frame.height ?? 0) <= scroll.contentSize.height+0.5)
            }
            assert(bottom.allSatisfy { $0.frame.height >= 44 && $0.frame.width >= 44 })
        }
        for button in buttons { assert(button.frame.width >= 44 && button.frame.height >= 44 && button.accessibilityLabel() != nil && button.imagePosition == .imageOnly) }
        chrome.controls.frame.size.height = 160
        chrome.controls.needsLayout = true; chrome.controls.layoutSubtreeIfNeeded()
        let column = descendants(chrome.controls).compactMap { $0 as? NSScrollView }.first!
        assert((column.documentView?.frame.width ?? 0) <= column.contentSize.width+0.5)
        assert(buttons.allSatisfy { $0.isHidden || $0.frame.width >= 44 })
        chrome.controls.frame.size.height = 316
        chrome.controls.needsLayout = true; chrome.controls.layoutSubtreeIfNeeded()
        let rotate = buttons.first { $0.title == "회전" }!
        for rotation in ["rot0","rot90","rot180","rot270"] {
            chrome.updateDevice(name: "Fixture",runtime: "iOS 27.2",connected: true,foldable: false,isWatch: false,rotation: rotation)
            chrome.rotationFailed()
            rotate.performClick(nil)
            assert(requests.last?["direction"] as? String == "clockwise" && requests.last?["orientation"] == nil)
            let count = requests.count; rotate.performClick(nil); assert(requests.count == count)
        }
        chrome.rotationFailed()
        chrome.updateDevice(name: "Fixture",runtime: "iOS 27.2",connected: true,foldable: true,isWatch: false,rotation: "rot90",primaryDisplay: false)
        rotate.performClick(nil); assert(requests.last?["direction"] as? String == "clockwise")
        chrome.commandFinished(action: "rotate",failed: true)
        let count = requests.count; rotate.performClick(nil); assert(requests.count == count+1)
        chrome.finishRotationFeedback(["structuredContent": ["rotation": ["requestedOrientation":"landscape-right", "screenConfirmed":false, "screenOrientation":"rot0", "assumedPortrait":true]]])
        let rotationFeedback = descendants(chrome.rail).compactMap { $0 as? NSTextField }.first { $0.accessibilityLabel() == "시뮬레이터 조작 결과" }!
        assert(rotate.isEnabled && rotationFeedback.stringValue.contains("세로 기준 첫 요청") && !rotationFeedback.stringValue.contains("실패"))
        chrome.finishRotationFeedback(["structuredContent": ["rotation": ["requestedOrientation":"portrait", "screenConfirmed":true]]])
        assert(rotationFeedback.stringValue.contains("화면 회전 확인"))
        chrome.rotationFailed(); chrome.setBusy(true)
        let busyCount = requests.count; rotate.performClick(nil); assert(requests.count == busyCount)
        chrome.setBusy(false)
        let capture = buttons.first { $0.title == "캡처" }!
        capture.performClick(nil); assert(requests.last?["action"] as? String == "screenshot")
        chrome.showFeedback("저장 실패",failed: true)
        let feedback = descendants(chrome.rail).compactMap { $0 as? NSTextField }.first { $0.accessibilityLabel() == "시뮬레이터 조작 결과" }!
        assert(feedback.stringValue.contains("저장 실패") && feedback.textColor == .systemRed)
        assert(feedback.isHidden, "No persistent status footer")
        let more = buttons.first { $0.title == "더보기" }!
        assert((more.accessibilityValue() as? String)?.contains("저장 실패") == true && more.contentTintColor == .systemRed)
        var responseAnchor: NSView?
        chrome.onResponse = { responseAnchor = $0 }
        let responseMenu = chrome.moreMenu()
        let responseItem = responseMenu.items.first { $0.title == "최근 응답…" }!
        assert(NSApp.sendAction(responseItem.action!, to: responseItem.target, from: responseItem))
        assert(responseAnchor === more, "Response history remains reachable from More")
        chrome.updateRecording(true,caption: "정지 0:03")
        assert(buttons.contains { $0.title == "정지 0:03" })
        chrome.updateDevice(name: "Fixture",runtime: "iOS 27.2",connected: false,foldable: true,isWatch: false,rotation: "rot0")
        let offline = requests.count; capture.performClick(nil); assert(requests.count == offline)
        assert(!chrome.angle.isEnabled)
        chrome.updateDevice(name: "Fixture",runtime: "iOS 27.2",connected: true,foldable: true,isWatch: false,rotation: "rot0")
        chrome.updateAngle(90); chrome.angle.doubleValue = 89; chrome.angle.onCommit?(89)
        assert(requests.last?["degrees"] as? Double == 89)
        chrome.commandFinished(action: "hinge",failed: true); chrome.updateAngle(90)
        assert(chrome.angle.doubleValue == 89,"Failed draft must survive external confirmed readback")
        let first = Data([1, 2]), active = Data([3, 4])
        assert(simulatorActiveCaptureData([["type": "image", "data": first.base64EncodedString()],
                                           ["type": "text", "text": "Screen 1 LCD (on: its pixels are coordinates)"],
                                           ["type": "image", "data": active.base64EncodedString()]]) == active)
        assert(simulatorActiveCaptureData([["type": "text", "text": "failed"]]) == nil)
        for display in [CGRect(x: -1920, y: 0, width: 1920, height: 1080), CGRect(x: 0, y: 80, width: 1024, height: 768)] {
            let frame = simulatorConstrainedFrame(CGRect(x: -3000, y: -200, width: 1800, height: 1400), to: display)
            assert(display.contains(frame))
        }
        for focused in [false, true] {
            for size in [CGSize(width: 336, height: 400), CGSize(width: 900, height: 700)] {
                let layout = simulatorDeviceLayout(in: size, screen: content.screen, bezel: 5, toolsVisible: false, focused: focused)
                let viewport = CGRect(origin: .zero, size: size)
                assert(viewport.contains(layout.handle) && viewport.contains(layout.body))
                if !focused { assert(viewport.contains(layout.controls) && viewport.contains(layout.rail) && viewport.contains(layout.resize)) }
            }
        }
        for size in [CGSize(width: 340, height: 590), CGSize(width: 500, height: 720), CGSize(width: 760, height: 650)] {
            for screen in [CGSize(width: 320,height: 600), CGSize(width: 540,height: 720), CGSize(width: 600,height: 320), CGSize(width: 720,height: 540)] {
                let g = simulatorDeviceLayout(in: size, screen: screen, bezel: 5, toolsVisible: false)
                let viewport = CGRect(origin: .zero, size: size)
                assert([g.body,g.handle,g.controls,g.rail,g.resize].allSatisfy { viewport.contains($0) })
                assert(abs(g.handle.minY-g.body.maxY) < 0.01 && abs(g.controls.minX-g.body.maxX) < 0.01 && abs(g.rail.maxY-g.body.minY) < 0.01)
                assert(!g.lcd.intersects(g.controls) && !g.lcd.intersects(g.rail) && !g.controls.intersects(g.resize) && !g.rail.intersects(g.resize))
                assert(g.controls.height >= 44 && g.rail.height >= 52)
            }
        }
        // An aspect-fit body can place the row at a quarter point on Retina.
        // Exercise layout after a run-loop turn without showing/activating it.
        content.focused = false
        for size in [CGSize(width: 500,height: 760), CGSize(width: 340,height: 590), CGSize(width: 760,height: 650)] {
            window.setContentSize(size); window.center()
            for screen in [CGSize(width: 320,height: 520), CGSize(width: 520,height: 320)] {
                content.screen = screen; content.needsLayout = true; content.layoutSubtreeIfNeeded()
                RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.02))
                let row = descendants(content.chrome.rail).compactMap { $0 as? NSScrollView }.first!
                let pixelTolerance = 0.5 / window.backingScaleFactor + 0.001
                func checkTaskRow() {
                    let clip = row.contentView.bounds
                    assert(abs(clip.origin.y) <= pixelTolerance, "Task-row offset exceeds backing-pixel rounding: \(clip)")
                    let document = row.documentView!
                    assert(document.frame.intersection(clip).height >= 44 - pixelTolerance,
                           "Pixel alignment must preserve the full icon row")
                    assert(document.subviews.allSatisfy { $0.frame.height >= 44 && $0.frame.width >= 44 })
                }
                checkTaskRow()
                for glass in [false,true] {
                    for group in [content.body,content.chrome.handle,content.chrome.controls,content.chrome.rail] { group.usesGlass = glass }
                    content.layoutSubtreeIfNeeded()
                    assert(!content.chrome.handle.clipsToBounds && !content.chrome.controls.clipsToBounds && !content.chrome.rail.clipsToBounds,
                           "Solid and glass attachment caps must not be clipped back into separate capsules")
                    checkTaskRow()
                }
            }
        }
        print("PASS device chrome: borderless focus eligibility, opaque body, transparent/handle/LCD/resize hit separation, icon-only targets/response menu, pixel-aligned task rows, unclipped material joins, focus recovery, backend-driven rotation, busy gating, capture selection/failure feedback and display bounds.")
    }
}
