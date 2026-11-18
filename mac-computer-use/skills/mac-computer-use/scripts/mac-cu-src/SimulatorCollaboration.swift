// Which agent session uses which simulator, and how sessions ask each other for one. mac-cu (the daemon) and
// sim-pilot (the command) read and write the same three files in ~/Library/Application Support/sim-pilot:
// claims.json (device → the session that uses it), requests.json (a session that waits for a device another one
// holds) and sessions.json (the sessions that used mac-cu or sim-pilot). The text between BEGIN and END is the same in
// simulator-pilot's sim-pilot.swift; scripts/tests/test_simulator_budget_core.py compares the two copies.

import Foundation

// BEGIN simulator-collab-core

/// Who an agent session is: recorded with each device it uses, so that other sessions and the person see which agent
/// of which project holds a simulator.
struct AgentIdentity: Equatable {
    /// "Claude Code", "Codex", or the app that runs the agent.
    var agent: String
    /// The agent's own session id, or "pid N" when the environment gives none.
    var session: String
    /// The folder name of the project, "" when unknown.
    var project: String
    /// The T3 thread, "" outside T3.
    var thread: String
    /// The process of the session: while it runs, its records count.
    var pid: Int32

    var label: String { project.isEmpty ? agent : "\(agent) · \(project)" }
    /// The same session: by its id, or by its process. An agent can give a new id to a session that goes on (after
    /// its context is cleared), and tools it started earlier still carry the old one.
    func isSame(_ other: AgentIdentity) -> Bool { other.session == session || other.pid == pid }
    func owns(_ claim: DeviceClaim) -> Bool { claim.by == session || claim.pid == pid }
    var json: [String: Any] { ["agent": agent, "session": session, "project": project, "thread": thread, "pid": Int(pid)] }

    init(agent: String, session: String, project: String = "", thread: String = "", pid: Int32) {
        self.agent = agent; self.session = session; self.project = project; self.thread = thread; self.pid = pid
    }

    init?(json: [String: Any]) {
        guard let session = json["session"] as? String, !session.isEmpty,
              let pid = (json["pid"] as? NSNumber)?.int32Value, pid > 0 else { return nil }
        self.init(agent: json["agent"] as? String ?? "?", session: session, project: json["project"] as? String ?? "",
                  thread: json["thread"] as? String ?? "", pid: pid)
    }

    /// From the environment of a process that the agent started. `parent`: the process that started it.
    /// `fallbackAgent`: the app that runs the agent, when the environment names no agent.
    static func detect(environment env: [String: String], directory: String, parent: Int32, fallbackAgent: String? = nil) -> AgentIdentity {
        let claude = env["CLAUDECODE"] != nil || env.keys.contains { $0.hasPrefix("CLAUDE_CODE_") }
        let codex = env.keys.contains { $0.hasPrefix("CODEX_") }
        let session = ["CLAUDE_CODE_HOST_SESSION_ID", "CLAUDE_CODE_SESSION_ID", "CODEX_SESSION_ID", "CODEX_THREAD_ID"]
            .lazy.compactMap { env[$0] }.first { !$0.isEmpty } ?? "pid \(parent)"
        return AgentIdentity(agent: claude ? "Claude Code" : codex ? "Codex" : fallbackAgent ?? "terminal", session: session,
                             project: collaborationProjectName(env["CLAUDE_PROJECT_DIR"] ?? directory),
                             thread: env["T3CODE_THREAD_ID"] ?? "", pid: Int32(env["CLAUDE_PID"] ?? "") ?? parent)
    }
}

/// The project a folder belongs to: the name of the nearest folder with .git at or above it, else of the folder.
/// "" for the home folder and the root, which are not projects.
func collaborationProjectName(_ directory: String) -> String {
    let start = URL(fileURLWithPath: directory).standardizedFileURL
    let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
    var url = start
    for _ in 0..<32 where url.path != "/" && url.path != home {
        if FileManager.default.fileExists(atPath: url.appendingPathComponent(".git").path) { return url.lastPathComponent }
        url = url.deletingLastPathComponent()
    }
    return start.path == "/" || start.path == home ? "" : start.lastPathComponent
}

func collaborationStamp(_ date: Date) -> String { ISO8601DateFormatter().string(from: date) }
func collaborationDate(_ text: String) -> Date? { ISO8601DateFormatter().date(from: text) }
func collaborationProcessAlive(_ pid: Int32) -> Bool { pid > 0 && (kill(pid, 0) == 0 || errno == EPERM) }

/// One record of claims.json. The first four fields are the format of sim-pilot 1.5 and earlier.
struct DeviceClaim: Equatable {
    var by: String
    var note: String
    var pid: Int32
    var since: String
    var agent = ""
    var project = ""
    var thread = ""
    /// mac-cu wrote it when the session sent input to the device, without `sim-pilot claim`: it lapses when unused.
    var auto = false
    var lastUsed = ""

    init(identity: AgentIdentity, note: String, auto: Bool, now: Date) {
        by = identity.session; self.note = note; pid = identity.pid; since = collaborationStamp(now)
        agent = identity.agent; project = identity.project; thread = identity.thread; self.auto = auto; lastUsed = since
    }

    init?(json: [String: Any]) {
        guard let by = json["by"] as? String, let pid = (json["pid"] as? NSNumber)?.int32Value else { return nil }
        self.by = by; self.pid = pid
        note = json["note"] as? String ?? ""; since = json["since"] as? String ?? ""
        agent = json["agent"] as? String ?? ""; project = json["project"] as? String ?? ""; thread = json["thread"] as? String ?? ""
        auto = json["auto"] as? Bool ?? false; lastUsed = json["lastUsed"] as? String ?? since
    }

    var json: [String: Any] {
        ["by": by, "note": note, "pid": Int(pid), "since": since, "agent": agent, "project": project, "thread": thread,
         "auto": auto, "lastUsed": lastUsed]
    }

    /// The agent and project, or the session id of a record without them.
    var who: String { agent.isEmpty ? by : project.isEmpty ? agent : "\(agent) · \(project)" }
    /// "Claude Code · Cards · 로그인 확인"; a record of an older sim-pilot shows its note, else its session id.
    var label: String { note.isEmpty ? who : agent.isEmpty ? note : "\(who) · \(note)" }
}

/// A session that waits for a device another session holds.
struct DeviceRequest: Equatable {
    var udid: String
    var from: AgentIdentity
    var note: String
    var at: String
    /// The holder's answer when it refused, "" while it has not.
    var declined = ""

    init(udid: String, from: AgentIdentity, note: String, now: Date) {
        self.udid = udid.uppercased(); self.from = from; self.note = note; at = collaborationStamp(now)
    }

    init?(json: [String: Any]) {
        guard let udid = json["udid"] as? String, let from = (json["from"] as? [String: Any]).flatMap(AgentIdentity.init(json:)) else { return nil }
        self.udid = udid.uppercased(); self.from = from
        note = json["note"] as? String ?? ""; at = json["at"] as? String ?? ""
        declined = json["declined"] as? String ?? ""
    }

    var json: [String: Any] { ["udid": udid, "from": from.json, "note": note, "at": at, "declined": declined] }
    var label: String { note.isEmpty ? from.label : "\(from.label) · \(note)" }
}

/// A claim that mac-cu wrote lapses this long after the session's last input.
let collaborationAutoClaimIdle: TimeInterval = 30 * 60
/// A request lapses this long after it was made.
let collaborationRequestLifetime: TimeInterval = 30 * 60
/// Times in the files are rewritten at most this often.
let collaborationTouchInterval: TimeInterval = 60

/// The claims that still count: of a running session, of a booted device (`booted` nil: not checked), and used
/// lately when mac-cu wrote them.
func liveClaims(_ all: [String: DeviceClaim], booted: Set<String>?, alive: (Int32) -> Bool, now: Date) -> [String: DeviceClaim] {
    all.filter { udid, claim in
        if let booted, !booted.contains(udid) { return false }
        if claim.auto, let used = collaborationDate(claim.lastUsed), now.timeIntervalSince(used) > collaborationAutoClaimIdle { return false }
        return alive(claim.pid)
    }
}

/// The requests that still count: the requester runs, it asked lately, and another session still holds the device.
func liveRequests(_ all: [DeviceRequest], claims: [String: DeviceClaim], alive: (Int32) -> Bool, now: Date) -> [DeviceRequest] {
    all.filter { request in
        guard alive(request.from.pid), let holder = claims[request.udid], !request.from.owns(holder) else { return false }
        guard let asked = collaborationDate(request.at) else { return false }
        return now.timeIntervalSince(asked) <= collaborationRequestLifetime
    }
}

/// A session sent input to a device. Without a claim the device becomes the session's (an automatic claim); its own
/// claim gets the time. Returns the other session that holds the device, when one does, and whether `claims` changed.
func recordSimulatorUse(_ claims: inout [String: DeviceClaim], udid: String, identity: AgentIdentity, now: Date) -> (holder: DeviceClaim?, changed: Bool) {
    let key = udid.uppercased()
    guard var claim = claims[key] else {
        claims[key] = DeviceClaim(identity: identity, note: "", auto: true, now: now)
        return (nil, true)
    }
    guard identity.owns(claim) else { return (claim, false) }
    if let used = collaborationDate(claim.lastUsed), now.timeIntervalSince(used) < collaborationTouchInterval { return (nil, false) }
    claim.lastUsed = collaborationStamp(now)
    claims[key] = claim
    return (nil, true)
}

/// Notes that a session used mac-cu or sim-pilot (`via`). True when `sessions` changed. A session is one record,
/// under the id it was first seen with; `session` in the record is the id it gave last.
func touchSession(_ sessions: inout [String: [String: Any]], identity: AgentIdentity, via: String, now: Date) -> Bool {
    let key = sessions[identity.session] != nil ? identity.session
        : sessions.first { ($0.value["pid"] as? NSNumber)?.int32Value == identity.pid }?.key ?? identity.session
    var entry = sessions[key] ?? ["firstSeen": collaborationStamp(now)]
    var tools = entry["via"] as? [String] ?? []
    if tools.contains(via), let seen = (entry["lastSeen"] as? String).flatMap(collaborationDate),
       now.timeIntervalSince(seen) < collaborationTouchInterval { return false }
    if !tools.contains(via) { tools.append(via) }
    entry.merge(identity.json) { _, new in new }
    entry["via"] = tools.sorted()
    entry["lastSeen"] = collaborationStamp(now)
    sessions[key] = entry
    return true
}

/// The three files and their lock.
struct CollaborationStore {
    let folder: URL

    /// ~/Library/Application Support/sim-pilot, or SIM_PILOT_STATE_DIR (the checks).
    static var standard: CollaborationStore {
        if let path = ProcessInfo.processInfo.environment["SIM_PILOT_STATE_DIR"], !path.isEmpty { return CollaborationStore(folder: URL(fileURLWithPath: path)) }
        return CollaborationStore(folder: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/sim-pilot"))
    }

    private func read(_ name: String) -> Any? {
        (try? Data(contentsOf: folder.appendingPathComponent(name))).flatMap { try? JSONSerialization.jsonObject(with: $0) }
    }

    private func write(_ name: String, _ object: Any) {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]) else { return }
        try? data.write(to: folder.appendingPathComponent(name), options: .atomic)
    }

    /// One reader-writer at a time, across mac-cu and sim-pilot.
    func locked<T>(_ body: () throws -> T) rethrows -> T {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let descriptor = open(folder.appendingPathComponent("state.lock").path, O_CREAT | O_RDWR, 0o644)
        guard descriptor >= 0 else { return try body() }
        defer { flock(descriptor, LOCK_UN); close(descriptor) }
        flock(descriptor, LOCK_EX)
        return try body()
    }

    private func storedClaims() -> [String: DeviceClaim] {
        var claims: [String: DeviceClaim] = [:]
        for (udid, value) in read("claims.json") as? [String: [String: Any]] ?? [:] { claims[udid.uppercased()] = DeviceClaim(json: value) }
        return claims
    }

    private func storedRequests() -> [DeviceRequest] { (read("requests.json") as? [[String: Any]] ?? []).compactMap(DeviceRequest.init(json:)) }

    /// Reads the live claims and requests, lets `body` change them, and writes what changed.
    func update<T>(booted: Set<String>? = nil, now: Date = Date(), alive: (Int32) -> Bool = collaborationProcessAlive,
                   _ body: (inout [String: DeviceClaim], inout [DeviceRequest]) throws -> T) rethrows -> T {
        try locked {
            let oldClaims = storedClaims(), oldRequests = storedRequests()
            var claims = liveClaims(oldClaims, booted: booted, alive: alive, now: now)
            var requests = liveRequests(oldRequests, claims: claims, alive: alive, now: now)
            let result = try body(&claims, &requests)
            requests = liveRequests(requests, claims: claims, alive: alive, now: now)
            if claims != oldClaims { write("claims.json", claims.mapValues(\.json)) }
            if requests != oldRequests { write("requests.json", requests.map(\.json)) }
            return result
        }
    }

    func state(booted: Set<String>? = nil, now: Date = Date()) -> (claims: [String: DeviceClaim], requests: [DeviceRequest]) {
        update(booted: booted, now: now) { claims, requests in (claims, requests) }
    }

    /// The sessions that still run, after noting `identity` (nil: only read).
    @discardableResult
    func sessions(seen identity: AgentIdentity? = nil, via: String = "", now: Date = Date(),
                  alive: (Int32) -> Bool = collaborationProcessAlive) -> [String: [String: Any]] {
        locked {
            let stored = read("sessions.json") as? [String: [String: Any]] ?? [:]
            var sessions = stored.filter { alive(($0.value["pid"] as? NSNumber)?.int32Value ?? 0) }
            var changed = sessions.count != stored.count
            if let identity, touchSession(&sessions, identity: identity, via: via, now: now) { changed = true }
            if changed { write("sessions.json", sessions) }
            return sessions
        }
    }
}

// END simulator-collab-core
