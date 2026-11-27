import Foundation
import Darwin
import XPC

enum PhysicalDeviceError: Error, CustomStringConvertible {
    case frameworkMissing(String), symbolMissing(String), noSuchDevice(String)
    case unavailable(String), connectionRefused(String)
    var description: String {
        switch self {
        case .frameworkMissing(let part): return "CoreDevice unavailable: framework missing: \(part). Install or select a supported Xcode."
        case .symbolMissing(let part): return "CoreDevice unavailable: symbol missing: \(part). Select a supported Xcode version."
        case .noSuchDevice(let id): return "No such device: \(id)"
        case .unavailable(let detail): return "Device not connected or unavailable: \(detail)"
        case .connectionRefused(let detail): return "Device connection refused: \(detail)"
        }
    }
}

struct PhysicalDeviceInfo {
    let identifier: UUID
    let name: String
    let model: String?
    let osVersion: String?
    let transport: String?
    let connectionState: String?
    let pairingState: String?
    /// The inventory's CoreDevice tunnel state ("connected", "disconnected", …); nil when not reported.
    var tunnelState: String? = nil
    var hardwareUDID: String? = nil
    var isAppleWatch = false
    var isIPad = false
}

/// Whether PhysicalDeviceSession's in-process CoreDevice calls may run in this process.
enum InProcessCoreDevice: Equatable {
    case available
    case unavailable(String)
}

private final class PhysicalManagerShim {
    @_silgen_name("$s10CoreDevice0B7ManagerC7devicesSDy10Foundation4UUIDVAA06RemoteB0CGvgTj")
    func devices() -> [UUID: AnyObject]
}
private struct PhysicalPeerExistential { var object, witness: UInt }
private final class PhysicalDeviceShim {
    @_silgen_name("$s10CoreDevice06RemoteB0C11descriptionSSvg")
    func describe() -> String
    @_silgen_name("$s10CoreDevice06RemoteB0C13xpcConnection22forFeatureIdentifiedBy7Mercury07XPCPeerE0_pSS_tYaKF")
    func connection(_ feature: String) async throws -> PhysicalPeerExistential
}
@_silgen_name("$s10CoreDevice0B7ManagerC6sharedACvgZ")
private func physicalSharedManager() -> AnyObject

final class PhysicalHIDLink {
    // Retain the peer as well as the remote connection for the full link lifetime.
    private let peer: AnyObject
    let connection: xpc_object_t
    fileprivate init(peer: AnyObject, connection: xpc_object_t) {
        self.peer = peer
        self.connection = connection
    }
}

final class PhysicalDeviceLink {
    typealias OpenFramework = (String) -> UnsafeMutableRawPointer?
    typealias FindSymbol = (UnsafeMutableRawPointer, String) -> UnsafeMutableRawPointer?
    private static let path = "/Library/Developer/PrivateFrameworks/CoreDevice.framework/CoreDevice"
    static let symbols = [
        "$s10CoreDevice0B7ManagerC6sharedACvgZ",
        "$s10CoreDevice0B7ManagerC7devicesSDy10Foundation4UUIDVAA06RemoteB0CGvgTj",
        "$s10CoreDevice06RemoteB0C11descriptionSSvg",
        "$s10CoreDevice06RemoteB0C13xpcConnection22forFeatureIdentifiedBy7Mercury07XPCPeerE0_pSS_tYaKF",
        "$s10CoreDevice06RemoteB0C13xpcConnection22forFeatureIdentifiedBy7Mercury07XPCPeerE0_pSS_tYaKFTu",
        "$s7Mercury17XPCPeerConnectionMp"
    ]
    /// Everything mac-cu's stub-module calls (PhysicalDeviceSession) import from CoreDevice and CoreDeviceUtilities
    /// (the latter is re-exported by CoreDevice): dispatch thunks, async function pointers, protocol/witness/
    /// associated-type descriptors and metadata accessors. Taken from the built executable's weak imports
    /// (`xcrun dyld_info -imports`); keep in step with CoreDeviceStubs and PhysicalDeviceSession.swift.
    static let inProcessSymbols = physicalInProcessSymbols
    /// Protocols whose existentials the stubs use; CoreDevice declares them without a class constraint
    /// (descriptor flag bit 16 set). A class-bound one would change the existential layout.
    static let openProtocols = ["$s10CoreDevice25CaptureScreenshotProtocolMp", "$s10CoreDevice17LockStateProtocolMp",
                                "$s10CoreDevice19DisplayInfoProtocolMp", "$s10CoreDevice0B18CapabilityProtocolMp"]
    static func protocolIsClassBound(_ descriptor: UnsafeMutableRawPointer) -> Bool {
        descriptor.load(as: UInt32.self) & (1 << 16) == 0
    }

    private let openFramework: OpenFramework
    private let findSymbol: FindSymbol
    private let imagesBound: () -> Bool
    private let protocolTypeMismatch: () -> String?
    private var frameworkHandle: UnsafeMutableRawPointer?
    private let frameworkLock = NSLock()
    private var inProcess: InProcessCoreDevice?
    /// Where the one-time explanation of a disabled in-process path goes.
    var log: (String) -> Void = { FileHandle.standardError.write(Data(("mac-cu: " + $0 + "\n").utf8)) }
    init(openFramework: @escaping OpenFramework = { dlopen($0, RTLD_LAZY | RTLD_LOCAL) },
         findSymbol: @escaping FindSymbol = { dlsym($0, $1) },
         imagesBound: @escaping () -> Bool = coreDeviceImagesBound,
         protocolTypeMismatch: @escaping () -> String? = coreDeviceProtocolTypeMismatch) {
        self.openFramework = openFramework
        self.findSymbol = findSymbol
        self.imagesBound = imagesBound
        self.protocolTypeMismatch = protocolTypeMismatch
    }
    /// Caller holds frameworkLock.
    private func checkedHandle() throws -> UnsafeMutableRawPointer {
        guard let handle = frameworkHandle ?? openFramework(Self.path) else { throw PhysicalDeviceError.frameworkMissing(Self.path) }
        frameworkHandle = handle
        for symbol in Self.symbols {
            guard findSymbol(handle, symbol) != nil else { throw PhysicalDeviceError.symbolMissing(symbol) }
        }
        // This executable's own weak bindings: the framework may open by path although it was not there at launch.
        guard imagesBound() else { throw PhysicalDeviceError.frameworkMissing("\(Self.path) (not bound at launch)") }
        guard let descriptor = findSymbol(handle, "$s7Mercury17XPCPeerConnectionMp"),
              Self.protocolIsClassBound(descriptor) else {
            throw PhysicalDeviceError.unavailable("unsupported Mercury peer ABI")
        }
        return handle
    }
    private func checkedManager() throws -> PhysicalManagerShim {
        frameworkLock.lock()
        defer { frameworkLock.unlock() }
        _ = try checkedHandle()
        return unsafeBitCast(physicalSharedManager(), to: PhysicalManagerShim.self)
    }

    /// Checked once per process before any stub-module call: the framework and this executable's bindings, every
    /// symbol those calls import, the protocols' class-constraint flags and the runtime ProtocolTypes. On a mismatch
    /// the in-process path stays off for the process (screenshots and state then use devicectl) and the reason is
    /// logged once.
    func inProcessCheck() -> InProcessCoreDevice {
        frameworkLock.lock()
        if let inProcess { frameworkLock.unlock(); return inProcess }
        let result: InProcessCoreDevice
        do {
            let handle = try checkedHandle()
            if let missing = Self.inProcessSymbols.first(where: { findSymbol(handle, $0) == nil }) {
                result = .unavailable("CoreDevice symbol missing: \(missing). The installed Xcode differs from the one mac-cu was built for.")
            } else if let bound = Self.openProtocols.first(where: { Self.protocolIsClassBound(findSymbol(handle, $0)!) }) {
                result = .unavailable("CoreDevice protocol \(bound) became class-bound. The installed Xcode differs from the one mac-cu was built for.")
            } else if let mismatch = protocolTypeMismatch() {
                result = .unavailable("CoreDevice ABI changed: \(mismatch).")
            } else {
                result = .available
            }
        } catch {
            result = .unavailable("\(error)")
        }
        inProcess = result
        frameworkLock.unlock()
        if case .unavailable(let reason) = result {
            log("in-process CoreDevice disabled for this process; screenshots and device state use devicectl. \(reason)")
        }
        return result
    }
    private func info(_ id: UUID, _ object: AnyObject) -> PhysicalDeviceInfo {
        let description = unsafeBitCast(object, to: PhysicalDeviceShim.self).describe()
        let parts = description.components(separatedBy: " (")
        let fields = parts.dropFirst().joined(separator: " (").trimmingCharacters(in: CharacterSet(charactersIn: ")")).components(separatedBy: ", ")
        return PhysicalDeviceInfo(identifier: id, name: parts.first ?? "", model: nil,
                                  osVersion: fields.count > 1 ? fields[1] : nil, transport: nil,
                                  connectionState: fields.first, pairingState: nil)
    }
    func listDevices() throws -> [PhysicalDeviceInfo] {
        let manager = try checkedManager()
        return manager.devices().map { info($0.key, $0.value) }
    }
    func openHID(identifier: UUID) async throws -> PhysicalHIDLink {
        try await openFeature(identifier: identifier, feature: "com.apple.coredevice.feature.remote.hid.digitizer")
    }
    /// The device's RemoteXPC connection for one HID feature (digitizer, button, …). CoreDevice keeps one connection
    /// per device and feature and hands the cached one out again.
    func openFeature(identifier: UUID, feature: String) async throws -> PhysicalHIDLink {
        let manager = try checkedManager()
        guard let object = manager.devices()[identifier] else { throw PhysicalDeviceError.noSuchDevice(identifier.uuidString) }
        let deviceInfo = info(identifier, object)
        guard deviceInfo.connectionState == "Connected" else { throw PhysicalDeviceError.unavailable(deviceInfo.connectionState ?? "unknown state") }
        let device = unsafeBitCast(object, to: PhysicalDeviceShim.self)
        let result: PhysicalPeerExistential
        do { result = try await device.connection(feature) }
        catch { throw PhysicalDeviceError.connectionRefused(String(describing: error)) }
        // The async call returns the peer owned (+1); take that ownership exactly once so the peer is released with the link.
        guard let raw = UnsafeRawPointer(bitPattern: result.object) else { throw PhysicalDeviceError.connectionRefused("empty Mercury peer") }
        let peer = Unmanaged<AnyObject>.fromOpaque(raw).takeRetainedValue()
        var mirror: Mirror? = Mirror(reflecting: peer)
        while let current = mirror {
            if let connection = current.children.first(where: { $0.label == "connection" })?.value as? xpc_object_t {
                // CoreDevice has already activated this connection; never set its event handler again.
                return PhysicalHIDLink(peer: peer, connection: connection)
            }
            mirror = current.superclassMirror
        }
        throw PhysicalDeviceError.connectionRefused("remote connection unavailable in Mercury peer")
    }
}

extension PhysicalHIDLink {
    func send(_ message: xpc_object_t) -> Bool {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "xpc_remote_connection_send_message") else { return false }
        let send = unsafeBitCast(symbol, to: (@convention(c) (xpc_object_t, xpc_object_t) -> Void).self)
        send(connection, message)
        return true
    }

    enum Barrier: Equatable { case acknowledged, failed(String), timedOut, unsupported }

    /// CoreDevice's HID barrier (HIDDigitizer.sendBarrier): a message holding only `isBarrier: true`, sent with a reply.
    /// The device answers after the events sent before it on this connection, so an answer means they reached it.
    /// Waits at most timeout seconds; a late reply is ignored.
    func barrier(timeout: Double) -> Barrier {
        typealias Handler = @convention(block) (xpc_object_t) -> Void
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "xpc_remote_connection_send_message_with_reply") else { return .unsupported }
        let sendWithReply = unsafeBitCast(symbol, to: (@convention(c) (xpc_object_t, xpc_object_t, DispatchQueue, Handler) -> Void).self)
        let message = Self.barrierMessage()
        let done = DispatchSemaphore(value: 0)
        let reply = PhysicalBarrierReply()
        let handler: Handler = { event in reply.value = event; done.signal() }
        sendWithReply(connection, message, PhysicalHIDLink.replyQueue, handler)
        guard done.wait(timeout: .now() + timeout) == .success, let event = reply.value else { return .timedOut }
        if xpc_get_type(event) == XPC_TYPE_ERROR {
            return .failed(xpc_dictionary_get_string(event, XPC_ERROR_KEY_DESCRIPTION).map { String(cString: $0) } ?? "connection error")
        }
        guard xpc_get_type(event) == XPC_TYPE_DICTIONARY else { return .failed("unexpected reply") }
        if let error = xpc_dictionary_get_value(event, "errorContainer") {
            return .failed(String(String(describing: error).prefix(200)))
        }
        return .acknowledged
    }
    private static let replyQueue = DispatchQueue(label: "mac-cu.device.barrier", autoreleaseFrequency: .workItem)
    /// HIDXPCService's barrier: a dictionary with only `isBarrier` (CoreDevice 651.31, see docs/design/device-hub-connection-analysis.md).
    static func barrierMessage() -> xpc_object_t {
        let message = xpc_dictionary_create(nil, nil, 0)
        xpc_dictionary_set_bool(message, "isBarrier", true)
        return message
    }
}

private final class PhysicalBarrierReply: @unchecked Sendable {
    private let lock = NSLock(); private var stored: xpc_object_t?
    var value: xpc_object_t? { get { lock.lock(); defer { lock.unlock() }; return stored } set { lock.lock(); stored = newValue; lock.unlock() } }
}

/// See PhysicalDeviceLink.inProcessSymbols. Generated from `xcrun dyld_info -imports mac-cu` (CoreDevice and
/// CoreDeviceUtilities imports of -O and -Onone builds, Xcode 27.2); device-remote-selfcheck compares it with its own executable's imports.
let physicalInProcessSymbols: [String] = [
    "$s10CoreDevice010AssertableB5StateV04coreB14ServicesLoadedACvgZ",
    "$s10CoreDevice010AssertableB5StateV08extendedB10InfoLoadedACvgZ",
    "$s10CoreDevice010AssertableB5StateV30developerModeEnabledIfRequiredACvgZ",
    "$s10CoreDevice010AssertableB5StateV50remoteServiceDiscoveryTrustedConnectivityAvailableACvgZ",
    "$s10CoreDevice010AssertableB5StateVMa",
    "$s10CoreDevice010AssertableB5StateVMn",
    "$s10CoreDevice010AssertableB5StateVN",
    "$s10CoreDevice010AssertableB5StateVSHAAMc",
    "$s10CoreDevice010AssertableB5StateVSQAAMc",
    "$s10CoreDevice06RemoteB0C07acquireB14UsageAssertion10withReason12requirementsAA0beF0CSS_AA0eF12RequirementsVtYaKF",
    "$s10CoreDevice06RemoteB0C07acquireB14UsageAssertion10withReason12requirementsAA0beF0CSS_AA0eF12RequirementsVtYaKFTu",
    "$s10CoreDevice06RemoteB0C11descriptionSSvg",
    "$s10CoreDevice06RemoteB0C13xpcConnection22forFeatureIdentifiedBy7Mercury07XPCPeerE0_pSS_tYaKF",
    "$s10CoreDevice06RemoteB0C13xpcConnection22forFeatureIdentifiedBy7Mercury07XPCPeerE0_pSS_tYaKFTu",
    "$s10CoreDevice06RemoteB0C15supportsFeature12identifiedBySbSS_tFTj",
    "$s10CoreDevice06RemoteB0C17getImplementation3for12ProtocolTypeQzAA22CapabilityStaticMemberVyxG_tYaKAA0bI0RzlFTjTu",
    "$s10CoreDevice06RemoteB0CMa",
    "$s10CoreDevice06RemoteB0CMm",
    "$s10CoreDevice06RemoteB0CMn",
    "$s10CoreDevice06RemoteB0CMo",
    "$s10CoreDevice06RemoteB0CN",
    "$s10CoreDevice0B10CapabilityTL",
    "$s10CoreDevice0B11OrientationO8rawValueSSvg",
    "$s10CoreDevice0B11OrientationOMa",
    "$s10CoreDevice0B14UsageAssertionC07releaseD0yyFTj",
    "$s10CoreDevice0B14UsageAssertionC27registerInvalidationHandler15invokingOnQueue7handlerySo17OS_dispatch_queueCSg_ys5Error_pSgctFTj",
    "$s10CoreDevice0B14UsageAssertionCMa",
    "$s10CoreDevice0B14UsageAssertionCMm",
    "$s10CoreDevice0B14UsageAssertionCMn",
    "$s10CoreDevice0B14UsageAssertionCMo",
    "$s10CoreDevice0B14UsageAssertionCN",
    "$s10CoreDevice0B7ManagerC6sharedACvgZ",
    "$s10CoreDevice0B7ManagerC7devicesSDy10Foundation4UUIDVAA06RemoteB0CGvgTj",
    "$s10CoreDevice0B7ManagerCMa",
    "$s10CoreDevice0B7ManagerCMm",
    "$s10CoreDevice0B7ManagerCMn",
    "$s10CoreDevice0B7ManagerCMo",
    "$s10CoreDevice0B7ManagerCN",
    "$s10CoreDevice0aB5ErrorVMa",
    "$s10CoreDevice0aB5ErrorVs0C0AAMc",
    "$s10CoreDevice10CapabilityVMa",
    "$s10CoreDevice10CapabilityVMn",
    "$s10CoreDevice10CapabilityVN",
    "$s10CoreDevice10CapabilityVSHAAMc",
    "$s10CoreDevice10CapabilityVSQAAMc",
    "$s10CoreDevice11DisplayInfoV11orientationAA011OrientationD0VSgvg",
    "$s10CoreDevice11DisplayInfoV8displaysSayAA0C0VGvg",
    "$s10CoreDevice11DisplayInfoVMa",
    "$s10CoreDevice11DisplayInfoVMn",
    "$s10CoreDevice11DisplayInfoVN",
    "$s10CoreDevice15OrientationInfoV07currentbC0AA0bC0Ovg",
    "$s10CoreDevice15OrientationInfoVMa",
    "$s10CoreDevice15OrientationInfoVMn",
    "$s10CoreDevice17LockStateProtocolMp",
    "$s10CoreDevice17LockStateProtocolP07currentcD0AA0cD0VvgTj",
    "$s10CoreDevice17LockStateProtocolP07currentcD0AA0cD0VvgTjTu",
    "$s10CoreDevice19DisplayInfoProtocolMp",
    "$s10CoreDevice19DisplayInfoProtocolP07displayD0AA0cD0VvgTj",
    "$s10CoreDevice19DisplayInfoProtocolP07displayD0AA0cD0VvgTjTu",
    "$s10CoreDevice19LockStateCapabilityVAA0bE0AAMc",
    "$s10CoreDevice19LockStateCapabilityVAA0bE0AAWP",
    "$s10CoreDevice19LockStateCapabilityVMa",
    "$s10CoreDevice19LockStateCapabilityVMn",
    "$s10CoreDevice19LockStateCapabilityVN",
    "$s10CoreDevice21DisplayInfoCapabilityVAA0bE0AAMc",
    "$s10CoreDevice21DisplayInfoCapabilityVAA0bE0AAWP",
    "$s10CoreDevice21DisplayInfoCapabilityVMa",
    "$s10CoreDevice21DisplayInfoCapabilityVMn",
    "$s10CoreDevice21DisplayInfoCapabilityVN",
    "$s10CoreDevice22CapabilityStaticMemberVA2A0bC0RzlE11displayInfoACyAA07DisplaygC0VGvgZ",
    "$s10CoreDevice22CapabilityStaticMemberVA2A0bC0RzlE17captureScreenshotACyAA07CapturegC0VGvgZ",
    "$s10CoreDevice22CapabilityStaticMemberVA2A0bC0RzlE9lockStateACyAA04LockgC0VGvgZ",
    "$s10CoreDevice22CapabilityStaticMemberVMn",
    "$s10CoreDevice25CaptureScreenshotProtocolMp",
    "$s10CoreDevice25CaptureScreenshotProtocolP07captureD015displayUniqueID6format0aB9Utilities0cD6OutputVSSSg_AG0D11ImageFormatOtYaAA0aB5ErrorVYKFTj",
    "$s10CoreDevice25CaptureScreenshotProtocolP07captureD015displayUniqueID6format0aB9Utilities0cD6OutputVSSSg_AG0D11ImageFormatOtYaAA0aB5ErrorVYKFTjTu",
    "$s10CoreDevice26UsageAssertionRequirementsV12deviceStates12capabilitiesACShyAA010AssertableB5StateVG_ShyAA10CapabilityVGtcfC",
    "$s10CoreDevice26UsageAssertionRequirementsVMa",
    "$s10CoreDevice26UsageAssertionRequirementsVMn",
    "$s10CoreDevice26UsageAssertionRequirementsVN",
    "$s10CoreDevice27CaptureScreenshotCapabilityVAA0bE0AAMc",
    "$s10CoreDevice27CaptureScreenshotCapabilityVAA0bE0AAWP",
    "$s10CoreDevice27CaptureScreenshotCapabilityVMa",
    "$s10CoreDevice27CaptureScreenshotCapabilityVMn",
    "$s10CoreDevice27CaptureScreenshotCapabilityVN",
    "$s10CoreDevice7DisplayV10nativeSizeSo6CGSizeVvg",
    "$s10CoreDevice7DisplayV10pointScaleSivg",
    "$s10CoreDevice7DisplayV18currentOrientationSSvg",
    "$s10CoreDevice7DisplayV7primarySbvg",
    "$s10CoreDevice7DisplayVMa",
    "$s10CoreDevice7DisplayVMn",
    "$s10CoreDevice9LockStateV18isPasscodeRequiredSbvg",
    "$s10CoreDevice9LockStateVMa",
    "$s10CoreDevice9LockStateVMn",
    "$s10CoreDevice9LockStateVN",
    "$s12ProtocolType10CoreDevice0D10CapabilityPTl",
    "$s19CoreDeviceUtilities21ScreenshotImageFormatO3pngyA2CmFWC",
    "$s19CoreDeviceUtilities21ScreenshotImageFormatOMa",
    "$s19CoreDeviceUtilities21ScreenshotImageFormatOMn",
    "$s19CoreDeviceUtilities21ScreenshotImageFormatON",
    "$s19CoreDeviceUtilities21ScreenshotImageFormatOSHAAMc",
    "$s19CoreDeviceUtilities21ScreenshotImageFormatOSQAAMc",
    "$s19CoreDeviceUtilities21ScreenshotImageFormatOSYAAMc",
    "$s19CoreDeviceUtilities21ScreenshotImageFormatOs12CaseIterableAAMc",
    "$s19CoreDeviceUtilities23CaptureScreenshotOutputV5imageSo10CGImageRefavg",
    "$s19CoreDeviceUtilities23CaptureScreenshotOutputVMa",
    "$s19CoreDeviceUtilities23CaptureScreenshotOutputVMn",
    "$s19CoreDeviceUtilities23CaptureScreenshotOutputVN",
]
