import AppKit

/// Standalone, window-free check. Compile only SimulatorHingeSlider.swift,
/// native-selfcheck-entry.swift and this file; launch through native_check_support.py.
/// This deliberately never creates NSApplication, an NSWindow or an event loop.
@main
struct SimulatorHingeSliderSelfcheck {
    static func main() {
        admitNativeSelfcheck()
        let slider = SimulatorHingeSlider(frame: NSRect(x: 0, y: 0, width: 264, height: 92))
        var previews: [Double] = []
        var commits: [Double] = []
        slider.onPreview = { previews.append($0) }
        slider.onCommit = { commits.append($0) }

        func clearCallbacks() {
            previews.removeAll()
            commits.removeAll()
        }
        func press(_ code: UInt16, shift: Bool = false) {
            let event = NSEvent.keyEvent(with: .keyDown, location: .zero,
                modifierFlags: shift ? [.shift] : [], timestamp: 0, windowNumber: 0,
                context: nil, characters: "", charactersIgnoringModifiers: "",
                isARepeat: false, keyCode: code)!
            slider.keyDown(with: event)
        }

        assert(slider.minValue == 0 && slider.maxValue == 180)
        assert(slider.numberOfTickMarks == 3 && !slider.allowsTickMarkValuesOnly)
        assert(slider.acceptsFirstResponder && slider.subviews.isEmpty)
        assert(slider.accessibilityRole() == .slider)
        assert(slider.accessibilityOrientation() == .horizontal)
        assert(slider.accessibilityChildren()?.isEmpty == true)
        assert(slider.accessibilityLabel() == "접기 각도")
        assert(slider.accessibilityHelp()?.contains("Shift-방향키") == true)
        assert((slider.accessibilityMinValue() as? NSNumber)?.doubleValue == 0)
        assert((slider.accessibilityMaxValue() as? NSNumber)?.doubleValue == 180)

        // All whole degrees survive round trips, at both supported widths and
        // with a nonzero bounds origin. A lower-row drag also must not snap.
        for width: CGFloat in [204, 264, 500] {
            slider.frame.size = NSSize(width: width, height: 92)
            slider.bounds.origin = NSPoint(x: 7, y: 11)
            for angle in 0...180 {
                var point = slider.point(for: Double(angle))
                assert(slider.angle(for: point) == Double(angle))
                point.y = slider.bounds.minY + 65
                assert(slider.angle(for: point) == Double(angle))
            }
            let targets = SimulatorHingeSlider.majorAngles.map { slider.tickHitRect(for: $0) }
            for (index, target) in targets.enumerated() {
                assert(target.width >= 44 && target.height >= 44)
                assert(slider.bounds.contains(target))
                assert(!target.intersects(slider.trackInteractionRect))
                assert(targets.dropFirst(index + 1).allSatisfy { !$0.intersects(target) })
                let angle = SimulatorHingeSlider.majorAngles[index]
                for x in [target.minX + 0.1, target.midX, target.maxX - 0.1] {
                    slider.doubleValue = 42
                    clearCallbacks()
                    assert(slider.beginAdjustment(at: NSPoint(x: x, y: target.midY)))
                    assert(slider.doubleValue == angle && previews == [angle] && commits.isEmpty)
                    slider.endAdjustment()
                    assert(commits == [angle])
                }
            }
        }
        slider.frame.size = NSSize(width: 264, height: 92)
        slider.bounds.origin = .zero
        assert(slider.angle(for: NSPoint(x: -1000, y: 22)) == 0)
        assert(slider.angle(for: NSPoint(x: 1000, y: 22)) == 180)
        assert(slider.exactTick(at: slider.point(for: 90)) == nil)

        // Programmatic assignments update the draft without applying it.
        clearCallbacks()
        for (input, expected): (Double, Double) in [(-1, 0), (500, 180), (89.4, 89), (89.5, 90), (.nan, 0), (.infinity, 0)] {
            slider.doubleValue = input
            assert(slider.doubleValue == expected)
        }
        assert(previews.isEmpty && commits.isEmpty)

        // A single pointer gesture previews freely, even directly beside 90,
        // and commits only its final integer. Repeated mouse-up is harmless.
        slider.doubleValue = 90
        clearCallbacks()
        assert(slider.beginAdjustment(at: slider.point(for: 90)))
        for angle in [89.0, 90, 91, 37] {
            slider.continueAdjustment(at: slider.point(for: angle))
            assert(slider.doubleValue == angle && commits.isEmpty)
        }
        assert(previews == [89, 90, 91, 37])
        slider.endAdjustment()
        slider.endAdjustment()
        assert(commits == [37])

        // The tick is only exact on initial selection. A one-degree drag from
        // its large label target must immediately reach 89, with no dead zone.
        slider.doubleValue = 45
        clearCallbacks()
        let tick = slider.tickHitRect(for: 90)
        let start = NSPoint(x: tick.minX + 1, y: tick.midY)
        assert(slider.beginAdjustment(at: start))
        let oneDegree = slider.point(for: 90).x - slider.point(for: 89).x
        slider.continueAdjustment(at: NSPoint(x: start.x - oneDegree, y: start.y))
        assert(slider.doubleValue == 89 && previews == [90, 89] && commits.isEmpty)
        slider.endAdjustment()
        assert(commits == [89])

        // A thumb's larger input target preserves the grab offset.
        slider.doubleValue = 90
        clearCallbacks()
        var grab = slider.point(for: 90)
        grab.x += 15
        assert(slider.beginAdjustment(at: grab))
        assert(slider.doubleValue == 90 && previews.isEmpty)
        slider.continueAdjustment(at: NSPoint(x: grab.x - oneDegree, y: grab.y))
        assert(slider.doubleValue == 89)
        slider.cancelAdjustment()
        assert(slider.doubleValue == 90 && previews == [89, 90] && commits.isEmpty)

        slider.doubleValue = 40
        clearCallbacks()
        assert(slider.beginAdjustment(at: slider.point(for: 150)))
        assert(slider.doubleValue == 150 && commits.isEmpty)
        slider.cancelAdjustment()
        assert(slider.doubleValue == 40 && previews == [150, 40] && commits.isEmpty)
        assert(!slider.beginAdjustment(at: NSPoint(x: 100, y: -1)))

        // Each keyboard adjustment previews then commits once, including repeats.
        slider.doubleValue = 89
        clearCallbacks()
        for (code, shift, expected): (UInt16, Bool, Double) in [
            (124, false, 90), (123, false, 89), (126, true, 99),
            (125, true, 89), (116, false, 90), (116, false, 180),
            (121, false, 90), (121, false, 0), (119, false, 180), (115, false, 0)
        ] {
            press(code, shift: shift)
            assert(slider.doubleValue == expected)
            assert(previews.last == expected && commits.last == expected)
            assert(previews.count == commits.count)
        }
        assert(commits.count == 10)
        press(123)
        press(121)
        assert(commits.count == 10) // Already at the lower bound.
        slider.doubleValue = 91
        press(121)
        assert(slider.doubleValue == 90)

        // AX uses numeric degrees plus spoken units/state; operations follow the
        // same preview/commit path, and invalid/disabled operations do nothing.
        slider.doubleValue = 89
        clearCallbacks()
        assert(slider.accessibilityPerformIncrement())
        assert(slider.doubleValue == 90 && commits == [90])
        assert(slider.accessibilityValueDescription() == "90도 · 직각")
        assert((slider.accessibilityValue() as? NSNumber)?.doubleValue == 90)
        assert(slider.accessibilityPerformDecrement())
        assert(slider.doubleValue == 89 && commits == [90, 89])
        slider.setAccessibilityValue(NSNumber(value: 137.4))
        assert(slider.doubleValue == 137 && commits == [90, 89, 137])
        slider.setAccessibilityValue(NSNumber(value: Double.nan))
        slider.setAccessibilityValue("invalid")
        assert(slider.doubleValue == 137 && commits == [90, 89, 137])
        slider.setAccessibilityValue(NSNumber(value: 1000))
        assert(slider.doubleValue == 180)

        // Disabling mid-gesture retains the draft and suppresses its commit.
        slider.doubleValue = 90
        clearCallbacks()
        assert(slider.beginAdjustment(at: slider.point(for: 90)))
        slider.continueAdjustment(at: slider.point(for: 89))
        slider.isEnabled = false
        slider.endAdjustment()
        assert(slider.doubleValue == 89 && previews == [89] && commits.isEmpty)
        assert(!slider.acceptsFirstResponder && !slider.isAccessibilityEnabled())
        assert(!slider.beginAdjustment(at: slider.point(for: 90)))
        assert(!slider.accessibilityPerformIncrement() && !slider.accessibilityPerformDecrement())
        slider.setAccessibilityValue(NSNumber(value: 40))
        press(119)
        assert(slider.doubleValue == 89 && commits.isEmpty)

        // A callback that disables the control must prevent the following commit.
        slider.isEnabled = true
        slider.onPreview = { _ in slider.isEnabled = false }
        slider.setAccessibilityValue(NSNumber(value: 90))
        assert(slider.doubleValue == 90 && commits.isEmpty)
        print("Hinge slider checks passed: every 0...180 degree, 44pt tick targets, free 89/90/91 drag, offset grabs, preview/commit/cancel, keyboard, one AX slider, AX actions and disabled interruption. No GUI opened.")
    }
}
