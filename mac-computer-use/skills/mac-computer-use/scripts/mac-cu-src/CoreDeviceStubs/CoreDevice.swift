// Declarations-only interface of Apple's private CoreDevice framework (Xcode 27.2, CoreDevice 651.31): the typed
// capability calls devicectl makes. native_build.py compiles this file with -emit-module only (library evolution, so
// every type stays opaque and is reached through the framework's own metadata); it is never linked into mac-cu.
// The product links the real framework weakly; PhysicalDeviceLink.inProcessCheck verifies the symbols, the protocol
// descriptors and the associated ProtocolTypes before PhysicalDeviceSession touches any of it.
// Names, kinds (class/struct/enum/protocol), class-body vs extension placement and signatures follow the exported
// symbols; a mismatch fails at link time. Keep PhysicalDeviceLink.inProcessSymbols in step with what is used here.
import Foundation
import CoreGraphics
import CoreDeviceUtilities

public struct CoreDeviceError: Error {}

public protocol DeviceCapabilityProtocol {}
public protocol DeviceCapability {
    associatedtype ImplType
    associatedtype ProtocolType
}
public struct CapabilityStaticMember<A> {}

public protocol CaptureScreenshotProtocol: DeviceCapabilityProtocol {
    func captureScreenshot(displayUniqueID: String?, format: ScreenshotImageFormat) async throws(CoreDeviceError) -> CaptureScreenshotOutput
}
public protocol LockStateProtocol: DeviceCapabilityProtocol {
    var currentLockState: LockState { get async throws }
}
public protocol DisplayInfoProtocol: DeviceCapabilityProtocol {
    var displayInfo: DisplayInfo { get async throws }
    func displayInfoUpdates() async throws -> AsyncThrowingStream<DisplayInfo, Error>
}

public struct CaptureScreenshotCapability: DeviceCapability {
    public typealias ImplType = Void
    public typealias ProtocolType = any CaptureScreenshotProtocol
}
public struct LockStateCapability: DeviceCapability {
    public typealias ImplType = Void
    public typealias ProtocolType = any LockStateProtocol
}
public struct DisplayInfoCapability: DeviceCapability {
    public typealias ImplType = Void
    public typealias ProtocolType = any DisplayInfoProtocol
}
extension CapabilityStaticMember where A: DeviceCapability {
    public static var captureScreenshot: CapabilityStaticMember<CaptureScreenshotCapability> { fatalError() }
    public static var lockState: CapabilityStaticMember<LockStateCapability> { fatalError() }
    public static var displayInfo: CapabilityStaticMember<DisplayInfoCapability> { fatalError() }
}

public struct LockState {
    public var isPasscodeRequired: Bool { fatalError() }
    public var hasBeenUnlockedSinceBoot: Bool { fatalError() }
}
public enum DeviceOrientation: String {
    case unknown, portrait, portraitUpsideDown, landscapeLeft, landscapeRight, faceUp, faceDown
}
public struct OrientationInfo {
    public var currentDeviceOrientation: DeviceOrientation { fatalError() }
    public var currentDeviceNonFlatOrientation: DeviceOrientation { fatalError() }
    public var currentDeviceOrientationLocked: Bool { fatalError() }
}
public struct Display {
    public enum BacklightState: String {
        case unknown, off, inactiveOn, activeDimmed, activeOn
    }
    public var displayId: UInt32 { fatalError() }
    public var primary: Bool { fatalError() }
    public var nativeSize: CGSize { fatalError() }
    public var pointScale: Int { fatalError() }
    public var currentOrientation: String { fatalError() }
    public var backlightState: BacklightState { fatalError() }
}
public struct DisplayInfo {
    public var displays: [Display] { fatalError() }
    public var orientation: OrientationInfo? { fatalError() }
    public var backlightState: Display.BacklightState { fatalError() }
}

/// Device states a usage assertion requires; only the members used here are declared.
public struct AssertableDeviceState: Hashable {
    public static var developerModeEnabledIfRequired: AssertableDeviceState { fatalError() }
    public static var coreDeviceServicesLoaded: AssertableDeviceState { fatalError() }
    public static var extendedDeviceInfoLoaded: AssertableDeviceState { fatalError() }
    public static var remoteServiceDiscoveryTrustedConnectivityAvailable: AssertableDeviceState { fatalError() }
}
/// Defined in CoreDeviceUtilities under the CoreDevice module name; re-exported by CoreDevice.
public struct Capability: Hashable {}
public struct UsageAssertionRequirements {
    public init(deviceStates: Set<AssertableDeviceState>, capabilities: Set<Capability>) { fatalError() }
}
public class DeviceUsageAssertion {
    public func releaseAssertion() { fatalError() }
    public func registerInvalidationHandler(invokingOnQueue queue: DispatchQueue?, handler: @escaping (Error?) -> Void) { fatalError() }
}

public class DeviceManager {
    public static var shared: DeviceManager { fatalError() }
    public var devices: [UUID: RemoteDevice] { fatalError() }
}
public class RemoteDevice {
    public func getImplementation<A: DeviceCapability>(for capability: CapabilityStaticMember<A>) async throws -> A.ProtocolType { fatalError() }
    public func supportsFeature(identifiedBy feature: String) -> Bool { fatalError() }
}
extension RemoteDevice {
    public var description: String { fatalError() }
    public func acquireDeviceUsageAssertion(withReason reason: String, requirements: UsageAssertionRequirements) async throws -> DeviceUsageAssertion { fatalError() }
}

public final class DetailedOperation<Result> {
    public var result: Result { get async throws { fatalError() } }
}
public protocol TransferFilesProtocol: DeviceCapabilityProtocol {
    func send(to: FileServicePath, from: [URL]) async throws -> DetailedOperation<DeviceFileSystemNode>
    func receive(from: FileServicePath, to: URL) async throws -> DetailedOperation<URL>
}
public struct TransferFilesCapability: DeviceCapability {
    public typealias ImplType = Void
    public typealias ProtocolType = any TransferFilesProtocol
}
extension CapabilityStaticMember where A: DeviceCapability {
    public static var remoteFileTransfer: CapabilityStaticMember<TransferFilesCapability> { fatalError() }
}
