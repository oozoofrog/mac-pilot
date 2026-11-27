// The daemon's side of SimulatorCollaboration.swift: each connection is an agent session with an identity; input that
// a session sends to a simulator is recorded as its use of the device, and tool results carry a notice when another
// session holds the device or waits for it.

import Foundation

/// The identity a client sent with its hello. A client from before 1.33 sends none: its session is then the process
/// that started the client (the agent), which is also the process sim-pilot records for that session.
func agentIdentity(hello: [String: Any], agent: String, peer: Int32, parent: (Int32) -> Int32 = parentProcess) -> AgentIdentity {
    if let sent = (hello["identity"] as? [String: Any]).flatMap(AgentIdentity.init(json:)) { return sent }
    let started = parent(peer)
    let pid = started > 1 ? started : peer
    return AgentIdentity(agent: agent, session: "pid \(pid)", pid: pid)
}

/// The process that started a process, 0 when unknown.
func parentProcess(of pid: Int32) -> Int32 {
    var info = kinfo_proc(), size = MemoryLayout<kinfo_proc>.stride
    var name: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
    guard pid > 0, sysctl(&name, 4, &info, &size, nil, 0) == 0, size > 0 else { return 0 }
    return info.kp_eproc.e_ppid
}

/// The process at the other end of a local socket, 0 when unknown.
func peerProcess(of fd: Int32) -> Int32 {
    var pid: pid_t = 0
    var size = socklen_t(MemoryLayout<pid_t>.size)
    return getsockopt(fd, SOL_LOCAL, LOCAL_PEERPID, &pid, &size) == 0 ? pid : 0
}

/// When each notice was last given, by session, device and kind: a notice is not repeated on every call.
private var collaborationNoticeTimes: [String: Date] = [:]
private let collaborationNoticeLock = NSLock()
let collaborationNoticeInterval: TimeInterval = 120

private func noticeDue(_ key: String, now: Date) -> Bool {
    collaborationNoticeLock.lock(); defer { collaborationNoticeLock.unlock() }
    if let last = collaborationNoticeTimes[key], now.timeIntervalSince(last) < collaborationNoticeInterval { return false }
    collaborationNoticeTimes[key] = now
    return true
}

/// What a session should know after a simulator action, as English text for the agent, or nil. `mutates`: the action
/// sent input, so the device counts as used by this session when nobody else holds it.
func simulatorCollaborationNotice(udid: String, name: String, mutates: Bool, identity: AgentIdentity,
                                  store: CollaborationStore = .standard, now: Date = Date()) -> String? {
    let key = udid.uppercased()
    let (holder, waiting): (DeviceClaim?, [DeviceRequest]) = store.update(now: now) { claims, requests in
        var holder: DeviceClaim?
        if mutates { holder = recordSimulatorUse(&claims, udid: key, identity: identity, now: now).holder }
        let mine = claims[key].map(identity.owns) ?? false
        return (holder, mine ? requests.filter { $0.udid == key && $0.declined.isEmpty } : [])
    }
    if let holder, noticeDue("\(identity.session)|\(key)|held", now: now) {
        return "Notice: \(name) is in use by another agent session (\(holder.label), since \(holder.since)). Your input reached the same "
            + "device. Stop and ask the user, or ask that session for the device: sim-pilot request --udid \(key) --note \"<why>\"."
    }
    if !waiting.isEmpty, noticeDue("\(identity.session)|\(key)|wanted", now: now) {
        let who = waiting.map { "\($0.label) (session \($0.from.session))" }.joined(separator: "; ")
        return "Notice: another agent session waits for \(name): \(who). When you are done: sim-pilot release --udid \(key) "
            + "(add --to <session> to hand it over). To keep it: sim-pilot decline --udid \(key) --note \"<until when>\"."
    }
    return nil
}

/// Lines for the simulator tool's list action: who uses each booted device and who waits for it.
func simulatorCollaborationLines(udids: [String], identity: AgentIdentity?, store: CollaborationStore = .standard) -> [String: String] {
    let state = store.state()
    var lines: [String: String] = [:]
    for udid in udids.map({ $0.uppercased() }) {
        guard let claim = state.claims[udid] else { continue }
        var line = identity?.owns(claim) == true ? "used by this session" + (claim.note.isEmpty ? "" : " (\(claim.note))") : "used by \(claim.label)"
        let waiting = state.requests.filter { $0.udid == udid && $0.declined.isEmpty }.map(\.label)
        if !waiting.isEmpty { line += "; waited for by " + waiting.joined(separator: ", ") }
        lines[udid] = line
    }
    return lines
}

/// The claim of another session on a simulator, or nil when it is free or this session's. Staged sensor fixtures are
/// consumed by whichever app listens, so writing to a device another session holds would hand that session our data.
func simulatorClaimByAnother(udid: String, identity: AgentIdentity?, store: CollaborationStore = .standard,
                             now: Date = Date()) -> DeviceClaim? {
    guard let claim = store.state(now: now).claims[udid.uppercased()] else { return nil }
    return identity?.owns(claim) == true ? nil : claim
}
