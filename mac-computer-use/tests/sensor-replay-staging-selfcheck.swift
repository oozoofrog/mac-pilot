// Offline regression check for macpilot-sensor-replay staging, symlink guards, readback verification,
// collaboration claim enforcement, error unwrapping, timeout and cancellation propagation.
import Foundation

struct ToolError: Error, LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

@main struct SensorReplayStagingSelfcheck {
    static func expect(_ condition: @autoclosure () -> Bool, _ message: String, line: UInt = #line) {
        if !condition() {
            fputs("FAIL line \(line): \(message)\n", stderr)
            exit(1)
        }
    }

    static func expectToolError(_ fragment: String, line: UInt = #line, _ body: () throws -> [String: Any]) -> String {
        do {
            let unexpected = try body()
            fputs("FAIL line \(line): expected ToolError(\(fragment)), got \(unexpected)\n", stderr)
            exit(1)
        } catch let error as ToolError {
            expect(error.message.contains(fragment), "expected '\(fragment)' in '\(error.message)'", line: line)
            return error.message
        } catch {
            fputs("FAIL line \(line): expected ToolError, got \(error)\n", stderr)
            exit(1)
        }
    }

    static func main() throws {
        guard CommandLine.arguments.count == 2 else {
            fputs("Usage: sensor-replay-staging-selfcheck /path/to/macpilot-sensor-replay\n", stderr)
            exit(64)
        }
        let compiledHelper = CommandLine.arguments[1]
        expect(FileManager.default.isExecutableFile(atPath: compiledHelper), "compiled helper must exist")
        expect(sensorReplayHelperTimeout >= 150, "parent timeout must exceed 3 x 45s devicectl budget")

        let root = FileManager.default.temporaryDirectory.appendingPathComponent("mac-pilot-replay-check-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let fixtureURL = root.appendingPathComponent("valid.json")
        let validJSON = Data(#"{"version":1,"events":[{"offsetMs":0,"motion":{"steps":3}},{"offsetMs":10,"location":{"latitude":37.5,"longitude":127.0,"altitudeMeters":25}}]}"#.utf8)
        try validJSON.write(to: fixtureURL)
        let deviceID = UUID()

        // 1. Simulator staging: creates Documents when absent, writes bytes, verifies readback, writes .ready.
        let container = root.appendingPathComponent("sim-container")
        try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
        let simReceipt = try stageSensorReplayCommand(
            ["simulator", deviceID.uuidString, "com.example.App", fixtureURL.path],
            runner: SimulatorPreparationTask(),
            runXC: { _, step, _, _ in
                expect(step == "simctl get_app_container", "unexpected step \(step)")
                return container.path + "\n"
            }
        )
        expect(simReceipt["state"] as? String == "staged" && simReceipt["events"] as? Int == 2, "simulator receipt")
        let stagedRel = simReceipt["path"] as? String ?? ""
        let stagedFile = container.appendingPathComponent(stagedRel)
        expect((try? Data(contentsOf: stagedFile)) == validJSON, "staged simulator bytes match")
        expect(FileManager.default.fileExists(atPath: stagedFile.path + ".ready"), "simulator .ready marker exists")

        // 2. Simulator symlink guard: Documents symlinked outside container is refused without writing outside.
        let escaped = root.appendingPathComponent("outside-documents")
        try FileManager.default.createDirectory(at: escaped, withIntermediateDirectories: true)
        let badContainer = root.appendingPathComponent("bad-container")
        try FileManager.default.createDirectory(at: badContainer, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: badContainer.appendingPathComponent("Documents"), withDestinationURL: escaped)
        do {
            _ = try stageSensorReplayCommand(
                ["simulator", deviceID.uuidString, "com.example.App", fixtureURL.path],
                runner: SimulatorPreparationTask(),
                runXC: { _, _, _, _ in badContainer.path }
            )
            fputs("FAIL: expected symlinked Documents refusal\n", stderr)
            exit(1)
        } catch {
            expect(error.localizedDescription.contains("Documents must be inside"), "symlink guard message: \(error.localizedDescription)")
        }
        expect(((try? FileManager.default.contentsOfDirectory(atPath: escaped.path)) ?? []).isEmpty, "nothing written outside container")

        // 3. Device 3-step staging and tampered readback rejection before .ready.
        var deviceSteps: [String] = []
        var remoteBytes = Data()
        var corruptReadback = false
        func fakeDeviceXC(_: SimulatorPreparationTask, _ step: String, _ args: [String], _ timeout: TimeInterval) throws -> String {
            expect(timeout == 45, "device step timeout must be 45s")
            deviceSteps.append(step)
            func flag(_ name: String) -> String {
                let idx = args.firstIndex(of: name)!
                return args[idx + 1]
            }
            if step == "devicectl copy to" {
                remoteBytes = try Data(contentsOf: URL(fileURLWithPath: flag("--source")))
            } else if step == "devicectl copy from" {
                let payload = corruptReadback ? Data("{\"version\":1,\"events\":[]}".utf8) : remoteBytes
                try payload.write(to: URL(fileURLWithPath: flag("--destination")))
            }
            return ""
        }
        let devReceipt = try stageSensorReplayCommand(
            ["device", deviceID.uuidString, "com.example.App", fixtureURL.path],
            runner: SimulatorPreparationTask(),
            runXC: fakeDeviceXC
        )
        expect(devReceipt["state"] as? String == "staged", "device receipt")
        expect(deviceSteps == ["devicectl copy to", "devicectl copy from", "devicectl ready marker"], "3-step order: \(deviceSteps)")

        deviceSteps.removeAll()
        corruptReadback = true
        do {
            _ = try stageSensorReplayCommand(
                ["device", deviceID.uuidString, "com.example.App", fixtureURL.path],
                runner: SimulatorPreparationTask(),
                runXC: fakeDeviceXC
            )
            fputs("FAIL: expected tampered readback refusal\n", stderr)
            exit(1)
        } catch {
            expect(error.localizedDescription.contains("Device readback differs"), "tamper message: \(error.localizedDescription)")
        }
        expect(deviceSteps == ["devicectl copy to", "devicectl copy from"], ".ready marker must not be sent after readback mismatch")

        // 4. Delivery layer: collaboration claim guard, auto-claim + waiting notice, physical access, error unwrapping, cancel & timeout.
        let store = CollaborationStore(folder: root.appendingPathComponent("collab"))
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let owner = AgentIdentity(agent: "Claude Code", session: "holder", project: "OtherApp", pid: getppid())
        let caller = AgentIdentity(agent: "Codex", session: "caller", project: "TestApp", pid: getpid())
        store.update(now: now) { claims, _ in
            claims[deviceID.uuidString.uppercased()] = DeviceClaim(identity: owner, note: "UI run", auto: false, now: now)
        }

        var helperInvoked = false
        var cancelled = false
        var allowedDevice: UUID?
        var currentHelper = compiledHelper
        var currentTimeout: TimeInterval = 5
        func makeBackend(identity: AgentIdentity? = caller) -> SensorReplayStagingBackend {
            SensorReplayStagingBackend(
                identity: { identity },
                physicalAllowed: { allowedDevice },
                checkPhysicalAccess: { _ in },
                approveSimulator: {},
                bootedSimulatorName: { _ in "iPhone 17e" },
                collaborationStore: { store },
                helperPath: { currentHelper },
                helperTimeout: currentTimeout,
                isCancelled: { cancelled },
                now: { now }
            )
        }

        let claimErr = expectToolError("in use by another agent session (Claude Code · OtherApp · UI run") {
            currentHelper = "/bin/sh"
            return try stageSensorReplay(
                ["platform": "simulator", "device": deviceID.uuidString, "app": "com.example.App", "fixture": fixtureURL.path],
                backend: SensorReplayStagingBackend(
                    identity: { caller }, physicalAllowed: { nil }, checkPhysicalAccess: { _ in }, approveSimulator: {},
                    bootedSimulatorName: { _ in "iPhone 17e" }, collaborationStore: { store },
                    helperPath: { helperInvoked = true; return compiledHelper }, isCancelled: { false }, now: { now }
                )
            )
        }
        expect(claimErr.contains("sim-pilot request --udid \(deviceID.uuidString)"), "claim refusal gives request command")
        expect(!helperInvoked, "claimed simulator must be rejected before spawning helper")

        // Release owner's claim; stage with a stub helper that succeeds, then check auto-claim and waiting notice.
        let okHelper = root.appendingPathComponent("ok-helper.sh")
        try Data("#!/bin/sh\nprintf '{\"state\":\"staged\",\"id\":\"11111111-1111-1111-1111-111111111111\",\"events\":2}'\n".utf8).write(to: okHelper)
        chmod(okHelper.path, 0o755)
        store.update(now: now) { claims, _ in claims.removeAll() }
        currentHelper = okHelper.path
        let stagedFree = try stageSensorReplay(
            ["platform": "simulator", "device": deviceID.uuidString, "app": "com.example.App", "fixture": fixtureURL.path],
            backend: makeBackend()
        )
        expect(store.state(now: now).claims[deviceID.uuidString.uppercased()]?.by == "caller", "unclaimed simulator records auto-claim")
        expect((stagedFree["content"] as? [[String: Any]])?.count == 1, "no notice when nobody waits")

        store.update(now: now) { _, requests in
            requests.append(DeviceRequest(udid: deviceID.uuidString, from: owner, note: "need next", now: now))
        }
        let stagedWanted = try stageSensorReplay(
            ["platform": "simulator", "device": deviceID.uuidString, "app": "com.example.App", "fixture": fixtureURL.path],
            backend: makeBackend()
        )
        let notices = (stagedWanted["content"] as? [[String: Any]] ?? []).compactMap { $0["text"] as? String }
        expect(notices.count == 2 && notices[1].contains("Notice: another agent session waits for iPhone 17e"), "waiting session notice appended")

        // Physical device requires connection-level allow before invoking helper.
        _ = expectToolError("Allow the device in this connection first.") {
            try stageSensorReplay(
                ["platform": "device", "device": deviceID.uuidString, "app": "com.example.App", "fixture": fixtureURL.path],
                backend: makeBackend()
            )
        }

        // Real compiled helper failure unwraps cleanly without Korean UI wrapper or duplicate prefix.
        allowedDevice = deviceID
        currentHelper = compiledHelper
        let badJSONURL = root.appendingPathComponent("bad.json")
        try Data(#"{"version":2,"events":[]}"#.utf8).write(to: badJSONURL)
        let badFixtureErr = expectToolError("Expected version 1 and 1 to 100000 events.") {
            try stageSensorReplay(
                ["platform": "device", "device": deviceID.uuidString, "app": "com.example.App", "fixture": badJSONURL.path],
                backend: makeBackend()
            )
        }
        expect(!badFixtureErr.contains("명령이 완료") && !badFixtureErr.contains("목록을 새로고침") && !badFixtureErr.contains("Sensor replay:"),
               "unwrapped error must be plain English without duplicate prefix: \(badFixtureErr)")

        // Cancellation propagates to helper process group promptly.
        let slowHelper = root.appendingPathComponent("slow-helper.sh")
        try Data("#!/bin/sh\ntrap '' TERM\nsleep 30 & wait\n".utf8).write(to: slowHelper)
        chmod(slowHelper.path, 0o755)
        currentHelper = slowHelper.path
        currentTimeout = 15
        cancelled = false
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.15) { cancelled = true }
        let cancelStart = Date()
        let cancelErr = expectToolError("Sensor replay staging was cancelled.") {
            try stageSensorReplay(
                ["platform": "device", "device": deviceID.uuidString, "app": "com.example.App", "fixture": fixtureURL.path],
                backend: makeBackend()
            )
        }
        expect(Date().timeIntervalSince(cancelStart) < 3.0, "cancellation stops helper process group quickly")
        expect(cancelErr.contains(".ready marker"), "cancellation explains .ready atomicity")

        // Timeout reports plain English timeout with .ready marker explanation.
        cancelled = false
        currentTimeout = 0.1
        let timeoutStart = Date()
        let timeoutErr = expectToolError("Sensor replay staging timed out.") {
            try stageSensorReplay(
                ["platform": "device", "device": deviceID.uuidString, "app": "com.example.App", "fixture": fixtureURL.path],
                backend: makeBackend()
            )
        }
        expect(Date().timeIntervalSince(timeoutStart) < 3.0 && timeoutErr.contains(".ready marker") && !timeoutErr.contains("새로고침"),
               "timeout message: \(timeoutErr)")

        print("PASS sensor replay staging selfcheck: simulator/device staging, symlink guard, readback tamper guard, claim refusal, collaboration notice, error unwrapping, cancellation and timeout")
    }
}
