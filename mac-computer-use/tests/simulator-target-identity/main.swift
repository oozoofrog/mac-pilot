import Foundation
import Darwin

guard CommandLine.arguments == [CommandLine.arguments[0], "--native-check"],
      getenv("MAC_CU_NATIVE_CHECK_CHILD") == nil else { exit(64) }
setenv("MAC_CU_NATIVE_CHECK_CHILD", "1", 1)

typealias Identity = SimulatorTargetIdentity
typealias Failure = Identity.Failure
struct TestFailure: Error { let name: String }
nonisolated(unsafe) var assertions = 0
@Sendable func check(_ value: Bool, _ name: String) throws {
    guard value else { throw TestFailure(name: name) }
    assertions += 1; print("PASS \(name)")
}
@Sendable func reject(_ error: Failure, _ name: String, _ body: () throws -> Void) throws {
    do { try body(); throw TestFailure(name: "accepted: " + name) }
    catch let actual as Failure { try check(actual == error, name) }
}
let device = "ABCDEFAB-1234-4567-89AB-ABCDEFABCDEF"
@Sendable func arguments(_ argv: [String] = ["fixture"], _ env: [String] = ["SIMULATOR_UDID=ABCDEFAB-1234-4567-89AB-ABCDEFABCDEF"]) -> [UInt8] {
    let count = UInt32(argv.count)
    return (0..<4).map { UInt8((count >> (8 * $0)) & 255) } + Array("/fixture\0\0".utf8) +
        (argv + env).flatMap { Array($0.utf8) + [UInt8(0)] }
}
@Sendable func status(pid: UInt32 = 123, seconds: UInt64 = 41, microseconds: UInt64 = 42,
            state: UInt32 = 2, flags: UInt32 = 0) -> proc_bsdinfo {
    var info = proc_bsdinfo()
    info.pbi_pid = pid; info.pbi_start_tvsec = seconds; info.pbi_start_tvusec = microseconds
    info.pbi_status = state; info.pbi_flags = flags
    return info
}
@Sendable func mock(statuses: [proc_bsdinfo] = [status(), status()], paths: [String] = ["/alias/target", "/alias/target"],
          bytes: [UInt8] = arguments(), canonical: @escaping (String) throws -> String = { _ in "/native/target" }) -> Identity.Reads {
    var statusIndex = 0, pathIndex = 0
    return Identity.Reads(status: { pid in
        guard pid == 123, statusIndex < statuses.count else { throw TestFailure(name: "extra/wrong status read") }
        defer { statusIndex += 1 }; return statuses[statusIndex]
    }, path: { pid in
        guard pid == 123, pathIndex < paths.count else { throw TestFailure(name: "extra/wrong path read") }
        defer { pathIndex += 1 }; return paths[pathIndex]
    }, arguments: { pid in
        guard pid == 123 else { throw TestFailure(name: "wrong argument PID") }; return bytes
    }, canonicalPath: canonical)
}
@Sendable func read(_ reads: Identity.Reads = mock(), deviceID: String = device) throws -> Identity {
    try Identity.read(pid: 123, deviceID: deviceID, reads: reads)
}

@Sendable func run() throws {
    let value = try read(deviceID: device.lowercased())
    try check(value.pid == 123 && value.start == [41, 42] && value.path == "/native/target" && value.deviceID == device,
              "exact device/lifetime/canonical path returned")
    _ = try read(mock(statuses: [status(state: 4, flags: 2), status(state: 3)]))
    try check(true, "final sleeping untraced state uses final status")
    try reject(.invalidRequest, "invalid requested device") { _ = try read(deviceID: "wrong") }
    try reject(.invalidRequest, "nonpositive PID") { _ = try Identity.read(pid: 0, deviceID: device, reads: mock()) }
    try reject(.identityChanged, "PID reuse during read") { _ = try read(mock(statuses: [status(), status(seconds: 42)])) }
    try reject(.identityChanged, "microsecond lifetime change") { _ = try read(mock(statuses: [status(), status(microseconds: 43)])) }
    for bad in [status(pid: 124), status(seconds: 0), status(microseconds: 1_000_000)] {
        try reject(.identityUnknown, "invalid initial process identity") { _ = try read(mock(statuses: [bad, status()])) }
        try reject(.identityUnknown, "invalid final process identity") { _ = try read(mock(statuses: [status(), bad])) }
    }
    for state: UInt32 in [0, 1, 4, 5, 6] {
        try reject(.targetUnavailable, "reject final nonrunning state \(state)") { _ = try read(mock(statuses: [status(), status(state: state)])) }
    }
    try reject(.targetUnavailable, "reject final traced target") { _ = try read(mock(statuses: [status(), status(flags: 2)])) }
    try reject(.targetUnavailable, "target belongs to another device") {
        _ = try read(mock(bytes: arguments(["fixture"], ["SIMULATOR_UDID=00000000-0000-4000-8000-000000000001"])))
    }
    try reject(.identityChanged, "observed executable change") {
        _ = try read(mock(paths: ["/before", "/after"], canonical: { $0 }))
    }
    var denied = mock(); denied.status = { _ in throw Failure.identityUnknown }
    try reject(.identityUnknown, "denied status has no fallback") { _ = try read(denied) }
    denied = mock(); denied.path = { _ in throw Failure.identityUnknown }
    try reject(.identityUnknown, "denied path has no fallback") { _ = try read(denied) }
    denied = mock(); denied.arguments = { _ in throw Failure.identityUnknown }
    try reject(.identityUnknown, "denied environment has no fallback") { _ = try read(denied) }
    try reject(.identityUnknown, "unresolved canonical path") { _ = try read(mock(canonical: { _ in throw Failure.identityUnknown })) }

    let size = Int32(MemoryLayout<proc_bsdinfo>.size)
    _ = try Identity.checkedStatus(status(), byteCount: size, pid: 123)
    try check(true, "complete BSD status size")
    for count: Int32 in [-1, 0, size - 1, size + 1] {
        try reject(.identityUnknown, "short/invalid BSD status size") { _ = try Identity.checkedStatus(status(), byteCount: count, pid: 123) }
    }
    try reject(.identityUnknown, "BSD status for wrong PID") { _ = try Identity.checkedStatus(status(pid: 1), byteCount: size, pid: 123) }
    let path = Array("/fixture\0".utf8)
    try check(try Identity.pathString(path, length: path.count - 1) == "/fixture", "proc_pidpath length excludes NUL")
    for count in [-1, 0, path.count, 4096] {
        try reject(.identityUnknown, "invalid path length") { _ = try Identity.pathString(path, length: count) }
    }
    for bytes in [Array("/fixture".utf8), Array("relative\0".utf8), [47, 255, 0], [47, 0, 65, 0]] {
        try reject(.identityUnknown, "unterminated/relative/invalid path") { _ = try Identity.pathString(bytes, length: bytes.count - 1) }
    }
    try reject(.identityUnknown, "oversized procargs result") { _ = try Identity.argumentBytes([0, 0], size: Identity.argumentLimit + 1) }
    try reject(.identityUnknown, "procargs count exceeds buffer") { _ = try Identity.argumentBytes([0, 0], size: 3) }
    try reject(.identityUnknown, "empty procargs result") { _ = try Identity.argumentBytes([0, 0], size: 0) }
    let padded = arguments() + [0, 0, 0]
    try check(try Identity.deviceID(in: padded) == device, "bounded environment padding")
    try check(try Identity.deviceID(in: arguments(["fixture"], ["SIMULATOR_UDID=" + device.lowercased()])) == device, "ASCII UUID case normalization")
    let invalidEnvironments = [[], ["OTHER_SIMULATOR_UDID=" + device], ["SIMULATOR_UDID=bad"],
        ["SIMULATOR_UDID=" + device, "SIMULATOR_UDID=" + device], ["SIMULATOR_UDID={" + device + "}"],
        ["SIMULATOR_UDID=" + device.replacingOccurrences(of: "-", with: "")], ["SIMULATOR_UDID=" + device + " "]]
    for env in invalidEnvironments {
        try reject(.identityUnknown, "missing/ambiguous/noncanonical device environment") { _ = try Identity.deviceID(in: arguments(["fixture"], env)) }
    }
    try reject(.identityUnknown, "argv key is not target environment") { _ = try Identity.deviceID(in: arguments(["fixture", "SIMULATOR_UDID=" + device], [])) }
    for argc: UInt32 in [0, 65536, UInt32.max] {
        var bytes = arguments()
        bytes.replaceSubrange(0..<4, with: (0..<4).map { UInt8((argc >> (8 * $0)) & 255) })
        try reject(.identityUnknown, "invalid argument count") { _ = try Identity.deviceID(in: bytes) }
    }
    for bytes in [[UInt8](), [1, 0, 0, 0], [1, 0, 0, 0, 0], Array(arguments().dropLast()),
                  [1, 0, 0, 0] + Array("/executable".utf8), Array(repeating: UInt8(0), count: Identity.argumentLimit + 1)] {
        try reject(.identityUnknown, "truncated/oversized argument block") { _ = try Identity.deviceID(in: bytes) }
    }
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("target-identity-path-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: folder) }
    let target = folder.appendingPathComponent("target")
    let alias = folder.appendingPathComponent("alias")
    try Data("owned".utf8).write(to: target)
    try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: target)
    let resolved = try Identity.canonicalPath(target.path)
    try check(try Identity.canonicalPath(alias.path) == resolved, "real symlink aliases agree")
    try FileManager.default.removeItem(at: target)
    try reject(.identityUnknown, "deleted target is not fabricated") { _ = try Identity.canonicalPath(target.path) }
    try reject(.identityUnknown, "dangling symlink is not lexical identity") { _ = try Identity.canonicalPath(alias.path) }
    for invalid in ["relative", "/a\0b", "/" + String(repeating: "a", count: 4096)] {
        try reject(.identityUnknown, "invalid canonical path input") { _ = try Identity.canonicalPath(invalid) }
    }
}

do {
    var calls = 0
    let forbidden = Identity.Reads(status: { _ in calls += 1; throw Failure.identityUnknown },
        path: { _ in calls += 1; throw Failure.identityUnknown }, arguments: { _ in calls += 1; throw Failure.identityUnknown },
        canonicalPath: { _ in calls += 1; throw Failure.identityUnknown })
    try reject(.invalidRequest, "main thread rejected before reads") { _ = try Identity.read(pid: 123, deviceID: device, reads: forbidden) }
    try check(calls == 0, "main thread performed zero reads")
} catch { fputs("FAIL \(error)\n", stderr); exit(1) }
let done = DispatchSemaphore(value: 0)
DispatchQueue.global().async {
    do { try run(); print("PASS \(assertions) native target identity assertions (mock-only)"); done.signal() }
    catch { fputs("FAIL \(error)\n", stderr); exit(1) }
}
guard done.wait(timeout: .now() + 10) == .success else { exit(1) }
