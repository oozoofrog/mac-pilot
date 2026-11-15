
// Appended to the complete frozen production file to access its private producer.
@main
struct CanonicalTemporaryPathCheck {
    static func main() throws {
        guard Array(CommandLine.arguments.dropFirst()) == ["--native-check"],
              getenv("MAC_CU_NATIVE_CHECK_CHILD") == nil else { exit(64) }
        setenv("MAC_CU_NATIVE_CHECK_CHILD", "1", 1)
        let environment = ProcessInfo.processInfo.environment
        guard let input = environment["CANONICAL_PATH_INPUT"],
              let receipt = environment["CANONICAL_PATH_RECEIPT"] else { exit(64) }
        let folder = try simulatorViewCaptureFolder()
        let file = folder.appendingPathComponent("request.json")
        let bytes = try Data(contentsOf: URL(fileURLWithPath: input))
        guard FileManager.default.createFile(atPath: file.path, contents: bytes,
                                             attributes: [.posixPermissions: 0o600]) else {
            throw ToolError("Cannot create private headless request")
        }
        let result = ["temporaryDirectory": FileManager.default.temporaryDirectory.path,
                      "folder": folder.path, "request": file.path]
        try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
            .write(to: URL(fileURLWithPath: receipt))
        print("PASS actual production folder producer; no capture/helper/target entry")
    }
}
