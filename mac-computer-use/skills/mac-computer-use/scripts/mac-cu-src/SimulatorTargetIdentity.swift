import Foundation
import Darwin

/// Targeted read only. No process launch, global enumeration, privilege change or fallback.
struct SimulatorTargetIdentity {
    let pid: Int32
    let start: [UInt64]
    let path: String
    let deviceID: String

    enum Failure: Error, Equatable, CustomStringConvertible {
        case invalidRequest, identityUnknown, identityChanged, targetUnavailable
        var description: String {
            switch self {
            case .invalidRequest: return "Target identity requires a valid PID/device and a background thread."
            case .identityUnknown: return "Cannot read complete target process identity."
            case .identityChanged: return "Target lifetime or executable changed while reading identity."
            case .targetUnavailable: return "Target device/state does not match, or the target is traced."
            }
        }
    }

    static let pathLimit = 4096
    static let argumentLimit = 1_048_576

    /// Four narrow reads permit deterministic boundary tests without real process access.
    struct Reads {
        var status: (Int32) throws -> proc_bsdinfo
        var path: (Int32) throws -> String
        var arguments: (Int32) throws -> [UInt8]
        var canonicalPath: (String) throws -> String

        static let system = Reads(status: { pid in
            var info = proc_bsdinfo()
            let size = Int32(MemoryLayout<proc_bsdinfo>.size)
            let count = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size)
            return try checkedStatus(info, byteCount: count, pid: pid)
        }, path: { pid in
            var bytes = [UInt8](repeating: 0, count: pathLimit)
            let count = proc_pidpath(pid, &bytes, UInt32(bytes.count))
            return try pathString(bytes, length: Int(count))
        }, arguments: { pid in
            var mib = [CTL_KERN, KERN_PROCARGS2, pid]
            var bytes = [UInt8](repeating: 0, count: argumentLimit)
            var size = bytes.count
            guard sysctl(&mib, UInt32(mib.count), &bytes, &size, nil, 0) == 0 else {
                throw Failure.identityUnknown
            }
            return try argumentBytes(bytes, size: size)
        }, canonicalPath: SimulatorTargetIdentity.canonicalPath)
    }

    static func read(pid: Int32, deviceID: String, reads: Reads = .system) throws -> Self {
        guard !Thread.isMainThread, pid > 0, let wanted = UUID(uuidString: deviceID)?.uuidString else {
            throw Failure.invalidRequest
        }
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        let before = try checkedStatus(reads.status(pid), byteCount: size, pid: pid)
        let path = try reads.canonicalPath(reads.path(pid))
        let observedDevice = try self.deviceID(in: reads.arguments(pid))
        let finalPath = try reads.canonicalPath(reads.path(pid))
        let after = try checkedStatus(reads.status(pid), byteCount: size, pid: pid)
        guard before.pbi_start_tvsec == after.pbi_start_tvsec,
              before.pbi_start_tvusec == after.pbi_start_tvusec, path == finalPath else {
            throw Failure.identityChanged
        }
        guard observedDevice == wanted, [UInt32(2), UInt32(3)].contains(after.pbi_status),
              after.pbi_flags & UInt32(PROC_FLAG_TRACED) == 0 else {
            throw Failure.targetUnavailable
        }
        // This sandwich is not an atomic exec identity. Capture independently revalidates
        // the target before attach and after recovery; never replace that with this value.
        return Self(pid: pid, start: [after.pbi_start_tvsec, after.pbi_start_tvusec],
                    path: path, deviceID: wanted)
    }

    static func checkedStatus(_ info: proc_bsdinfo, byteCount: Int32, pid: Int32) throws -> proc_bsdinfo {
        guard pid > 0, byteCount == MemoryLayout<proc_bsdinfo>.size, info.pbi_pid == UInt32(pid),
              info.pbi_start_tvsec > 0, info.pbi_start_tvusec < 1_000_000 else {
            throw Failure.identityUnknown
        }
        return info
    }

    static func pathString(_ bytes: [UInt8], length: Int) throws -> String {
        // libproc proc_pidpath returns strlen(buffer), excluding the NUL byte.
        guard length > 0, length < pathLimit, length < bytes.count, bytes[length] == 0,
              !bytes.prefix(length).contains(0), let value = String(bytes: bytes.prefix(length), encoding: .utf8),
              value.hasPrefix("/") else { throw Failure.identityUnknown }
        return value
    }

    static func canonicalPath(_ path: String) throws -> String {
        guard path.hasPrefix("/"), path.utf8.count < pathLimit, !path.utf8.contains(0) else {
            throw Failure.identityUnknown
        }
        var resolved = [CChar](repeating: 0, count: pathLimit)
        guard path.withCString({ Darwin.realpath($0, &resolved) }) != nil,
              let end = resolved.firstIndex(of: 0), end > 0,
              let value = String(bytes: resolved.prefix(end).map { UInt8(bitPattern: $0) }, encoding: .utf8),
              value.hasPrefix("/") else { throw Failure.identityUnknown }
        return value
    }

    static func argumentBytes(_ bytes: [UInt8], size: Int) throws -> [UInt8] {
        guard size >= 5, size <= argumentLimit, size <= bytes.count else { throw Failure.identityUnknown }
        return Array(bytes.prefix(size))
    }

    /// Parse only the exact environment key after argc argument strings. Do not retain
    /// or report any other argument/environment value. Supported hosts are little endian.
    static func deviceID(in bytes: [UInt8]) throws -> String {
        guard bytes.count >= 5, bytes.count <= argumentLimit else { throw Failure.identityUnknown }
        let argc = bytes.prefix(4).enumerated().reduce(UInt32(0)) { $0 | UInt32($1.element) << (8 * $1.offset) }
        guard argc > 0, argc < 65536, let executableEnd = bytes[4...].firstIndex(of: 0), executableEnd > 4 else {
            throw Failure.identityUnknown
        }
        var cursor = executableEnd + 1
        while cursor < bytes.count, bytes[cursor] == 0 { cursor += 1 }
        for _ in 0..<argc {
            guard cursor < bytes.count, let end = bytes[cursor...].firstIndex(of: 0) else { throw Failure.identityUnknown }
            cursor = end + 1
        }
        let prefix = Array("SIMULATOR_UDID=".utf8)
        var device: String?
        while cursor < bytes.count {
            guard let end = bytes[cursor...].firstIndex(of: 0) else { throw Failure.identityUnknown }
            let field = bytes[cursor..<end]
            if field.starts(with: prefix) {
                guard device == nil, field.count == prefix.count + 36,
                      let raw = String(bytes: field.dropFirst(prefix.count), encoding: .ascii),
                      let normalized = UUID(uuidString: raw)?.uuidString, raw.uppercased() == normalized else {
                    throw Failure.identityUnknown
                }
                device = normalized
            }
            cursor = end + 1
        }
        guard let device else { throw Failure.identityUnknown }
        return device
    }
}
