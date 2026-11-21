import AppKit

func checkDesktopDisconnect(app: String, target: pid_t, previous: pid_t) throws {
    let listener = socket(AF_UNIX, SOCK_STREAM, 0)
    guard listener >= 0 else { throw ToolError("Failed to create test listener.") }
    defer { close(listener) }
    // macOS sockaddr_un paths are limited to 103 bytes. Keep the private test address short.
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("desktop-" + UUID().uuidString + ".sock")
    guard url.path.utf8.count < 104, withAddress(url, { bind(listener, $0, $1) }) == 0 else {
        throw ToolError("Failed to bind isolated test listener.")
    }
    defer { unlink(url.path) }
    guard chmod(url.path, 0o600) == 0, listen(listener, 1) == 0, let client = connectSocket(url) else {
        throw ToolError("Failed to connect the test client.")
    }
    defer { close(client) }
    guard let socket = acceptClient(listener) else { throw ToolError("Failed to accept test connection.") }
    let done = DispatchSemaphore(value: 0)
    DispatchQueue.global().async {
        serve(socket, host: executablePath(of: getpid()))
        done.signal()
    }
    func send(_ id: Int, _ args: [String: Any]) throws {
        guard writeLine(client, ["jsonrpc": "2.0", "id": id, "method": "tools/call",
                                 "params": ["name": "act", "arguments": args.merging(["app": app]) { _, name in name }]]) else {
            throw ToolError("MCP request write failed.")
        }
    }
    func receive(_ id: Int, error: Bool = false) throws -> [String: Any] {
        var value: [String: Any] = [:]
        readLines(client) { data in
            value = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
            return false
        }
        guard value["id"] as? Int == id, let result = value["result"] as? [String: Any],
              (result["isError"] as? Bool == true) == error else {
            throw ToolError("Unexpected MCP result for \(id): \(value)")
        }
        return result["structuredContent"] as? [String: Any] ?? [:]
    }

    let begin: [String: Any] = ["chain": "begin", "actions": [["type": "wait", "seconds": 0]]]
    try send(1, begin)
    guard let id = try receive(1)["chain"] as? String, frontmostPID() == target else { throw ToolError("Failed to acquire MCP chain.") }
    try send(2, ["chain": id, "actions": [["type": "wait", "seconds": 1], ["type": "wait", "seconds": 0]]])
    usleep(200_000)
    guard writeLine(client, ["jsonrpc": "2.0", "method": "notifications/cancelled", "params": ["requestId": 2]]) else {
        throw ToolError("Cancellation write failed.")
    }
    let interrupted = try receive(2, error: true)
    guard interrupted["completed"] as? Int == 0, interrupted["skipped"] as? Int == 1, frontmostPID() == previous else {
        throw ToolError("Cancelled request must release focus and skip its next action.")
    }
    try send(3, begin)
    guard try receive(3)["chain"] as? String != nil, frontmostPID() == target else { throw ToolError("Second MCP acquisition failed.") }
    shutdown(client, SHUT_WR)
    guard done.wait(timeout: .now() + 5) == .success else { throw ToolError("The MCP connection did not terminate.") }
    handleQueue.sync {}
    guard frontmostPID() == previous else { throw ToolError("Disconnect did not restore previous focus.") }
    print("PASS production MCP request cancellation and disconnect over isolated Unix socket")
}
