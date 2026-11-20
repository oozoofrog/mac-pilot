extension MacPilotTests {
    @MainActor func testSimulatorAcceptance() async throws {
        let target = "org.macpilot.fixture.xctest"
        let app = XCUIApplication(bundleIdentifier: target)
        defer { app.terminate() }
        func command(_ action: String, _ identifier: String? = nil) async throws -> [String: Any] {
            try await execute(Request(session: UUID(), sequence: 1, action: action, target: identifier, seconds: 0), bundleID: target)
        }
        _ = try await command("activate")
        XCTAssertEqual(app.state, .runningForeground)
        let snapshot = try await command("describe")
        let ids = (snapshot["elements"] as? [[String: Any]])?.compactMap { $0["identifier"] as? String } ?? []
        XCTAssertTrue(ids.contains("save"))
        let absent = try await command("wait", "saved")
        XCTAssertEqual(absent["found"] as? Bool, false)
        for id in ["missing", "duplicate"] {
            do {
                _ = try await command("tap", id)
                XCTFail("Expected the ambiguous or missing element to be refused")
            } catch { XCTAssertTrue(error.localizedDescription.contains("exactly one")) }
        }
        _ = try await command("tap", "save")
        let found = try await command("wait", "saved")
        XCTAssertEqual(found["found"] as? Bool, true)
        let type = Request(session: UUID(), sequence: 1, action: "type", target: "name", seconds: nil, text: "MacPilot")
        _ = try await execute(type, bundleID: target)
        XCTAssertEqual(app.staticTexts["echo"].label, "MacPilot")
        var secure = Request(session: UUID(), sequence: 1, action: "type", target: "secret", seconds: nil)
        secure.text = "example"
        do { _ = try await execute(secure, bundleID: target); XCTFail("Expected refusal") }
        catch { XCTAssertTrue(error.localizedDescription.contains("plain text field")) }
        app.terminate()
        do {
            _ = try await command("describe")
            XCTFail("Expected foreground check to fail")
        } catch { XCTAssertTrue(error.localizedDescription.contains("foreground")) }
    }
}

extension MacPilotTests {
    func testSocketSession() async throws {
        for failure in ["replay", "wrong session", "wrong key", "truncated"] {
            var descriptors: [Int32] = [-1, -1]
            guard socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors) == 0 else { throw XCTestSocketError.closed }
            let key = SymmetricKey(size: .bits256)
            let id = UUID()
            let client = XCTestSocket(fd: descriptors[0], key: key)
            let peer = XCTestSocket(fd: descriptors[1], key: key)
            defer { close(client.fd); close(peer.fd) }
            let server = Task.detached { try await self.serve(peer, session: id, target: nil) }
            func response() throws -> [String: Any] {
                let data = try client.receive(.reply, until: XCTestSocket.now + 5)
                return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            }
            func request(_ sender: XCTestSocket, _ uuid: UUID, _ seq: Int) throws {
                let data = try JSONSerialization.data(withJSONObject: ["action": "ping", "session": uuid.uuidString, "sequence": seq])
                try sender.send(data, as: .request, until: XCTestSocket.now + 5)
            }
            XCTAssertEqual(try response()["state"] as? String, "ready")
            try request(client, id, 1)
            let pong = try response()
            XCTAssertEqual(pong["state"] as? String, "pong")
            XCTAssertEqual(pong["sequence"] as? Int, 1)
            switch failure {
            case "replay": try request(client, id, 1)
            case "wrong session": try request(client, UUID(), 2)
            case "wrong key": try request(XCTestSocket(fd: client.fd, key: SymmetricKey(size: .bits256)), id, 2)
            default:
                var length = UInt32(64).bigEndian
                _ = Darwin.send(client.fd, &length, 4, 0)
                shutdown(client.fd, SHUT_WR)
            }
            do {
                try await server.value
                XCTAssertEqual(failure, "truncated")
            } catch { XCTAssertNotEqual(failure, "truncated") }
            var pending = pollfd(fd: client.fd, events: Int16(POLLIN), revents: 0)
            XCTAssertEqual(poll(&pending, 1, 0), 0)
        }
    }
}
