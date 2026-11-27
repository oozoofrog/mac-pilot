import AppKit
import XPC

// All device operations are injected so the policy and HID messages can be checked offline.
struct DeviceBackend {
    var list: () throws -> [PhysicalDeviceInfo]
    var locked: (UUID) throws -> Bool
    var display: (PhysicalDeviceInfo) throws -> CGSize
    var screenshot: (UUID, CGSize) throws -> String
    var open: (UUID, CGSize) throws -> HIDLink
    /// Opens the connections for these HID features (digitizer, button); nil: open serves every action.
    var openFeatures: ((UUID, CGSize, Set<String>) throws -> HIDLink)? = nil
    var cancelled: () -> Bool = { false }
    /// Ends cached device sessions (nil: every one), releasing what they hold: release, or allowing another device.
    var endSessions: (UUID?) -> Void = { _ in }
    /// A line for list about how screenshots and state are read, when it matters (fallback mode).
    var status: () -> String? = { nil }
    var xctestLocked: ((PhysicalDeviceInfo) throws -> Bool)?
}

final class DeviceTool {
    static let maxTypeLength = 200
    static func transportName(_ transport: String) -> String {
        switch transport {
        case "wired": return "USB"
        case "localNetwork": return "network"
        default: return transport
        }
    }
    private var selection: PhysicalDeviceInfo?
    private var allowed: UUID? { selection?.identifier }
    private let backend: DeviceBackend
    init(_ backend: DeviceBackend) { self.backend = backend }

    /// Why a listed device cannot be used now, with what to do; nil when it can. A wired device must be connected;
    /// a paired device on the network is accepted, because its CoreDevice tunnel is raised on first use.
    static func connectionProblem(_ device: PhysicalDeviceInfo) -> String? {
        if let pairing = device.pairingState, pairing != "paired" {
            if device.isAppleWatch { return "pair the companion iPhone in Xcode (Window > Devices and Simulators), then trust this Mac on the Apple Watch" }
            return "the device is not paired with this Mac (\(pairing)). Connect it with a USB cable, unlock it and tap Trust, then retry"
        }
        if device.connectionState == "Connected" || device.tunnelState == "connected" { return nil }
        if let transport = device.transport, transport != "wired", device.pairingState == "paired" { return nil }
        return "\(device.connectionState ?? device.tunnelState ?? "unknown state"). Connect it with a USB cable, or keep it unlocked " +
            "with Wi-Fi on the same network as this Mac (paired before over USB), then retry"
    }

    func checkFixtureAccess(_ id: UUID) throws {
        guard allowed == id else { throw ToolError("Allow this physical device first.") }
        guard let target = try backend.list().first(where: { $0.identifier == id }) else { throw PhysicalDeviceError.noSuchDevice(id.uuidString) }
        if let problem = Self.connectionProblem(target) { throw PhysicalDeviceError.unavailable(problem) }
        let locked: Bool
        // The Watch's in-process check is slower but exact; without in-process CoreDevice use the devicectl fallback.
        if target.isAppleWatch, let readLock = backend.xctestLocked, let state = try? readLock(target) { locked = state }
        else { locked = try backend.locked(id) }
        guard !locked else { throw ToolError("Unlock the selected device before staging a fixture.") }
    }

    @discardableResult
    func checkXCTestAccess(_ id: UUID) throws -> PhysicalDeviceInfo {
        guard let selection, selection.identifier == id else { throw ToolError("Allow this physical device first.") }
        guard selection.isAppleWatch ? selection.pairingState == "paired" : selection.transport == "wired" else {
            throw ToolError("Select a paired Apple Watch or a USB iPhone or iPad for XCTest.")
        }
        guard let readLock = backend.xctestLocked else { throw ToolError("The in-process XCTest lock check is unavailable.") }
        guard try !readLock(selection) else { throw ToolError("Unlock the selected device before using XCTest.") }
        return selection
    }

    func call(_ args: [String: Any]) throws -> [String: Any] {
        let action = args["action"] as? String ?? ""
        func text(_ value: String) -> [String: Any] { ["content": [["type": "text", "text": value]]] }
        if action == "list" {
            let devices = try backend.list()
            return text((devices.isEmpty ? "No physical devices found." : devices.map {
                "\($0.identifier.uuidString) | \($0.name) | \($0.connectionState ?? "unknown") | \($0.transport.map(Self.transportName) ?? "unknown transport") | \($0.osVersion ?? "unknown OS") | \($0.identifier == allowed ? "allowed" : "not allowed")"
            }.joined(separator: "\n")) + (backend.status().map { "\n" + $0 } ?? ""))
        }
        let known = ["allow", "release", "screenshot", "tap", "swipe", "key", "type", "button"]
        guard known.contains(action) else { throw ToolError("Unknown device action: \(action).") }
        if action == "release" {
            selection = nil
            backend.endSessions(nil)
            return text("Physical device permission released.")
        }
        guard let value = args["device"] as? String, let id = UUID(uuidString: value) else {
            throw ToolError("Use a physical device identifier (UUID), never its name. Run device list, then device allow with device set to that identifier.")
        }
        if action == "allow" {
            guard let found = try backend.list().first(where: { $0.identifier == id }) else { throw PhysicalDeviceError.noSuchDevice(value) }
            if let problem = Self.connectionProblem(found) { throw PhysicalDeviceError.unavailable(problem) }
            if let previous = allowed, previous != id { backend.endSessions(previous) }
            selection = found
            return text("Allowed \(id.uuidString) (\(found.transport.map(Self.transportName) ?? "unknown transport")) for this server process.")
        }
        guard allowed == id else { throw ToolError("Device \(id.uuidString) is not allowed. Run device allow with device set to this identifier first.") }
        guard let found = try backend.list().first(where: { $0.identifier == id }) else { throw PhysicalDeviceError.noSuchDevice(value) }
        if found.isIPad && action != "screenshot" {
            throw ToolError("iPad uses XCTest (xctestStart…xctestStop) for UI automation, screenshot, and sensor_replay; raw HID input is unavailable.")
        }
        if let problem = Self.connectionProblem(found) { throw PhysicalDeviceError.unavailable(problem) }
        if found.isAppleWatch && !["screenshot", "tap", "swipe"].contains(action) {
            throw ToolError("Apple Watch supports screenshot, tap and swipe, plus XCTest. Keyboard and iPhone buttons are unavailable.")
        }
        let size = try backend.display(found)
        if action == "screenshot" {
            let caption = found.isIPad
                ? "iPad screen: \(Int(size.width))×\(Int(size.height)) points. Use XCTest actions (xctestDescribe, xctestTap, xctestType) for iPad input."
                : "Portrait screen: \(Int(size.width))×\(Int(size.height)) points; image pixels are input coordinates."
            return ["content": [["type": "text", "text": caption], ["type": "image", "data": try backend.screenshot(id, size), "mimeType": "image/jpeg"]]]
        }
        if try backend.locked(id) { throw ToolError("Device is locked or requires a passcode. Unlock it yourself and retry; mac-cu never enters a passcode.") }
        func coordinate(_ x: String, _ y: String) throws -> CGPoint {
            guard let px = (args[x] as? NSNumber)?.doubleValue, let py = (args[y] as? NSNumber)?.doubleValue,
                  px.isFinite, py.isFinite, px >= 0, py >= 0, px < size.width, py < size.height else {
                throw ToolError("\(x), \(y) must be coordinates inside the \(Int(size.width))×\(Int(size.height)) portrait screen in points.")
            }
            return CGPoint(x: px, y: py)
        }
        let seconds = (args["seconds"] as? NSNumber)?.doubleValue ?? (action == "swipe" ? 0.3 : 0.05)
        guard seconds.isFinite, seconds >= 0.02, seconds <= 10 else { throw ToolError("seconds must be between 0.02 and 10.") }
        var from = CGPoint.zero, to = CGPoint.zero, chords: [[UInt64]] = [], button: UInt64 = 0
        switch action {
        case "tap": from = try coordinate("x", "y")
        case "swipe": from = try coordinate("x", "y"); to = try coordinate("to_x", "to_y")
        case "key": chords = [try keyChord(args["key"] as? String ?? "")]
        case "type":
            guard let value = args["text"] as? String, !value.isEmpty else { throw ToolError("type needs text.") }
            // Each key takes about 30 ms and the lock state is read once before sending, so keep one call short.
            guard value.count <= DeviceTool.maxTypeLength else { throw ToolError("type accepts at most \(DeviceTool.maxTypeLength) characters per call; send longer text in parts.") }
            // Physical keyboard layout cannot be queried here; require the user to select US English.
            let strokes: [(UInt64, Bool)]
            do { strokes = try keyStrokes(value, korean: false) }
            catch { throw ToolError("type supports only US keyboard characters; select a US English hardware keyboard on the device. Unsupported text is refused.") }
            chords = strokes.map { $0.1 ? [0xE1, $0.0] : [$0.0] }
        case "button":
            let buttons: [String: UInt64] = ["home": 0x40, "lock": 0x30, "side": 0x30, "volumeUp": 0xE9, "volumeDown": 0xEA]
            guard let usage = buttons[args["button"] as? String ?? ""] else { throw ToolError("button must be home, lock, side, volumeUp or volumeDown.") }; button = usage
        default: throw ToolError("Unknown device action: \(action).")
        }
        // Taps, swipes, keys and Home go out on the digitizer feature; the other buttons on the button feature.
        // an iPhone 14 Pro (iOS 27.2, 2026-11-14): Home on the button feature had its barrier answered but was ignored 3 of 3
        // times, while Home on the digitizer feature returned to the Home Screen; volume works on the button feature.
        let buttonFeature = button == 0x40 ? PhysicalFeature.hid : PhysicalFeature.button
        let features: Set<String> = [action == "button" ? buttonFeature : PhysicalFeature.hid]
        /// Waits until the device has taken the events sent so far: CoreDevice's barrier on each feature used, or,
        /// where the link has none or the device does not answer within its timeout, the earlier fixed wait while the
        /// queued sends leave the process. The drain when every barrier was answered.
        func settle(_ link: HIDLink) -> HIDLink.Drain? {
            if let drained = link.drain(features), drained.acknowledged.isSuperset(of: features) { return drained }
            _ = withExtendedLifetime(link) { usleep(500_000) }
            return nil
        }
        func deliver(_ link: HIDLink) throws {
            // Opening the connection can take seconds; the device may have been locked meanwhile. This narrows the gap
            // but is not atomic: the host cannot tie an event to the device's lock state.
            if try backend.locked(id) { throw ToolError("Device became locked before the input was sent; nothing was sent. Unlock it yourself and retry; mac-cu never enters a passcode.") }
            var sent = 0
            switch action {
            case "tap": link.touch(from, phase: 0, screen: nil); usleep(UInt32(seconds * 1_000_000)); link.touch(from, phase: 2, screen: nil)
            case "swipe":
                link.touch(from, phase: 0, screen: nil)
                for step in 1...12 { usleep(UInt32(seconds / 12 * 1_000_000)); let t = CGFloat(step) / 12; link.touch(CGPoint(x: from.x + (to.x - from.x) * t, y: from.y + (to.y - from.y) * t), phase: 1, screen: nil) }
                link.touch(to, phase: 2, screen: nil)
            case "key", "type":
                // Keys go out as IndigoKeyboardButtonEvent on the digitizer feature. CoreDevice defines no such message
                // (it has no Indigo keyboard; Device Hub sends keys as HID reports to the UniversalHID keyboard service,
                // HIDKeyboard.send(key:state:) with capability .hid.keyboard). The device has accepted it so far; the
                // barrier after the last key confirms the connection drained, not that each key was taken. Prefer the
                // keyboard service if keys start to drop.
                for chord in chords {
                    if backend.cancelled() {
                        let drained = settle(link) != nil
                        throw ToolError("Cancelled after \(sent) of \(chords.count) keys were " + (drained ? "sent; the connection drained, which does not confirm the device acted." : "submitted to the device connection; delivery is not confirmed."))
                    }
                    link.chord(chord); sent += 1
                }
            case "button":
                guard link.button(page: 0x0c, usage: button, down: true, feature: buttonFeature) else {
                    throw ToolError("The device's button connection is not available; the button was not pressed. Check the connection and retry.")
                }
                usleep(UInt32(seconds * 1_000_000))
                // Always release a pressed button, even if the down event's connection failed meanwhile.
                link.button(page: 0x0c, usage: button, down: false, feature: buttonFeature)
            default: break
            }
        }
        let link = try backend.openFeatures?(id, size, features) ?? backend.open(id, size)
        try deliver(link)
        // RemoteXPC sends are asynchronous; the barrier tells when the device has taken them.
        if let drained = settle(link) {
            // The answer means the connection drained, not that the device acted: on an iPhone 14 Pro (iOS 27.2, 2026-11-14)
            // closing the connection right after it cancelled taps (4 of 4), and holding it 500 ms longer let the tap
            // through. Hold it without delaying the result; a process that exits sooner must wait that long itself.
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) { withExtendedLifetime(link) {} }
            return text("Sent \(action); the connection drained (barrier answered in \(Int((drained.seconds * 1000).rounded())) ms). That does not confirm the device acted: check the device screen.")
        }
        return text("Submitted \(action) to the device connection; delivery is not confirmed. Check the device screen for the result.")
    }
}

private func deviceJSON(_ command: [String], id: UUID, timeout: Int = 15) throws -> [String: Any] {
    let result = shell("/usr/bin/xcrun", ["devicectl", "device", "info"] + command + ["--device", id.uuidString, "--json-output", "-", "--quiet", "--timeout", "\(timeout)"], timeout: Double(timeout + 3))
    guard result.status == 0, let start = result.output.firstIndex(of: "{"),
          let data = String(result.output[start...]).data(using: .utf8),
          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let value = json["result"] as? [String: Any] else {
        throw PhysicalDeviceError.connectionRefused("devicectl \(command.joined(separator: " ")) failed; check Xcode, pairing and the device connection: \(result.output)")
    }
    return value
}

/// The Xcode device inventory. Entries of other devices are only compared locally, never reported.
private func deviceInventory() throws -> [[String: Any]] {
    let listing = shell("/usr/bin/xcrun", ["devicectl", "list", "devices", "--json-output", "-", "--quiet", "--timeout", "15"], timeout: 18)
    guard listing.status == 0, let start = listing.output.firstIndex(of: "{"),
          let data = String(listing.output[start...]).data(using: .utf8),
          let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let result = root["result"] as? [String: Any], let devices = result["devices"] as? [[String: Any]] else {
        throw PhysicalDeviceError.unavailable("Cannot read the Xcode device inventory; install or select Xcode and retry.")
    }
    return devices
}

/// The devicectl screenshot: the fallback when the in-process path is off or fails.
private func devicectlScreenshot(_ id: UUID) throws -> CGImage {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("mac-cu-device-\(UUID().uuidString).png")
    defer { try? FileManager.default.removeItem(at: url) }
    let result = shell("/usr/bin/xcrun", ["devicectl", "device", "capture", "screenshot", "--device", id.uuidString, "--destination", url.path, "--timeout", "15"], timeout: 18)
    guard result.status == 0, let image = NSImage(contentsOf: url), let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { throw PhysicalDeviceError.connectionRefused("Screenshot failed; check pairing and connection: \(result.output)") }
    return cg
}

/// One in-process session call with the devicectl path as fallback: when the in-process path is off for this
/// process, or the call fails (the fallback then reports the device's real condition).
func physicalWithFallback<T>(_ sessions: PhysicalDeviceSessions, _ id: UUID, seconds: Double, _ what: String,
                             _ inProcess: @escaping (PhysicalDeviceSession) async throws -> T, fallback: () throws -> T) throws -> T {
    if let session = sessions.session(id) {
        if case .success(let value) = Result(catching: { try physicalBlocking(seconds, what) { try await inProcess(session) } }) { return value }
    }
    return try fallback()
}

/// One HID feature connection of a physical device as an input link uses it.
struct PhysicalInputRoute {
    let send: (xpc_object_t) -> Bool
    let barrier: (Double) -> PhysicalHIDLink.Barrier
}

/// An input link over per-feature connections: each message goes to the connection of its featureIdentifier (none:
/// not sent), and drain sends CoreDevice's barrier on each feature asked for, waiting up to barrierWait for each.
func physicalInputLink(_ routes: [String: PhysicalInputRoute], connection: xpc_object_t, size: CGSize, deviceID: String,
                       barrierWait: Double = 2) -> HIDLink {
    HIDLink(externalConnection: connection, size: size, deviceID: deviceID, send: { _, message in
        let feature = xpc_dictionary_get_string(message, "featureIdentifier").map { String(cString: $0) } ?? ""
        guard let route = routes[feature] else { return false }
        return route.send(message)
    }, drain: { features in
        var drained = HIDLink.Drain()
        let start = CFAbsoluteTimeGetCurrent()
        for feature in features.sorted() {
            guard let route = routes[feature] else { drained.unconfirmed[feature] = "no connection"; continue }
            switch route.barrier(barrierWait) {
            case .acknowledged: drained.acknowledged.insert(feature)
            case .timedOut: drained.unconfirmed[feature] = "no barrier answer within \(barrierWait) s"
            case .unsupported: drained.unconfirmed[feature] = "barrier unavailable"
            case .failed(let reason): drained.unconfirmed[feature] = reason
            }
        }
        drained.seconds = CFAbsoluteTimeGetCurrent() - start
        return drained
    })
}

private func physicalBackend() -> DeviceBackend {
    let core = PhysicalDeviceLink()
    let sessions = PhysicalDeviceSessions(available: { core.inProcessCheck() }, makePort: { CoreDevicePort() })
    func devicectlLocked(_ id: UUID, timeout: Int = 15) throws -> Bool {
        let state = try deviceJSON(["lockState"], id: id, timeout: timeout)
        guard let passcode = state["passcodeRequired"] as? Bool else { throw ToolError("Cannot read device lock state; input refused.") }
        return passcode
    }
    /// One connection per HID feature the action uses (CoreDevice caches them per device and feature), the digitizer's
    /// as the link's own. Sends are routed by the message's featureIdentifier; drain sends CoreDevice's barrier on each.
    func openInput(_ id: UUID, _ size: CGSize, _ features: Set<String>) throws -> HIDLink {
        guard dlsym(UnsafeMutableRawPointer(bitPattern: -2), "xpc_remote_connection_send_message") != nil else { throw PhysicalDeviceError.symbolMissing("xpc_remote_connection_send_message") }
        var links: [String: PhysicalHIDLink] = [:]
        for feature in [PhysicalFeature.hid] + features.subtracting([PhysicalFeature.hid]).sorted() {
            // A network device's HID features appear once its tunnel is up; the session raises it and keeps it.
            // If that fails, opening the connection below reports the device's state.
            if let session = sessions.session(id) {
                _ = try? physicalBlocking(45, "the tunnel for input") { try await session.prepared(for: feature) }
            }
            let done = DispatchSemaphore(value: 0)
            let outcome = PhysicalBox<Result<PhysicalHIDLink, Error>>()
            Task { do { outcome.value = .success(try await core.openFeature(identifier: id, feature: feature)) } catch { outcome.value = .failure(error) }; done.signal() }
            guard done.wait(timeout: .now() + 20) == .success, let opened = outcome.value else {
                throw PhysicalDeviceError.connectionRefused("HID connection (\(feature.split(separator: ".").last ?? "")) timed out; check pairing and try again")
            }
            links[feature] = try opened.get()
        }
        let digitizer = links[PhysicalFeature.hid]!
        return physicalInputLink(links.mapValues { remote in
            PhysicalInputRoute(send: { message in remote.send(message) }, barrier: { remote.barrier(timeout: $0) })
        }, connection: digitizer.connection, size: size, deviceID: id.uuidString)
    }
    return DeviceBackend(list: {
        let devices = try deviceInventory()
        // CoreDevice's own state when it is usable; the inventory alone otherwise.
        let known = Dictionary((try? core.listDevices())?.map { ($0.identifier, $0) } ?? [], uniquingKeysWith: { a, _ in a })
        return devices.compactMap { item -> PhysicalDeviceInfo? in
            let properties = item["properties"] as? [String: Any]
            let hardware = (properties?["hardware"] as? [String: Any]) ?? (item["hardwareProperties"] as? [String: Any])
            guard let kind = hardware?["deviceType"] as? String, ["iPhone", "iPad", "appleWatch"].contains(kind),
                  hardware?["reality"] as? String == "physical",
                  let value = item["identifier"] as? String, let id = UUID(uuidString: value) else { return nil }
            let connection = (properties?["connection"] as? [String: Any]) ?? (item["connectionProperties"] as? [String: Any])
            let device = (item["deviceProperties"] as? [String: Any])
            let transport = connection?["transportType"] as? String, tunnel = connection?["tunnelState"] as? String
            sessions.noteTransport(id, transport)
            let own = known[id]
            let system = ["appleWatch": "watchOS", "iPad": "iPadOS"][kind] ?? "iOS"
            return PhysicalDeviceInfo(identifier: id, name: own?.name ?? (device?["name"] as? String ?? ""), model: hardware?["marketingName"] as? String,
                                      osVersion: own?.osVersion ?? (device?["osVersionNumber"] as? String).map { system + " " + $0 },
                                      transport: transport,
                                      connectionState: own?.connectionState ?? (tunnel == "connected" ? "Connected" : tunnel.map { "tunnel \($0)" }),
                                      pairingState: connection?["pairingState"] as? String, tunnelState: tunnel, hardwareUDID: hardware?["udid"] as? String,
                                      isAppleWatch: kind == "appleWatch", isIPad: kind == "iPad")
        }
    }, locked: { id in
        // The rule is that mac-cu never enters a passcode. A device without a passcode reports false even
        // on its lock screen; input there cannot type a passcode, so it is allowed.
        try physicalWithFallback(sessions, id, seconds: 8, "the lock state", { try await $0.lockState() }, fallback: { try devicectlLocked(id) })
    }, display: { device in
        let id = device.identifier
        let display = try physicalWithFallback(sessions, id, seconds: 8, "the display", { try await $0.displayInfo() }, fallback: {
            physicalPrimaryDisplay(try deviceJSON(["displays"], id: id))
        })
        let points = display.points(for: device)
        guard let points else { throw ToolError("Cannot determine a primary portrait display; landscape and unknown orientation are refused.") }
        return points
    }, screenshot: { id, size in
        let image = try physicalWithFallback(sessions, id, seconds: 10, "the screenshot", { session in
            do { return try await session.capture() }
            catch PhysicalSessionError.busy {
                // Another capture holds the device's capture step for a few tens of ms.
                for _ in 0..<5 {
                    try await Task.sleep(nanoseconds: 60_000_000)
                    do { return try await session.capture() } catch PhysicalSessionError.busy { continue }
                }
                throw PhysicalSessionError.busy
            }
        }, fallback: { try devicectlScreenshot(id) })
        return try jpegBase64(image, size: size)
    }, open: { id, size in
        try openInput(id, size, [PhysicalFeature.hid])
    }, openFeatures: { id, size, features in
        try openInput(id, size, features)
    }, cancelled: { currentSession?.requestCancelled ?? false }, endSessions: { sessions.end($0) }, status: {
        sessions.unavailableReason.map { "In-process CoreDevice is off (\($0)); screenshots and device state use devicectl (slower)." }
    }, xctestLocked: { device in
        guard let session = sessions.session(device.identifier) else { throw ToolError("XCTest requires the in-process CoreDevice lock check.") }
        return try physicalBlocking(device.isAppleWatch ? 45 : 8, "the XCTest lock state") { try await session.lockState() }
    })
}

private func physicalPrimaryDisplay(_ info: [String: Any]) -> PhysicalDisplayState {
    guard let displays = info["displays"] as? [[String: Any]],
          let display = displays.first(where: { ($0["primary"] as? Bool) == true }),
          let pixels = display["nativeSize"] as? [Double], pixels.count == 2,
          let scale = display["pointScale"] as? NSNumber else { return PhysicalDisplayState() }
    let orientation = info["orientation"] as? [String: Any]
    return .primary(pixels: CGSize(width: pixels[0], height: pixels[1]), scale: CGFloat(scale.doubleValue),
                    rotation: display["currentOrientation"] as? String,
                    orientation: orientation.map { $0["currentDeviceOrientation"] as? String ?? "unknown" })
}

let physicalDeviceTool = DeviceTool(physicalBackend())
func deviceTool(_ arguments: [String: Any]) throws -> [String: Any] { try physicalDeviceTool.call(arguments) }
