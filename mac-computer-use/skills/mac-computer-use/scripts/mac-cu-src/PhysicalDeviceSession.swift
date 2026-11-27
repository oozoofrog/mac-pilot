import Foundation
import CoreGraphics
@_weakLinked import CoreDevice
@_weakLinked import CoreDeviceUtilities

// In-process CoreDevice calls for one allowed physical device: screenshots, lock state and display information
// without a devicectl subprocess, over the CoreDevice tunnel that USB and network connections both use.
// Nothing here touches a CoreDevice declaration before PhysicalDeviceLink.inProcessCheck() has passed; the registry
// hands out sessions only after it. The CoreDevice-facing part is behind PhysicalDevicePort so the session's rules
// (tunnel assertion, cached implementations, teardown) are checked offline with fakes.

// MARK: - Runtime ABI facts (used by PhysicalDeviceLink.inProcessCheck)

/// True when this executable's own weak imports from CoreDevice and CoreDeviceUtilities were bound at launch. A copy
/// whose framework load paths point nowhere, or a Mac without Xcode, has them unbound even if the framework can be
/// opened later by path; calling through them would jump to null.
func coreDeviceImagesBound() -> Bool {
    if #_hasSymbol(DeviceManager.self), #_hasSymbol(RemoteDevice.self), #_hasSymbol(CaptureScreenshotCapability.self),
       #_hasSymbol(LockStateCapability.self), #_hasSymbol(DisplayInfoCapability.self), #_hasSymbol(LockState.self),
       #_hasSymbol(DisplayInfo.self), #_hasSymbol(UsageAssertionRequirements.self), #_hasSymbol(AssertableDeviceState.self),
       #_hasSymbol(Capability.self), #_hasSymbol(DeviceUsageAssertion.self),
       #_hasSymbol(CaptureScreenshotOutput.self), #_hasSymbol(ScreenshotImageFormat.self) {
        return true
    }
    return false
}

/// Resolved through the framework's own witness table at run time, so a stub that names the wrong ProtocolType is
/// caught before a generic call writes its result into a buffer of the wrong size.
@inline(never) @_optimize(none)
private func runtimeProtocolType<A: DeviceCapability>(_: A.Type) -> Any.Type { A.ProtocolType.self }

/// nil when the framework's ProtocolTypes are the existentials the stubs declare; otherwise what differs.
func coreDeviceProtocolTypeMismatch() -> String? {
    let pairs: [(String, Any.Type, Any.Type)] = [
        ("CaptureScreenshotCapability", runtimeProtocolType(CaptureScreenshotCapability.self), (any CaptureScreenshotProtocol).self),
        ("LockStateCapability", runtimeProtocolType(LockStateCapability.self), (any LockStateProtocol).self),
        ("DisplayInfoCapability", runtimeProtocolType(DisplayInfoCapability.self), (any DisplayInfoProtocol).self),
    ]
    for (name, runtime, declared) in pairs where runtime != declared {
        return "\(name).ProtocolType is \(runtime), the stub declares \(declared)"
    }
    return nil
}

// MARK: - Session contract

enum PhysicalSessionError: Error, CustomStringConvertible, Equatable {
    case inProcessUnavailable(String)
    case notFound
    case notConnected(String)
    /// CoreDevice 25003: another screenshot is being captured on the device. Returns at once; retry later.
    case busy
    case timedOut(String)
    case failed(String)
    case closed

    var description: String {
        switch self {
        case .inProcessUnavailable(let reason): return "In-process CoreDevice is unavailable: \(reason)"
        case .notFound: return "CoreDevice does not know this device; connect it and retry."
        case .notConnected(let detail): return "Device not connected: \(detail)"
        case .busy: return "A screenshot capture is already in progress on the device."
        case .timedOut(let what): return "The device did not answer \(what) in time."
        case .failed(let detail): return detail
        case .closed: return "The device session has ended."
        }
    }
}

struct PhysicalDisplayState: Equatable {
    var portraitPoints: CGSize?
    var portraitPixels: CGSize?
    var nativePixels: CGSize?
    var watchPointsWithoutOrientation: CGSize?
    var anyOrientationPoints: CGSize?

    static func primary(pixels: CGSize, scale: CGFloat, rotation: String?, orientation: String?) -> Self {
        guard pixels.width > 0, pixels.height > 0 else { return Self() }
        var state = Self(nativePixels: pixels)
        guard scale.isFinite, scale > 0 else { return state }
        let rotated = (rotation == "rot90" || rotation == "rot270") && pixels.height > pixels.width
        state.anyOrientationPoints = rotated
            ? CGSize(width: pixels.height / scale, height: pixels.width / scale)
            : CGSize(width: pixels.width / scale, height: pixels.height / scale)
        guard rotation == "rot0", pixels.height > pixels.width else { return state }
        let points = CGSize(width: pixels.width / scale, height: pixels.height / scale)
        if orientation == "portrait" {
            state.portraitPoints = points
            state.portraitPixels = pixels
        } else if orientation == nil {
            state.watchPointsWithoutOrientation = points
        }
        return state
    }

    func points(for device: PhysicalDeviceInfo) -> CGSize? {
        if device.isIPad { return anyOrientationPoints }
        return portraitPoints ?? (device.isAppleWatch ? watchPointsWithoutOrientation : nil)
    }
}

/// One device as PhysicalDeviceSession needs it. The implementations returned are fetched once per session.
protocol PhysicalRemote: AnyObject {
    func supports(_ feature: String) -> Bool
    func acquireAssertion(reason: String) async throws -> PhysicalAssertion
    func screenshotCapturer() async throws -> () async throws -> CGImage
    func lockReader() async throws -> () async throws -> Bool
    func displayReader() async throws -> () async throws -> PhysicalDisplayState
}

protocol PhysicalAssertion: AnyObject {
    func release()
    /// Called once if CoreDevice ends the assertion itself (tunnel gone).
    func onInvalidated(_ body: @escaping (String) -> Void)
}

protocol PhysicalDevicePort: AnyObject {
    func remote(_ id: UUID) -> PhysicalRemote?
}

enum PhysicalFeature {
    static let screenshot = "com.apple.coredevice.feature.capturescreenshot"
    static let lockState = "com.apple.coredevice.feature.getlockstate"
    static let displayInfo = "com.apple.coredevice.feature.getdisplayinfo"
    static let hid = "com.apple.coredevice.feature.remote.hid.digitizer"
    static let button = "com.apple.coredevice.feature.remote.hid.button"
}

/// Runs body with a deadline; CoreDevice calls have none of their own. On timeout the call is abandoned (its task is
/// cancelled, which CoreDevice may ignore) and timedOut is thrown.
func physicalDeadline<T>(_ seconds: Double, _ what: String, _ body: @escaping () async throws -> T) async throws -> T {
    let once = PhysicalOnce()
    return try await withCheckedThrowingContinuation { continuation in
        let work = Task {
            do { let value = try await body(); if once.claim() { continuation.resume(returning: value) } }
            catch { if once.claim() { continuation.resume(throwing: error) } }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + seconds) {
            if once.claim() { work.cancel(); continuation.resume(throwing: PhysicalSessionError.timedOut(what)) }
        }
    }
}

/// Calls async work from a synchronous caller that is not on the Swift concurrency pool (tool queue, state readers).
func physicalBlocking<T>(_ seconds: Double, _ what: String, _ body: @escaping () async throws -> T) throws -> T {
    let done = DispatchSemaphore(value: 0)
    let box = PhysicalBox<Result<T, Error>>()
    Task {
        do { box.value = .success(try await physicalDeadline(seconds, what, body)) } catch { box.value = .failure(error) }
        done.signal()
    }
    guard done.wait(timeout: .now() + seconds + 2) == .success, let result = box.value else { throw PhysicalSessionError.timedOut(what) }
    return try result.get()
}

final class PhysicalOnce: @unchecked Sendable {
    private let lock = NSLock(); private var done = false
    func claim() -> Bool { lock.lock(); defer { lock.unlock() }; if done { return false }; done = true; return true }
}
final class PhysicalBox<T>: @unchecked Sendable {
    private let lock = NSLock(); private var stored: T?
    var value: T? { get { lock.lock(); defer { lock.unlock() }; return stored } set { lock.lock(); stored = newValue; lock.unlock() } }
}

func physicalIsCaptureBusy(_ error: Error) -> Bool {
    if let session = error as? PhysicalSessionError { return session == .busy }
    return (error as NSError).code == 25003 || String(describing: error).contains("25003")
}

// MARK: - Session

/// One allowed device. Holds the remote, the usage assertion when one was needed to raise the tunnel, and the
/// screenshot / lock-state / display-info implementations (fetched once, dropped on failure or disconnect). The
/// screenshot is one still frame per call; nothing here repeats requests.
/// Methods may be called from any task; overlapping captures run concurrently.
final class PhysicalDeviceSession {
    let id: UUID
    private let port: PhysicalDevicePort
    private let transport: () -> String?
    private let clock: () -> TimeInterval
    /// Waits this long for the device to appear in CoreDevice's list and for its features after the tunnel rises.
    var appearWait: TimeInterval = 3
    var featureWait: TimeInterval = 10
    var assertionWait: TimeInterval = 30
    var callWait: TimeInterval = 8

    private let lock = NSLock()
    private var assertion: PhysicalAssertion?
    private var acquiring: Task<Void, Error>?
    private var capturer: (() async throws -> CGImage)?
    private var lockRead: (() async throws -> Bool)?
    private var display: (() async throws -> PhysicalDisplayState)?
    private var fetching: [AnyKeyPath: Task<Any, Error>] = [:]
    private var isClosed = false
    private(set) var assertionsAcquired = 0
    private(set) var assertionsReleased = 0
    private(set) var implementationFetches = 0
    private(set) var invalidations = 0

    init(id: UUID, port: PhysicalDevicePort, transport: @escaping () -> String?,
         clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.id = id
        self.port = port
        self.transport = transport
        self.clock = clock
    }

    var closed: Bool { lock.lock(); defer { lock.unlock() }; return isClosed }
    var holdsAssertion: Bool { lock.lock(); defer { lock.unlock() }; return assertion != nil }
    var holdsImplementations: Bool { lock.lock(); defer { lock.unlock() }; return capturer != nil || lockRead != nil || display != nil }

    private func locked<T>(_ body: () throws -> T) rethrows -> T { lock.lock(); defer { lock.unlock() }; return try body() }

    /// The remote with the feature available. A network device (or any device whose features are missing) first gets
    /// a usage assertion, which raises the CoreDevice tunnel; the session keeps it until close or invalidation.
    func prepared(for feature: String) async throws -> PhysicalRemote {
        guard !closed else { throw PhysicalSessionError.closed }
        var remote = port.remote(id)
        let appear = clock() + appearWait
        while remote == nil, clock() < appear {
            try await Task.sleep(nanoseconds: 100_000_000)
            remote = port.remote(id)
        }
        guard let remote else { throw PhysicalSessionError.notFound }
        let wired = transport() == "wired"
        if (!wired || !remote.supports(feature)) && !holdsAssertion {
            try await acquireAssertion(remote)
        }
        let deadline = clock() + featureWait
        while !remote.supports(feature) {
            guard clock() < deadline else {
                throw PhysicalSessionError.notConnected("the device does not offer \(feature.split(separator: ".").last ?? "") yet; " +
                    "unlock it and keep it on the same network or connected by cable, then retry")
            }
            try await Task.sleep(nanoseconds: 250_000_000)
        }
        guard !closed else { throw PhysicalSessionError.closed }
        return remote
    }

    /// Single flight: concurrent first calls share one acquisition.
    private func acquireAssertion(_ remote: PhysicalRemote) async throws {
        let task: Task<Void, Error> = locked {
            if let acquiring { return acquiring }
            let created = Task { [weak self] in
                guard let self else { return }
                let held = try await physicalDeadline(self.assertionWait, "the tunnel request (usage assertion)") {
                    try await remote.acquireAssertion(reason: "mac-cu device session")
                }
                let keep: Bool = self.locked {
                    if self.isClosed { return false }
                    self.assertion = held
                    self.assertionsAcquired += 1
                    return true
                }
                guard keep else { held.release(); self.locked { self.assertionsReleased += 1 }; throw PhysicalSessionError.closed }
                held.onInvalidated { [weak self, weak held] _ in
                    // CoreDevice ended it (tunnel gone): drop our reference without releasing it again and acquire
                    // again on the next use.
                    guard let self else { return }
                    self.locked {
                        if self.assertion === held { self.assertion = nil }
                        self.invalidations += 1
                    }
                    self.dropImplementations()
                }
            }
            acquiring = created
            return created
        }
        defer { locked { if acquiring == task { acquiring = nil } } }
        try await task.value
    }

    /// Cached, or fetched once for concurrent first callers.
    private func implementation<T>(_ path: ReferenceWritableKeyPath<PhysicalDeviceSession, T?>, feature: String,
                                   fetch: @escaping (PhysicalRemote) async throws -> T) async throws -> T {
        let task: Task<Any, Error> = try locked {
            if isClosed { throw PhysicalSessionError.closed }
            if let cached = self[keyPath: path] { return Task { cached } }
            if let running = fetching[path] { return running }
            let made = Task<Any, Error> { [self] in
                let remote = try await prepared(for: feature)
                let value = try await physicalDeadline(callWait, "the implementation request") { try await fetch(remote) }
                locked { implementationFetches += 1 }
                return value
            }
            fetching[path] = made
            return made
        }
        do {
            let value = try await task.value as! T
            locked {
                // Kept unless the session dropped its implementations (or closed) while this fetch ran.
                if fetching[path] == task { fetching[path] = nil; if !isClosed { self[keyPath: path] = value } }
            }
            return value
        } catch {
            locked { if fetching[path] == task { fetching[path] = nil } }
            throw error
        }
    }

    /// Forgets the implementations (kept assertion is unaffected); the next call fetches them again.
    func dropImplementations() {
        locked { capturer = nil; lockRead = nil; display = nil; fetching.removeAll() }
    }

    private func failed(_ error: Error) -> Error {
        if physicalIsCaptureBusy(error) { return PhysicalSessionError.busy }
        if case PhysicalSessionError.closed = error { return error }
        dropImplementations()
        if error is PhysicalSessionError { return error }
        return PhysicalSessionError.failed(String(String(describing: error).prefix(300)))
    }

    func capture() async throws -> CGImage {
        let call = try await implementation(\.capturer, feature: PhysicalFeature.screenshot) { try await $0.screenshotCapturer() }
        do { return try await physicalDeadline(callWait, "the screenshot request", call) } catch { throw failed(error) }
    }

    /// True while the device requires a passcode.
    func lockState() async throws -> Bool {
        let call = try await implementation(\.lockRead, feature: PhysicalFeature.lockState) { try await $0.lockReader() }
        do { return try await physicalDeadline(callWait, "the lock state request", call) } catch { throw failed(error) }
    }

    func displayInfo() async throws -> PhysicalDisplayState {
        let reader = try await implementation(\.display, feature: PhysicalFeature.displayInfo) { try await $0.displayReader() }
        do { return try await physicalDeadline(callWait, "the display request", reader) } catch { throw failed(error) }
    }

    /// Ends the session: implementations dropped, the assertion released exactly once. Idempotent.
    func close() {
        let held: PhysicalAssertion? = locked {
            guard !isClosed else { return nil }
            isClosed = true
            defer { assertion = nil }
            return assertion
        }
        dropImplementations()
        if let held { held.release(); locked { assertionsReleased += 1 } }
    }
}

// MARK: - Registry

/// Sessions of allowed devices. One session per device, reused across calls; ended by release, by allowing another
/// device, or after idleClose without use.
final class PhysicalDeviceSessions {
    private let available: () -> InProcessCoreDevice
    private let makePort: () -> PhysicalDevicePort
    private let clock: () -> TimeInterval
    var idleClose: TimeInterval = 120
    private let lock = NSLock()
    private var port: PhysicalDevicePort?
    private var entries: [UUID: (session: PhysicalDeviceSession, lastUse: TimeInterval)] = [:]
    private var transports: [UUID: String] = [:]
    private var sweeper: DispatchSourceTimer?

    init(available: @escaping () -> InProcessCoreDevice, makePort: @escaping () -> PhysicalDevicePort,
         clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.available = available
        self.makePort = makePort
        self.clock = clock
    }

    /// The transport the inventory reported last ("wired", "localNetwork", …).
    func noteTransport(_ id: UUID, _ transport: String?) {
        lock.lock(); transports[id] = transport; lock.unlock()
    }

    /// Why the in-process path is off, or nil when it is on.
    var unavailableReason: String? {
        if case .unavailable(let reason) = available() { return reason }
        return nil
    }

    /// The device's session, or nil when the in-process path is off for this process.
    func session(_ id: UUID) -> PhysicalDeviceSession? {
        guard case .available = available() else { return nil }
        lock.lock(); defer { lock.unlock() }
        let now = clock()
        if let entry = entries[id], !entry.session.closed {
            entries[id]?.lastUse = now
            return entry.session
        }
        let port = self.port ?? makePort()
        self.port = port
        let made = PhysicalDeviceSession(id: id, port: port, transport: { [weak self] in
            guard let self else { return nil }
            self.lock.lock(); defer { self.lock.unlock() }
            return self.transports[id]
        }, clock: clock)
        entries[id] = (made, now)
        startSweeper()
        return made
    }

    /// Ends one device's session, or every session.
    func end(_ id: UUID?) {
        lock.lock()
        let ending = entries.filter { id == nil || $0.key == id }
        for key in ending.keys { entries[key] = nil }
        lock.unlock()
        for entry in ending.values { entry.session.close() }
    }

    /// Closes sessions unused for idleClose. Called by the sweeper; public for checks.
    func sweep() {
        lock.lock()
        let now = clock()
        let idle = entries.filter { now - $0.value.lastUse >= idleClose }
        for key in idle.keys { entries[key] = nil }
        lock.unlock()
        for entry in idle.values { entry.session.close() }
    }

    var count: Int { lock.lock(); defer { lock.unlock() }; return entries.count }

    private func startSweeper() {
        guard sweeper == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(deadline: .now() + 30, repeating: 30)
        timer.setEventHandler { [weak self] in self?.sweep() }
        sweeper = timer
        timer.resume()
    }
}

// MARK: - CoreDevice port (touches the stub declarations; only reached after inProcessCheck passed)

final class CoreDevicePort: PhysicalDevicePort {
    func remote(_ id: UUID) -> PhysicalRemote? {
        DeviceManager.shared.devices[id].map(CoreDeviceRemote.init)
    }
}

private final class CoreDeviceRemote: PhysicalRemote {
    let device: RemoteDevice
    init(_ device: RemoteDevice) { self.device = device }

    func supports(_ feature: String) -> Bool { device.supportsFeature(identifiedBy: feature) }

    /// Acquires a CoreDevice usage assertion with the four required device states so CoreDeviceService raises the
    /// tunnel and keeps it up while the assertion is held.
    func acquireAssertion(reason: String) async throws -> PhysicalAssertion {
        let requirements = UsageAssertionRequirements(deviceStates: [.developerModeEnabledIfRequired, .coreDeviceServicesLoaded,
                                                                     .extendedDeviceInfoLoaded, .remoteServiceDiscoveryTrustedConnectivityAvailable],
                                                      capabilities: [])
        return CoreDeviceAssertion(try await device.acquireDeviceUsageAssertion(withReason: reason, requirements: requirements))
    }

    func screenshotCapturer() async throws -> () async throws -> CGImage {
        let capture = try await device.getImplementation(for: CapabilityStaticMember<CaptureScreenshotCapability>.captureScreenshot)
        return { try await capture.captureScreenshot(displayUniqueID: nil, format: .png).image }
    }

    func lockReader() async throws -> () async throws -> Bool {
        let lock = try await device.getImplementation(for: CapabilityStaticMember<LockStateCapability>.lockState)
        return { try await lock.currentLockState.isPasscodeRequired }
    }

    func displayReader() async throws -> () async throws -> PhysicalDisplayState {
        let displays = try await device.getImplementation(for: CapabilityStaticMember<DisplayInfoCapability>.displayInfo)
        return { coreDeviceDisplayState(try await displays.displayInfo) }
    }
}

private func coreDeviceDisplayState(_ info: DisplayInfo) -> PhysicalDisplayState {
    guard let display = info.displays.first(where: { $0.primary }) else { return PhysicalDisplayState() }
    return .primary(pixels: display.nativeSize, scale: CGFloat(display.pointScale), rotation: display.currentOrientation,
                    orientation: info.orientation?.currentDeviceOrientation.rawValue)
}

private final class CoreDeviceAssertion: PhysicalAssertion {
    let assertion: DeviceUsageAssertion
    init(_ assertion: DeviceUsageAssertion) { self.assertion = assertion }
    func release() { assertion.releaseAssertion() }
    func onInvalidated(_ body: @escaping (String) -> Void) {
        let once = PhysicalOnce()
        assertion.registerInvalidationHandler(invokingOnQueue: .global(qos: .utility)) { error in
            if once.claim() { body(error.map { String(describing: $0) } ?? "invalidated") }
        }
    }
}
