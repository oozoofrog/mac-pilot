// The simulator tool: touches, keys, buttons and text for a booted iOS Simulator, sent as HID events
// to the simulator's dtuhidd (Xcode 27 and later), so the Simulator window can stay in the background.
//
// Undocumented parts: CoreSimulator (SimServiceContext, SimDevice lookup:error:) to find the device
// and the port of its HID service, and three XPC functions for simulator ports (resolved with dlsym).
// The message format is the one of idb's FBSimulatorDTUHIDTransport (github.com/cameroncooke/idb).

import AppKit
import IOKit
import XPC

let hidService = "com.apple.coredevice.feature.remote.hid.digitizer"
let vendorService = "com.apple.coredevice.feature.remote.hid.vendordefined"

/// A connection to the HID service of one booted simulator. dtuhidd makes its virtual keyboard and touch
/// screen when the first message comes, and removes them when the connection closes. iOS drops key
/// events from a keyboard that it has not set up yet, and an app keeps its keyboard layout for a
/// keyboard, so mac-cu keeps one connection for each simulator until the server ends.
final class HIDLink {
    let deviceID: String
    let connection: xpc_connection_t
    private let transmit: (xpc_object_t) -> Bool
    private let simulatorOverlay: Bool
    let size: CGSize  // The screen in points.
    private let statusLock = NSLock()
    private var isClosed = false
    var closed: Bool {
        get { statusLock.lock(); defer { statusLock.unlock() }; return isClosed }
        set { statusLock.lock(); defer { statusLock.unlock() }; isClosed = newValue }
    }

    init(connection: xpc_connection_t, size: CGSize, deviceID: String, send: ((xpc_object_t) -> Bool)? = nil) {
        self.connection = connection
        self.size = size
        self.deviceID = deviceID
        self.simulatorOverlay = true
        self.transmit = send ?? { message in
            xpc_connection_send_message(connection, message)
            let done = DispatchSemaphore(value: 0)
            xpc_connection_send_barrier(connection) { done.signal() }
            return done.wait(timeout: .now() + 2) == .success
        }
    }

    // The caller retains the CoreDevice peers and supplies the RemoteXPC sender (routing by the message's
    // featureIdentifier) and, optionally, the delivery barrier.
    init(externalConnection connection: xpc_object_t, size: CGSize, deviceID: String,
         send: @escaping (xpc_object_t, xpc_object_t) -> Bool, drain: ((Set<String>) -> Drain)? = nil) {
        self.connection = connection
        self.size = size
        self.deviceID = deviceID
        self.simulatorOverlay = false
        self.transmit = { send(connection, $0) }
        self.externalDrain = drain
    }

    /// Physical devices: which features' barriers the device answered after the last event, and why the others are
    /// unconfirmed (no answer in time, an error, or no barrier on that path).
    struct Drain {
        var acknowledged: Set<String> = []
        var unconfirmed: [String: String] = [:]
        var seconds: Double = 0
    }
    private var externalDrain: ((Set<String>) -> Drain)?
    /// Waits for the device to take the events sent so far on these features; nil when this link has no barrier
    /// (the simulator, whose sends already wait for dtuhidd).
    func drain(_ features: Set<String>) -> Drain? { externalDrain?(features) }

    @discardableResult
    func send(_ type: String, _ payload: xpc_object_t, feature: String = hidService) -> Bool {
        guard !closed else { return false }
        let message = xpc_dictionary_create(nil, nil, 0)
        xpc_dictionary_set_string(message, "messageType", type)
        xpc_dictionary_set_bool(message, "isBarrier", false)
        xpc_dictionary_set_string(message, "featureIdentifier", feature)
        xpc_dictionary_set_value(message, "payload", payload)
        return transmit(message) && !closed
    }

    /// A USB HID keyboard usage (page 7).
    func key(_ usage: UInt64, down: Bool) {
        let payload = xpc_dictionary_create(nil, nil, 0)
        xpc_dictionary_set_uint64(payload, "usageCode", usage)
        xpc_dictionary_set_uint64(payload, "state", down ? 1 : 2)
        send("IndigoKeyboardButtonEvent", payload)
        usleep(15_000)
    }

    /// feature: the simulator's dtuhidd takes buttons on the digitizer feature. A physical device (iPhone 14 Pro, iOS 27.2,
    /// 2026-11-14) took volume on CoreDevice's button feature (com.apple.coredevice.feature.remote.hid.button) and
    /// Home only on the digitizer feature; the caller picks.
    @discardableResult
    func button(page: UInt64, usage: UInt64, down: Bool, feature: String = hidService) -> Bool {
        let payload = xpc_dictionary_create(nil, nil, 0)
        xpc_dictionary_set_uint64(payload, "usagePage", page)
        xpc_dictionary_set_uint64(payload, "usageCode", usage)
        xpc_dictionary_set_uint64(payload, "state", down ? 1 : 2)
        return send("IndigoButtonEvent", payload, feature: feature)
    }

    /// Touchscreens that have had their first event.
    var warmed: Set<UInt64> = []

    /// One finger at a point in points, or two with second (pinch, rotate). phase: 0 down, 1 move, 2 up. With screen (a
    /// device with more than one), the touch goes to that screen's own touchscreen; without, to the main screen (target 0).
    func touch(_ point: CGPoint, phase: UInt64, screen: ActiveScreen?, second: CGPoint? = nil) {
        func normalized(_ point: CGPoint) -> CGPoint { screen?.normalized(point) ?? CGPoint(x: point.x / size.width, y: point.y / size.height) }
        func position(_ point: CGPoint) -> xpc_object_t {
            let at = normalized(point)
            let position = xpc_dictionary_create(nil, nil, 0)
            xpc_dictionary_set_double(position, "x", Double(at.x))
            xpc_dictionary_set_double(position, "y", Double(at.y))
            return position
        }
        let target = screen?.target ?? 0
        func event(_ phase: UInt64) {
            let payload = xpc_dictionary_create(nil, nil, 0)
            xpc_dictionary_set_value(payload, "pointOne", position(point))
            if let second { xpc_dictionary_set_value(payload, "pointTwo", position(second)) }
            xpc_dictionary_set_uint64(payload, "eventType", phase)
            xpc_dictionary_set_uint64(payload, "edge", 0)
            xpc_dictionary_set_uint64(payload, "target", target)
            send("IndigoDigitizerEvent", payload)
        }
        // dtuhidd drops the first touches to a touchscreen it has not set up; an end with no contact sets it up (idb waits 400 ms).
        if simulatorOverlay, target != 0, !warmed.contains(target) {
            event(2)
            usleep(400_000)
            warmed.insert(target)
        }
        event(phase)
        var contacts = [GestureContact(id: 1, point: point, touching: phase != 2)]
        if let second { contacts.append(GestureContact(id: 2, point: second, touching: phase != 2)) }
        if simulatorOverlay { showSimulatorTouches(deviceID, contacts: contacts, screen: screen) }
    }

    /// A control of a foldable device (Device Hub's hinge slider and orientation picker): a vendor-defined HID event
    /// (page 0xff61, usage 0x5b) whose data is a serialized dictionary. dtuhidd takes it on any of its HID connections and
    /// gives it to the device's avpCustom service (0x500). Format from the strings of Device Hub's CoreDevicePopDeviceKitExtension.
    func deviceControl(_ source: String, _ type: String, _ value: Any) throws {
        let report: [String: Any] = ["provider": "com.apple.Virtualization.VirtualMachines", "source": source, "type": type, "value": value]
        let data = IOCFSerialize(report as CFDictionary, 1) as Data
        let payload = xpc_dictionary_create(nil, nil, 0)
        xpc_dictionary_set_uint64(payload, "usagePage", 0xff61)
        xpc_dictionary_set_uint64(payload, "usage", 0x5b)
        xpc_dictionary_set_uint64(payload, "version", 0)
        data.withUnsafeBytes { xpc_dictionary_set_data(payload, "data", $0.baseAddress!, data.count) }
        guard send("IndigoVendorDefinedEvent", payload, feature: vendorService) else {
            throw ToolError("The device control could not be delivered. Read the device state before retrying.")
        }
    }

    /// Turns the Digital Crown of an Apple Watch as Device Hub does for a mouse wheel over the crown (DeviceKit's "Crown
    /// Scroll", seen in its log): IndigoScrollEvent on the scroll service, target 0 (digitalCrown; 1 is a dial), NSEvent
    /// phases began 1, changed 4, ended 8, about 20 ms apart. Events that come all at once do not turn it.
    func crown(_ amount: Double) {
        let steps = max(Int((abs(amount) / 6).rounded(.up)), 1), step = amount / Double(steps)
        crownEvent(1, step / 2)
        for _ in 0..<steps { crownEvent(4, step) }
        crownEvent(8, 0)
    }

    /// One event of a crown turn: phase 1 began, 4 changed, 8 ended (NSEvent's phases).
    func crownEvent(_ phase: UInt64, _ dy: Double) {
        let point = xpc_dictionary_create(nil, nil, 0)
        xpc_dictionary_set_double(point, "x", 0)
        xpc_dictionary_set_double(point, "y", dy)
        xpc_dictionary_set_double(point, "z", 0)
        let payload = xpc_dictionary_create(nil, nil, 0)
        xpc_dictionary_set_value(payload, "point", point)
        xpc_dictionary_set_uint64(payload, "phase", phase)
        xpc_dictionary_set_uint64(payload, "momentum", 0)
        xpc_dictionary_set_uint64(payload, "target", 0)
        send("IndigoScrollEvent", payload, feature: "com.apple.coredevice.feature.remote.hid.scroll")
        usleep(20_000)
    }

    /// Presses the keys of a chord in order and releases them in reverse order.
    func chord(_ usages: [UInt64]) {
        usages.forEach { key($0, down: true) }
        usages.reversed().forEach { key($0, down: false) }
    }
}

var hidLinks: [String: HIDLink] = [:]
// Serialized by handleQueue; survives LCD close/reopen, shared by absolute and relative commands.
var simulatorRotationStates: [String: SimulatorRotationState] = [:]

// MARK: - CoreSimulator

/// The default device set of the selected Xcode.
func simulatorDevices() throws -> [NSObject] {
    guard dlopen("/Library/Developer/PrivateFrameworks/CoreSimulator.framework/CoreSimulator", RTLD_NOW) != nil,
          let contextClass = NSClassFromString("SimServiceContext") as AnyObject? else {
        throw ToolError("CoreSimulator was not found. Install Xcode and its iOS Simulator.")
    }
    let developerDir = shell("/usr/bin/xcode-select", ["-p"]).output.trimmingCharacters(in: .whitespacesAndNewlines)
    typealias ContextFn = @convention(c) (AnyObject, Selector, NSString, UnsafeMutablePointer<NSError?>?) -> AnyObject?
    typealias SetFn = @convention(c) (AnyObject, Selector, UnsafeMutablePointer<NSError?>?) -> AnyObject?
    var error: NSError?
    let contextSelector = NSSelectorFromString("sharedServiceContextForDeveloperDir:error:")
    let setSelector = NSSelectorFromString("defaultDeviceSetWithError:")
    guard let contextIMP = class_getMethodImplementation(object_getClass(contextClass), contextSelector),
          let context = unsafeBitCast(contextIMP, to: ContextFn.self)(contextClass, contextSelector, developerDir as NSString, &error),
          let setIMP = class_getMethodImplementation(object_getClass(context), setSelector),
          let set = unsafeBitCast(setIMP, to: SetFn.self)(context, setSelector, &error),
          let devices = set.value(forKey: "devices") as? [NSObject]
    else { throw ToolError("CoreSimulator did not give the simulators: \(error?.localizedDescription ?? "no reason").") }
    return devices
}

func udid(of device: NSObject) -> String { (device.value(forKey: "UDID") as? NSUUID)?.uuidString ?? "" }

func isBooted(_ device: NSObject) -> Bool { device.value(forKey: "stateString") as? String == "Booted" }

/// The screen of the device in points.
func screenSize(of device: NSObject) -> CGSize {
    let type = device.value(forKey: "deviceType") as? NSObject
    let pixels = (type?.value(forKey: "mainScreenSize") as? NSValue)?.sizeValue ?? .zero
    let scale = CGFloat((type?.value(forKey: "mainScreenScale") as? NSNumber)?.doubleValue ?? 1)
    return CGSize(width: pixels.width / scale, height: pixels.height / scale)
}

/// The booted simulator with this name or UDID, or the only booted one when name is empty.
func bootedDevice(_ name: String) throws -> NSObject {
    let booted = try simulatorDevices().filter(isBooted)
    let names = booted.map { "\($0.value(forKey: "name") ?? "?") (\(udid(of: $0)))" }.joined(separator: ", ")
    if name.isEmpty {
        guard booted.count == 1 else {
            throw ToolError(booted.isEmpty ? "No simulator is booted." : "Several simulators are booted. Name one in device: \(names).")
        }
        return booted[0]
    }
    let matches = booted.filter { udid(of: $0).caseInsensitiveCompare(name) == .orderedSame || $0.value(forKey: "name") as? String == name }
    guard matches.count == 1 else {
        throw ToolError(matches.isEmpty ? "No booted simulator \"\(name)\". Booted: \(names.isEmpty ? "none" : names)."
                                        : "Several booted simulators are named \"\(name)\". Use the UDID: \(names).")
    }
    return matches[0]
}

/// An XPC connection, not yet resumed, to a CoreDevice service of a booted simulator.
func simulatorConnection(_ device: NSObject, _ service: String) throws -> xpc_connection_t {
    typealias LookupFn = @convention(c) (AnyObject, Selector, NSString, UnsafeMutablePointer<NSError?>?) -> UInt32
    let selector = NSSelectorFromString("lookup:error:")
    var error: NSError?
    guard let lookupIMP = class_getMethodImplementation(object_getClass(device), selector) else {
        throw ToolError("This CoreSimulator has no lookup:error:.")
    }
    let port = unsafeBitCast(lookupIMP, to: LookupFn.self)(device, selector, service as NSString, &error)
    guard port != 0 else {
        throw ToolError("The simulator has no \(service) (it needs Xcode 27 or later, and a fully booted simulator): \(error?.localizedDescription ?? "no reason").")
    }
    let handle = dlopen(nil, RTLD_NOW)
    guard let endpointSymbol = dlsym(handle, "xpc_endpoint_create_mach_port_4sim"),
          let connectionSymbol = dlsym(handle, "xpc_connection_create_from_endpoint"),
          let sim2HostSymbol = dlsym(handle, "xpc_connection_enable_sim2host_4sim"),
          let endpoint = unsafeBitCast(endpointSymbol, to: (@convention(c) (mach_port_t, UInt64, UInt64) -> xpc_object_t?).self)(port, 0, 0),
          let connection = unsafeBitCast(connectionSymbol, to: (@convention(c) (xpc_object_t) -> xpc_connection_t?).self)(endpoint)
    else { throw ToolError("macOS has no XPC connection to simulator ports.") }
    // Without this, dtuhidd sees the peer but not the messages.
    unsafeBitCast(sim2HostSymbol, to: (@convention(c) (xpc_connection_t) -> Void).self)(connection)
    return connection
}

/// A replaced connection may report its cancellation after the new link is already in use.
func simulatorHIDConnectionFailed(_ link: HIDLink, deviceID id: String) {
    link.closed = true
    handleQueue.async {
        guard hidLinks[id] === link else { return }
        invalidateSimulatorObservation(id)
        showSimulatorTouches(id, contacts: [], screen: nil)
    }
}

func hidLink(for device: NSObject) throws -> HIDLink {
    let id = udid(of: device)
    if let link = hidLinks[id], !link.closed { return link }
    invalidateSimulatorObservation(id)
    let connection = try simulatorConnection(device, hidService)
    let link = HIDLink(connection: connection, size: screenSize(of: device), deviceID: id)
    xpc_connection_set_event_handler(connection) { event in
        if xpc_get_type(event) == XPC_TYPE_ERROR {
            simulatorHIDConnectionFailed(link, deviceID: id)
        }
    }
    xpc_connection_resume(connection)
    hidLinks[id] = link
    // Reconnecting input must not reset the visible device pose or advance a failed request.
    // The first message makes the devices. A Shift release changes nothing; then iOS sets them up.
    link.key(0xE1, down: false)
    usleep(1_000_000)
    return link
}

// MARK: - Screens

/// The integrated screen that is on, on a device with more than one (iPhone Duo: the cover, or the inner screen
/// when it is open). Touches reach it through its own touchscreen (digitizer target), with points in 0...1 of the
/// screen before rotation, as idb does (SimulatorDisplayGeometry, github.com/facebook/idb).
struct ActiveScreen {
    let id: String           // CoreDevice's displayId, the Screen ID of simctl io
    let name: String
    let target: UInt64       // its touchscreen
    let unrotated: CGSize    // points before rotation
    var rotation: String     // Host presentation: rot0, rot90, rot180 or rot270
    var foldable = true      // more than one integrated screen (iPhone Duo); false for a turned device with one
    var primary = false      // CoreDevice's primary screen: the cover of iPhone Duo
    var framebufferRotation: String? = nil // Actual guest readback, when presentation differs.
    var guestRotation: String { framebufferRotation ?? rotation }
    var presentationQuarterTurns: Int { (rotationQuarterTurns(rotation) - rotationQuarterTurns(guestRotation) + 4) % 4 }
    var guestPoints: CGSize {
        guestRotation == "rot90" || guestRotation == "rot270" ? CGSize(width: unrotated.height, height: unrotated.width) : unrotated
    }
    /// App AX frames and simctl images already follow the guest's orientation.
    func presentingGuestFrame(_ frame: CGRect) -> CGRect {
        ActiveScreen(id: id, name: name, target: target, unrotated: guestPoints,
                     rotation: "rot\(presentationQuarterTurns * 90)").shown(frame)
    }

    /// The screen in points as it is shown: the pixels of its screenshot.
    var points: CGSize {
        rotation == "rot90" || rotation == "rot270" ? CGSize(width: unrotated.height, height: unrotated.width) : unrotated
    }

    /// A point of the screen as shown, in 0...1 of the screen before rotation.
    func normalized(_ p: CGPoint) -> CGPoint {
        let w = unrotated.width, h = unrotated.height
        let u: CGPoint
        switch rotation {
        case "rot90": u = CGPoint(x: p.y, y: h - p.x)
        case "rot180": u = CGPoint(x: w - p.x, y: h - p.y)
        case "rot270": u = CGPoint(x: w - p.y, y: p.x)
        default: u = p
        }
        return CGPoint(x: u.x / w, y: u.y / h)
    }

    /// A frame in points of the screen before rotation, on the screen as shown.
    func shown(_ r: CGRect) -> CGRect {
        let w = unrotated.width, h = unrotated.height
        switch rotation {
        case "rot90": return CGRect(x: h - r.maxY, y: r.minX, width: r.height, height: r.width)
        case "rot180": return CGRect(x: w - r.maxX, y: h - r.maxY, width: r.width, height: r.height)
        case "rot270": return CGRect(x: r.minY, y: w - r.maxX, width: r.height, height: r.width)
        default: return r
        }
    }
}

/// The touchscreen target of each screen (by its unique ID), for each simulator.
var touchscreenTargets: [String: [String: UInt64]] = [:]

/// The screen that is on, for a device with more than one integrated screen (iPhone Duo) or one that is turned; nil for a
/// device with one screen that is not turned. CoreDevice is asked at each action (0.15 s), since a fold or turn can come from anywhere.
func activeScreen(of device: NSObject, readback: [[String: Any]]? = nil) throws -> ActiveScreen? {
    let id = udid(of: device)
    // A synchronous read supersedes any earlier passive read, including external pose changes.
    simulatorObserver(id).invalidate()
    guard let raw = readback ?? displays(of: id) else { return nil }
    if touchscreenTargets[id] == nil,
       raw.filter({ ($0["type"] as? [String: Any])?["integrated"] != nil }).count > 1 {
        touchscreenTargets[id] = try touchscreens(of: device)
    }
    var state = simulatorRotationStates[id] ?? SimulatorRotationState()
    state.observe(SimulatorRotationObservation.read(raw))
    simulatorRotationStates[id] = state
    return try simulatorScreen(raw, targets: touchscreenTargets[id] ?? [:], pose: state.presentation)
}

/// Pure snapshot projection. Background readers never touch HID links, session, rotation state or target caches.
func simulatorScreen(_ displays: [[String: Any]], targets: [String: UInt64], pose: SimulatorOrientation?) throws -> ActiveScreen? {
    let integrated = displays.filter { ($0["type"] as? [String: Any])?["integrated"] != nil }
    guard !integrated.isEmpty else { return nil }
    guard let on = integrated.first(where: { $0["active"] as? Bool == true }),
          let bounds = on["bounds"] as? [[NSNumber]], bounds.count == 2, bounds[1].count == 2,
          let scale = (on["pointScale"] as? NSNumber)?.doubleValue, scale > 0 else {
        throw ToolError("No screen of the simulator is on. Press the lock button to wake it, then try again.")
    }
    let foldable = integrated.count > 1
    let rotation = on["currentOrientation"] as? String ?? "rot0"
    if !foldable && rotation == "rot0" && pose == nil { return nil }
    let target = foldable ? (on["uniqueId"] as? String).flatMap { targets[$0] } : 0
    guard let target else { throw ToolError("The active screen has no known touchscreen. Refresh the device connection.") }
    var screen = ActiveScreen(id: "\(on["displayId"] ?? "")", name: on["name"] as? String ?? "main", target: target,
        unrotated: CGSize(width: bounds[1][0].doubleValue / scale, height: bounds[1][1].doubleValue / scale),
        rotation: rotation, foldable: foldable, primary: on["primary"] as? Bool ?? false)
    if let pose {
        screen.framebufferRotation = rotation
        screen.rotation = pose.screenRotation(inner: foldable && !screen.primary)
    }
    return screen
}

struct SimulatorObservedScreen {
    let booted: Bool
    let screen: ActiveScreen?
    let angle: Double?
    var rotationObservation: SimulatorRotationObservation? = nil
}
private let simulatorObservationLock = NSLock()
private var simulatorObservationLanes: [String: SimulatorObservationLane<SimulatorObservedScreen>] = [:]
private var simulatorAngleLanes: [String: SimulatorObservationLane<Double>] = [:]
func simulatorAngleObserver(_ id: String) -> SimulatorObservationLane<Double> {
    simulatorObservationLock.withLock {
        if let lane = simulatorAngleLanes[id] { return lane }
        let lane = SimulatorObservationLane<Double>(); simulatorAngleLanes[id] = lane; return lane
    }
}
func invalidateSimulatorObservation(_ id: String) {
    simulatorObserver(id).invalidate(); simulatorAngleObserver(id).invalidate()
}
func simulatorObserver(_ id: String) -> SimulatorObservationLane<SimulatorObservedScreen> {
    simulatorObservationLock.withLock {
        if let lane = simulatorObservationLanes[id] { return lane }
        let lane = SimulatorObservationLane<SimulatorObservedScreen>()
        simulatorObservationLanes[id] = lane
        return lane
    }
}

/// Called on handleQueue; captures immutable mapping, then all slow status IO runs off that queue.
func observeSimulator(_ device: NSObject, for seconds: TimeInterval = 0) {
    let id = udid(of: device), lane = simulatorObserver(udid(of: device))
    let targets = touchscreenTargets[id] ?? [:], pose = simulatorRotationStates[id]?.presentation
    let ticket = lane.ticket
    let window = DispatchQueue.main.sync { simulatorWindows[id] }
    lane.observe(for: seconds, read: { task in
        guard isBooted(device) else { return SimulatorObservedScreen(booted: false, screen: nil, angle: nil) }
        guard let raw = displays(of: id, task: task), !task.isCancelled,
              case let .success(projected) = Result(catching: { try simulatorScreen(raw, targets: targets, pose: pose) }) else { return nil }
        return SimulatorObservedScreen(booted: true, screen: projected, angle: nil, rotationObservation: SimulatorRotationObservation.read(raw))
    }, receive: { [weak window] value in
        guard let window, simulatorWindows[id] === window else { return }
        guard value.booted else { window.window.close(); return }
        window.show(value.screen)
        window.observedRotation(value.rotationObservation)
        handleQueue.async {
            guard lane.isCurrent(ticket) else { return }
            var state = simulatorRotationStates[id] ?? SimulatorRotationState()
            state.observe(value.rotationObservation)
            simulatorRotationStates[id] = state
        }
        if !window.toolbox.busy && !window.toolbox.manualPending { window.pointerGeometryReady = true }
    })
    if !targets.isEmpty {
        simulatorAngleObserver(id).observe(for: seconds, read: { task in
            guard isBooted(device), !task.isCancelled else { return nil }
            return try? hingeAngle(of: device, cancelled: { task.isCancelled })
        }, receive: { [weak window] angle in
            guard let window, simulatorWindows[id] === window else { return }
            window.toolbox.updateAngle(angle); window.content.chrome.updateAngle(angle)
        })
    }
}

/// The hinge angle in degrees of a foldable simulator: the first sample of CoreDevice's streamhingeangle action, which
/// dtdeviceinfod in the simulator serves. The message is CoreDevice's action invocation; each key below was found by sending
/// it without that key and reading dtdeviceinfod's decoding error.
func hingeAngle(of device: NSObject, cancelled: () -> Bool = { false }) throws -> Double {
    let feature = "com.apple.coredevice.feature.monitormotion"
    let connection = try simulatorConnection(device, feature)
    let sample = DispatchSemaphore(value: 0)
    let valueLock = NSLock()
    var angle: Double?, failure = ""
    xpc_connection_set_event_handler(connection) { event in
        valueLock.lock(); defer { valueLock.unlock() }
        guard xpc_get_type(event) == XPC_TYPE_DICTIONARY else { return }
        if let error = xpc_dictionary_get_dictionary(event, "CoreDevice.error"),
           let info = xpc_dictionary_get_dictionary(error, "userInfo"), let text = xpc_dictionary_get_string(info, "NSDebugDescription") {
            failure = String(cString: text)
            sample.signal()
        }
        // {CoreDevice.XPCMessageKey.sideChannelStatus: {pushing: {elements: [{angle: {value, unit}, ...}]}}}
        guard let status = xpc_dictionary_get_dictionary(event, "CoreDevice.XPCMessageKey.sideChannelStatus"),
              let pushing = xpc_dictionary_get_dictionary(status, "pushing"),
              let elements = xpc_dictionary_get_array(pushing, "elements"), xpc_array_get_count(elements) > 0,
              let value = xpc_dictionary_get_dictionary(xpc_array_get_dictionary(elements, 0)!, "angle")
        else { return }
        angle = xpc_dictionary_get_double(value, "value")
        sample.signal()
    }
    xpc_connection_resume(connection)
    defer { xpc_connection_cancel(connection) }
    func dictionary(_ values: [String: xpc_object_t]) -> xpc_object_t {
        let d = xpc_dictionary_create(nil, nil, 0)
        values.forEach { xpc_dictionary_set_value(d, $0.key, $0.value) }
        return d
    }
    let degrees = dictionary(["symbol": xpc_string_create("°"),
                              "converter": dictionary(["coefficient": xpc_double_create(1), "constant": xpc_double_create(0)])])
    let interval = xpc_array_create(nil, 0)  // Swift Duration: attoseconds as (high Int64, low UInt64); 0.1 s.
    xpc_array_append_value(interval, xpc_int64_create(0))
    xpc_array_append_value(interval, xpc_uint64_create(100_000_000_000_000_000))
    // The installed CoreDevice's version (Xcode 27.2: 651.31), as CoreDevice's own clients send it.
    let versionString = Bundle(path: "/Library/Developer/PrivateFrameworks/CoreDevice.framework")?
        .infoDictionary?["CFBundleShortVersionString"] as? String ?? "651.31"
    let parts = versionString.split(separator: ".").compactMap { UInt64($0) }
    let components = xpc_array_create(nil, 0)
    (parts + Array(repeating: 0, count: max(3 - parts.count, 0))).forEach { xpc_array_append_value(components, xpc_uint64_create($0)) }
    var side = UUID().uuid
    let proxy = xpc_dictionary_create(nil, nil, 0)
    withUnsafeBytes(of: &side) { xpc_dictionary_set_uuid(proxy, "sideChannel", $0.bindMemory(to: UInt8.self).baseAddress!) }
    let message = dictionary([
        "CoreDevice.featureIdentifier": xpc_string_create(feature),
        "CoreDevice.actionIdentifier": xpc_string_create("com.apple.coredevice.action.streamhingeangle"),
        "CoreDevice.deviceIdentifier": xpc_string_create(udid(of: device)),
        "CoreDevice.invocationIdentifier": xpc_string_create(UUID().uuidString),
        "CoreDevice.coreDeviceVersion": dictionary(["components": components, "originalComponentsCount": xpc_int64_create(Int64(parts.count)),
                                                    "stringValue": xpc_string_create(versionString)]),
        "CoreDevice.CoreDeviceDDIProtocolVersion": xpc_int64_create(0),
        "CoreDevice.input": dictionary([
            "actualInput": dictionary(["changeThreshold": dictionary(["value": xpc_double_create(0.5), "unit": degrees]),
                                       "updateInterval": interval]),
            "streamProxy": proxy,
        ]),
    ])
    xpc_connection_send_message(connection, message)
    let deadline = ProcessInfo.processInfo.systemUptime + 5
    while !cancelled(), ProcessInfo.processInfo.systemUptime < deadline {
        if sample.wait(timeout: .now() + 0.05) == .success {
            if let result = valueLock.withLock({ angle }) { return result }
            break
        }
    }
    let reason = valueLock.withLock { failure }
    throw ToolError("The simulator did not give its hinge angle\(reason.isEmpty ? "" : ": \(reason)").")
}

/// The touchscreen target of each screen (by its unique ID), from the universal HID service's connected services:
/// a touchscreen is a service of the digitizer page (0x0D, usage 0x04) whose ID is 0x100 | its target.
func touchscreens(of device: NSObject) throws -> [String: UInt64] {
    let connection = try simulatorConnection(device, "com.apple.coredevice.feature.remote.universalhidservice")
    xpc_connection_set_event_handler(connection) { _ in }
    xpc_connection_resume(connection)
    defer { xpc_connection_cancel(connection) }
    let request = xpc_dictionary_create(nil, nil, 0)
    xpc_dictionary_set_bool(request, "isBarrier", false)
    let payload = xpc_dictionary_create(nil, nil, 0)
    xpc_dictionary_set_value(payload, "connectedServices", xpc_dictionary_create(nil, nil, 0))
    xpc_dictionary_set_value(request, "payload", payload)
    let reply = xpc_connection_send_message_with_reply_sync(connection, request)
    guard xpc_get_type(reply) == XPC_TYPE_DICTIONARY, let services = xpc_dictionary_get_value(reply, "connectedServices"),
          xpc_get_type(services) == XPC_TYPE_ARRAY
    else { throw ToolError("The simulator did not list its touchscreens.") }
    var targets: [String: UInt64] = [:]
    xpc_array_apply(services) { _, service in
        let serviceID = xpc_dictionary_get_uint64(service, "_ServiceID")
        if xpc_dictionary_get_uint64(service, "PrimaryUsagePage") == 0x0D, xpc_dictionary_get_uint64(service, "PrimaryUsage") == 0x04,
           serviceID & ~0xFF == 0x100, serviceID & 0xFF != 0, let display = xpc_dictionary_get_string(service, "displayUUID") {
            targets[String(cString: display)] = serviceID & 0xFF
        }
        return true
    }
    return targets
}

// MARK: - Keys

/// US keyboard: character to HID usage and Shift.
let usKeys: [Character: (UInt64, Bool)] = {
    var keys: [Character: (UInt64, Bool)] = ["\n": (40, false), "\t": (43, false), " ": (44, false)]
    for (offset, letter) in "abcdefghijklmnopqrstuvwxyz".enumerated() {
        keys[letter] = (UInt64(4 + offset), false)
        keys[Character(letter.uppercased())] = (UInt64(4 + offset), true)
    }
    for (offset, pair) in zip("1234567890", "!@#$%^&*()").enumerated() {
        keys[pair.0] = (UInt64(30 + offset), false)
        keys[pair.1] = (UInt64(30 + offset), true)
    }
    for (usage, pair) in [(45, "-_"), (46, "=+"), (47, "[{"), (48, "]}"), (49, "\\|"), (51, ";:"), (52, "'\""),
                          (53, "`~"), (54, ",<"), (55, ".>"), (56, "/?")] {
        keys[pair.first!] = (UInt64(usage), false)
        keys[pair.last!] = (UInt64(usage), true)
    }
    return keys
}()

let namedHIDKeys: [String: UInt64] = [
    "return": 40, "enter": 40, "escape": 41, "esc": 41, "delete": 42, "backspace": 42, "tab": 43, "space": 44,
    "capslock": 57, "home": 74, "pageup": 75, "forwarddelete": 76, "end": 77, "pagedown": 78,
    "right": 79, "left": 80, "down": 81, "up": 82,
    "f1": 58, "f2": 59, "f3": 60, "f4": 61, "f5": 62, "f6": 63, "f7": 64, "f8": 65, "f9": 66, "f10": 67, "f11": 68, "f12": 69,
]
let hidModifiers: [String: UInt64] = [
    "ctrl": 0xE0, "control": 0xE0, "shift": 0xE1, "alt": 0xE2, "option": 0xE2, "opt": 0xE2, "cmd": 0xE3, "command": 0xE3,
]

/// Hangul in two-set (dubeolsik) keys, as Latin letters of the US layout (upper case is Shift).
let hangulInitials = ["r", "R", "s", "e", "E", "f", "a", "q", "Q", "t", "T", "d", "w", "W", "c", "z", "x", "v", "g"]
let hangulVowels = ["k", "o", "i", "O", "j", "p", "u", "P", "h", "hk", "ho", "hl", "y", "n", "nj", "np", "nl", "b", "m", "ml", "l"]
let hangulFinals = ["", "r", "R", "rt", "s", "sw", "sg", "e", "f", "fr", "fa", "fq", "ft", "fx", "fv", "fg", "a", "q", "qt",
                    "t", "T", "d", "w", "c", "z", "x", "v", "g"]
/// Compatibility jamo (ㄱ U+3131 to ㅣ U+3163) to keys.
let jamoKeys: [Character: String] = {
    let consonants = "ㄱㄲㄳㄴㄵㄶㄷㄸㄹㄺㄻㄼㄽㄾㄿㅀㅁㅂㅃㅄㅅㅆㅇㅈㅉㅊㅋㅌㅍㅎ"
    let keys = ["r", "R", "rt", "s", "sw", "sg", "e", "E", "f", "fr", "fa", "fq", "ft", "fx", "fv", "fg", "a", "q", "Q", "qt",
                "t", "T", "d", "w", "W", "c", "z", "x", "v", "g"]
    var map = Dictionary(uniqueKeysWithValues: zip(consonants, keys))
    for (vowel, key) in zip("ㅏㅐㅑㅒㅓㅔㅕㅖㅗㅘㅙㅚㅛㅜㅝㅞㅟㅠㅡㅢㅣ", hangulVowels) { map[vowel] = key }
    return map
}()

/// The two-set keys of a Hangul syllable or jamo, or nil for other characters.
func hangulKeys(_ character: Character) -> String? {
    if let keys = jamoKeys[character] { return keys }
    guard let scalar = character.unicodeScalars.first, character.unicodeScalars.count == 1,
          (0xAC00...0xD7A3).contains(scalar.value) else { return nil }
    let index = Int(scalar.value - 0xAC00)
    return hangulInitials[index / 588] + hangulVowels[index % 588 / 28] + hangulFinals[index % 28]
}

/// The HID usages to type the text: (usage, Shift) for each key.
func keyStrokes(_ text: String, korean: Bool) throws -> [(UInt64, Bool)] {
    var strokes: [(UInt64, Bool)] = []
    var latin = false, hangul = false
    for character in text {
        if let keys = hangulKeys(character) {
            hangul = true
            strokes += keys.map { usKeys[$0]! }
        } else if let stroke = usKeys[character] {
            if character.isLetter { latin = true }
            strokes.append(stroke)
        } else {
            throw ToolError("\"\(character)\" has no key on the US or Korean two-set keyboard. Use the paste action.")
        }
    }
    if hangul && !korean {
        throw ToolError("The simulator's keyboard is not Korean, so Hangul keys would type Latin letters. Use the paste action.")
    }
    if latin && korean {
        throw ToolError("The simulator's keyboard is Korean, so Latin letters would type Hangul. Use the paste action.")
    }
    return strokes
}

/// The usages of a key combination such as "Return", "cmd+a" or "shift+Tab".
func keyChord(_ combination: String) throws -> [UInt64] {
    var parts = combination.split(separator: "+").map { $0.trimmingCharacters(in: .whitespaces) }
    if combination.hasSuffix("++") || combination == "+" { parts = parts.filter { !$0.isEmpty } + ["+"] }
    guard let key = parts.popLast(), !key.isEmpty else { throw ToolError("No key in \"\(combination)\".") }
    var usages = try parts.map { name -> UInt64 in
        guard let usage = hidModifiers[name.lowercased()] else { throw ToolError("Unknown modifier \"\(name)\".") }
        return usage
    }
    if let usage = namedHIDKeys[key.lowercased()] {
        usages.append(usage)
    } else if key.count == 1, let (usage, shift) = usKeys[Character(key)] {
        if shift { usages.append(0xE1) }
        usages.append(usage)
    } else {
        throw ToolError("Unknown key \"\(key)\". Use a US keyboard character or one of: \(namedHIDKeys.keys.sorted().joined(separator: ", ")).")
    }
    return usages
}

// MARK: - Pasteboard

/// paste puts the text on the Mac pasteboard and puts the user's items back after the Allow Paste tap:
/// the app reads the text from the Mac when it pastes, so an earlier change would paste the user's items.
var savedPasteboard: [NSPasteboardItem]?
var pasteboardRestore: DispatchWorkItem?
/// The changeCount right after paste set the text: another value means the user copied something since.
var pasteChangeCount = 0

func restorePasteboard(after seconds: Double) {
    pasteboardRestore?.cancel()
    let work = DispatchWorkItem {
        guard let items = savedPasteboard else { return }
        savedPasteboard = nil
        guard NSPasteboard.general.changeCount == pasteChangeCount else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects(items)
    }
    pasteboardRestore = work
    DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
}

/// A copy of the items, because the pasteboard's own items are not valid after clearContents.
func copyPasteboardItems() -> [NSPasteboardItem] {
    (NSPasteboard.general.pasteboardItems ?? []).map { item in
        let copy = NSPasteboardItem()
        for type in item.types { if let data = item.data(forType: type) { copy.setData(data, forType: type) } }
        return copy
    }
}

// MARK: - Tool

struct ShellResult { let status: Int32; let output: String }

/// Runs a command and stops it after timeout seconds (simctl io can wait a minute for the screen).
func shell(_ path: String, _ arguments: [String], timeout: Double = 15) -> ShellResult {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: path)
    process.arguments = arguments
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    process.standardInput = FileHandle.nullDevice  // Not mac-cu's stdin: that is the MCP channel.
    guard (try? process.run()) != nil else { return ShellResult(status: -1, output: "") }
    let timer = DispatchWorkItem {
        guard process.isRunning else { return }
        process.terminate()
        // A child that ignores SIGTERM must not hold the serial request queue forever.
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) { if process.isRunning { kill(process.processIdentifier, SIGKILL) } }
    }
    DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timer)
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    timer.cancel()
    let output = String(decoding: data, as: UTF8.self)
    if process.terminationReason == .uncaughtSignal {
        return ShellResult(status: -1, output: output + "\nStopped after \(Int(timeout)) seconds.")
    }
    return ShellResult(status: process.terminationStatus, output: output)
}

struct SimulatorScreen { let id: String; let name: String; let points: CGSize }

/// The built-in screens of a simulator, from simctl io enumerate. A device with more than one (iPhone Duo) needs
/// --display for each screenshot.
func builtInScreens(_ id: String) -> [SimulatorScreen] {
    shell("/usr/bin/xcrun", ["simctl", "io", id, "enumerate"]).output.components(separatedBy: "Screen ID: ").dropFirst().compactMap { block in
        let lines = block.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        func value(_ key: String) -> String? { lines.first { $0.hasPrefix(key + ": ") }.map { String($0.dropFirst(key.count + 2)) } }
        let numbers = (value("Pixel Size") ?? "").split { !$0.isNumber && $0 != "." }.compactMap { Double($0) }
        guard value("Screen Type") == "Integrated", numbers.count == 2, let scale = Double(value("Preferred UI Scale") ?? ""), scale > 0
        else { return nil }
        return SimulatorScreen(id: lines[0], name: value("Name") ?? lines[0], points: CGSize(width: numbers[0] / scale, height: numbers[1] / scale))
    }
}

/// A JPEG of the simulator screen as base64, scaled to the screen's points: a pixel of it is a point for tap.
/// With display, the picture of that screen; its points can be the other way round when the screen is turned.
/// With guides (element frames in points), the measurement guides are drawn on it.
func simulatorScreenshot(_ id: String, size: CGSize, display: String? = nil, guides: [GuideBox]? = nil, presentation: ActiveScreen? = nil) throws -> String {
    let file = FileManager.default.temporaryDirectory.appendingPathComponent("mac-cu-\(id)-\(display ?? "main").png")
    defer { try? FileManager.default.removeItem(at: file) }
    let result = shell("/usr/bin/xcrun", ["simctl", "io", id, "screenshot"] + (display.map { ["--display=\($0)"] } ?? []) + [file.path])
    guard result.status == 0, let image = NSImage(contentsOf: file),
          let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
        throw ToolError("No screenshot: \(result.output)")
    }
    if let presentation {
        let shown = try simulatorRotatedImage(cgImage, quarterTurns: presentation.presentationQuarterTurns)
        return try jpegBase64(shown, size: presentation.points, guides: guides)
    }
    let turned = display != nil && (cgImage.width > cgImage.height) != (size.width > size.height)
    return try jpegBase64(cgImage, size: turned ? CGSize(width: size.height, height: size.width) : size, guides: guides)
}

/// The image scaled to size, as a base64 JPEG. With guides, the measurement guides are drawn on it (Guides.swift).
func jpegBase64(_ cgImage: CGImage, size: CGSize, guides: [GuideBox]? = nil) throws -> String {
    guard let context = CGContext(data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8,
                                  bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
    else { throw ToolError("The screenshot could not be made smaller.") }
    context.interpolationQuality = .high
    context.draw(cgImage, in: CGRect(origin: .zero, size: size))
    guard let scaled = context.makeImage() else { throw ToolError("The screenshot could not be made smaller.") }
    let picture = guides.map { drawGuides(on: scaled, boxes: $0) } ?? scaled
    guard let jpeg = NSBitmapImageRep(cgImage: picture).representation(using: .jpeg, properties: [.compressionFactor: guides == nil ? 0.7 : 0.8])
    else { throw ToolError("The screenshot could not be made smaller.") }
    return jpeg.base64EncodedString()
}

func point(_ arguments: [String: Any], _ x: String, _ y: String) throws -> CGPoint {
    guard let px = (arguments[x] as? NSNumber)?.doubleValue, let py = (arguments[y] as? NSNumber)?.doubleValue else {
        throw ToolError("This action needs \(x) and \(y) in points (the pixels of the screenshot action).")
    }
    return CGPoint(x: px, y: py)
}

func simulatorTool(_ arguments: [String: Any]) throws -> [String: Any] {
    let action = arguments["action"] as? String ?? ""
    func text(_ value: String) -> [String: Any] { ["content": [["type": "text", "text": value]]] }
    if action == "list" {
        let booted = try simulatorDevices().filter(isBooted)
        let lines = booted.map { device -> String in
            let size = screenSize(of: device)
            let runtime = (device.value(forKey: "runtime") as? NSObject)?.value(forKey: "name") as? String ?? "?"
            return "\(device.value(forKey: "name") ?? "?") | \(udid(of: device)) | \(runtime) | \(Int(size.width))×\(Int(size.height)) points"
        }
        return text(lines.isEmpty ? "No simulator is booted." : "Booted simulators (name | UDID | runtime | screen):\n" + lines.joined(separator: "\n"))
    }
    if ["axSnapshot", "axAction"].contains(action) {
        guard let explicitDevice = arguments["device"] as? String, UUID(uuidString: explicitDevice) != nil else {
            throw ToolError("Typed AX commands require an explicit device UDID")
        }
        if action == "axAction" {
            guard let wire = arguments["ax"] as? [String: Any] else { throw SimulatorAXWireError.invalidEnvelope }
            _ = try SimulatorAXEnvelope(wire)
        }
    }
    try approve("Simulator", bundleID: "com.apple.iphonesimulator")
    let device = try bootedDevice(arguments["device"] as? String ?? "")
    let activity = SimulatorToolActivity(arguments: arguments, source: "에이전트 · \(currentSession?.agent ?? "mac-cu")",
                                        connection: currentSession?.activityID, request: currentSession?.activityRequestID)
    return try executeSimulatorCommand(arguments, device: device, activity: activity)
}

/// Both tool buttons and MCP use the existing backend, serialized on handleQueue.
func executeSimulatorCommand(_ arguments: [String: Any], device: NSObject, activity: SimulatorToolActivity) throws -> [String: Any] {
    let id = udid(of: device)
    let window = DispatchQueue.main.sync { simulatorWindows[id] }
    // Mutations revoke operation observations; synchronous screen reads also supersede older display samples.
    let mutation = activity.mutatesDevice
    if mutation {
        invalidateSimulatorObservation(id)
        SimulatorInspectionHost.invalidate(deviceID: id)
    }
    DispatchQueue.main.async { [weak window] in window?.commandStarted(activity) }
    do {
        let poseChange = activity.action == "rotate" || (activity.action == "hinge" && mutation)
        if poseChange, let cleanup = DispatchQueue.main.sync(execute: { window?.takeInputForPoseChange() }),
           !cleanup.keys.isEmpty || !cleanup.contacts.isEmpty {
            let link = try hidLink(for: device)
            for key in cleanup.keys { link.key(key, down: false) }
            for contact in cleanup.contacts { link.touch(contact.0, phase: 2, screen: cleanup.screen, second: contact.1) }
        }
        let result = try simulatorDeviceTool(arguments, device: device)
        if ["hinge", "rotate", "button"].contains(activity.action) { observeSimulator(device, for: 4) }
        DispatchQueue.main.async { [weak window] in window?.commandFinished(activity, response: result) }
        return result
    } catch {
        if mutation { invalidateSimulatorObservation(id); observeSimulator(device, for: 4) }
        let message = (error as? ToolError)?.message ?? error.localizedDescription
        DispatchQueue.main.async { [weak window] in
            window?.commandFinished(activity, response: ["isError": true, "content": [["type": "text", "text": message]]])
        }
        throw error
    }
}

private func simulatorDeviceTool(_ arguments: [String: Any], device: NSObject) throws -> [String: Any] {
    let action = arguments["action"] as? String ?? ""
    func text(_ value: String) -> [String: Any] { ["content": [["type": "text", "text": value]]] }
    let id = udid(of: device)
    let snapshotStarted = ProcessInfo.processInfo.systemUptime
    let raw = simulatorCommandNeedsActiveScreen(action) ? displays(of: id) : nil
    let screen = try simulatorCommandNeedsActiveScreen(action) ? activeScreen(of: device, readback: raw) : nil
    func inspectionScope() -> [String: Any] {
        let size = screen?.points ?? screenSize(of: device)
        return ["device": id, "screen": screen?.id ?? "main", "rotation": screen?.rotation ?? "rot0",
                "guestRotation": screen?.guestRotation ?? "rot0", "width": size.width, "height": size.height]
    }
    if ["tap", "press"].contains(action), arguments["inspectionElement"] != nil {
        guard let scope = arguments["inspectionScope"] as? [String: Any],
              NSDictionary(dictionary: inspectionScope()).isEqual(to: scope) else {
            throw ToolError("선택한 기기 화면이나 방향이 바뀌었습니다. 화면 요소를 새로 읽으세요.")
        }
    }
    if action == "screenshot" {
        let size = screen?.points ?? screenSize(of: device)
        let name = device.value(forKey: "name") ?? id
        let screens = builtInScreens(id)
        // Guides: the elements of the front app (as describe lists them), numbered in tree order, with boxes on the picture.
        var guides: [GuideBox]?
        var guideList: [[String: Any]] = []
        if arguments["guides"] as? Bool ?? false {
            let elements = try simulatorElements(device, screen: screen)
            let all = guideBoxes(elements.map { $0.offScreen ? nil : $0.frame }, within: CGRect(origin: .zero, size: size))
            guides = Array(all.prefix(maxGuideBoxes))
            let lines = guides!.map { "\($0.number) " + elements[$0.number].line }
            guideList = [["type": "text", "text": "Guides: rulers, a 100 px grid and numbered boxes on the picture" +
                (all.count > maxGuideBoxes ? " for the first \(maxGuideBoxes) elements" : "") +
                ". Boxes (number, role, label, id, value, center x,y in points, size):\n" + lines.joined(separator: "\n")]]
        }
        if screens.count < 2 {
            return ["content": [
                ["type": "text", "text": "Screenshot of \(name): \(Int(size.width))×\(Int(size.height)) points. Its pixels are the x and y of tap and swipe."],
                ["type": "image", "data": try simulatorScreenshot(id, size: size, guides: guides), "mimeType": "image/jpeg"],
            ] + guideList]
        }
        // tap, swipe and describe use the screen that is on (screen); without it, the main screen of the device type.
        var content: [[String: Any]] = [["type": "text", "text": """
            \(name) has \(screens.count) built-in screens: one picture for each. A screen that is off is black. \
            tap, swipe and describe use the screen that is on\(screen.map { " (\($0.name))" } ?? ""): \
            \(Int(size.width))×\(Int(size.height)) points.
            """]]
        for picture in screens {
            let used = screen.map { picture.id == $0.id } ?? (picture.points == size)
            content.append(["type": "text", "text": "Screen \(picture.id) \(picture.name)\(used ? " (on: its pixels are the x and y of tap and swipe)" : ""):"])
            content.append(["type": "image", "data": try simulatorScreenshot(id, size: picture.points, display: picture.id, guides: used ? guides : nil, presentation: used ? screen : nil), "mimeType": "image/jpeg"])
        }
        return ["content": content + guideList]
    }
    if action == "axSnapshot" {
        _ = try SimulatorInspectionHost.prepare(device: device, screen: screen)
        let snapshot = try simulatorAXHostSnapshot(device, deviceID: id, screen: screen)
        let target = snapshot["target"] as? [String: Any] ?? [:]
        return ["content": [["type": "text", "text": "AX snapshot captured; guest operations require qualification"]],
                "structuredContent": ["inspection": ["pid": target["pid"] ?? 0, "elements": snapshot["nodes"] ?? [],
                    "scope": inspectionScope(), "axSnapshot": snapshot]]]
    }
    if action == "axAction" {
        _ = try SimulatorInspectionHost.prepare(device: device, screen: screen)
        guard let envelope = arguments["ax"] as? [String: Any] else { throw SimulatorAXWireError.invalidEnvelope }
        let result = try simulatorAXHostAction(envelope, deviceID: id)
        return ["content": [["type": "text", "text": "AX: \(result["state"] ?? "unknown") · \(result["delivery"] ?? "unknown")"]],
                "structuredContent": ["axResult": result, "axBinding": ["captureID": envelope["captureID"] ?? "", "nodeID": envelope["nodeID"] ?? ""]]]
    }
    let target = arguments["target"] as? String ?? ""
    let timeout = (arguments["timeout"] as? NSNumber)?.doubleValue
    if action == "describe", arguments["inspection"] as? Bool == true {
        let pid = try simulatorFrontPid(device)
        var hitTestSelectorAvailable = false
        let elements = try simulatorElements(device, screen: screen) { _, objects in
            hitTestSelectorAvailable = objects.first?.responds(to: NSSelectorFromString("accessibilityHitTest:")) ?? false
        }
        guard try simulatorFrontPid(device) == pid else { throw ToolError("조회 중 전면 앱이 바뀌었습니다. 다시 읽으세요.") }
        return ["content": [["type": "text", "text": "화면 요소 \(elements.count)개를 읽었습니다."]],
                "structuredContent": ["inspection": ["pid": Int(pid), "app": processName(pid),
                    "elements": elements.map(\.inspectionData), "scope": inspectionScope(), "selectionMethod": "normalized AX frame candidates",
                    "hitTestSelectorAvailable": hitTestSelectorAvailable]]]
    }
    if action == "describe" {
        return text(try describeSimulator(device, screen: screen, query: arguments["query"] as? String ?? ""))
    }
    if action == "press", let selected = arguments["inspectionElement"] as? [String: Any],
       let pid = arguments["inspectionPid"] as? Int {
        try pressSimulatorInspectionElement(device, screen: screen, selected: selected, pid: pid)
        return text("선택한 요소의 접근성 실행(AXPress)을 완료했습니다. 터치는 보내지 않았습니다.")
    }
    if action == "press" {
        guard !target.isEmpty else { throw ToolError("press needs target: a label, id or value.") }
        let pressed = try pressSimulatorElement(device, screen: screen, target: target)
        return text("Pressed \(pressed.line) with the accessibility press action.")
    }
    if action == "wait" {
        guard !target.isEmpty else { throw ToolError("wait needs target: a label, id or value to wait for.") }
        let (found, matches) = try waitForSimulatorElement(device, screen: screen, target: target, seconds: min(max(timeout ?? 10, 0), 60))
        let others = matches.count > 1 ? "\n\(matches.count - 1) more match:\n" + matches.dropFirst().map(\.line).joined(separator: "\n") : ""
        return text("Found: \(found.line)\(others)")
    }
    func shownScreen(_ s: ActiveScreen?) -> String {
        s.map { "\($0.name) (screen \($0.id), \(Int($0.points.width))×\(Int($0.points.height)) points, host \($0.rotation), guest \($0.guestRotation))" } ?? "none"
    }
    if action == "window" {
        return text(try simulatorWindowAction(device, active: screen, close: arguments["close"] as? Bool ?? false))
    }
    if action == "gesture" {
        return text(try runSimulatorGesture(arguments: arguments, device: device, screen: screen,
                                            cancelled: { currentSession?.requestCancelled ?? false }))
    }
    if action == "hinge" {
        guard screen?.foldable == true else { throw ToolError("This simulator has one screen and no hinge.") }
        let names: [String: Double] = ["closed": 0, "open": 180]
        let state = (arguments["state"] as? String ?? "").lowercased()
        guard let degrees = (arguments["degrees"] as? NSNumber)?.doubleValue ?? names[state] else {
            if !state.isEmpty { throw ToolError("state is closed or open.") }
            return text("Hinge at \(try hingeAngle(of: device))°. The screen that is on: \(shownScreen(screen)).")
        }
        guard (0...180).contains(degrees) else { throw ToolError("degrees is 0 (closed) to 180 (open flat).") }
        // Both observations are fresh in this request. A stale/unknown angle cannot skip a trajectory.
        let from = try hingeAngle(of: device)
        if ProcessInfo.processInfo.systemUptime - snapshotStarted < 0.5,
           simulatorHingeAlreadySatisfied(target: degrees, angle: from, primary: screen?.primary) {
            var result = text("Hinge already at \(from)°. Active screen verified: \(shownScreen(screen)). No motion was sent.")
            result["structuredContent"] = ["hinge": ["requestedDegrees": degrees, "observedDegrees": from, "alreadySatisfied": true, "confirmationPending": false]]
            return result
        }
        let link = try hidLink(for: device)
        observeSimulator(device, for: 6)
        // Keep continuous 3-degree steps and endpoint hold; observation does not own this input lane.
        let steps = max(1, Int((abs(degrees - from) / 3).rounded(.up)))
        for step in 1...steps {
            try link.deviceControl("hinge-slider-control", "range", from + (degrees - from) * Double(step) / Double(steps))
            usleep(16_000)
        }
        // SpringBoard smooths the hinge readings; one event can leave it short of the angle (seen: 5.9° for 0°), so hold the end.
        for _ in 0..<10 { try link.deviceControl("hinge-slider-control", "range", degrees); usleep(50_000) }
        invalidateSimulatorObservation(id)
        var result = text("Delivered continuous hinge motion to \(degrees)° and the endpoint hold. Actual angle/display confirmation is pending; read hinge or inspect the LCD for observed state.")
        result["structuredContent"] = ["hinge": ["requestedDegrees": degrees, "delivered": true, "alreadySatisfied": false, "confirmationPending": true]]
        return result
    }

    if action == "rotate" {
        // Relative direction is an internal toolbar request, resolved on the same serialized queue
        // as MCP's absolute orientations. The UI must not compute it from a fixed cover framebuffer.
        let direction = arguments["direction"] as? String
        let absolute = (arguments["orientation"] as? String).flatMap { SimulatorOrientation(rawValue: $0.lowercased()) }
        guard (["clockwise", "counterclockwise"].contains(direction ?? "") && arguments["orientation"] == nil) || (direction == nil && absolute != nil) else {
            throw ToolError("orientation is one of: portrait, landscape-left, landscape-right, upside-down.")
        }
        guard let before = raw.flatMap(SimulatorRotationObservation.read) else {
            throw ToolError("Cannot read the active display before rotating. No orientation request was sent.")
        }
        let link = before.foldable ? try hidLink(for: device) : nil
        var state = simulatorRotationStates[id] ?? SimulatorRotationState()
        state.observe(before)
        let assumedPortrait = direction != nil && state.reference == nil
        let origin = state.reference ?? .portrait
        let target = absolute ?? (direction == "counterclockwise" ? origin.counterclockwise : origin.clockwise)
        let signedTurns = origin.signedQuarterTurns(to: target, direction: direction)
        try state.deliver(target, after: before, presentsDevice: true) {
            if let link {
                // A barrier proves local delivery only, not guest acknowledgement or screen rotation.
                try link.deviceControl("orientation-picker-control", "enum", target.picker)
            } else {
                let result = shell("/usr/bin/xcrun", ["devicectl", "device", "orientation", "set", "--device", id, target.devicectl, "--quiet"])
                guard result.status == 0 else { throw ToolError("devicectl could not send the orientation: \(result.output)") }
            }
        }
        simulatorRotationStates[id] = state
        simulatorObserver(id).invalidate()
        // Successful local delivery commits host geometry before passive guest observation.
        if let raw, let presented = try simulatorScreen(raw, targets: touchscreenTargets[id] ?? [:], pose: state.presentation) {
            let window = DispatchQueue.main.sync { simulatorWindows[id] }
            DispatchQueue.main.async { [weak window] in
                if let window, simulatorWindows[id] === window { window.presentRotation(presented, signedQuarterTurns: signedTurns) }
            }
        }
        var detail: [String: Any] = ["requestedOrientation": target.rawValue, "screenConfirmed": false,
            "assumedPortrait": assumedPortrait, "screenChanged": false, "delivered": true,
            "confirmationPending": true, "screenOrientation": before.rotation]
        detail["presentationOrientation"] = target.screenRotation(inner: before.foldable && !before.primary)
        detail["signedQuarterTurns"] = signedTurns
        let basis = assumedPortrait ? " No reliable starting pose was available; this relative request used portrait as its starting reference." : ""
        var result = text("Delivered orientation request \(target.rawValue). Guest orientation confirmation is pending; the last observed framebuffer was \(before.rotation).\(basis) The front app turns only to the orientations it supports.")
        result["structuredContent"] = ["rotation": detail]
        return result
    }
    if action == "views" {
        // The app: by bundle id from launchctl, or the front app.
        let bundle = arguments["app"] as? String ?? ""
        var pid = Int32(0)
        if bundle.isEmpty {
            pid = try simulatorFrontPid(device)
        } else {
            let list = shell("/usr/bin/xcrun", ["simctl", "spawn", id, "launchctl", "list"]).output
            let line = list.split(separator: "\n").first { $0.contains("UIKitApplication:\(bundle)[") }
            pid = line.flatMap { Int32($0.split(separator: "\t").first ?? "") } ?? 0
            guard pid > 0 else { throw ToolError("\(bundle) is not running in the simulator. Launch it first.") }
        }
        let capture = try simulatorViews(pid: pid, deviceID: id, query: arguments["query"] as? String ?? "")
        var result = text(capture.content["text"] as? String ?? capture.content["message"] as? String ?? "UIKit capture unavailable.")
        result["structuredContent"] = ["viewCapture": capture.content]
        result["isError"] = capture.status != .success
        return result
    }
    let link = try hidLink(for: device)
    let seconds = (arguments["seconds"] as? NSNumber)?.doubleValue
    switch action {
    case "tap":
        var at: CGPoint
        var note = ""
        if let selected = arguments["inspectionElement"] as? [String: Any] {
            guard let expectedPid = arguments["inspectionPid"] as? Int,
                  Int(try simulatorFrontPid(device)) == expectedPid else {
                throw ToolError("전면 앱이 바뀌었습니다. 화면 요소를 새로 읽으세요.")
            }
            let matches = try simulatorElements(device, screen: screen).filter { NSDictionary(dictionary: $0.inspectionData).isEqual(to: simulatorAXLegacyRow(selected)) }
            guard matches.count == 1, let found = matches.first,
                  found.inside, found.enabled != false, found.frame.width > 0, found.frame.height > 0 else {
                throw ToolError("선택 이후 화면 요소가 바뀌었거나 대상을 구분할 수 없습니다. 화면 요소를 새로 읽고 다시 선택하세요.")
            }
            at = found.center
            note = " (선택한 요소: \(found.line))"
        } else if arguments["x"] == nil, !target.isEmpty {
            let (found, matches) = try waitForSimulatorElement(device, screen: screen, target: target, seconds: min(max(timeout ?? 5, 0), 60))
            at = found.center
            note = " (\(found.line)\(matches.count > 1 ? "; \(matches.count) elements match, this is the first (wholly on screen first, then tree order)" : ""))"
        } else {
            at = try point(arguments, "x", "y")
        }
        link.touch(at, phase: 0, screen: screen)
        usleep(UInt32(min(max(seconds ?? 0.05, 0.02), 10) * 1_000_000))
        link.touch(at, phase: 2, screen: screen)
        if savedPasteboard != nil { restorePasteboard(after: 2) }  // The answer to Allow Paste.
        return text("Tapped at \(Int(at.x)), \(Int(at.y))\(screen.map { " on \($0.name)" } ?? "")\(note).")
    case "swipe":
        let from = try point(arguments, "x", "y"), to = try point(arguments, "to_x", "to_y")
        let steps = 12, duration = min(max(seconds ?? 0.3, 0.05), 10)
        link.touch(from, phase: 0, screen: screen)
        for step in 1...steps {
            let t = CGFloat(step) / CGFloat(steps)
            usleep(UInt32(duration / Double(steps) * 1_000_000))
            link.touch(CGPoint(x: from.x + (to.x - from.x) * t, y: from.y + (to.y - from.y) * t), phase: 1, screen: screen)
        }
        link.touch(to, phase: 2, screen: screen)
        return text("Swiped from \(Int(from.x)), \(Int(from.y)) to \(Int(to.x)), \(Int(to.y))\(screen.map { " on \($0.name)" } ?? "").")
    case "type":
        let value = arguments["text"] as? String ?? ""
        let mode = keyboardInputMode(id)
        for (usage, shift) in try keyStrokes(value, korean: mode.hasPrefix("ko")) {
            link.chord(shift ? [0xE1, usage] : [usage])
        }
        return text("Typed \(value.count) characters as keys (keyboard \(mode.isEmpty ? "unknown" : mode)).")
    case "crown":
        let runtime = (device.value(forKey: "runtime") as? NSObject)?.value(forKey: "name") as? String ?? ""
        guard runtime.lowercased().contains("watch") else { throw ToolError("crown is for an Apple Watch simulator.") }
        let amount = (arguments["amount"] as? NSNumber)?.doubleValue ?? 60
        link.crown(amount)
        return text("Turned the Digital Crown by \(Int(amount)) (positive scrolls the content down, negative up). Check with screenshot.")
    case "key":
        let combination = arguments["key"] as? String ?? ""
        link.chord(try keyChord(combination))
        return text("Pressed \(combination).")
    case "button":
        let usages: [String: UInt64] = ["home": 0x40, "lock": 0x30, "side": 0x30, "siri": 0xCF]
        let name = (arguments["button"] as? String ?? "").lowercased()
        guard let usage = usages[name] else { throw ToolError("button is one of: home, lock, side, siri.") }
        // Right after home, the accessibility tree is still the last app's for a moment (E8): wait until the front pid changes.
        let before = name == "home" ? try? simulatorFrontPid(device) : nil
        link.button(page: 0x0C, usage: usage, down: true)
        usleep(UInt32(min(max(seconds ?? 0.1, 0.05), 10) * 1_000_000))
        link.button(page: 0x0C, usage: usage, down: false)
        guard let before else { return text("Pressed the \(name) button.") }
        var front = before
        for _ in 0..<12 where front == before { usleep(250_000); front = (try? simulatorFrontPid(device)) ?? before }
        return text("Pressed the home button. Front app: \(processName(front))\(front == before ? " (unchanged after 3 s: it was already the home screen, or the screen changed within it)" : "").")
    case "paste":
        let value = arguments["text"] as? String ?? ""
        guard !value.isEmpty else { throw ToolError("paste needs text.") }
        // simctl pbcopy does not reach the simulator in Xcode 27. CoreDevice copies the Mac pasteboard to the
        // booted simulators, and the app reads the text from the Mac pasteboard when it pastes.
        DispatchQueue.main.sync {
            if savedPasteboard == nil { savedPasteboard = copyPasteboardItems() }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(value, forType: .string)
            pasteChangeCount = NSPasteboard.general.changeCount
        }
        usleep(1_000_000)
        let inserted: Bool
        do { inserted = try pasteThroughSimulatorEditMenu(device, screen: screen, link: link) }
        catch { restorePasteboard(after: 0); throw error }
        if !inserted { link.chord([0xE3, 25]) }  // cmd+V
        restorePasteboard(after: 60)
        if inserted { return text("Selected Paste in the native input edit menu, preserving its selection. If iOS asks to allow the paste, tap Allow Paste. The Mac pasteboard will be restored after that tap or 60 seconds.") }
        return text("""
            Put the text on the Mac pasteboard (the simulators get it from there) and pressed cmd+V. iOS asks the app to allow the paste \
            ("Allow Paste", "붙여넣기 허용"): take a screenshot and tap that button. The Mac pasteboard holds \
            the text too until 2 seconds after that tap (or 60 seconds), then mac-cu puts the user's back.
            """)
    default:
        throw ToolError("Unknown simulator action \"\(action)\".")
    }
}
