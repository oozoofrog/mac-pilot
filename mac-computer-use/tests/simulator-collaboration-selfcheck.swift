// Offline checks of SimulatorCollaboration.swift and its daemon side: the files are in a temporary folder, and no
// simulator, process list or record of this Mac is read.
// swiftc -parse-as-library SimulatorCollaboration.swift SimulatorCollaborationHost.swift simulator-collaboration-selfcheck.swift -o check && ./check

import Foundation

@main struct SimulatorCollaborationSelfcheck {
    static func main() {
        var count = 0
        func expect(_ condition: @autoclosure () -> Bool, _ message: String, line: UInt = #line) {
            count += 1
            if !condition() { print("FAIL line \(line): \(message)"); exit(1) }
        }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("mac-cu-collaboration-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        func later(_ minutes: Double) -> Date { now.addingTimeInterval(minutes * 60) }

        // Who a session is.
        let project = folder.appendingPathComponent("Cards/Sources/App")
        try? FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: folder.appendingPathComponent("Cards/.git"), withIntermediateDirectories: true)
        let claude = AgentIdentity.detect(environment: ["CLAUDECODE": "1", "CLAUDE_CODE_SESSION_ID": "s-claude", "CLAUDE_PID": "4242",
                                                       "T3CODE_THREAD_ID": "thread-1"], directory: project.path, parent: 7)
        expect(claude == AgentIdentity(agent: "Claude Code", session: "s-claude", project: "Cards", thread: "thread-1", pid: 4242), "Claude Code in T3: \(claude)")
        expect(claude.label == "Claude Code · Cards", "label")
        let host = AgentIdentity.detect(environment: ["CLAUDE_CODE_HOST_SESSION_ID": "host", "CLAUDE_CODE_SESSION_ID": "child"], directory: "/", parent: 7)
        expect(host.session == "host" && host.pid == 7 && host.project.isEmpty && host.label == "Claude Code", "the host session wins; the root is no project")
        let codex = AgentIdentity.detect(environment: ["CODEX_THREAD_ID": "s-codex", "CLAUDE_PROJECT_DIR": project.path], directory: "/", parent: 9)
        expect(codex.agent == "Codex" && codex.session == "s-codex" && codex.project == "Cards" && codex.pid == 9, "Codex: \(codex)")
        let plain = AgentIdentity.detect(environment: [:], directory: folder.appendingPathComponent("loose").path, parent: 11, fallbackAgent: "Ghostty")
        expect(plain.agent == "Ghostty" && plain.session == "pid 11" && plain.project == "loose", "no agent in the environment: \(plain)")
        expect(AgentIdentity.detect(environment: [:], directory: FileManager.default.homeDirectoryForCurrentUser.path, parent: 1).project.isEmpty, "the home folder is no project")
        expect(AgentIdentity(json: claude.json) == claude, "an identity survives JSON")
        expect(AgentIdentity(json: ["session": "", "pid": 3]) == nil && AgentIdentity(json: ["session": "x"]) == nil, "an identity needs a session and a process")

        // Records of sim-pilot 1.5 and earlier.
        let old = DeviceClaim(json: ["by": "old-session", "note": "PR 589 tests", "pid": 5, "since": "2026-11-18T23:03:00Z"])
        expect(old?.label == "PR 589 tests" && old?.who == "old-session" && old?.auto == false && old?.lastUsed == "2026-11-18T23:03:00Z", "an old record keeps its note")
        expect(DeviceClaim(json: ["by": "bare", "pid": 5])?.label == "bare", "an old record without a note shows its session")
        expect(DeviceClaim(json: ["note": "no owner"]) == nil, "a record needs a session and a process")
        let explicit = DeviceClaim(identity: claude, note: "로그인 확인", auto: false, now: now)
        expect(explicit.label == "Claude Code · Cards · 로그인 확인" && DeviceClaim(json: explicit.json) == explicit, "a new record names agent, project and note")

        // Which records count.
        let a = "AAAAAAAA-0000-0000-0000-000000000001", b = "BBBBBBBB-0000-0000-0000-000000000002"
        var auto = DeviceClaim(identity: codex, note: "", auto: true, now: now)
        let alive: (Int32) -> Bool = { $0 != 99 }
        expect(liveClaims([a: explicit, b: auto], booted: [a], alive: alive, now: now).keys.sorted() == [a], "a device that is off has no record")
        expect(liveClaims([a: explicit, b: auto], booted: nil, alive: alive, now: later(29)).count == 2, "an automatic record lasts while used lately")
        expect(liveClaims([a: explicit, b: auto], booted: nil, alive: alive, now: later(31)).keys.sorted() == [a], "an automatic record lapses; a claim does not")
        auto.pid = 99
        expect(liveClaims([b: auto], booted: nil, alive: alive, now: now).isEmpty, "a record of an ended session is dropped")
        auto.pid = codex.pid

        // Use through mac-cu.
        var claims: [String: DeviceClaim] = [:]
        var use = recordSimulatorUse(&claims, udid: a.lowercased(), identity: codex, now: now)
        expect(use.holder == nil && use.changed && claims[a]?.auto == true && claims[a]?.by == "s-codex", "input to a free device records the session")
        use = recordSimulatorUse(&claims, udid: a, identity: codex, now: now.addingTimeInterval(30))
        expect(use.holder == nil && !use.changed, "the time is not rewritten within a minute")
        use = recordSimulatorUse(&claims, udid: a, identity: codex, now: later(5))
        expect(use.changed && claims[a]?.lastUsed == collaborationStamp(later(5)) && claims[a]?.since == collaborationStamp(now), "later input moves the last use, not the start")
        use = recordSimulatorUse(&claims, udid: a, identity: claude, now: later(6))
        expect(use.holder?.by == "s-codex" && !use.changed && claims[a]?.by == "s-codex", "input to another session's device changes nothing and names the holder")

        var renamed = codex
        renamed.session = "s-codex-after-clear"
        use = recordSimulatorUse(&claims, udid: a, identity: renamed, now: later(7))
        expect(use.holder == nil, "the same process under a new session id is the same session")
        expect(claude.isSame(AgentIdentity(agent: "Claude Code", session: "other-id", pid: claude.pid)) && !claude.isSame(codex), "sessions match by id or process")

        // Requests.
        let request = DeviceRequest(udid: a.lowercased(), from: claude, note: "스크린샷 한 장", now: now)
        expect(request.udid == a && DeviceRequest(json: request.json) == request && request.label == "Claude Code · Cards · 스크린샷 한 장", "a request survives JSON")
        expect(liveRequests([request], claims: claims, alive: alive, now: later(29)).count == 1, "a request lasts while the device is held")
        expect(liveRequests([request], claims: claims, alive: alive, now: later(31)).isEmpty, "a request lapses")
        expect(liveRequests([request], claims: [:], alive: alive, now: now).isEmpty, "a request for a free device is over")
        expect(liveRequests([request], claims: [a: explicit], alive: alive, now: now).isEmpty, "a request is over when the requester holds the device")
        expect(liveRequests([request], claims: claims, alive: { _ in false }, now: now).isEmpty, "a request of an ended session is dropped")

        // The files.
        let store = CollaborationStore(folder: folder.appendingPathComponent("state"))
        expect(store.state().claims.isEmpty && store.state().requests.isEmpty && store.sessions().isEmpty, "no files: nothing")
        let self1 = AgentIdentity(agent: "Claude Code", session: "one", project: "Cards", pid: getpid())
        let self2 = AgentIdentity(agent: "Codex", session: "two", project: "Pressleaf", pid: getppid())  // another process that runs
        store.update(now: now) { claims, _ in claims[a] = DeviceClaim(identity: self1, note: "빌드 확인", auto: false, now: now) }
        store.update(now: now) { _, requests in requests.append(DeviceRequest(udid: a, from: self2, note: "", now: now)) }
        var state = store.state(now: now)
        expect(state.claims[a]?.label == "Claude Code · Cards · 빌드 확인" && state.requests.map(\.from.session) == ["two"], "claims and requests are stored")
        let text = (try? String(contentsOf: store.folder.appendingPathComponent("claims.json"), encoding: .utf8)) ?? ""
        expect(["\"by\"", "\"note\"", "\"pid\"", "\"since\""].allSatisfy(text.contains), "claims.json keeps the fields that sim-pilot 1.5 reads")
        store.update(now: now) { claims, requests in claims[a] = DeviceClaim(identity: requests[0].from, note: "", auto: false, now: now) }
        state = store.state(now: now)
        expect(state.claims[a]?.by == "two" && state.requests.isEmpty, "handing the device to the requester ends its request")
        try? Data("not json".utf8).write(to: store.folder.appendingPathComponent("claims.json"))
        expect(store.state().claims.isEmpty, "a broken file reads as no records")

        // Sessions.
        expect(store.sessions(seen: self1, via: "mac-cu", now: now)["one"]?["via"] as? [String] == ["mac-cu"], "a session is noted")
        let stamp = store.sessions(seen: self1, via: "mac-cu", now: now.addingTimeInterval(30))["one"]?["lastSeen"] as? String
        expect(stamp == collaborationStamp(now), "the time is not rewritten within a minute")
        let both = store.sessions(seen: self1, via: "sim-pilot", now: now.addingTimeInterval(40))["one"]
        expect(both?["via"] as? [String] == ["mac-cu", "sim-pilot"] && both?["firstSeen"] as? String == collaborationStamp(now), "a second tool is added at once")
        let cleared = store.sessions(seen: AgentIdentity(agent: "Claude Code", session: "one-after-clear", project: "Cards", pid: getpid()), via: "sim-pilot", now: later(5))
        expect(cleared.count == 1 && cleared["one"]?["session"] as? String == "one-after-clear", "a session that got a new id stays one record: \(cleared)")
        expect(store.sessions(seen: AgentIdentity(agent: "Codex", session: "gone", pid: 1), via: "mac-cu", alive: { $0 != 1 })["gone"] != nil
               && store.sessions(alive: { $0 != 1 })["gone"] == nil, "an ended session is dropped at the next read")

        // What the daemon tells a session.
        let host2 = CollaborationStore(folder: folder.appendingPathComponent("daemon"))
        expect(simulatorCollaborationNotice(udid: a, name: "iPhone", mutates: false, identity: self1, store: host2, now: now) == nil
               && host2.state(now: now).claims.isEmpty, "reading a device records nothing")
        expect(simulatorCollaborationNotice(udid: a, name: "iPhone", mutates: true, identity: self1, store: host2, now: now) == nil
               && host2.state(now: now).claims[a]?.auto == true, "input records an automatic claim and needs no notice")
        let held = simulatorCollaborationNotice(udid: a, name: "iPhone", mutates: true, identity: self2, store: host2, now: now)
        expect(held?.contains("in use by another agent session (Claude Code · Cards") == true && held?.contains("sim-pilot request --udid \(a)") == true, "input to a held device: \(held ?? "nil")")
        expect(simulatorCollaborationNotice(udid: a, name: "iPhone", mutates: true, identity: self2, store: host2, now: now.addingTimeInterval(10)) == nil, "the same notice is not repeated at once")
        expect(simulatorCollaborationNotice(udid: a, name: "iPhone", mutates: true, identity: self2, store: host2, now: later(3)) != nil, "and comes again later")
        host2.update(now: now) { _, requests in requests.append(DeviceRequest(udid: a, from: self2, note: "곧 필요", now: now)) }
        let wanted = simulatorCollaborationNotice(udid: a, name: "iPhone", mutates: false, identity: self1, store: host2, now: now)
        expect(wanted?.contains("Codex · Pressleaf · 곧 필요 (session two)") == true && wanted?.contains("release --udid \(a)") == true, "the holder learns who waits: \(wanted ?? "nil")")
        let lines = simulatorCollaborationLines(udids: [a.lowercased(), b], identity: self1, store: host2)
        expect(lines[a] == "used by this session; waited for by Codex · Pressleaf · 곧 필요" && lines[b] == nil, "list lines: \(lines)")
        expect(simulatorCollaborationLines(udids: [a], identity: self2, store: host2)[a]?.hasPrefix("used by Claude Code · Cards") == true, "another session sees the holder")
        expect(simulatorClaimByAnother(udid: b, identity: self2, store: host2, now: now) == nil, "free simulator has no other holder")
        expect(simulatorClaimByAnother(udid: a, identity: self1, store: host2, now: now) == nil, "own simulator claim is allowed")
        expect(simulatorClaimByAnother(udid: a, identity: AgentIdentity(agent: "Claude Code", session: "rotated", pid: self1.pid), store: host2, now: now) == nil,
               "same process under rotated session id still owns claim")
        expect(simulatorClaimByAnother(udid: a, identity: self2, store: host2, now: now)?.by == "one", "other session claim blocks sensor staging")
        expect(simulatorClaimByAnother(udid: a, identity: nil, store: host2, now: now)?.by == "one", "anonymous caller cannot bypass an active claim")
        expect(agentIdentity(hello: ["identity": self1.json], agent: "T3 Code", peer: 5) == self1, "the hello's identity is used")
        expect(agentIdentity(hello: [:], agent: "T3 Code", peer: 5, parent: { _ in 40 }) == AgentIdentity(agent: "T3 Code", session: "pid 40", pid: 40), "an older client is known by the agent process that started it")
        expect(agentIdentity(hello: [:], agent: "T3 Code", peer: 5, parent: { _ in 1 }).pid == 5, "or by its own process when launchd started it")
        expect(parentProcess(of: getpid()) == getppid(), "the parent of a process")

        print("PASS \(count) simulator collaboration assertions; no simulator, process or record of this Mac touched")
    }
}
