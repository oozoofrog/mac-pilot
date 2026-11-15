import Foundation
import Darwin

let args = Array(CommandLine.arguments.dropFirst())
guard args.first == "--native-check", (args.count == 1 || (args.count == 2 && UUID(uuidString: args[1]) != nil)),
      getenv("MAC_CU_NATIVE_CHECK_CHILD") == nil else { exit(64) }
setenv("MAC_CU_NATIVE_CHECK_CHILD", "1", 1)
var count = 0
func check(_ value: Bool, _ name: String) { guard value else { fatalError(name) }; count += 1; print("PASS \(name)") }
let id = "00000000-0000-4000-8000-000000000001"
func arguments(_ argv: [String], environment: [String]) -> [UInt8] {
    let n = UInt32(argv.count)
    var result = (0..<4).map { UInt8((n >> (8*$0)) & 255) }
    result += Array("/fixture/launchd_sim\0\0".utf8)
    for part in argv + environment { result += Array(part.utf8); result.append(0) }
    return result
}
check(SimulatorBootIdentity.deviceID(in: arguments(["launchd_sim"],environment:["SIMULATOR_UDID=\(id)"])) == id,"extract exact device environment")
check(SimulatorBootIdentity.deviceID(in: arguments(["launchd_sim","SIMULATOR_UDID=\(id)"],environment:[])) == nil,"argv does not grant device identity")
check(SimulatorBootIdentity.deviceID(in: arguments(["launchd_sim"],environment:["OTHER_SIMULATOR_UDID=\(id)"])) == nil,"reject environment suffix match")
check(SimulatorBootIdentity.deviceID(in: arguments(["launchd_sim"],environment:["SIMULATOR_UDID=\(id)","SIMULATOR_UDID=\(id)"])) == nil,"reject duplicate device identifiers")
check(SimulatorBootIdentity.deviceID(in: arguments(["launchd_sim"],environment:["SIMULATOR_UDID=invalid"])) == nil,"reject malformed device identifier")
check(SimulatorBootIdentity.deviceID(in: [0,0,0,0,0]) == nil,"reject zero argument count")
check(SimulatorBootIdentity.deviceID(in: Array(arguments(["launchd_sim"],environment:["SIMULATOR_UDID=\(id)"]).dropLast())) == nil,"reject truncated environment")
check(SimulatorBootIdentity.read(pid: getpid()) == nil,"ordinary process is not a Simulator boot")
check(SimulatorBootIdentity.current(deviceID:"invalid") == nil,"invalid selected device cannot discover fallback")
if args.count == 2 {
    guard let first = SimulatorBootIdentity.current(deviceID:args[1]), let second = SimulatorBootIdentity.read(pid:first.pid) else { fatalError("selected boot identity unavailable") }
    check(first == second && first.deviceID == UUID(uuidString:args[1])!.uuidString,"selected live boot lifetime and device recheck")
    print("Observed selected launchd_sim PID \(first.pid), start \(first.seconds).\(first.microseconds); no GUI or guest operation")
}
check(SimulatorInspectionHost.runtimeFingerprint(identifier: "com.apple.CoreSimulator.SimRuntime.iOS-27-2", build: "24B114") == "com.apple.CoreSimulator.SimRuntime.iOS-27-2|24B114", "runtime identifier and build")
check(SimulatorInspectionHost.runtimeFingerprint(identifier: "com.apple.CoreSimulator.SimRuntime.iOS-27-2-iPhone19-4", build: "24B91016s") != SimulatorInspectionHost.runtimeFingerprint(identifier: "com.apple.CoreSimulator.SimRuntime.iOS-27-2", build: "24B114"), "same display name cannot alias runtime")
for (identifier, build): (Any?, Any?) in [(nil, "24B114"), ("id", nil), (1, "build"), ("id|other", "build"), ("id", "build\n"), ("", "build")] {
    check(SimulatorInspectionHost.runtimeFingerprint(identifier: identifier, build: build) == nil, "malformed runtime metadata")
}
print("PASS \(count) inspection lifecycle assertions")

let metadataRoot = FileManager.default.temporaryDirectory.appendingPathComponent("ax-runtime-plist-" + UUID().uuidString)
try FileManager.default.createDirectory(at: metadataRoot.appendingPathComponent("System/Library/CoreServices"), withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: metadataRoot) }
let metadataFile = metadataRoot.appendingPathComponent("System/Library/CoreServices/SystemVersion.plist")
check(SimulatorInspectionHost.runtimeBuild(root: metadataRoot) == nil, "missing runtime plist fails closed")
for build: Any in ["24B114", "24B91016s", "", "24B114\n", "24 B114", "24B114|other", 24, String(repeating: "1", count: 80)] {
    try PropertyListSerialization.data(fromPropertyList: ["ProductBuildVersion": build], format: .binary, options: 0).write(to: metadataFile)
    let valid = (build as? String == "24B114" || build as? String == "24B91016s")
    check((SimulatorInspectionHost.runtimeBuild(root: metadataRoot) != nil) == valid, "runtime build strict validation")
}
try Data(repeating: 65, count: 65537).write(to: metadataFile)
check(SimulatorInspectionHost.runtimeBuild(root: metadataRoot) == nil, "oversized runtime plist fails closed")
try Data("not a plist".utf8).write(to: metadataFile)
check(SimulatorInspectionHost.runtimeBuild(root: metadataRoot) == nil, "malformed runtime plist fails closed")
check(SimulatorInspectionHost.runtimeMetadata(NSObject()) == nil, "unverified runtime provenance fails closed")
print("PASS \(count) inspection lifecycle and runtime metadata assertions")
