import Foundation
import ObjectiveC
import Darwin

/// A Simulator boot is the kernel lifetime of its own launchd_sim, not a SimDevice pointer.
struct SimulatorBootIdentity: Equatable {
    let deviceID: String
    let pid: Int32
    let seconds: UInt64
    let microseconds: UInt64
    let executable: String
    var key: String { "\(deviceID):\(pid):\(seconds):\(microseconds):\(executable)" }

    /// Extract only the device identifier. Never log or persist the process environment.
    static func deviceID(in bytes: [UInt8]) -> String? {
        guard bytes.count >= 5 else { return nil }
        let argc = bytes.prefix(4).enumerated().reduce(UInt32(0)) { $0 | UInt32($1.element) << (8 * $1.offset) }
        guard argc > 0, argc < 65536, let executableEnd = bytes[4...].firstIndex(of: 0) else { return nil }
        var cursor = executableEnd + 1
        while cursor < bytes.count, bytes[cursor] == 0 { cursor += 1 }
        for _ in 0..<argc {
            guard cursor < bytes.count, let end = bytes[cursor...].firstIndex(of: 0) else { return nil }
            cursor = end + 1
        }
        var matches: [String] = []
        let prefix = Array("SIMULATOR_UDID=".utf8)
        while cursor < bytes.count {
            guard let end = bytes[cursor...].firstIndex(of: 0) else { return nil }
            let field = bytes[cursor..<end]
            if field.starts(with: prefix) {
                guard let raw = String(bytes: field.dropFirst(prefix.count), encoding: .ascii),
                      let id = UUID(uuidString: raw) else { return nil }
                matches.append(id.uuidString)
            }
            cursor = end + 1
        }
        return matches.count == 1 ? matches[0] : nil
    }

    static func read(pid: Int32) -> Self? {
        func info() -> proc_bsdinfo? {
            var value = proc_bsdinfo()
            let count = Int32(MemoryLayout<proc_bsdinfo>.size)
            guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &value, count) == count,
                  value.pbi_pid == UInt32(pid), value.pbi_uid == getuid(), value.pbi_status != 5 else { return nil }
            return value
        }
        guard pid > 0, let before = info() else { return nil }
        var path = [CChar](repeating: 0, count: 4096)
        guard proc_pidpath(pid, &path, UInt32(path.count)) > 0 else { return nil }
        let executable = String(cString: path)
        guard (executable as NSString).lastPathComponent == "launchd_sim" else { return nil }
        var mib = [CTL_KERN, KERN_PROCARGS2, pid]
        var bytes = [UInt8](repeating: 0, count: 1_048_576)
        var size = bytes.count
        guard sysctl(&mib, UInt32(mib.count), &bytes, &size, nil, 0) == 0,
              size <= bytes.count, let device = deviceID(in: Array(bytes.prefix(size))),
              let after = info(), before.pbi_start_tvsec == after.pbi_start_tvsec,
              before.pbi_start_tvusec == after.pbi_start_tvusec else { return nil }
        return Self(deviceID: device, pid: pid, seconds: after.pbi_start_tvsec,
                    microseconds: after.pbi_start_tvusec, executable: executable)
    }

    static func current(deviceID: String) -> Self? {
        guard let wanted = UUID(uuidString: deviceID)?.uuidString else { return nil }
        let needed = proc_listpids(UInt32(PROC_ALL_PIDS), 0, nil, 0)
        guard needed > 0, needed <= 1_048_576 else { return nil }
        var pids = [Int32](repeating: 0, count: Int(needed) / MemoryLayout<Int32>.size + 128)
        let capacity = pids.count * MemoryLayout<Int32>.size
        let count = proc_listpids(UInt32(PROC_ALL_PIDS), 0, &pids, Int32(capacity))
        guard count > 0, count < capacity else { return nil }
        var matches: [Self] = []
        for pid in pids.prefix(Int(count) / MemoryLayout<Int32>.size) where pid > 0 {
            var name = [CChar](repeating: 0, count: 64)
            guard proc_name(pid, &name, UInt32(name.count)) > 0, String(cString: name) == "launchd_sim",
                  let identity = read(pid: pid), identity.deviceID == wanted else { continue }
            matches.append(identity)
        }
        return matches.count == 1 ? matches[0] : nil
    }
}

/// Host generations persist across window close/reopen. No lock enters main or handleQueue.
enum SimulatorInspectionHost {
    private struct Record: Equatable { let boot: SimulatorBootIdentity; let presentation: String; let runtime: String }
    private static let lock = NSLock()
    private static var records: [String: Record] = [:]
    private static var generation: UInt64 = 0

    static func invalidate(deviceID: String) {
        lock.lock(); defer { lock.unlock() }
        records.removeValue(forKey: deviceID)
        SimulatorAXHostLifecycle.shared.invalidate(deviceID: deviceID)
    }

    static func presentation(device: NSObject, screen: ActiveScreen?) -> String {
        let size = screen?.points ?? screenSize(of: device)
        return "\(screen?.id ?? "main")|\(screen?.rotation ?? "rot0")|\(screen?.guestRotation ?? "rot0")|\(size.width)x\(size.height)"
    }

    static func runtimeFingerprint(identifier: Any?, build: Any?) -> String? {
        guard let identifier = identifier as? String, let build = build as? String,
              !identifier.isEmpty, !build.isEmpty, !identifier.contains("|"), !build.contains("|"),
              identifier.utf8.count < 256, build.utf8.count < 64,
              identifier.unicodeScalars.allSatisfy({ $0.isASCII && !CharacterSet.controlCharacters.contains($0) }),
              build.unicodeScalars.allSatisfy({ $0.isASCII && !CharacterSet.controlCharacters.contains($0) }) else { return nil }
        return identifier + "|" + build
    }

    /// Read only the build under the selected runtime object's authoritative root.
    static func runtimeBuild(root: URL) -> (build: String, source: URL)? {
        guard root.isFileURL, root.path.hasPrefix("/") else { return nil }
        let resolvedRoot = root.resolvingSymlinksInPath().standardizedFileURL
        let source = resolvedRoot.appendingPathComponent("System/Library/CoreServices/SystemVersion.plist").resolvingSymlinksInPath().standardizedFileURL
        guard source.path.hasPrefix(resolvedRoot.path + "/"),
              let metadata = try? source.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
              metadata.isRegularFile == true, let size = metadata.fileSize, size > 0, size <= 65536,
              let file = try? FileHandle(forReadingFrom: source) else { return nil }
        defer { try? file.close() }
        guard let data = try? file.read(upToCount: 65537), !data.isEmpty, data.count <= 65536,
              let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any],
              let build = plist["ProductBuildVersion"] as? String, build.utf8.count < 64,
              build.range(of: #"\A[0-9]+[A-Z][0-9]+[a-z]?\z"#, options: .regularExpression) != nil else { return nil }
        return (build, source)
    }

    static func runtimeMetadata(_ runtime: NSObject) -> (fingerprint: String, source: URL)? {
        let framework = URL(fileURLWithPath: "/Library/Developer/PrivateFrameworks/CoreSimulator.framework/CoreSimulator").resolvingSymlinksInPath().path
        guard let image = class_getImageName(type(of: runtime)),
              URL(fileURLWithPath: String(cString: image)).resolvingSymlinksInPath().path == framework,
              runtime.responds(to: NSSelectorFromString("identifier")), runtime.responds(to: NSSelectorFromString("root")),
              let root = runtime.value(forKey: "root") as? String, root.hasPrefix("/"), root.utf8.count < 4096,
              !root.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              let metadata = runtimeBuild(root: URL(fileURLWithPath: root)),
              let fingerprint = runtimeFingerprint(identifier: runtime.value(forKey: "identifier"), build: metadata.build) else { return nil }
        return (fingerprint, metadata.source)
    }

    static func prepare(device: NSObject, screen: ActiveScreen?) throws -> SimulatorAXScope {
        guard !Thread.isMainThread else { throw ToolError("Inspection identity requires background dispatch.") }
        let id = udid(of: device)
        guard isBooted(device), let boot = SimulatorBootIdentity.current(deviceID: id),
              let runtimeObject = device.value(forKey: "runtime") as? NSObject,
              let metadata = runtimeMetadata(runtimeObject) else {
            invalidate(deviceID: id)
            throw ToolError("시뮬레이터의 현재 부팅 수명과 런타임을 확인할 수 없습니다.")
        }
        let presentation = presentation(device: device, screen: screen)
        let runtime = metadata.fingerprint
        let record = Record(boot: boot, presentation: presentation, runtime: runtime)
        lock.lock(); defer { lock.unlock() }
        if records[id] != record || (try? SimulatorAXHostLifecycle.shared.current(deviceID: id)) == nil {
            generation &+= 1; records[id] = record
            SimulatorAXHostLifecycle.shared.update(deviceID: id, bootIdentity: boot.key, presentation: presentation,
                                                   generation: generation, runtime: runtime)
        }
        return try SimulatorAXHostLifecycle.shared.current(deviceID: id)
    }
}
