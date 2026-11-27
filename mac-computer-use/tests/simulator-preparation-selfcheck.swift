import Foundation
import Darwin

@main
struct SimulatorPreparationSelfcheck {
    static func fails(_ fragment: String, _ work: () throws -> Void) {
        do { try work(); fatalError("Expected failure: \(fragment)") }
        catch { assert(error.localizedDescription.contains(fragment), error.localizedDescription) }
    }
    static func main() throws {
        let f = PreparationFixture.self
        let inventory = try SimulatorPreparationInventory.decode(f.json(), developerDirectory: "fixture")
        assert(inventory.compatibleTypes(for: f.runtime).map(\.id) == [f.phone])
        assert(inventory.compatibleTypes(for: f.duoRuntime).map(\.id) == [f.duo], "Explicit runtime support overrides generic type version bounds")
        assert(inventory.runtimes[0].title != inventory.runtimes[1].title)
        let phone = inventory.devices[0]
        assert(phone.matches(query: "phone IOS", filter: .available))
        assert(phone.matches(query: f.id.lowercased(), filter: .all))
        assert(!phone.matches(query: "missing", filter: .all) && !phone.matches(query: "", filter: .booted))
        let legacy = try SimulatorPreparationInventory.decode(f.json(supported: false), developerDirectory: "fixture")
        assert(legacy.compatibleTypes(for: f.runtime).map(\.id) == [f.phone])
        let ambiguous = f.json(supported: false).replacingOccurrences(of: f.runtime, with: f.duoRuntime + "-legacy")
        let ambiguousInventory = try SimulatorPreparationInventory.decode(ambiguous, developerDirectory: "fixture")
        assert(ambiguousInventory.compatibleTypes(for: f.duoRuntime + "-legacy").isEmpty)
        fails("목록") { _ = try SimulatorPreparationInventory.decode("{}", developerDirectory: "") }

        let boot = PreparationFake([f.json(), f.json(state: "Booted")])
        _ = try boot.backend().boot(f.id)
        assert(boot.commands.map { Array($0.dropFirst()) } == [["simctl", "boot", f.id], ["simctl", "bootstatus", f.id]])
        assert(boot.selectCount == 1, "Readback stays pinned to the original developer directory")
        let running = PreparationFake([f.json(state: "Booted")])
        _ = try running.backend().boot(f.id)
        assert(running.commands.allSatisfy { !$0.contains("boot") }, "Already booted devices must not reboot")
        let booting = PreparationFake([f.json(state: "Booting"), f.json(state: "Booted")])
        _ = try booting.backend().boot(f.id)
        assert(booting.commands == [["/usr/bin/xcrun", "simctl", "bootstatus", f.id]], "A boot in progress must be awaited without sending another boot")
        for state in ["Booted", "Booting", "Shutdown"] {
            let claimed = PreparationFake([f.json(state: state)]); claimed.owners[f.id] = "Other session"
            fails("사용 기록") { _ = try claimed.backend().boot(f.id) }; assert(claimed.commands.isEmpty)
        }
        let badBoot = PreparationFake()
        fails("실제 부팅") { _ = try badBoot.backend().boot(f.id) }
        for state in ["Shutting Down", "Unknown"] {
            let transitional = PreparationFake([f.json(state: state)])
            fails("기기가 없거나") { _ = try transitional.backend().boot(f.id) }; assert(transitional.commands.isEmpty)
        }
        fails("UDID") { _ = try PreparationFake().backend().boot("booted") }
        let missingXcode = PreparationFake(); missingXcode.directory = "/Library/Developer/CommandLineTools"
        fails("전체 Xcode") { _ = try missingXcode.backend().inventory() }

        let create = PreparationFake([f.json(), f.json(created: true)])
        let (id, _) = try create.backend().create(name: " New phone ", typeID: f.phone, runtimeID: f.runtime)
        assert(id == f.newID && create.commands[0] == ["/usr/bin/xcrun", "simctl", "create", "New phone", f.phone, f.runtime])
        for name in ["", "-option", "line\nbreak", String(repeating: "x", count: 81)] {
            let fake = PreparationFake(); fails("기기 이름") { _ = try fake.backend().create(name: name, typeID: f.phone, runtimeID: f.runtime) }; assert(fake.commands.isEmpty)
        }
        let incompatible = PreparationFake()
        fails("지원하는 기기") { _ = try incompatible.backend().create(name: "New phone", typeID: f.phone, runtimeID: f.duoRuntime) }; assert(incompatible.commands.isEmpty)
        let mismatch = PreparationFake([f.json(), f.json(created: true, type: f.duo)])
        fails("실제 기기") { _ = try mismatch.backend().create(name: "New phone", typeID: f.phone, runtimeID: f.runtime) }
        let invalidID = PreparationFake(); invalidID.onCommand = { _ in "not-a-uuid" }
        fails("UDID") { _ = try invalidID.backend().create(name: "New phone", typeID: f.phone, runtimeID: f.runtime) }
        let commandFailure = PreparationFake(); commandFailure.onCommand = { _ in throw SimulatorPreparationError("Xcode fixture failure") }
        fails("Xcode fixture failure") { _ = try commandFailure.backend().boot(f.id) }

        let download = PreparationFake(); _ = try download.backend().installRuntime(platform: "iOS")
        assert(download.commands == [["/usr/bin/xcodebuild", "-downloadPlatform", "iOS"]])
        fails("사용 가능한 런타임") { _ = try PreparationFake().backend().installRuntime(platform: "tvOS") }
        let invalidPlatform = PreparationFake()
        fails("지원하는 플랫폼") { _ = try invalidPlatform.backend().installRuntime(platform: "invalid") }; assert(invalidPlatform.commands.isEmpty)
        let image = FileManager.default.temporaryDirectory.appendingPathComponent("runtime fixture \(UUID()).dmg")
        try Data().write(to: image); defer { try? FileManager.default.removeItem(at: image) }
        let imported = PreparationFake([f.json(), f.json(build: "A2")])
        _ = try imported.backend().installRuntime(platform: "iOS", image: image)
        assert(imported.commands == [["/usr/bin/xcodebuild", "-importPlatform", image.path]])
        fails("새로 사용 가능") { _ = try PreparationFake().backend().installRuntime(platform: "iOS", image: image) }
        fails("DMG") { _ = try PreparationFake().backend().installRuntime(platform: "iOS", image: URL(fileURLWithPath: "/no-such-runtime.dmg")) }
        print("PASS preparation backend: compatibility, distinct runtimes, pinned Xcode, exact UUID/type readback, boot/claim guards, create validation, runtime download/import readback and failures")

        // Real local subprocesses only; no simulator mutations, download or shell interpolation
        // occurs in production. Shell snippets below are fixed synthetic process fixtures.
        let runner = SimulatorPreparationTask()
        let result = try runner.run("/bin/sh", ["-c", "printf 'json-output'; printf 'warning' >&2"], timeout: 2, stream: false)
        assert(result == "json-output", "stderr must not corrupt simctl JSON or create UUID")
        let literal = "a b;$(do-not-run)`literal`"
        let literalOutput = try runner.run("/usr/bin/printf", ["%s", literal], timeout: 2, stream: false)
        assert(literalOutput == literal)
        setenv("MAC_PILOT_FIXTURE_SECRET", "fixture-value", 1)
        defer { unsetenv("MAC_PILOT_FIXTURE_SECRET") }
        let environment = try runner.run("/usr/bin/env", [], timeout: 2, stream: false)
        assert(!environment.contains("MAC_PILOT_FIXTURE_SECRET") && !environment.contains("OPENAI_API_KEY"))
        runner.selectDeveloperDirectory("/fixture/Xcode.app/Contents/Developer")
        let pinned = try runner.run("/usr/bin/printenv", ["DEVELOPER_DIR"], timeout: 2, stream: false)
        assert(pinned.contains("/fixture/"))
        fails("명령이 완료") { _ = try runner.run("/bin/sh", ["-c", "printf 'fixture failure' >&2; exit 7"], timeout: 2) }
        fails("No such file") { _ = try runner.run("/no-such-mac-pilot-command", [], timeout: 1) }
        let cancelled = SimulatorPreparationTask(); cancelled.cancel()
        fails("취소") { _ = try cancelled.run("/usr/bin/true", [], timeout: 2) }
        let active = SimulatorPreparationTask()
        var sawReady = false
        active.onOutput = { text in if text.contains("ready") { sawReady = true; active.cancel() } }
        let start = Date()
        fails("취소") { _ = try active.run("/bin/sh", ["-c", "trap '' TERM; printf ready; sleep 30 & wait"], timeout: 5) }
        assert(sawReady && Date().timeIntervalSince(start) < 3, "Cancellation must escalate past ignored TERM and pipe-holding descendants")
        let timeout = SimulatorPreparationTask(); let beforeTimeout = Date()
        fails("초과") { _ = try timeout.run("/bin/sh", ["-c", "trap '' TERM; sleep 30 & wait"], timeout: 0.1) }
        assert(Date().timeIntervalSince(beforeTimeout) < 3)
        // A separately owned process must survive cancellation of the operation.
        let unrelated = Process(); unrelated.executableURL = URL(fileURLWithPath: "/bin/sleep"); unrelated.arguments = ["30"]
        try unrelated.run(); defer { unrelated.terminate(); unrelated.waitUntilExit() }
        let flood = SimulatorPreparationTask(); let beforeFlood = Date()
        fails("초과") { _ = try flood.run("/usr/bin/yes", ["fixture"], timeout: 0.1) }
        assert(unrelated.isRunning && Date().timeIntervalSince(beforeFlood) < 3)
        let overflow = SimulatorPreparationTask()
        fails("목록 응답이 너무 큽니다") { _ = try overflow.run("/bin/sh", ["-c", "head -c 9000000 /dev/zero"], timeout: 10, stream: false) }
        assert(SimulatorPreparationError("취소", kind: .cancelled).agentText(command: "Sensor replay staging") == "Sensor replay staging was cancelled.")
        assert(SimulatorPreparationError("초과", kind: .timedOut).agentText(command: "Sensor replay staging") == "Sensor replay staging timed out.")
        let childFailed = SimulatorPreparationError("명령이 완료되지 않았습니다", kind: .failed, status: 1, standardError: "  Sensor replay: Expected version 1. \n")
        assert(childFailed.agentText(command: "Sensor replay staging", prefix: "Sensor replay: ") == "Expected version 1.")
        let silentFailed = SimulatorPreparationError("명령이 완료되지 않았습니다", kind: .failed, status: 2, standardError: " \n ")
        assert(silentFailed.agentText(command: "Sensor replay staging", prefix: "Sensor replay: ") == "Sensor replay staging failed (exit status 2).")
        print("PASS preparation task: argument boundaries, stdout/stderr separation, environment filtering, bounded output, spawn/exit errors, preflight/in-flight cancellation, ignored TERM, descendants, timeout and unrelated process survival")
    }
}
