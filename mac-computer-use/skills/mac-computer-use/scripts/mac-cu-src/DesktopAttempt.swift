import AppKit
import ApplicationServices
import CryptoKit

// Accessed on the daemon's serial request queue. The underlying AX element map is shared by PID.
private struct DesktopSnapshot {
    let owner: UUID
    let session: Session
    let window: AXUIElement?
    let revision: UUID
    let bounds: CGRect?
    let scale: CGFloat
}

struct DesktopAttempt {
    fileprivate let token = UUID().uuidString
    fileprivate let issued = ProcessInfo.processInfo.systemUptime
    fileprivate let owner: UUID
    fileprivate let session: Session
    fileprivate let window: AXUIElement?
    fileprivate let controls: [AXUIElement]
    fileprivate let operation: SHA256.Digest
    fileprivate var observed = false

    func matches(window candidate: AXUIElement?) -> Bool { window == candidate }
}

private var desktopSnapshots: [pid_t: DesktopSnapshot] = [:]
private var desktopAttempts: [pid_t: DesktopAttempt] = [:]

private func usesCoordinates(_ action: [String: Any]) -> Bool {
    ["click_at", "drag"].contains(action["type"] as? String ?? "")
}

func desktopCheckSnapshot(_ client: AgentSession, _ session: Session, _ actions: [[String: Any]]) throws {
    guard actions.contains(where: { $0["element"] != nil || usesCoordinates($0) }) else { return }
    guard let snapshot = desktopSnapshots[session.pid], snapshot.owner == client.activityID,
          snapshot.session === session, !session.app.isTerminated, snapshot.window == frontWindow(of: session),
          snapshot.revision == session.stateRevision else {
        throw ToolError("The target snapshot changed. Call get_app_state and use its current targets.")
    }
    for action in actions where action["element"] != nil {
        guard let index = action["element"] as? Int, session.elements.indices.contains(index) else {
            throw ToolError("An element number is outside the current snapshot. Call get_app_state before sending input.")
        }
    }
    if actions.contains(where: usesCoordinates),
       snapshot.bounds == nil || snapshot.scale != session.screenshotScale || snapshot.bounds != snapshot.window.flatMap(frame) {
        throw ToolError("The target window geometry changed. Read its screenshot again before using coordinates.")
    }
}

func desktopRecordSnapshot(_ client: AgentSession, _ session: Session, observed: Bool) {
    let window = session.stateWindow
    guard window == frontWindow(of: session) else {
        desktopSnapshots.removeValue(forKey: session.pid)
        return
    }
    desktopSnapshots[session.pid] = DesktopSnapshot(owner: client.activityID, session: session, window: window,
        revision: session.stateRevision, bounds: session.stateBounds, scale: session.screenshotScale)
    if observed, let attempt = desktopAttempts[session.pid], attempt.owner == client.activityID,
       attempt.session === session, attempt.window == window {
        desktopAttempts[session.pid]?.observed = true
    }
}

private func hitControl(_ session: Session, _ bounds: CGRect, _ action: [String: Any], x: String, y: String) -> AXUIElement? {
    guard let px = action[x] as? NSNumber, let py = action[y] as? NSNumber, session.screenshotScale > 0 else { return nil }
    let point = CGPoint(x: bounds.minX + px.doubleValue / session.screenshotScale,
                        y: bounds.minY + py.doubleValue / session.screenshotScale)
    guard bounds.contains(point) else { return nil }
    var hit: AXUIElement?
    guard AXUIElementCopyElementAtPosition(session.root, Float(point.x), Float(point.y), &hit) == .success else { return nil }
    return hit
}

private func belongsToWindow(_ control: AXUIElement, _ window: AXUIElement) -> Bool {
    var current: AXUIElement? = control
    for _ in 0..<maxDepth {
        guard let node = current else { return false }
        if node == window || element(attribute(node, kAXWindowAttribute)) == window { return true }
        current = element(attribute(node, kAXParentAttribute))
    }
    return false
}

func desktopPrepareAttempt(_ client: AgentSession, _ session: Session, _ actions: [[String: Any]]) -> DesktopAttempt? {
    guard actions.count == 1, var action = actions.first, let kind = action["type"] as? String,
          !session.app.isTerminated, (try? desktopCheckSnapshot(client, session, actions)) != nil else { return nil }
    let window = frontWindow(of: session)
    var controls: [AXUIElement]
    switch kind {
    case "click", "set_value", "select_text", "scroll", "perform":
        guard let index = action.removeValue(forKey: "element") as? Int, session.elements.indices.contains(index) else { return nil }
        let control = session.elements[index]
        guard flag(control, kAXEnabledAttribute) != false,
              statusItems(of: session).contains(control) || window.map({ belongsToWindow(control, $0) }) == true else { return nil }
        controls = [control]
    case "press_key", "type_text":
        guard let window, let focused = element(attribute(session.root, kAXFocusedUIElementAttribute)),
              belongsToWindow(focused, window) else { return nil }
        controls = [focused]
    case "click_at", "drag":
        guard let window, let bounds = frame(window), let hit = hitControl(session, bounds, action, x: "x", y: "y"),
              belongsToWindow(hit, window) else { return nil }
        controls = [hit]
        if kind == "drag" {
            guard let end = hitControl(session, bounds, action, x: "to_x", y: "to_y"), belongsToWindow(end, window) else { return nil }
            controls.append(end)
        }
    case "menu":
        guard window != nil, let path = action["path"] as? [String], !path.isEmpty,
              var item = element(attribute(session.root, kAXMenuBarAttribute)) else { return nil }
        for title in path {
            guard let next = menuItems(item).first(where: { string($0, kAXTitleAttribute)?.lowercased() == title.lowercased() }) else { return nil }
            item = next
        }
        controls = [item]
    default: return nil
    }
    guard let data = try? JSONSerialization.data(withJSONObject: action, options: [.sortedKeys]) else { return nil }
    return DesktopAttempt(owner: client.activityID, session: session, window: window, controls: controls,
                          operation: SHA256.hash(data: data))
}

func desktopPublishAttempt(_ attempt: DesktopAttempt?) -> String? {
    guard let attempt, !attempt.session.app.isTerminated,
          ProcessInfo.processInfo.systemUptime - attempt.issued < 30 else { return nil }
    desktopAttempts[attempt.session.pid] = attempt
    return attempt.token
}

func desktopConsumeAttempt(_ client: AgentSession, _ session: Session, _ actions: [[String: Any]],
                           receipt: String?, expected: String?, observed: String?) throws -> DesktopAttempt {
    guard let attempt = desktopAttempts[session.pid], attempt.owner == client.activityID, attempt.session === session,
          attempt.token == receipt, ProcessInfo.processInfo.systemUptime - attempt.issued < 30 else {
        throw ToolError("Auto mode needs a current background receipt for this operation. Try one action in the background and inspect its result.")
    }
    guard attempt.observed, let expected = expected?.trimmingCharacters(in: .whitespacesAndNewlines), !expected.isEmpty,
          let observed = observed?.trimmingCharacters(in: .whitespacesAndNewlines), !observed.isEmpty, expected != observed else {
        throw ToolError("Read the same window with get_app_state. Describe the expected result and the different observed result before requesting foreground.")
    }
    guard let retry = desktopPrepareAttempt(client, session, actions), retry.window == attempt.window,
          retry.controls == attempt.controls, retry.operation == attempt.operation else {
        throw ToolError("The target or action differs from the background attempt. Read the window and reconcile its current state.")
    }
    desktopAttempts.removeValue(forKey: session.pid)
    return attempt
}

func desktopInvalidateAttempts(_ session: Session) {
    desktopAttempts.removeValue(forKey: session.pid)
    desktopSnapshots.removeValue(forKey: session.pid)
}

func desktopForgetAttempts(_ client: AgentSession) {
    desktopAttempts = desktopAttempts.filter { $0.value.owner != client.activityID }
    desktopSnapshots = desktopSnapshots.filter { $0.value.owner != client.activityID }
}
