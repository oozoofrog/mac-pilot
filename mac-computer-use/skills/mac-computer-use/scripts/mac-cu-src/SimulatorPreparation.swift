import Foundation
import Darwin

struct SimulatorPreparationError: LocalizedError {
    enum Kind { case other, failed, timedOut, cancelled }
    let message: String
    var kind = Kind.other
    /// For `failed`: the child's exit status and standard error, unformatted.
    var status: Int32 = 0
    var standardError = ""
    var errorDescription: String? { message }
    init(_ message: String) { self.message = message }
    init(_ message: String, kind: Kind, status: Int32 = 0, standardError: String = "") {
        self.message = message; self.kind = kind; self.status = status; self.standardError = standardError
    }
}

struct PreparedSimulatorType {
    let id: String
    let name: String
    let family: String
    let minimum: UInt64
    let maximum: UInt64
}
struct PreparedSimulatorRuntime {
    let id: String
    let name: String
    let available: Bool
    let version: UInt64
    let supportedTypes: Set<String>?
    let platform: String
    let build: String
    var title: String { "\(name) · \(build) · \(id)" }
}
struct PreparedSimulatorDevice {
    let id: String
    let name: String
    let runtimeID: String
    let runtime: String
    let typeID: String
    let state: String
    let available: Bool
    var booted: Bool { state == "Booted" }
    var stateTitle: String { ["Booted": "실행 중", "Booting": "부팅 중", "Shutdown": "종료됨", "Shutting Down": "종료 중"][state] ?? state }
    var canStart: Bool { available && ["Booted", "Booting", "Shutdown"].contains(state) }
    func matches(query: String, filter: SimulatorPreparationFilter) -> Bool {
        guard filter != .available || available, filter != .booted || booted else { return false }
        let text = [name, id, runtime, state, stateTitle].joined(separator: " ")
        return query.split(whereSeparator: \.isWhitespace).allSatisfy { text.localizedCaseInsensitiveContains($0) }
    }
}
enum SimulatorPreparationFilter: Int, CaseIterable {
    case all, available, booted
    var title: String { ["전체 기기", "사용 가능한 기기", "실행 중인 기기"][rawValue] }
}
struct SimulatorPreparationInventory {
    let developerDirectory: String
    let devices: [PreparedSimulatorDevice]
    let runtimes: [PreparedSimulatorRuntime]
    let types: [PreparedSimulatorType]
    static let empty = SimulatorPreparationInventory(developerDirectory: "", devices: [], runtimes: [], types: [])
    static func version(_ value: String) -> UInt64 {
        let parts = value.split(separator: ".").prefix(3).map { UInt64($0) ?? 0 }
        return (parts.first ?? 0) << 16 | (parts.count > 1 ? parts[1] : 0) << 8 | (parts.count > 2 ? parts[2] : 0)
    }
    static func decode(_ text: String, developerDirectory: String) throws -> Self {
        guard let data = text.data(using: .utf8), let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rawRuntimes = root["runtimes"] as? [[String: Any]], let rawTypes = root["devicetypes"] as? [[String: Any]],
              let rawDevices = root["devices"] as? [String: [[String: Any]]] else {
            throw SimulatorPreparationError("Xcode의 시뮬레이터 목록을 읽을 수 없습니다.")
        }
        let runtimes = rawRuntimes.compactMap { item -> PreparedSimulatorRuntime? in
            guard let id = item["identifier"] as? String, let name = item["name"] as? String else { return nil }
            let supported = (item["supportedDeviceTypes"] as? [[String: Any]]).map { Set($0.compactMap { $0["identifier"] as? String }) }
            let platform = item["platform"] as? String ?? ["iOS", "watchOS", "tvOS", "visionOS"].first { id.contains(".\($0)-") } ?? ""
            return PreparedSimulatorRuntime(id: id, name: name, available: item["isAvailable"] as? Bool ?? false,
                version: version(item["version"] as? String ?? "0"), supportedTypes: supported,
                platform: platform, build: item["buildversion"] as? String ?? "")
        }.sorted { $0.version == $1.version ? $0.id < $1.id : $0.version > $1.version }
        let types = rawTypes.compactMap { item -> PreparedSimulatorType? in
            guard let id = item["identifier"] as? String, let name = item["name"] as? String else { return nil }
            return PreparedSimulatorType(id: id, name: name, family: item["productFamily"] as? String ?? "",
                minimum: (item["minRuntimeVersion"] as? NSNumber)?.uint64Value ?? 0,
                maximum: (item["maxRuntimeVersion"] as? NSNumber)?.uint64Value ?? UInt64(UInt32.max))
        }
        let devices: [PreparedSimulatorDevice] = rawDevices.flatMap { runtimeID, rows -> [PreparedSimulatorDevice] in
            rows.compactMap { item -> PreparedSimulatorDevice? in
                guard let id = item["udid"] as? String, let name = item["name"] as? String else { return nil }
                let runtime = runtimes.first { $0.id == runtimeID }
                let available = (item["isAvailable"] as? Bool ?? false) && (runtime?.available == true)
                return PreparedSimulatorDevice(id: id, name: name, runtimeID: runtimeID, runtime: runtime?.title ?? runtimeID,
                    typeID: item["deviceTypeIdentifier"] as? String ?? "", state: item["state"] as? String ?? "Unknown", available: available)
            }
        }.sorted { $0.booted == $1.booted ? ($0.name == $1.name ? $0.id < $1.id : $0.name < $1.name) : $0.booted }
        return Self(developerDirectory: developerDirectory, devices: devices, runtimes: runtimes, types: types)
    }
    func compatibleTypes(for runtimeID: String) -> [PreparedSimulatorType] {
        guard let runtime = runtimes.first(where: { $0.id == runtimeID && $0.available }) else { return [] }
        return types.filter { type in
            if let supported = runtime.supportedTypes { return supported.contains(type.id) }
            // Unknown platforms must not fall through to Vision. A specialized runtime without
            // explicit support metadata is ambiguous: do not offer guessed device types.
            let suffix = runtimeID.components(separatedBy: ".SimRuntime.").last ?? ""
            let components = suffix.split(separator: "-").dropFirst()
            guard !components.isEmpty, components.allSatisfy({ UInt($0) != nil }) else { return false }
            let families = ["iOS": ["iPhone", "iPad"], "watchOS": ["Apple Watch"], "tvOS": ["Apple TV"], "visionOS": ["Apple Vision"]]
            let familyMatches = families[runtime.platform]?.contains(type.family) == true
            return familyMatches && type.minimum <= runtime.version && runtime.version <= type.maximum
        }
    }
}

/// Owns only the child commands of one UI operation. It never resets devices or kills another session's processes.
final class SimulatorPreparationTask {
    private let lock = NSLock()
    private var cancelled = false
    private var developerDirectory: String?
    var onOutput: (String) -> Void = { _ in }
    func selectDeveloperDirectory(_ path: String) { lock.withLock { developerDirectory = path } }
    func cancel() { lock.withLock { cancelled = true } }
    var isCancelled: Bool { lock.withLock { cancelled } }
    func checkCancellation() throws {
        if lock.withLock({ cancelled }) { throw SimulatorPreparationError("작업이 취소되었습니다. 이미 생성·설치·실행된 항목은 유지합니다. 목록을 새로고침하세요.", kind: .cancelled) }
    }
    func run(_ executable: String, _ arguments: [String], timeout: TimeInterval = 60, stream: Bool = true) throws -> String {
        try checkCancellation()
        // Only this command's process group receives cancellation. Create it atomically:
        // Process.run + setpgid races with exec and can signal an unrelated group.
        let out = Pipe(), err = Pipe()
        var actions: posix_spawn_file_actions_t?; posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0)
        for (pipe, destination) in [(out, STDOUT_FILENO), (err, STDERR_FILENO)] {
            posix_spawn_file_actions_adddup2(&actions, pipe.fileHandleForWriting.fileDescriptor, destination)
            posix_spawn_file_actions_addclose(&actions, pipe.fileHandleForReading.fileDescriptor)
            posix_spawn_file_actions_addclose(&actions, pipe.fileHandleForWriting.fileDescriptor)
        }
        var attr: posix_spawnattr_t?; posix_spawnattr_init(&attr)
        defer { posix_spawnattr_destroy(&attr) }
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT))
        posix_spawnattr_setpgroup(&attr, 0)
        // Do not pass arbitrary MCP/service credentials to Xcode or its children.
        var env = ProcessInfo.processInfo.environment.filter { ["HOME", "TMPDIR", "USER", "LOGNAME", "LANG", "LC_ALL", "LC_CTYPE"].contains($0.key) }
        env["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin"
        if let path = lock.withLock({ developerDirectory }) { env["DEVELOPER_DIR"] = path }
        let argv = ([executable] + arguments).map { strdup($0) } + [nil]
        let envp = env.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { argv.forEach { free($0) }; envp.forEach { free($0) } }
        var pid: pid_t = 0
        let code = argv.withUnsafeBufferPointer { a in envp.withUnsafeBufferPointer { e in
            posix_spawn(&pid, executable, &actions, &attr, a.baseAddress!, e.baseAddress!)
        } }
        out.fileHandleForWriting.closeFile(); err.fileHandleForWriting.closeFile()
        defer { out.fileHandleForReading.closeFile(); err.fileHandleForReading.closeFile() }
        guard code == 0 else { throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO) }
        for pipe in [out, err] { _ = fcntl(pipe.fileHandleForReading.fileDescriptor, F_SETFL, O_NONBLOCK) }
        let started = ProcessInfo.processInfo.systemUptime
        var stopping: TimeInterval?; var timedOut = false; var status: Int32 = 0
        var stdout = Data(), stderr = Data(), exceeded = false
        var pendingOutput = Data(), lastOutput = started
        var buffer = [UInt8](repeating: 0, count: 16_384)
        func drain(_ pipe: Pipe, into data: inout Data, limit: Int) {
            // Bound each drain so continuously writing children cannot starve cancellation.
            for _ in 0..<16 {
                let count = read(pipe.fileHandleForReading.fileDescriptor, &buffer, buffer.count)
                if count <= 0 { break }
                let chunk = Data(buffer.prefix(count))
                if stream {
                    pendingOutput.append(chunk)
                    if pendingOutput.count > 16_384 { pendingOutput.removeFirst(pendingOutput.count - 16_384) }
                }
                data.append(chunk)
                if data.count > limit { if pipe === out { exceeded = true }; data.removeFirst(data.count - limit) }
            }
        }
        while true {
            drain(out, into: &stdout, limit: stream ? 65_536 : 8_388_608)
            drain(err, into: &stderr, limit: 65_536)
            let now = ProcessInfo.processInfo.systemUptime
            if stream && !pendingOutput.isEmpty && now - lastOutput >= 0.1 {
                onOutput(String(decoding: pendingOutput, as: UTF8.self)); pendingOutput.removeAll(keepingCapacity: true); lastOutput = now
            }
            if stopping == nil && (lock.withLock({ cancelled }) || now - started >= timeout) {
                timedOut = !lock.withLock({ cancelled }); stopping = now
                kill(-pid, SIGTERM)
            }
            // Reap after escalation when stopping, so a descendant that ignores TERM cannot
            // retain the group or pipe and prevent the UI from completing cancellation.
            if let stopping, now - stopping >= 0.5 { kill(-pid, SIGKILL) }
            if stopping == nil || now - stopping! >= 0.5 {
                let waited = waitpid(pid, &status, WNOHANG)
                if waited == pid { break }
                if waited == -1 && errno != EINTR { throw POSIXError(.ECHILD) }
            }
            usleep(20_000)
        }
        drain(out, into: &stdout, limit: stream ? 65_536 : 8_388_608)
        drain(err, into: &stderr, limit: 65_536)
        if stream && !pendingOutput.isEmpty { onOutput(String(decoding: pendingOutput, as: UTF8.self)) }
        try checkCancellation()
        if timedOut { throw SimulatorPreparationError("제한 시간을 초과했습니다. 이미 준비한 항목은 유지합니다. 목록을 새로고침하세요.", kind: .timedOut) }
        let text = String(decoding: stdout, as: UTF8.self)
        guard status == 0 else {
            let errorText = String(String(decoding: stderr, as: UTF8.self).suffix(4000))
            throw SimulatorPreparationError("명령이 완료되지 않았습니다 (종료 상태 \(status)).\n\(errorText)\n\(text.suffix(2000))",
                                            kind: .failed, status: status, standardError: errorText)
        }
        if exceeded && !stream { throw SimulatorPreparationError("목록 응답이 너무 큽니다. Xcode에서 기기 상태를 확인하세요.") }
        return text
    }
}

final class SimulatorPreparationBackend {
    typealias Execute = (String, [String], TimeInterval, Bool) throws -> String
    private let execute: Execute
    private let selectDeveloperDirectory: (String) -> Void
    private let claims: () -> [String: String]
    private var developerDirectory: String?
    init(task: SimulatorPreparationTask, claims: @escaping () -> [String: String]) {
        execute = task.run; selectDeveloperDirectory = task.selectDeveloperDirectory; self.claims = claims
    }
    init(execute: @escaping Execute, selectDeveloperDirectory: @escaping (String) -> Void = { _ in }, claims: @escaping () -> [String: String] = { [:] }) {
        self.execute = execute; self.selectDeveloperDirectory = selectDeveloperDirectory; self.claims = claims
    }
    func inventory() throws -> SimulatorPreparationInventory {
        let path: String
        if let developerDirectory { path = developerDirectory }
        else { path = try execute("/usr/bin/xcode-select", ["-p"], 10, false).trimmingCharacters(in: .whitespacesAndNewlines) }
        guard path.hasSuffix("/Contents/Developer") else { throw SimulatorPreparationError("전체 Xcode가 필요합니다. Xcode를 설치하고 활성 개발자 경로를 선택하세요. mac-cu는 개발자 경로를 임의 변경하지 않습니다.") }
        selectDeveloperDirectory(path)
        developerDirectory = path
        return try .decode(execute("/usr/bin/xcrun", ["simctl", "list", "--json"], 30, false), developerDirectory: path)
    }
    func boot(_ id: String) throws -> SimulatorPreparationInventory {
        guard UUID(uuidString: id) != nil else { throw SimulatorPreparationError("정확한 기기 UDID를 선택하세요.") }
        let before = try inventory()
        guard let device = before.devices.first(where: { $0.id == id }), device.canStart else { throw SimulatorPreparationError("기기가 없거나 런타임을 사용할 수 없습니다. 목록을 새로고침하세요.") }
        guard claims()[id] == nil else { throw SimulatorPreparationError("다른 세션의 사용 기록이 있습니다. 해당 세션에서 확인한 뒤 실행하세요.") }
        if device.state == "Shutdown" {
            _ = try execute("/usr/bin/xcrun", ["simctl", "boot", id], 60, true)
        }
        _ = try execute("/usr/bin/xcrun", ["simctl", "bootstatus", id], 180, true)
        let after = try inventory()
        guard after.devices.first(where: { $0.id == id })?.booted == true else { throw SimulatorPreparationError("실행 명령 후 실제 부팅 상태를 확인하지 못했습니다.") }
        return after
    }
    func create(name: String, typeID: String, runtimeID: String) throws -> (String, SimulatorPreparationInventory) {
        let clean = try Self.deviceName(name)
        let before = try inventory()
        guard before.compatibleTypes(for: runtimeID).contains(where: { $0.id == typeID }) else { throw SimulatorPreparationError("선택한 런타임에서 지원하는 기기 유형을 선택하세요.") }
        let id = try execute("/usr/bin/xcrun", ["simctl", "create", clean, typeID, runtimeID], 60, true).trimmingCharacters(in: .whitespacesAndNewlines)
        guard UUID(uuidString: id) != nil else { throw SimulatorPreparationError("생성한 기기의 UDID를 받지 못했습니다. 목록에서 실제 상태를 확인하세요.") }
        let after = try inventory()
        guard after.devices.contains(where: { $0.id == id && $0.runtimeID == runtimeID && $0.typeID == typeID && $0.name == clean }) else { throw SimulatorPreparationError("생성 명령 후 실제 기기를 확인하지 못했습니다.") }
        return (id, after)
    }
    static func deviceName(_ name: String) throws -> String {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, clean.count <= 80, !clean.hasPrefix("-"), !clean.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else { throw SimulatorPreparationError("기기 이름은 제어 문자 없이 1~80자로 입력하세요. 첫 글자에 -는 사용할 수 없습니다.") }
        return clean
    }
    func installRuntime(platform: String, image: URL? = nil) throws -> SimulatorPreparationInventory {
        guard ["iOS", "watchOS", "tvOS", "visionOS"].contains(platform) else { throw SimulatorPreparationError("지원하는 플랫폼을 선택하세요.") }
        let before = try inventory()
        if let image {
            guard image.isFileURL, image.pathExtension.lowercased() == "dmg",
                  (try? image.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true,
                  FileManager.default.isReadableFile(atPath: image.path) else { throw SimulatorPreparationError("기존 런타임 DMG 파일을 선택하세요.") }
            _ = try execute("/usr/bin/xcodebuild", ["-importPlatform", image.path], 3600, true)
        } else {
            _ = try execute("/usr/bin/xcodebuild", ["-downloadPlatform", platform], 7200, true)
        }
        let after = try inventory()
        if image == nil {
            guard after.runtimes.contains(where: { $0.available && $0.platform == platform }) else { throw SimulatorPreparationError("설치 명령은 끝났지만 선택 플랫폼의 사용 가능한 런타임을 확인하지 못했습니다.") }
        } else {
            // A zero exit alone cannot tell which DMG runtime was imported. Only report an
            // installation when a runtime appeared, changed build or became available.
            let changed = after.runtimes.contains { runtime in
                runtime.available && !before.runtimes.contains { $0.id == runtime.id && $0.build == runtime.build && $0.available }
            }
            guard changed else { throw SimulatorPreparationError("가져오기 명령은 끝났지만 새로 사용 가능해진 런타임은 확인하지 못했습니다. 이미 설치된 이미지일 수 있습니다. 목록을 확인하세요.") }
        }
        return after
    }
}

extension SimulatorPreparationError {
    /// English text for an agent about a failed child command, without the preparation window's Korean guidance.
    /// `prefix` is a line marker the child writes before its own message; it is removed so it is not repeated.
    func agentText(command: String, prefix: String = "") -> String {
        switch kind {
        case .cancelled: return "\(command) was cancelled."
        case .timedOut: return "\(command) timed out."
        case .failed:
            let lines = standardError.split(whereSeparator: \.isNewline).map { line -> String in
                let text = line.trimmingCharacters(in: .whitespaces)
                return !prefix.isEmpty && text.hasPrefix(prefix) ? String(text.dropFirst(prefix.count)) : text
            }.filter { !$0.isEmpty }
            return lines.isEmpty ? "\(command) failed (exit status \(status))." : lines.joined(separator: "\n")
        case .other: return "\(command) failed: \(message)"
        }
    }
}
