import Foundation
import CryptoKit
import System
@_weakLinked import CoreDevice
@_weakLinked import CoreDeviceUtilities

final class WatchXCTestFiles {
    private let transfer: any TransferFilesProtocol
    private let bundle: String
    private let directory: String
    private let work: URL
    private(set) var lastReadError: String?

    init(device: UUID, bundle: String, session: UUID, work: URL) throws {
        let linked = UnsafeMutableRawPointer(bitPattern: -2)
        guard watchFileSymbols.allSatisfy({ dlsym(linked, $0) != nil }),
              let descriptor = dlsym(linked, "$s10CoreDevice21TransferFilesProtocolMp"),
              (descriptor.load(as: UInt32.self) >> 16) & 1 == 0,
              #_hasSymbol(TransferFilesCapability.self), #_hasSymbol(FileServicePath.self),
              #_hasSymbol(DeviceFileSystemNode.self), #_hasSymbol(FileServicePath.init(domain:relativePath:directoryTransferOptions:)),
              #_hasSymbol(CapabilityStaticMember<TransferFilesCapability>.remoteFileTransfer),
              watchTransferProtocol(TransferFilesCapability.self) == (any TransferFilesProtocol).self else {
            throw ToolError("The selected Xcode does not provide the watch runner file service.")
        }
        self.bundle = bundle
        self.directory = "Library/Caches/macpilot-" + session.uuidString + "/"
        self.work = work
        transfer = try physicalBlocking(20, "the watch runner file service") {
            guard let remote = DeviceManager.shared.devices[device] else { throw PhysicalSessionError.notFound }
            return try await remote.getImplementation(for: CapabilityStaticMember<TransferFilesCapability>.remoteFileTransfer)
        }
    }

    private func path(_ name: String) -> FileServicePath {
        FileServicePath(domain: .appDataContainer(bundle, nil), relativePath: FilePath(directory + name), directoryTransferOptions: nil)
    }

    func send(_ data: Data, sequence: Int, key: SymmetricKey, until deadline: Double) throws {
        let name = "request-\(sequence)"
        let local = work.appendingPathComponent(name)
        try XCTestSocket.frame(data, as: .request, key: key).write(to: local, options: .atomic)
        try physicalBlocking(max(0, deadline - XCTestSocket.now), "the watch runner request") { [self] in
            defer { try? FileManager.default.removeItem(at: local) }
            let operation = try await transfer.send(to: path(name), from: [local])
            _ = try await operation.result
        }
    }

    func read(sequence: Int, key: SymmetricKey, until deadline: Double) throws -> Data? {
        let name = "reply-\(sequence)"
        let local = work.appendingPathComponent(UUID().uuidString)
        let frame: Data
        do {
            frame = try physicalBlocking(max(0, deadline - XCTestSocket.now), "the watch runner reply") { [self] in
                defer { try? FileManager.default.removeItem(at: local) }
                let operation = try await transfer.receive(from: path(name), to: local)
                _ = try await operation.result
                let file = try FileHandle(forReadingFrom: local)
                defer { try? file.close() }
                return try file.read(upToCount: XCTestSocket.Direction.reply.limit + 5) ?? Data()
            }
        } catch {
            lastReadError = error.localizedDescription
            return nil
        }
        lastReadError = nil
        guard let data = try XCTestSocket.open(frame, as: .reply, key: key) else { throw XCTestSocketError.frame }
        return data
    }
}

@inline(never) @_optimize(none)
private func watchTransferProtocol<C: DeviceCapability>(_ capability: C.Type) -> Any.Type { C.ProtocolType.self }

private let watchFileSymbols = [
    "$s10CoreDevice17DetailedOperationC6resultxvg",
    "$s10CoreDevice17DetailedOperationC6resultxvgTu",
    "$s10CoreDevice21TransferFilesProtocolMp",
    "$s10CoreDevice21TransferFilesProtocolP4send2to4fromAA17DetailedOperationCy0aB9Utilities0B14FileSystemNodeVGAI0L11ServicePathV_Say10Foundation3URLVGtYaKFTj",
    "$s10CoreDevice21TransferFilesProtocolP4send2to4fromAA17DetailedOperationCy0aB9Utilities0B14FileSystemNodeVGAI0L11ServicePathV_Say10Foundation3URLVGtYaKFTjTu",
    "$s10CoreDevice21TransferFilesProtocolP7receive4from2toAA17DetailedOperationCy10Foundation3URLVG0aB9Utilities15FileServicePathV_AKtYaKFTj",
    "$s10CoreDevice21TransferFilesProtocolP7receive4from2toAA17DetailedOperationCy10Foundation3URLVG0aB9Utilities15FileServicePathV_AKtYaKFTjTu",
    "$s10CoreDevice22CapabilityStaticMemberVA2A0bC0RzlE18remoteFileTransferACyAA0h5FilesC0VGvgZ",
    "$s10CoreDevice23TransferFilesCapabilityVAA0bE0AAMc",
    "$s10CoreDevice23TransferFilesCapabilityVAA0bE0AAWP",
    "$s10CoreDevice23TransferFilesCapabilityVMa",
    "$s10CoreDevice23TransferFilesCapabilityVMn",
    "$s10CoreDevice23TransferFilesCapabilityVN",
    "$s19CoreDeviceUtilities0B14FileSystemNodeVMa",
    "$s19CoreDeviceUtilities0B14FileSystemNodeVMn",
    "$s19CoreDeviceUtilities0B14FileSystemNodeVN",
    "$s19CoreDeviceUtilities15FileServicePathV0dE6DomainO16appDataContaineryAESS_SSSgtcAEmFWC",
    "$s19CoreDeviceUtilities15FileServicePathV0dE6DomainOMa",
    "$s19CoreDeviceUtilities15FileServicePathV6domain08relativeF024directoryTransferOptionsA2C0dE6DomainO_6System0dF0VAA0dm9DirectoryjK0VSgtcfC",
    "$s19CoreDeviceUtilities15FileServicePathVMa",
    "$s19CoreDeviceUtilities15FileServicePathVMn",
    "$s19CoreDeviceUtilities15FileServicePathVN",
    "$s19CoreDeviceUtilities34FileSystemDirectoryTransferOptionsVMa",
    "$s19CoreDeviceUtilities34FileSystemDirectoryTransferOptionsVMn",
]
