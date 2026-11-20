import XCTest
import CryptoKit
import Darwin

private struct Request: Decodable {
    let session: UUID
    let sequence: Int
    let action: String
    let target: String?
    let seconds: Double?
    var text: String? = nil
}

private struct RunnerError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

final class MacPilotTests: XCTestCase {
    private let issueLock = NSLock()
    private var issueCount = 0

    override func record(_ issue: XCTIssue) {
        issueLock.withLock { issueCount += 1 }
        super.record(issue)
    }

    func testServe() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let session = UUID(uuidString: env["MACPILOT_SESSION"] ?? ""),
              let port = UInt16(env["MACPILOT_PORT"] ?? ""), port >= 49152,
              let secret = Data(base64Encoded: env["MACPILOT_KEY"] ?? ""), secret.count == 32 else {
            throw RunnerError("Start this USB runner from MacPilot.")
        }
        let listener = socket(AF_INET, SOCK_STREAM, 0)
        guard listener >= 0 else { throw RunnerError("Cannot create the runner socket.") }
        defer { close(listener) }
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(listener, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0, listen(listener, 1) == 0 else { throw RunnerError("Cannot listen on the runner loopback port.") }
        try XCTestSocket.wait(listener, events: Int16(POLLIN), until: XCTestSocket.now + 90)
        let fd = accept(listener, nil, nil)
        guard fd >= 0 else { throw RunnerError("Cannot accept the USB connection.") }
        defer { close(fd) }
        var one: Int32 = 1
        guard setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout.size(ofValue: one))) == 0 else {
            throw RunnerError("Cannot configure the USB connection.")
        }
        try await serve(XCTestSocket(fd: fd, key: SymmetricKey(data: secret)), session: session, target: env["MACPILOT_TARGET"])
    }

    private func serve(_ socket: XCTestSocket, session: UUID, target: String?) async throws {
        func reply(_ sequence: Int, _ payload: [String: Any]) throws {
            let record = payload.merging(["session": session.uuidString, "sequence": sequence]) { _, new in new }
            try socket.send(JSONSerialization.data(withJSONObject: record), as: .reply, until: XCTestSocket.now + 5)
        }
        try reply(0, ["state": "ready"])
        var sequence = 1
        let expiry = XCTestSocket.now + 900
        while XCTestSocket.now < expiry {
            let data: Data
            do { data = try socket.receive(.request, until: min(expiry, XCTestSocket.now + 120)) }
            catch XCTestSocketError.closed { return }
            catch XCTestSocketError.timeout { return }
            let request = try JSONDecoder().decode(Request.self, from: data)
            guard request.session == session, request.sequence == sequence else { throw RunnerError("Unexpected XCTest session or sequence.") }
            if request.action == "stop" { return }
            let result: [String: Any]
            do {
                let count = issueLock.withLock { issueCount }
                let value = try await execute(request, bundleID: target)
                guard issueLock.withLock({ issueCount == count }) else {
                    throw RunnerError("XCTest reported an interaction failure. Observe the app before retrying.")
                }
                result = value
            } catch {
                result = ["error": error.localizedDescription]
            }
            try reply(sequence, result)
            sequence += 1
        }
    }

    @MainActor
    private func execute(_ request: Request, bundleID: String?) async throws -> [String: Any] {
        if request.action == "ping" { return ["state": "pong"] }
        guard let bundleID, !bundleID.isEmpty else { throw RunnerError("This session has no target application.") }
        let app = XCUIApplication(bundleIdentifier: bundleID)
        func requireForeground() throws {
            guard app.state == .runningForeground else { throw RunnerError("The selected app must already be in the foreground.") }
        }
        if request.action == "activate" {
            app.activate()
            try requireForeground()
            return ["state": "foreground"]
        }
        try requireForeground()
        if request.action == "describe" {
            var rows: [[String: Any]] = []
            var truncated = false
            func visit(_ item: XCUIElementSnapshot, depth: Int) {
                guard rows.count < 200, depth <= 32 else { truncated = true; return }
                rows.append(["depth": depth, "type": item.elementType.rawValue,
                             "identifier": String(item.identifier.prefix(256)), "label": String(item.label.prefix(256)),
                             "enabled": item.isEnabled])
                for child in item.children {
                    if rows.count >= 200 { truncated = true; break }
                    visit(child, depth: depth + 1)
                }
            }
            visit(try app.snapshot(), depth: 0)
            try requireForeground()
            return ["elements": rows, "truncated": truncated]
        }
        guard ["wait", "tap", "type"].contains(request.action),
              let id = request.target, !id.isEmpty, id.utf8.count <= 256 else { throw RunnerError("Expected a bounded accessibility identifier.") }
        let matches = app.descendants(matching: .any).matching(NSPredicate(format: "identifier == %@", id))
        if request.action == "wait" {
            let seconds = request.seconds ?? 3
            guard seconds.isFinite, (0...10).contains(seconds) else { throw RunnerError("Wait must be 0 to 10 seconds.") }
            let deadline = ProcessInfo.processInfo.systemUptime + seconds
            repeat {
                try requireForeground()
                if matches.count > 0 { return ["found": true] }
                if ProcessInfo.processInfo.systemUptime >= deadline { break }
                try await Task.sleep(nanoseconds: 150_000_000)
            } while true
            return ["found": false]
        }
        guard matches.count == 1 else { throw RunnerError("Input requires exactly one matching element.") }
        let element = matches.element
        guard element.isHittable, element.isEnabled else { throw RunnerError("The element cannot receive a tap.") }
        try requireForeground()
        if request.action == "type" {
            guard [.textField, .textView, .searchField].contains(element.elementType),
                  let text = request.text, !text.isEmpty, text.count <= 200, text.utf8.count <= 2048 else {
                throw RunnerError("Typing requires a plain text field and 1 to 200 characters (up to 2048 bytes).")
            }
            element.tap()
            try requireForeground()
            element.typeText(text)
            return ["state": "text dispatched"]
        }
        element.tap()
        return ["state": "tap dispatched"]
    }
}
