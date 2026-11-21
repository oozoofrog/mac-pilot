// Declarations-only interface of Apple's private CoreDeviceUtilities framework (Xcode 27.2, CoreDevice 651.31).
// native_build.py compiles this file with -emit-module only; it is never linked into mac-cu. The product links the
// real framework weakly and checks the runtime ABI before any call (PhysicalDeviceLink.inProcessCheck).
// Names, kinds and signatures follow the framework's exported symbols; a mismatch fails at link time.
import CoreGraphics

public enum ScreenshotImageFormat: String, CaseIterable, Sendable {
    case png
}

public struct CaptureScreenshotOutput {
    public var image: CGImage { fatalError() }
    public var displayUniqueID: String? { fatalError() }
    public var imageFormat: ScreenshotImageFormat { fatalError() }
}

import System
public struct DeviceFileSystemNode {}
public struct FileSystemDirectoryTransferOptions {}
public struct FileServicePath {
    public enum FileServiceDomain { case appDataContainer(String, String?) }
    public init(domain: FileServiceDomain, relativePath: FilePath, directoryTransferOptions: FileSystemDirectoryTransferOptions?) { fatalError() }
}
