import Foundation
import CoreGraphics

@main struct SimulatorRotationSelfcheck {
    static func main() {
        for pose in SimulatorOrientation.allCases {
            assert(pose.signedQuarterTurns(to:pose.clockwise,direction:"clockwise") == 1)
            assert(pose.signedQuarterTurns(to:pose.counterclockwise,direction:"counterclockwise") == -1)
            assert(pose.signedQuarterTurns(to:pose.counterclockwise) == -1)
            assert(pose.signedQuarterTurns(to:pose) == 0)
        }
        assert(SimulatorOrientation.landscapeLeft.signedQuarterTurns(to:.portrait,direction:"clockwise") == 1)
        assert(SimulatorOrientation.portrait.signedQuarterTurns(to:.landscapeLeft,direction:"counterclockwise") == -1)
        let cover = SimulatorRotationObservation(display: "1", rotation: "rot0", foldable: true, primary: true)
        func inner(_ pose: SimulatorOrientation) -> SimulatorRotationObservation {
            .init(display: "0", rotation: pose.screenRotation(inner: true), foldable: true, primary: false)
        }
        var state = SimulatorRotationState()
        state.observe(cover)
        assert(state.reference == nil && state.nextClockwise == .landscapeRight)
        for target in [SimulatorOrientation.landscapeRight, .upsideDown, .landscapeLeft, .portrait, .landscapeRight] {
            for _ in 0..<10 { state.observe(cover) }
            assert(state.nextClockwise == target, "Unchanged cover polls must not restart the cycle")
            state.sent(target, after: cover)
        }
        var ordinary = SimulatorRotationState()
        let upright = SimulatorRotationObservation(display: "main", rotation: "rot0", foldable: false, primary: true)
        ordinary.observe(upright)
        ordinary.sent(.landscapeRight, after: upright, presentsDevice: false)
        ordinary.observe(upright)
        assert(ordinary.presentation == nil && ordinary.nextClockwise == .upsideDown)
        ordinary.sent(.upsideDown, after: upright, presentsDevice: false)
        ordinary.observe(.init(display: "main", rotation: "rot90", foldable: false, primary: true))
        assert(ordinary.nextClockwise == .landscapeLeft, "Delayed first request cannot overwrite latest relative intent")
        ordinary.observe(.init(display: "main", rotation: "rot180", foldable: false, primary: true))
        ordinary.observe(.init(display: "main", rotation: "rot270", foldable: false, primary: true))
        assert(ordinary.nextClockwise == .portrait, "Ordinary devices still follow observable external turns")
        enum SendFailure: Error { case closed }
        let preservedReference = ordinary.reference
        do {
            try ordinary.deliver(.portrait, after: upright, presentsDevice: false) { throw SendFailure.closed }
            assertionFailure("Failed send returned success")
        } catch { assert(ordinary.reference == preservedReference) }
        let failedTarget = state.nextClockwise
        // A failed delivery never calls sent(). A new unchanged poll must preserve retry.
        state.observe(cover); state.observe(nil)
        assert(state.nextClockwise == failedTarget)
        state.sent(.portrait, after: cover)
        assert(state.nextClockwise == .landscapeRight, "Absolute requests seed the same relative sequence")
        state.observe(inner(.landscapeLeft))
        assert(state.nextClockwise == .landscapeRight, "Unfolding cannot override the explicitly positioned host")
        state.sent(.portrait, after: inner(.landscapeLeft))
        state.observe(inner(.landscapeLeft))
        assert(state.nextClockwise == .landscapeRight, "An unchanged unsupported app must not erase a delivered request")
        state.observe(inner(.upsideDown))
        assert(state.nextClockwise == .landscapeRight, "Guest app reorientation cannot override host pose")
        for pose in SimulatorOrientation.allCases {
            assert(inner(pose).inferredOrientation == pose)
            assert(SimulatorRotationObservation(display: "main", rotation: pose.screenRotation(inner: false), foldable: false, primary: true).inferredOrientation == pose)
        }
        assert(SimulatorOrientation.portrait.screenRotation(inner: true) == "rot90")
        assert(SimulatorOrientation.upsideDown.picker == "pud")
        assert(cover.inferredOrientation == nil)
        var devices = ["a": state, "b": SimulatorRotationState()]
        devices["b"]!.observe(cover)
        assert(devices["a"]!.nextClockwise == .landscapeRight && devices["b"]!.reference == nil)
        let preserved = devices["a"]!.reference
        // Input connection lifecycle does not mutate this state; failed sends never call sent().
        devices["a"]!.observe(nil)
        assert(devices["a"]!.reference == preserved && devices["b"]!.reference == nil)
        func display(_ rotation: String?, active: Bool = true) -> [String: Any] {
            var d: [String: Any] = ["type": ["integrated": [:]], "displayId": 1, "active": active, "primary": true]
            d["currentOrientation"] = rotation
            return d
        }
        assert(SimulatorRotationObservation.read([display("rot0")])?.inferredOrientation == .portrait)
        var legacy = display("rot90")
        legacy.removeValue(forKey: "active")
        legacy["backlightState"] = "unknown"
        assert(SimulatorRotationObservation.read([legacy])?.rotation == "rot90")
        assert(routedSimulatorDisplay([legacy, legacy]) == nil)
        legacy["active"] = false
        assert(routedSimulatorDisplay([legacy]) == nil)
        assert(SimulatorRotationObservation.read([]) == nil)
        assert(SimulatorRotationObservation.read([display(nil)]) == nil)
        assert(SimulatorRotationObservation.read([display("unknown")]) == nil)
        assert(SimulatorRotationObservation.read([display("rot0", active: false)]) == nil)
        assert(SimulatorRotationObservation.read([display("rot0"), display("rot90", active: false)])?.inferredOrientation == nil)
        let pixels: [UInt8] = (1...6).flatMap { [UInt8($0 * 30), 0, 0, 255] }
        let provider = CGDataProvider(data: Data(pixels) as CFData)!
        let image = CGImage(width: 2, height: 3, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 8,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
        let expected = [[1,2,3,4,5,6], [5,3,1,6,4,2], [6,5,4,3,2,1], [2,4,6,1,3,5]]
        for turn in 0..<4 {
            let rotated = try! simulatorRotatedImage(image, quarterTurns: turn)
            assert(rotated.width == (turn % 2 == 0 ? 2 : 3) && rotated.height == (turn % 2 == 0 ? 3 : 2))
            let data = rotated.dataProvider!.data! as Data
            var actual: [Int] = []
            for y in 0..<rotated.height { for x in 0..<rotated.width { actual.append(Int(data[y * rotated.bytesPerRow + x * 4]) / 30) } }
            assert(actual == expected[turn], "Actual screenshot pixels must turn clockwise, without mirroring or double rotation")
        }
        print("PASS image pixels: exact clockwise quarter turns, reverse and full cycle")
        print("PASS rotation: closed-cover cycle, unchanged/missing polls, failed delivery retry, shared absolute requests, Duo axes, host pose retention/ordinary external turns, per-device isolation/reconnection and unavailable readback")
    }
}
