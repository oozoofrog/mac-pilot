import Foundation
import CoreGraphics

/// A requested physical pose is independent of the active app's framebuffer rotation.
/// In particular, Duo's cover SpringBoard stays rot0 through every requested pose.
enum SimulatorOrientation: String, CaseIterable {
    case portrait, landscapeRight = "landscape-right", upsideDown = "upside-down", landscapeLeft = "landscape-left"
    var clockwise: Self {
        switch self {
        case .portrait: return .landscapeRight
        case .landscapeRight: return .upsideDown
        case .upsideDown: return .landscapeLeft
        case .landscapeLeft: return .portrait
        }
    }
    var counterclockwise: Self { Self.allCases[(Self.allCases.firstIndex(of: self)! + 3) % 4] }
    /// Resolve intent on the serialized delivery lane, never from wrapped view angles.
    func signedQuarterTurns(to target: Self, direction: String? = nil) -> Int {
        if direction == "clockwise" { return 1 }
        if direction == "counterclockwise" { return -1 }
        let delta = (Self.allCases.firstIndex(of: target)! - Self.allCases.firstIndex(of: self)! + 4) % 4
        return delta == 3 ? -1 : delta
    }
    var picker: String { self == .upsideDown ? "pud" : rawValue }
    var devicectl: String {
        switch self {
        case .portrait: return "portrait"
        case .landscapeRight: return "landscapeRight"
        case .upsideDown: return "portraitUpsideDown"
        case .landscapeLeft: return "landscapeLeft"
        }
    }
    var title: String {
        switch self {
        case .portrait: return "세로"
        case .landscapeRight: return "가로 오른쪽"
        case .upsideDown: return "거꾸로"
        case .landscapeLeft: return "가로 왼쪽"
        }
    }
    func screenRotation(inner: Bool) -> String {
        let index = Self.allCases.firstIndex(of: self)!
        return "rot\(((index + (inner ? 1 : 0)) % 4) * 90)"
    }
}

struct SimulatorRotationObservation: Equatable {
    let display: String
    let rotation: String
    let foldable: Bool
    let primary: Bool
    /// Read orientation directly: activeScreen intentionally uses nil for an ordinary rot0
    /// screen, which cannot distinguish portrait from an unavailable readback.
    static func read(_ displays: [[String: Any]]) -> Self? {
        let integrated = displays.filter { ($0["type"] as? [String: Any])?["integrated"] != nil }
        guard let active = integrated.first(where: { $0["active"] as? Bool == true }),
              let rotation = active["currentOrientation"] as? String,
              ["rot0", "rot90", "rot180", "rot270"].contains(rotation) else { return nil }
        return Self(display: String(describing: active["displayId"] ?? "main"), rotation: rotation,
                    foldable: integrated.count > 1, primary: active["primary"] as? Bool ?? true)
    }
    var inferredOrientation: SimulatorOrientation? {
        // The cover's rot0 is not evidence of a portrait device pose.
        guard !(foldable && primary && rotation == "rot0") else { return nil }
        return SimulatorOrientation.allCases.first { $0.screenRotation(inner: foldable && !primary) == rotation }
    }
}

/// Accessed only on handleQueue. Input reconnection preserves the visible host pose.
/// Before the first request, guest orientation supplies a starting reference. Once explicitly
/// positioned, the host pose survives app orientation changes and display/hinge transitions.
struct SimulatorRotationState {
    private(set) var reference: SimulatorOrientation?
    private(set) var presentation: SimulatorOrientation?
    private(set) var pendingGuest: SimulatorOrientation?
    private(set) var lastObservation: SimulatorRotationObservation?
    mutating func observe(_ observation: SimulatorRotationObservation?) {
        guard let observation else { return }
        if pendingGuest == observation.inferredOrientation { pendingGuest = nil }
        if presentation == nil, pendingGuest == nil, observation != lastObservation { reference = observation.inferredOrientation }
        lastObservation = observation
    }
    var nextClockwise: SimulatorOrientation { (reference ?? .portrait).clockwise }
    mutating func deliver(_ orientation: SimulatorOrientation, after observation: SimulatorRotationObservation?,
                          presentsDevice: Bool, send: () throws -> Void) rethrows {
        try send()
        sent(orientation, after: observation, presentsDevice: presentsDevice)
    }
    mutating func sent(_ orientation: SimulatorOrientation, after observation: SimulatorRotationObservation?, presentsDevice: Bool = true) {
        reference = orientation
        presentation = presentsDevice ? orientation : nil
        pendingGuest = presentsDevice ? nil : orientation
        lastObservation = observation
    }
}

/// Quarter-turn geometry shared by live surfaces, input/AX and captured images.
func rotationQuarterTurns(_ rotation: String) -> Int {
    ["rot0", "rot90", "rot180", "rot270"].firstIndex(of: rotation) ?? 0
}

/// simctl supplies an image in guest orientation; rotate its real pixels into host presentation.
func simulatorRotatedImage(_ image: CGImage, quarterTurns: Int) throws -> CGImage {
    let turns = (quarterTurns % 4 + 4) % 4
    if turns == 0 { return image }
    let w = image.width, h = image.height
    let size = turns % 2 == 0 ? CGSize(width: w, height: h) : CGSize(width: h, height: w)
    guard let context = CGContext(data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8,
                                  bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw SimulatorImageRotationError.allocation }
    context.translateBy(x: size.width / 2, y: size.height / 2)
    context.rotate(by: -CGFloat(turns) * .pi / 2)
    context.draw(image, in: CGRect(x: -CGFloat(w)/2, y: -CGFloat(h)/2, width: CGFloat(w), height: CGFloat(h)))
    guard let result = context.makeImage() else { throw SimulatorImageRotationError.allocation }
    return result
}
private enum SimulatorImageRotationError: Error { case allocation }
