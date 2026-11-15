// This executable contains the verbatim Foundation core extracted from Fixture.swift.
import Foundation
import Darwin

let args = Array(CommandLine.arguments.dropFirst())
guard args == ["--native-check"], getenv("MAC_CU_NATIVE_CHECK_CHILD") == nil,
      getenv("MAC_CU_FIXTURE_CHILD") == nil else { exit(64) }
setenv("MAC_CU_NATIVE_CHECK_CHILD", "1", 1)
let base = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().appendingPathComponent("containers")
try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
var passed = 0
func check(_ condition: Bool, _ message: String) throws {
    if !condition { throw RecordingFailure.refused("TEST FAILED: " + message) }
}
func rejects(_ label: String, _ body: () throws -> Void) throws {
    var refused = false
    do { try body() } catch { refused = true; print("EXPECTED REFUSAL \(label): \(error)") }
    try check(refused, label)
}
func test(_ label: String, _ body: () throws -> Void) throws {
    try body(); passed += 1; print("PASS \(label)")
}
struct Scenario {
    let root: URL
    let id: RecordingIdentity
    let initial: RecordingEntry
    let startup: RecordingStartup
    var directory: URL { root.appendingPathComponent(".recording-entry-v1") }
    init() throws {
        root = base.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let executable = root.appendingPathComponent("Fixture")
        let plist = root.appendingPathComponent("Info.plist")
        try Data("fixture executable".utf8).write(to: executable)
        try Data("fixture plist".utf8).write(to: plist)
        let digest = recordingHash(Data((try RecordingEntry.digest(executable.path, limit: 1024) + ":" + RecordingEntry.digest(plist.path, limit: 1024)).utf8))
        id = RecordingIdentity(deviceID: "device-A", bundleID: "fixture.bundle", executableRealpath: executable.path,
            dataRealpath: root.path, dataUUID: root.lastPathComponent, installationDigest: digest)
        initial = RecordingEntry(identity: id, target: RecordingTarget(pid: 100, startSeconds: 90, startMicroseconds: 1), wall: 1000, uptime: 100)
        startup = try initial.enter(arguments: ["--fixture-session", "session-A"], environment: ["MAC_CU_FIXTURE_SESSION": "session-A"])
    }
    func next(wall: Double = 1002, uptime: Double = 102, identity: RecordingIdentity? = nil) -> RecordingEntry {
        RecordingEntry(identity: identity ?? id, target: RecordingTarget(pid: 101, startSeconds: 101, startMicroseconds: 1), wall: wall, uptime: uptime)
    }
    func arm(remaining: Double = 30, issued: Double = 999) throws -> [String: Any] {
        try initial.arm(recordingEncode(RecordingArm(version: 1, action: "armRestart", restartID: UUID().uuidString,
            session: "session-A", pid: 100, issuedUnixSeconds: issued, remainingSeconds: remaining,
            identity: id, oldTarget: initial.target)), startup: startup)
    }
    func mutate(_ name: String = "restart.pending.json", _ body: (inout [String: Any]) -> Void) throws {
        let url = directory.appendingPathComponent(name)
        var object = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
        body(&object)
        try JSONSerialization.data(withJSONObject: object, options: .sortedKeys).write(to: url)
    }
    func restart(_ entry: RecordingEntry? = nil, args: [String] = [], env: [String: String] = ["SWIFTUI_VIEW_DEBUG": "287"]) throws -> RecordingStartup {
        try (entry ?? next()).enter(arguments: args, environment: env)
    }
    func spent() -> Bool { FileManager.default.fileExists(atPath: directory.appendingPathComponent("restart.spent").path) }
}
do {
    try test("initial, immutable session, closed capsule, exclusive reentry") {
        let s = try Scenario(); try check(s.startup.mode == "initial" && s.startup.capsule.session == "session-A", "initial")
        try rejects("initial reentry") { _ = try s.initial.enter(arguments: ["--fixture-session", "session-A"], environment: ["MAC_CU_FIXTURE_SESSION": "session-A"]) }
    }
    try test("argv-free restart exactly once and receipt hash") {
        let s = try Scenario(); let receipt = try s.arm()
        let bytes = try Data(contentsOf: s.directory.appendingPathComponent("restart.pending.json"))
        try check(receipt["pendingSHA256"] as? String == recordingHash(bytes), "receipt digest")
        let startup = try s.restart()
        try check(startup.mode == "recordingRestart" && startup.restartID == receipt["restartID"] as? String && s.spent(), "success")
        try rejects("replay") { _ = try s.restart() }
        try rejects("rearm") { _ = try s.arm() }
    }
    let environments: [[String: String]] = [[:], ["SWIFTUI_VIEW_DEBUG":"28"], ["SWIFTUI_VIEW_DEBUG":"287", "MAC_CU_FIXTURE_SESSION":"session-A"], ["SWIFTUI_VIEW_DEBUG":"287", "MAC_CU_FIXTURE_CHILD":""], ["SWIFTUI_VIEW_DEBUG":"287", "MAC_CU_NATIVE_CHECK_CHILD":"1"]]
    for (index, env) in environments.enumerated() {
        try test("entry environment refusal \(index), before consumption") {
            let s = try Scenario(); _ = try s.arm()
            try rejects("environment") { _ = try s.restart(env: env) }; try check(!s.spent(), "precondition retained")
        }
    }
    for args in [["--fixture-session"], ["--unknown"], ["--fixture-session", "session-A"]] {
        try test("partial/mixed arguments \(args)") {
            let s = try Scenario(); _ = try s.arm(); try rejects("arguments") { _ = try s.restart(args: args) }
            try check(!s.spent(), "entry shape before burn")
        }
    }
    for field in ["session", "version", "restartID", "oldTarget", "unexpected"] {
        try test("pending closed schema/binding \(field), burned") {
            let s = try Scenario(); _ = try s.arm()
            try s.mutate { $0[field] = field == "version" ? 2 : "foreign" }
            try rejects(field) { _ = try s.restart() }; try check(s.spent(), "invalid consumed remains burned")
        }
    }
    for field in ["deviceID", "bundleID", "executableRealpath", "dataRealpath", "dataUUID", "installationDigest"] {
        try test("identity mismatch \(field)") {
            let s = try Scenario(); _ = try s.arm()
            try s.mutate { var id = $0["identity"] as! [String: Any]; id[field] = "foreign"; $0["identity"] = id }
            try rejects(field) { _ = try s.restart() }; try check(s.spent(), "foreign burned")
        }
    }
    for (wall, uptime) in [(1030.0,130.0), (999,102), (1002,99), (1002,110), (1010,102), (Double.nan,102)] {
        try test("expiry/wall/uptime \(wall)/\(uptime)") {
            let s = try Scenario(); _ = try s.arm(); try rejects("clock") { _ = try s.restart(s.next(wall: wall, uptime: uptime)) }
        }
    }
    for field in ["issuedUnixSeconds", "expiresUnixSeconds", "issuedUptime", "expiresUptime"] {
        try test("malformed timing \(field)") {
            let s = try Scenario(); _ = try s.arm(); try s.mutate { $0[field] = -1 }
            try rejects(field) { _ = try s.restart() }
        }
    }
    for remaining in [-1.0, 0, 1, 61, Double.infinity] {
        try test("arm duration \(remaining)") { let s = try Scenario(); try rejects("duration") { _ = try s.arm(remaining: remaining) } }
    }
    for issued in [1001.0, 994.0] {
        try test("arm timestamp \(issued)") { let s = try Scenario(); try rejects("freshness") { _ = try s.arm(issued: issued) } }
    }
    for file in ["bootstrap.json", "restart.pending.json"] {
        try test("symlink \(file)") {
            let s = try Scenario(); _ = try s.arm(); let url = s.directory.appendingPathComponent(file)
            try FileManager.default.removeItem(at: url); try FileManager.default.createSymbolicLink(at: url, withDestinationURL: s.root.appendingPathComponent("Info.plist"))
            try rejects("symlink") { _ = try s.restart() }; try check(s.spent(), "symlink burned")
        }
    }
    try test("directory symlink and unsafe mode") {
        let s = try Scenario(); _ = try s.arm()
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: s.directory.path)
        try rejects("directory mode") { _ = try s.restart() }
        let other = s.root.appendingPathComponent("moved")
        try FileManager.default.moveItem(at: s.directory, to: other)
        try FileManager.default.createSymbolicLink(at: s.directory, withDestinationURL: other)
        try rejects("directory symlink") { _ = try s.restart() }
    }
    for content in [Data(repeating: 65, count: 8193), Data("{".utf8)] {
        try test("oversize/malformed pending \(content.count)") {
            let s = try Scenario(); _ = try s.arm(); try content.write(to: s.directory.appendingPathComponent("restart.pending.json"))
            try rejects("pending") { _ = try s.restart() }; try check(s.spent(), "malformed burned")
        }
    }
    try test("unsafe file mode and hardlink") {
        let s = try Scenario(); _ = try s.arm(); let url = s.directory.appendingPathComponent("bootstrap.json")
        try FileManager.default.linkItem(at: url, to: s.root.appendingPathComponent("link"))
        try rejects("hardlink") { _ = try s.restart() }
        let t = try Scenario(); _ = try t.arm(); try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: t.directory.appendingPathComponent("bootstrap.json").path)
        try rejects("file mode") { _ = try t.restart() }
    }
    try test("deterministic competing claim/crash after burn") {
        let s = try Scenario(); _ = try s.arm(); let store = try RecordingStore(data: s.root.path, create: false)
        try store.burn(); try rejects("competing consume") { _ = try s.restart() }
        try check(FileManager.default.fileExists(atPath: s.directory.appendingPathComponent("restart.pending.json").path), "pending evidence retained")
    }
    try test("crash after rename and invalid consume never restored") {
        let s = try Scenario(); _ = try s.arm(); let store = try RecordingStore(data: s.root.path, create: false)
        _ = try store.consume(); try rejects("post rename crash") { _ = try s.restart() }
        try check(!FileManager.default.fileExists(atPath: s.directory.appendingPathComponent("restart.pending.json").path), "no restoration")
    }
    try test("consume destination collision burns") {
        let s = try Scenario(); _ = try s.arm(); let store = try RecordingStore(data: s.root.path, create: false)
        try store.write("restart.consumed.json", Data("collision".utf8)); try rejects("rename collision") { _ = try s.restart() }
        try check(s.spent(), "collision burned")
    }
    try test("crash after arm claim refuses rearm") {
        let s = try Scenario(); let store = try RecordingStore(data: s.root.path, create: false)
        try store.write("arm.claim", Data("interrupted".utf8)); try rejects("rearm") { _ = try s.arm() }
    }
    try test("cancel exact pending hash, durable no rearm/restart") {
        let s = try Scenario(); let receipt = try s.arm()
        func cancel(_ hash: String) throws -> [String: Any] {
            try s.initial.cancel(recordingEncode(RecordingCancel(version: 1, action: "cancelRestart", restartID: receipt["restartID"] as! String,
                session: "session-A", pid: 100, issuedUnixSeconds: 1000, pendingSHA256: hash)), startup: s.startup)
        }
        try rejects("wrong cancellation hash") { _ = try cancel("wrong") }; try check(!s.spent(), "exact cancellation only")
        _ = try cancel(receipt["pendingSHA256"] as! String)
        try rejects("cancelled restart") { _ = try s.restart() }; try rejects("cancelled rearm") { _ = try s.arm() }
    }
    try test("actual installation digest changes and nofollow bounds") {
        let s = try Scenario(); let exe = s.root.appendingPathComponent("Fixture")
        let before = try RecordingEntry.digest(exe.path, limit: 1024)
        try Data("replaced".utf8).write(to: exe)
        let after = try RecordingEntry.digest(exe.path, limit: 1024); try check(before != after, "digest pin changes")
        try rejects("file bound") { _ = try RecordingEntry.digest(exe.path, limit: 1) }
        try FileManager.default.removeItem(at: exe); try FileManager.default.createSymbolicLink(at: exe, withDestinationURL: s.root.appendingPathComponent("Info.plist"))
        try rejects("install symlink") { _ = try RecordingEntry.digest(exe.path, limit: 1024) }
    }
    for field in ["session", "pid", "identity", "oldTarget", "version", "action", "restartID", "unknown"] {
        try test("arm rejects malformed/binding \(field) before claim") {
            let s = try Scenario()
            let q = RecordingArm(version: 1, action: "armRestart", restartID: UUID().uuidString,
                session: "session-A", pid: 100, issuedUnixSeconds: 1000, remainingSeconds: 30, identity: s.id, oldTarget: s.initial.target)
            var object = try JSONSerialization.jsonObject(with: recordingEncode(q)) as! [String: Any]
            object[field] = "wrong"
            try rejects(field) { _ = try s.initial.arm(JSONSerialization.data(withJSONObject: object), startup: s.startup) }
            try check(!FileManager.default.fileExists(atPath: s.directory.appendingPathComponent("arm.claim").path), "no premature claim")
        }
    }
    try test("arm claim mismatch burns restart") {
        let s = try Scenario(); _ = try s.arm()
        try Data("wrong".utf8).write(to: s.directory.appendingPathComponent("arm.claim"))
        try rejects("claim mismatch") { _ = try s.restart() }; try check(s.spent(), "claim mismatch burned")
    }
    try test("bounded private control reader") {
        let s = try Scenario(); let path = s.root.appendingPathComponent("control.json")
        try Data("{}".utf8).write(to: path)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
        let bytes = try RecordingEntry.controlBytes(path.path); try check(bytes == Data("{}".utf8), "control read")
        try Data(repeating: 0, count: 8193).write(to: path)
        try rejects("control oversized") { _ = try RecordingEntry.controlBytes(path.path) }
        try FileManager.default.removeItem(at: path)
        try FileManager.default.createSymbolicLink(at: path, withDestinationURL: s.root.appendingPathComponent("Info.plist"))
        try rejects("control symlink") { _ = try RecordingEntry.controlBytes(path.path) }
    }
    print("PASS ALL \(passed) executable headless cases; no Simulator app executed")
} catch { fputs("FAIL \(error)\n", stderr); exit(1) }
