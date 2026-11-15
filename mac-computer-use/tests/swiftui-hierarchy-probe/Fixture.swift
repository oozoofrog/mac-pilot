import SwiftUI
import UIKit

// BEGIN RECORDING ENTRY CORE -- extracted verbatim by the headless runner.
import Foundation
import CryptoKit
import Darwin
import MachO

struct RecordingIdentity: Codable, Equatable {
    let deviceID: String
    let bundleID: String
    let executableRealpath: String
    let dataRealpath: String
    let dataUUID: String
    let installationDigest: String
}
struct RecordingTarget: Codable, Equatable {
    let pid: Int
    let startSeconds: UInt64
    let startMicroseconds: UInt64
}
struct RecordingCapsule: Codable, Equatable {
    let version: Int
    let session: String
    let identity: RecordingIdentity
    let oldTarget: RecordingTarget
}
struct RecordingPending: Codable {
    let version: Int
    let restartID: String
    let session: String
    let oldTarget: RecordingTarget
    let identity: RecordingIdentity
    let issuedUnixSeconds: Double
    let expiresUnixSeconds: Double
    let issuedUptime: Double
    let expiresUptime: Double
}
struct RecordingArm: Codable {
    let version: Int
    let action: String
    let restartID: String
    let session: String
    let pid: Int
    let issuedUnixSeconds: Double
    let remainingSeconds: Double
    let identity: RecordingIdentity
    let oldTarget: RecordingTarget
}
struct RecordingCancel: Codable {
    let version: Int
    let action: String
    let restartID: String
    let session: String
    let pid: Int
    let issuedUnixSeconds: Double
    let pendingSHA256: String
}
struct RecordingStartup {
    let capsule: RecordingCapsule
    let mode: String
    let restartID: String?
    var fields: [String: Any] {
        ["startupMode": mode, "restartID": restartID as Any? ?? NSNull(),
         "oldTarget": ["pid": capsule.oldTarget.pid, "startSeconds": capsule.oldTarget.startSeconds,
                       "startMicroseconds": capsule.oldTarget.startMicroseconds], "currentPID": getpid()]
    }
}
enum RecordingFailure: Error { case refused(String) }
func recordingRequire(_ condition: @autoclosure () -> Bool, _ reason: String) throws {
    if !condition() { throw RecordingFailure.refused(reason) }
}
func recordingHash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
func recordingEncode<T: Encodable>(_ value: T) throws -> Data {
    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
    return try encoder.encode(value)
}
func recordingDecode<T: Codable>(_ type: T.Type, _ bytes: Data) throws -> T {
    try recordingRequire(bytes.count <= 8192, "oversize schema")
    let value = try JSONDecoder().decode(type, from: bytes)
    // Roundtrip equality rejects unknown members, wrong scalar types and non-finite numbers.
    let original = try JSONSerialization.jsonObject(with: bytes) as? NSDictionary
    let canonical = try JSONSerialization.jsonObject(with: recordingEncode(value)) as? NSDictionary
    try recordingRequire(original != nil && original == canonical, "closed schema")
    return value
}
final class RecordingStore {
    private let fd: Int32
    init(data: String, create: Bool) throws {
        let root = open(data, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        try recordingRequire(root >= 0, "data directory")
        defer { close(root) }
        var rootStat = stat()
        try recordingRequire(fstat(root, &rootStat) == 0 && rootStat.st_uid == getuid(), "data owner")
        if create {
            try recordingRequire(mkdirat(root, ".recording-entry-v1", 0o700) == 0, "exclusive bootstrap directory")
            try recordingRequire(fsync(root) == 0, "persist data directory")
        }
        fd = openat(root, ".recording-entry-v1", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        try recordingRequire(fd >= 0, "private directory")
        var s = stat()
        if fstat(fd, &s) != 0 || s.st_uid != getuid() || s.st_mode & 0o777 != 0o700 {
            close(fd); throw RecordingFailure.refused("private directory mode/owner")
        }
    }
    deinit { close(fd) }
    func read(_ name: String) throws -> Data {
        let file = openat(fd, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        try recordingRequire(file >= 0, "missing/nofollow \(name)")
        defer { close(file) }
        var s = stat()
        try recordingRequire(fstat(file, &s) == 0 && s.st_mode & S_IFMT == S_IFREG &&
            s.st_mode & 0o777 == 0o600 && s.st_uid == getuid() && s.st_nlink == 1 &&
            s.st_size > 0 && s.st_size <= 8192, "bounded private file")
        var bytes = Data(count: Int(s.st_size))
        let count = bytes.withUnsafeMutableBytes { Darwin.read(file, $0.baseAddress, $0.count) }
        var after = stat()
        try recordingRequire(count == bytes.count && fstat(file, &after) == 0 &&
            s.st_ino == after.st_ino && s.st_size == after.st_size &&
            s.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec && s.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
            "file changed")
        return bytes
    }
    func exists(_ name: String) -> Bool {
        var s = stat()
        return fstatat(fd, name, &s, AT_SYMLINK_NOFOLLOW) == 0 || errno != ENOENT
    }
    func write(_ name: String, _ bytes: Data) throws {
        try recordingRequire(bytes.count > 0 && bytes.count <= 8192, "write bounds")
        let file = openat(fd, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        try recordingRequire(file >= 0, "exclusive \(name)")
        defer { close(file) }
        let count = bytes.withUnsafeBytes { Darwin.write(file, $0.baseAddress, $0.count) }
        try recordingRequire(count == bytes.count && fsync(file) == 0 && fsync(fd) == 0, "persist \(name)")
    }
    func burn() throws {
        // O_EXCL is the shared arbitration point for consume and cancellation. Never removed.
        try write("restart.spent", Data("spent-v1".utf8))
    }
    func consume() throws -> Data {
        try burn()
        let before = try read("restart.pending.json")
        var beforeStat = stat()
        try recordingRequire(fstatat(fd, "restart.pending.json", &beforeStat, AT_SYMLINK_NOFOLLOW) == 0, "pending inode")
        try recordingRequire(renameatx_np(fd, "restart.pending.json", fd, "restart.consumed.json", UInt32(RENAME_EXCL)) == 0,
                             "exclusive consume")
        try recordingRequire(fsync(fd) == 0, "persist consume")
        let after = try read("restart.consumed.json")
        var afterStat = stat()
        try recordingRequire(fstatat(fd, "restart.consumed.json", &afterStat, AT_SYMLINK_NOFOLLOW) == 0 &&
            beforeStat.st_dev == afterStat.st_dev && beforeStat.st_ino == afterStat.st_ino && before == after,
            "consume inode/bytes changed")
        return after
    }
}
struct RecordingEntry {
    let identity: RecordingIdentity
    let target: RecordingTarget
    let wall: Double
    let uptime: Double
    func validateClock() throws {
        try recordingRequire(wall.isFinite && wall > 0 && uptime.isFinite && uptime > 0, "clock unavailable")
    }
    func enter(arguments: [String], environment: [String: String]) throws -> RecordingStartup {
        try recordingRequire(environment["MAC_CU_FIXTURE_CHILD"] == nil && environment["MAC_CU_NATIVE_CHECK_CHILD"] == nil,
                             "inherited entry")
        try validateClock()
        if arguments.count == 2 && arguments[0] == "--fixture-session",
           let session = environment["MAC_CU_FIXTURE_SESSION"], arguments[1] == session {
            try recordingRequire(!session.isEmpty && session.utf8.count <= 256, "session bounds")
            let store = try RecordingStore(data: identity.dataRealpath, create: true)
            let capsule = RecordingCapsule(version: 1, session: session, identity: identity, oldTarget: target)
            try store.write("bootstrap.json", recordingEncode(capsule))
            return RecordingStartup(capsule: capsule, mode: "initial", restartID: nil)
        }
        try recordingRequire(arguments.isEmpty && environment["MAC_CU_FIXTURE_SESSION"] == nil &&
            environment["SWIFTUI_VIEW_DEBUG"] == "287", "restart entry shape")
        let store = try RecordingStore(data: identity.dataRealpath, create: false)
        // Once the restart entry shape and directory are admitted, every attempt is permanently burned.
        let bytes = try store.consume()
        let capsule = try recordingDecode(RecordingCapsule.self, store.read("bootstrap.json"))
        let pending = try recordingDecode(RecordingPending.self, bytes)
        try recordingRequire(capsule.version == 1 && pending.version == 1 && capsule.identity == identity &&
            pending.identity == identity && capsule.session == pending.session && capsule.oldTarget == pending.oldTarget &&
            target != pending.oldTarget && UUID(uuidString: pending.restartID) != nil &&
            !capsule.session.isEmpty && capsule.session.utf8.count <= 256, "restart binding")
        let claim = try store.read("arm.claim")
        try recordingRequire(claim == Data(pending.restartID.utf8), "arm claim binding")
        let duration = pending.expiresUptime - pending.issuedUptime
        try recordingRequire(duration.isFinite && duration > 0 && duration <= 60 &&
            abs((pending.expiresUnixSeconds - pending.issuedUnixSeconds) - duration) < 0.001 &&
            wall >= pending.issuedUnixSeconds && wall < pending.expiresUnixSeconds &&
            uptime >= pending.issuedUptime && uptime < pending.expiresUptime &&
            abs((wall - pending.issuedUnixSeconds) - (uptime - pending.issuedUptime)) <= 2, "restart expiry/clock continuity")
        return RecordingStartup(capsule: capsule, mode: "recordingRestart", restartID: pending.restartID)
    }
    func arm(_ bytes: Data, startup: RecordingStartup) throws -> [String: Any] {
        try validateClock()
        let q = try recordingDecode(RecordingArm.self, bytes)
        try recordingRequire(startup.mode == "initial" && q.version == 1 && q.action == "armRestart" &&
            q.session == startup.capsule.session && q.pid == target.pid && q.oldTarget == target &&
            q.identity == identity && UUID(uuidString: q.restartID) != nil, "arm binding")
        let age = wall - q.issuedUnixSeconds
        try recordingRequire(age >= 0 && age < 5 && q.remainingSeconds.isFinite && q.remainingSeconds > age &&
            q.remainingSeconds <= 60, "arm freshness/duration")
        let store = try RecordingStore(data: identity.dataRealpath, create: false)
        let storedCapsule = try recordingDecode(RecordingCapsule.self, store.read("bootstrap.json"))
        try recordingRequire(!store.exists("restart.spent") && !store.exists("arm.claim") &&
            storedCapsule == startup.capsule, "arm capsule")
        // A crash after this durable claim refuses all future arms, including incomplete writes.
        try store.write("arm.claim", Data(q.restartID.utf8))
        let duration = q.remainingSeconds - age
        let record = RecordingPending(version: 1, restartID: q.restartID, session: q.session, oldTarget: target,
            identity: identity, issuedUnixSeconds: wall, expiresUnixSeconds: wall + duration,
            issuedUptime: uptime, expiresUptime: uptime + duration)
        let recordBytes = try recordingEncode(record)
        try store.write("restart.pending.json", recordBytes)
        return ["version": 1, "status": "armed", "restartID": q.restartID,
                "pendingSHA256": recordingHash(recordBytes), "pending": try JSONSerialization.jsonObject(with: recordBytes)]
    }
    func cancel(_ bytes: Data, startup: RecordingStartup) throws -> [String: Any] {
        let q = try recordingDecode(RecordingCancel.self, bytes)
        try recordingRequire(startup.mode == "initial" && q.version == 1 && q.action == "cancelRestart" &&
            q.session == startup.capsule.session && q.pid == target.pid && wall >= q.issuedUnixSeconds &&
            wall - q.issuedUnixSeconds < 5, "cancel binding")
        let store = try RecordingStore(data: identity.dataRealpath, create: false)
        let pending = try store.read("restart.pending.json")
        let record = try recordingDecode(RecordingPending.self, pending)
        try recordingRequire(record.restartID == q.restartID && recordingHash(pending) == q.pendingSHA256 &&
            record.session == q.session && record.oldTarget == target && record.identity == identity, "cancel exact pending")
        try store.burn()
        return ["version": 1, "status": "cancelled", "restartID": q.restartID, "pendingSHA256": q.pendingSHA256]
    }
    static func digest(_ path: String, limit: Int64) throws -> String {
            let fd = open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
            try recordingRequire(fd >= 0, "installation file")
            defer { close(fd) }
            var s = stat()
            try recordingRequire(fstat(fd, &s) == 0 && s.st_mode & S_IFMT == S_IFREG && s.st_uid == getuid() &&
                s.st_size > 0 && s.st_size <= limit, "installation bounds")
            let file = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
            let bytes = try file.read(upToCount: Int(limit) + 1) ?? Data()
            var after = stat()
            try recordingRequire(bytes.count == s.st_size && fstat(fd, &after) == 0 &&
                s.st_size == after.st_size && s.st_ino == after.st_ino &&
                s.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec && s.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
                "installation changed/read")
            return recordingHash(bytes)
        }
    static func controlBytes(_ path: String) throws -> Data {
        let fd = open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        try recordingRequire(fd >= 0, "control open")
        defer { close(fd) }
        var s = stat()
        try recordingRequire(fstat(fd, &s) == 0 && s.st_uid == getuid() && s.st_mode & S_IFMT == S_IFREG &&
            s.st_mode & 0o777 == 0o600 && s.st_nlink == 1 && s.st_size > 0 && s.st_size <= 8192, "control bounds/mode")
        let bytes = try FileHandle(fileDescriptor: fd, closeOnDealloc: false).read(upToCount: 8193) ?? Data()
        try recordingRequire(bytes.count == s.st_size, "control changed")
        return bytes
    }
    static func native() throws -> RecordingEntry {
        var size: UInt32 = 0
        _ = _NSGetExecutablePath(nil, &size)
        var buffer = [CChar](repeating: 0, count: Int(size))
        try recordingRequire(_NSGetExecutablePath(&buffer, &size) == 0, "native executable")
        let executable = URL(fileURLWithPath: String(cString: buffer)).resolvingSymlinksInPath().path
        let app = Bundle.main.bundleURL.resolvingSymlinksInPath().path
        let data = URL(fileURLWithPath: NSHomeDirectory()).resolvingSymlinksInPath().path
        try recordingRequire(executable == app + "/" + (Bundle.main.object(forInfoDictionaryKey: "CFBundleExecutable") as? String ?? ""), "bundle executable")
        let executableHash = try digest(executable, limit: 128 * 1024 * 1024)
        let plistHash = try digest(app + "/Info.plist", limit: 1024 * 1024)
        var info = kinfo_proc()
        var length = MemoryLayout<kinfo_proc>.size
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        try recordingRequire(sysctl(&mib, 4, &info, &length, nil, 0) == 0 && length == MemoryLayout<kinfo_proc>.size,
                             "native self lifetime")
        let start = info.kp_proc.p_starttime
        try recordingRequire(start.tv_sec > 0 && start.tv_usec >= 0 && start.tv_usec < 1_000_000, "native start time")
        guard let device = ProcessInfo.processInfo.environment["SIMULATOR_UDID"], UUID(uuidString: device) != nil,
              let bundle = Bundle.main.bundleIdentifier, UUID(uuidString: URL(fileURLWithPath: data).lastPathComponent) != nil else {
            throw RecordingFailure.refused("guest device/container identity")
        }
        return RecordingEntry(identity: RecordingIdentity(deviceID: device, bundleID: bundle,
            executableRealpath: executable, dataRealpath: data, dataUUID: URL(fileURLWithPath: data).lastPathComponent,
            installationDigest: recordingHash(Data((executableHash + ":" + plistHash).utf8))),
            target: RecordingTarget(pid: Int(getpid()), startSeconds: UInt64(start.tv_sec), startMicroseconds: UInt64(start.tv_usec)),
            wall: Date().timeIntervalSince1970, uptime: ProcessInfo.processInfo.systemUptime)
    }
}
// END RECORDING ENTRY CORE

@MainActor
enum ProbeTrace {
    private static var count = 0
    static func record(_ event: String, fields: [String: Any] = [:]) {
        guard count < 64 else { return }
        count += 1
        var value = fields
        value.merge(["event": event, "pid": getpid(), "unixSeconds": Date().timeIntervalSince1970,
            "flag": ProcessInfo.processInfo.environment["SWIFTUI_VIEW_DEBUG"] as Any? ?? NSNull()]) { _, b in b }
        guard let bytes = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]), bytes.count < 4096 else { return }
        let path = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("fixture-lifecycle.log")
        if !FileManager.default.fileExists(atPath: path.path) { FileManager.default.createFile(atPath: path.path, contents: nil) }
        if let file = try? FileHandle(forWritingTo: path) {
            defer { try? file.close() }
            _ = try? file.seekToEnd(); try? file.write(contentsOf: bytes + Data([10]))
        }
    }
}

@main
struct SwiftUIProbeApp: App {
    @StateObject private var state: ProbeState
    init() {
        let startup: RecordingStartup
        do {
            // Reject inherited entry before native identity reads or observable fixture state.
            guard getenv("MAC_CU_FIXTURE_CHILD") == nil, getenv("MAC_CU_NATIVE_CHECK_CHILD") == nil else { exit(64) }
            startup = try RecordingEntry.native().enter(arguments: Array(CommandLine.arguments.dropFirst()),
                environment: ProcessInfo.processInfo.environment)
        } catch { exit(64) }
        setenv("MAC_CU_FIXTURE_CHILD", "1", 1)
        _state = StateObject(wrappedValue: ProbeState(startup: startup))
        ProbeTrace.record("App.init", fields: startup.fields)
        DispatchQueue.main.async { ProbeTrace.record("first-main-queue-callback") }
    }
    var body: some Scene {
        WindowGroup { ProbeContent(state: state).preferredColorScheme(.light) }
    }
}

struct ProbeRects: PreferenceKey {
    static let defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, b in b })
    }
}

extension View {
    func measure(_ name: String) -> some View {
        background(GeometryReader { geometry in
            Color.clear.preference(key: ProbeRects.self, value: [name: geometry.frame(in: .global)])
        })
    }
}

struct ProbeContent: View {
    @ObservedObject var state: ProbeState
    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            Text("ALPHA SWIFTUI 731").font(.system(size: 24, weight: .bold))
                .foregroundStyle(Color(red: 0.1, green: 0.2, blue: 0.7)).measure("title")
            HStack(spacing: 24) {
                Rectangle().fill(Color(red: 0.85, green: 0.15, blue: 0.2))
                    .frame(width: 120, height: 72).measure("rectangle")
                Circle().fill(Color(red: 0.1, green: 0.65, blue: 0.3))
                    .frame(width: 72, height: 72).opacity(0.65).measure("circle")
            }
            Text("BRAVO DECLARATIVE 482").font(.system(size: 18, weight: .medium))
                .foregroundStyle(Color.black).padding(12)
                .overlay(Rectangle().stroke(Color.blue, lineWidth: 2)).measure("subtitle")
            if state.alternate {
                HStack { Text("DELTA BRANCH 914"); Circle().fill(Color.purple).frame(width: 24, height: 24) }
                    .font(.system(size: 20)).measure("branch")
            } else {
                Text("CHARLIE BRANCH 263").font(.system(size: 20)).measure("branch")
            }
            ProbeUIKit().frame(width: 280, height: 48).measure("representable")
            Spacer(minLength: 0)
        }
        .frame(width: 320, height: 470, alignment: .topLeading).padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color.white)
        .onPreferenceChange(ProbeRects.self) { state.rects = $0; ProbeTrace.record("rects", fields: ["count": $0.count]) }
        .onAppear { state.start() }
    }
}

@MainActor final class ProductWitness: UILabel {
    static weak var current: ProductWitness?
    var hiddenSets = 0, alphaSets = 0
    let nodeGeneration = UUID().uuidString
    override var isHidden: Bool { didSet { hiddenSets += 1 } }
    override var alpha: CGFloat { didSet { alphaSets += 1 } }
    override init(frame: CGRect) { super.init(frame: frame); Self.current = self }
    required init?(coder: NSCoder) { fatalError("unused") }
}

struct ProbeUIKit: UIViewRepresentable {
    func makeUIView(context: Context) -> UILabel {
        let label = ProductWitness(); label.text = "UIKit witness 596"
        label.textColor = .black; label.backgroundColor = UIColor(red: 0.9, green: 0.8, blue: 0.2, alpha: 1)
        label.accessibilityIdentifier = "swiftui.probe.witness"
        return label
    }
    func updateUIView(_ view: UILabel, context: Context) {}
}

@MainActor
final class ProbeState: ObservableObject {
    @Published var alternate = false
    var rects: [String: CGRect] = [:]
    private var timer: Timer?
    private var sequence = 0
    private var controls = 0
    private var receipt: [String: Any] = [:]
    private let started = ProcessInfo.processInfo.systemUptime
    private let generation = UUID().uuidString
    private let session: String
    private var documents: URL { FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0] }
    private let startup: RecordingStartup
    private var restartReceipt: [String: Any] = [:]
    private var restartControlSeen = false
    init(startup: RecordingStartup) {
        self.startup = startup; self.session = startup.capsule.session
        ProbeTrace.record("ProbeState.init", fields: startup.fields)
    }
    private func restartControl() {
        guard let bytes = try? RecordingEntry.controlBytes(documents.appendingPathComponent("restart-control.json").path),
              bytes.count <= 8192,
              let q = (try? JSONSerialization.jsonObject(with: bytes)) as? [String: Any],
              let action = q["action"] as? String,
              action == "armRestart" || action == "cancelRestart" else { return }
        if action == "armRestart" && restartControlSeen { return }
        do {
            let entry = try RecordingEntry.native()
            let result = try action == "armRestart" ? entry.arm(bytes, startup: startup) : entry.cancel(bytes, startup: startup)
            restartControlSeen = true; restartReceipt = result
            ProbeTrace.record("restartControl", fields: result)
        } catch {
            restartControlSeen = true
            if restartReceipt.isEmpty { restartReceipt = ["version": 1, "status": "refused"] }
        }
    }

    func start() {
        guard timer == nil else { return }
        ProbeTrace.record("onAppear.timer-start")
        timer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }
    private func tick() {
        if sequence < 3 { ProbeTrace.record("timer.tick", fields: ["rectCount": rects.count, "sceneCount": UIApplication.shared.connectedScenes.count]) }
        // Finite ordinary fixture control. No graph/debug API runs in this app.
        if ProcessInfo.processInfo.systemUptime - started > 600 { timer?.invalidate(); timer = nil; return }
        guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive }), !rects.isEmpty else { return }
        let control = documents.appendingPathComponent("branch-control.json")
        if controls == 0, let bytes = try? Data(contentsOf: control), bytes.count <= 4096,
           let q = (try? JSONSerialization.jsonObject(with: bytes)) as? [String: Any],
           q["session"] as? String == session,
           q["pid"] as? Int == Int(getpid()), q["action"] as? String == "alternate",
           let id = q["requestID"] as? String,
           let issued = q["issuedUnixSeconds"] as? Double, abs(Date().timeIntervalSince1970 - issued) < 5 {
            controls += 1; alternate = true
            receipt = ["requestID": id, "status": "applied", "unixSeconds": Date().timeIntervalSince1970]
        }
        restartControl()
        sequence += 1
        var value: [String: Any] = ["pid": getpid(), "sequence": sequence, "generation": generation,
            "sceneID": scene.session.persistentIdentifier, "branch": alternate ? "delta" : "charlie",
            "unixSeconds": Date().timeIntervalSince1970, "scale": scene.screen.scale,
            "orientation": scene.interfaceOrientation.rawValue, "graphOracleCalls": 0,
            "graphDebugLaunchFlag": ProcessInfo.processInfo.environment["SWIFTUI_VIEW_DEBUG"] as Any? ?? NSNull(),
            "samples": ProductWitness.current.map { [["sequence": sequence, "unixSeconds": Date().timeIntervalSince1970,
                "nodeGeneration": $0.nodeGeneration, "hidden": $0.isHidden, "alpha": Double($0.alpha),
                "setterCounts": ["hidden": $0.hiddenSets, "alpha": $0.alphaSets]]] } ?? [],
            "controlReceipt": receipt, "rois": rects.mapValues { [$0.minX, $0.minY, $0.width, $0.height] }]
        value.merge(startup.fields) { _, b in b }; value["restartReceipt"] = restartReceipt
        if let bytes = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) {
            try? bytes.write(to: documents.appendingPathComponent("edit-oracle.json"), options: .atomic)
            try? bytes.write(to: documents.appendingPathComponent("geometry-oracle.json"), options: .atomic)
        }
    }
}
