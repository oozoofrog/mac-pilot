import Foundation
#if targetEnvironment(simulator)
import UIKit
#endif

func fixtureDiagnostic(_ stage: String) {
    let line = "\(ISO8601DateFormatter().string(from: Date())) pid=\(getpid()) fixture.\(stage)\n"
    let data = Data(line.utf8)
    FileHandle.standardError.write(data)
    #if targetEnvironment(simulator)
    NSLog("%@", line)
    do {
        let directory = try FileManager.default.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let file = directory.appendingPathComponent("fixture-lifecycle.log")
        if !FileManager.default.fileExists(atPath: file.path) { FileManager.default.createFile(atPath: file.path, contents: nil) }
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
    } catch { NSLog("fixture.diagnosticWriteFailed %@", String(describing: error)) }
    #endif
}

@main
struct FixtureEntry {
    static func main() {
        let args = Array(CommandLine.arguments.dropFirst())
        guard args.count == 2, args[0] == "--fixture-session",
              let token = ProcessInfo.processInfo.environment["MAC_CU_FIXTURE_SESSION"],
              !token.isEmpty, args[1] == token, getenv("MAC_CU_FIXTURE_CHILD") == nil else {
            fixtureDiagnostic("entry.rejected argc=\(args.count) inherited=\(getenv("MAC_CU_FIXTURE_CHILD") != nil)")
            exit(64)
        }
        fixtureDiagnostic("entry.accepted argc=\(args.count) tokenMatched=true")
        setenv("MAC_CU_FIXTURE_CHILD", "1", 1)
        #if targetEnvironment(simulator)
        UIApplicationMain(CommandLine.argc, CommandLine.unsafeArgv, nil, NSStringFromClass(FixtureDelegate.self))
        #else
        print("PASS fixture dispatch only; UIKit is excluded")
        #endif
    }
}
