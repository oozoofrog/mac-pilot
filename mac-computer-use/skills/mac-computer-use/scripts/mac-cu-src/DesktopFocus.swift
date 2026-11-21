import AppKit

private func focusedWindow(_ root: AXUIElement) -> AXUIElement? {
    element(attribute(root, kAXFocusedWindowAttribute))
}

private func descendsFrom(_ node: AXUIElement?, _ ancestor: AXUIElement) -> Bool {
    var candidate = node
    for _ in 0..<32 {
        guard let current = candidate else { break }
        if current == ancestor { return true }
        candidate = element(attribute(current, kAXParentAttribute))
    }
    return false
}

// handleQueue serializes acquisition, input, deadlines and release. Observers only invalidate.
final class DesktopFocus {
    let owner: AgentSession
    let session: Session
    let id: String?
    let previous: NSRunningApplication?
    let previousWindow: AXUIElement?
    let originalPointer = CGEvent(source: nil)?.location
    let target: AXUIElement?
    let statusItem: AXUIElement?
    private(set) var popover: AXUIElement?
    private let lock = NSLock()
    private var interruption: String?
    private var workspaceObserver: NSObjectProtocol?
    private var axObserver: AXObserver?
    private var observedWindow: AXUIElement?
    private(set) var deadline: DispatchTime?
    private var releases: [String: CGEvent] = [:]

    init(owner: AgentSession, session: Session, begin: Bool, action: [String: Any]?) throws {
        self.owner = owner
        self.session = session
        id = begin ? UUID().uuidString : nil
        previous = frontmostPID().flatMap(NSRunningApplication.init(processIdentifier:))
        previousWindow = previous.flatMap { focusedWindow(AXUIElementCreateApplication($0.processIdentifier)) }
        let item = (action?["element"] as? Int).flatMap { session.elements.indices.contains($0) ? session.elements[$0] : nil }
        statusItem = item.flatMap { statusItems(of: session).contains($0) ? $0 : nil }
        target = frontWindow(of: session)
        guard target != nil || statusItem != nil else { throw ToolError("Cannot identify the foreground target window.") }
    }

    private func invalidate(_ reason: String) {
        lock.lock()
        let newlyInterrupted = interruption == nil
        if newlyInterrupted { interruption = reason }
        lock.unlock()
        if newlyInterrupted {
            handleQueue.async { [weak self] in
                if let self, desktopHold === self { closeDesktopFocus(self, restore: false) }
            }
        }
    }

    var hasInterrupted: Bool {
        lock.lock(); defer { lock.unlock() }
        return interruption != nil
    }

    private var interruptionReason: String? {
        lock.lock(); defer { lock.unlock() }
        return interruption
    }

    func expectedWindow(_ window: AXUIElement?) -> Bool {
        if let target, let window {
            if descendsFrom(window, target) { return true }
            // AppKit also exposes an attached sheet from its hosting window.
            if string(window, kAXRoleAttribute) == kAXSheetRole, children(target).contains(window) { return true }
        }
        if let statusItem, let window {
            return descendsFrom(window, statusItem) || children(statusItem).contains(window)
        }
        return window == nil && statusItem != nil
    }

    private func windowChanged(_ reported: AXUIElement) {
        let role = string(reported, kAXRoleAttribute)
        let applicationEvent = role == kAXApplicationRole
        let current = applicationEvent ? focusedWindow(session.root) : reported
        if !expectedWindow(current) {
            invalidate("The focus notification identified a different window (role \(role ?? "unavailable")).")
        } else if applicationEvent, current == observedWindow, statusItem == nil {
            // An application-only notification does not identify the intermediate window.
            // A window-specific notification identifies it even when AppKit reports it twice.
            invalidate("The app reported an ambiguous return to its previous window.")
        }
        observedWindow = current
    }

    func watch() throws {
        // Install and remove observers on their delivery thread to protect their context lifetime.
        var installed = false
        DispatchQueue.main.sync {
            observedWindow = focusedWindow(session.root)
            workspaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
            ) { [weak self] note in
                guard let self, let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
                if app.processIdentifier != self.session.pid { self.invalidate("Another app became active.") }
            }
            var observer: AXObserver?
            guard AXObserverCreate(session.pid, { _, node, _, context in
                guard let context else { return }
                Unmanaged<DesktopFocus>.fromOpaque(context).takeUnretainedValue().windowChanged(node)
            }, &observer) == .success, let observer else { return }
            let result = AXObserverAddNotification(observer, session.root, kAXFocusedWindowChangedNotification as CFString,
                                                   Unmanaged.passUnretained(self).toOpaque())
            guard result == .success else { return }
            axObserver = observer
            CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
            installed = true
        }
        guard installed || (id == nil && statusItem != nil) else {
            throw ToolError("The app cannot report foreground window changes.")
        }
    }

    func validate(point: CGPoint? = nil) throws {
        guard !hasInterrupted, !session.app.isTerminated, frontmostPID() == session.pid,
              expectedWindow(focusedWindow(session.root)) else {
            let reason = interruptionReason ?? "The target app or focused window changed."
            invalidate(reason)
            throw ToolError("Foreground input stopped: " + reason)
        }
        if let deadline, deadline <= .now() { throw ToolError("The foreground chain expired.") }
        guard !owner.requestCancelled, modes()["input"] != "background" else {
            throw ToolError("Foreground input cancelled or disabled.")
        }
        if let point {
            var hit: AXUIElement?
            guard AXUIElementCopyElementAtPosition(AXUIElementCreateSystemWide(), Float(point.x), Float(point.y), &hit) == .success,
                  let hit, let window = element(attribute(hit, kAXWindowAttribute)) ?? element(attribute(hit, kAXTopLevelUIElementAttribute)),
                  expectedWindow(window) || (statusItem.map { descendsFrom(hit, $0) } ?? false) else {
                throw ToolError("The pointer position does not belong to the owned window.")
            }
        }
    }

    func post(_ event: CGEvent) throws {
        let key = event.type == .keyDown || event.type == .keyUp
        try validate(point: key ? nil : event.location)
        if key, focusedWindow(session.root) == nil {
            guard let statusItem, let popup = statusPopover(in: [statusItem]),
                  let focused = element(attribute(session.root, kAXFocusedUIElementAttribute)),
                  descendsFrom(focused, popup) else { throw ToolError("Cannot verify the focused keyboard destination.") }
        }
        let token = key ? "key-\(event.getIntegerValueField(.keyboardEventKeycode))"
            : "mouse-\(event.getIntegerValueField(.mouseEventButtonNumber))"
        let release: CGEventType?
        switch event.type {
        case .leftMouseDown: release = .leftMouseUp
        case .rightMouseDown: release = .rightMouseUp
        case .keyDown: release = .keyUp
        case .leftMouseUp, .rightMouseUp, .keyUp: release = nil; releases.removeValue(forKey: token)
        default: release = nil
        }
        if let release, let up = event.copy() { up.type = release; up.flags = []; releases[token] = up }
        event.post(tap: .cghidEventTap)
    }

    func finish(restore: Bool) -> Bool {
        DispatchQueue.main.sync {
            if let observer = workspaceObserver { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
            if let observer = axObserver { CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes) }
            workspaceObserver = nil
            axObserver = nil
        }
        // Release incomplete pairs at their original process without clicking a different front window.
        for event in releases.values { event.postToPid(session.pid) }
        releases.removeAll()
        guard restore, !hasInterrupted, frontmostPID() == session.pid, expectedWindow(focusedWindow(session.root)) else { return false }
        if let originalPointer { CGWarpMouseCursorPosition(originalPointer) }
        guard let previous, previous.processIdentifier != session.pid else { return true }
        guard !previous.isTerminated, let previousWindow,
              focusedWindow(AXUIElementCreateApplication(previous.processIdentifier)) == previousWindow else { return false }
        // One activation only. Repeated activation attempts could override intervening user input.
        _ = AXUIElementSetAttributeValue(AXUIElementCreateApplication(previous.processIdentifier), kAXFrontmostAttribute as CFString, kCFBooleanTrue)
        for _ in 0..<10 {
            let now = frontmostPID()
            if now == previous.processIdentifier { return focusedWindow(AXUIElementCreateApplication(previous.processIdentifier)) == previousWindow }
            if now != session.pid { break }
            usleep(20_000)
        }
        return false
    }

    func retainPopover(_ element: AXUIElement) {
        guard popover == nil else { return }
        popover = element
        checkPopoverPresence()
    }

    private func checkPopoverPresence() {
        handleQueue.asyncAfter(deadline: .now() + .milliseconds(300)) { [weak self] in
            guard let self, desktopHold === self, let item = self.statusItem else { return }
            guard self.popover == statusPopover(in: [item]) else {
                closeDesktopFocus(self, restore: false)
                return
            }
            do {
                try self.validate()
                self.checkPopoverPresence()
            } catch {
                closeDesktopFocus(self)
            }
        }
    }

    func renew() {
        let expiry = DispatchTime.now() + .seconds(30)
        deadline = expiry
        handleQueue.asyncAfter(deadline: expiry) { [weak self] in
            guard let self, desktopHold === self, self.deadline == expiry else { return }
            _ = closeDesktopFocus(self)
        }
    }
}

private(set) var desktopHold: DesktopFocus?
var realDesktopInput: DesktopFocus?

@discardableResult
func closeDesktopFocus(_ held: DesktopFocus, restore: Bool = true) -> Bool {
    guard desktopHold === held else { return false }
    desktopHold = nil
    if let id = held.id { held.owner.lastEndedDesktopChain = (id, held.session.app) }
    return held.finish(restore: restore)
}

func releaseDesktopFocus(owner: AgentSession) {
    if let held = desktopHold, held.owner === owner { closeDesktopFocus(held) }
}

private func discardExpiredFocus() {
    guard let held = desktopHold else { return }
    if held.hasInterrupted || held.session.app.isTerminated || (held.deadline.map { $0 <= .now() } ?? false) {
        closeDesktopFocus(held)
    }
}

func desktopFocusBusy(owner: AgentSession) -> Bool {
    discardExpiredFocus()
    return desktopHold != nil
}

func guardDesktopAct(_ chain: String?, session: Session, owner: AgentSession) throws {
    discardExpiredFocus()
    guard let held = desktopHold else {
        if let chain, chain != "begin" { throw ToolError("Unknown or expired foreground chain. Inspect state before starting again.") }
        return
    }
    guard held.owner === owner, held.session === session else { throw ToolError("Desktop focus is busy.") }
    guard chain == held.id, chain != nil || held.popover != nil else { throw ToolError("Supply the active foreground chain ID.") }
    do { try held.validate() } catch { closeDesktopFocus(held); throw error }
}

func observeDesktopChain(_ id: String, session: Session, owner: AgentSession) throws {
    guard id != "begin" else { throw ToolError("Observation needs an existing chain ID.") }
    try guardDesktopAct(id, session: session, owner: owner)
}

func endDesktopChain(_ id: String, owner: AgentSession, app: String) throws -> [String: Any] {
    let target = app.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    guard let held = desktopHold, held.id == id, held.owner === owner else {
        guard let last = owner.lastEndedDesktopChain, last.id == id, matches(last.app, target) else { throw ToolError("Unknown foreground chain for this app.") }
        return ["content": [["type": "text", "text": "Foreground chain already ended."]]]
    }
    guard matches(held.session.app, target) else { throw ToolError("The foreground chain belongs to a different app.") }
    let restored = closeDesktopFocus(held)
    return ["content": [["type": "text", "text": restored ? "Foreground chain ended." : "Foreground chain ended. Previous focus was not restored."]]]
}

func acquireDesktopFocus(session: Session, owner: AgentSession, chain: String?, action: [String: Any]?,
                         admission: DesktopAttempt?) throws -> DesktopFocus {
    try guardDesktopAct(chain, session: session, owner: owner)
    if let held = desktopHold { return held }
    let held = try DesktopFocus(owner: owner, session: session, begin: chain == "begin", action: action)
    if let admission, !admission.matches(window: held.target) {
        throw ToolError("The background attempt window changed. Inspect the current target before sending input.")
    }
    desktopHold = held
    do {
        if frontmostPID() != session.pid { bringToFront(session, window: held.target) }
        try held.validate()
        try held.watch()
        try held.validate()
        if held.id != nil { held.renew() }
    } catch {
        closeDesktopFocus(held)
        throw error
    }
    return held
}
