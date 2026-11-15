// The accessibility tree of a booted iOS Simulator, for the simulator tool's describe and wait actions and
// for tap with target.
//
// Undocumented parts: AccessibilityPlatformTranslation (AXPTranslator) turns the simulator app's
// accessibility into Mac platform elements, and CoreSimulator's SimDevice
// sendAccessibilityRequestAsync:completionQueue:completionHandler: carries its requests to the simulator.
// The bridge delegate is the one of idb's FBSimulatorAccessibilityCommands (github.com/cameroncooke/idb).
// Frames come in points of the device screen, the same as the x and y of tap and swipe.

import AppKit

struct SimulatorElement {
    let role: String
    let label: String
    let identifier: String
    let value: String
    let frame: CGRect
    let depth: Int
    let screen: CGSize

    var supportedActions: [String] = []
    var enabled: Bool?

    var inspectionData: [String: Any] {
        var data: [String: Any] = ["role": role, "label": label, "identifier": identifier, "value": value,
         "x": frame.origin.x, "y": frame.origin.y, "width": frame.width, "height": frame.height,
         "depth": depth, "inside": inside, "offScreen": offScreen, "actions": supportedActions]
        if let enabled { data["enabled"] = enabled }
        return data
    }

    /// The whole frame is on the screen. Elements of a screen the app left behind can stay in the tree, moved off it.
    var inside: Bool { CGRect(origin: .zero, size: screen).insetBy(dx: -1, dy: -1).contains(frame) }
    var offScreen: Bool { !CGRect(origin: .zero, size: screen).intersects(frame) }

    var center: CGPoint { CGPoint(x: frame.midX, y: frame.midY) }

    /// The words an agent can name the element by.
    var names: [String] { [label, identifier, value].filter { !$0.isEmpty } }

    var line: String {
        var parts = [role]
        if !label.isEmpty { parts.append("\"\(label)\"") }
        if !identifier.isEmpty { parts.append("id=\(identifier)") }
        if !value.isEmpty { parts.append("value=\"\(value)\"") }
        parts.append("at \(Int(center.x)),\(Int(center.y)) (\(Int(frame.width))×\(Int(frame.height)))")
        if offScreen { parts.append("[off screen]") } else if !inside && screen != .zero { parts.append("[partly off screen]") }
        return parts.joined(separator: " ")
    }
}

#if SAX_LIVE_VALIDATION
private enum SAXLiveEvidence {
    static var requests = 0
    static var replies = 0
    static var dispatches = 0
}
#endif
private let accessibilityCompletionQueue = DispatchQueue(label: "mac-cu.simulator-ax.completion")

final class SimulatorAccessibilityBridge: NSObject {
    private struct Registration { let device: NSObject; var budget: SimulatorAXBudget }
    private let lock = NSLock()
    private var devices: [String: Registration] = [:]
    func register(_ device: NSObject, budget: SimulatorAXBudget) -> String {
        SimulatorAXExecutor.sync {
            let token = UUID().uuidString
            lock.lock(); devices[token] = Registration(device: device, budget: budget); lock.unlock()
            return token
        }
    }
    func update(_ token: String, budget: SimulatorAXBudget) {
        SimulatorAXExecutor.sync { lock.lock(); devices[token]?.budget = budget; lock.unlock() }
    }
    func unregister(_ token: String) {
        SimulatorAXExecutor.sync { lock.lock(); devices[token]?.budget.cancel(); devices[token] = nil; lock.unlock() }
    }
    #if SAX_INSPECTION_TESTING || SAX_LIVE_VALIDATION
    var registrationCount: Int { lock.lock(); defer { lock.unlock() }; return devices.count }
    #endif
    @objc(accessibilityTranslationDelegateBridgeCallbackWithToken:)
    func callback(_ token: NSString) -> (AnyObject) -> AnyObject? {
        // Resolve at invocation, not closure creation: an old callback cannot keep routing a removed token.
        return { [weak self] request in
            guard let self else { return nil }
            return SimulatorAXExecutor.sync {
                self.lock.lock(); let registration = self.devices[token as String]; self.lock.unlock()
                guard let registration, (try? registration.budget.check()) != nil else { return nil }
                let reply = SimulatorAXReply()
                #if SAX_LIVE_VALIDATION
                SAXLiveEvidence.requests += 1
                #endif
                let sent = SimulatorAXAdapter.sendRequest(request, device: registration.device, queue: accessibilityCompletionQueue) { reply.finish($0 as AnyObject?) }
                #if SAX_LIVE_VALIDATION
                if sent.status != .SAXOK { fputs("SAX bridge status=\(sent.status.rawValue) diagnostic=\(sent.diagnostic)\n", stderr) }
                #endif
                guard sent.status == .SAXOK else { registration.budget.cancel(); reply.finish(nil); return nil }
                let answer = reply.wait(registration.budget)
                if answer == nil { registration.budget.cancel() }
                #if SAX_LIVE_VALIDATION
                if answer != nil { SAXLiveEvidence.replies += 1 }
                #endif
                return answer
            }
        }
    }
    @objc(accessibilityTranslationConvertPlatformFrameToSystem:withToken:)
    func convert(_ rect: CGRect, token: NSString) -> CGRect { rect }
    @objc(accessibilityTranslationRootParentWithToken:)
    func rootParent(_ token: NSString) -> AnyObject? { nil }
}
private var accessibilityBridge: SimulatorAccessibilityBridge?
private var accessibilityTranslator: NSObject?
private func axObject(_ result: SAXResult) throws -> NSObject {
    guard result.status == .SAXOK, let object = result.objectValue as? NSObject else { throw ToolError("AX boundary: \(result.diagnostic) [\(result.status.rawValue)]") }
    return object
}
private func translator() throws -> (NSObject, SimulatorAccessibilityBridge) {
    if let accessibilityTranslator, let accessibilityBridge { return (accessibilityTranslator, accessibilityBridge) }
    let path = "/System/Library/PrivateFrameworks/AccessibilityPlatformTranslation.framework/AccessibilityPlatformTranslation"
    guard dlopen(path, RTLD_NOW) != nil else { throw ToolError("AccessibilityPlatformTranslation unavailable") }
    let shared = try axObject(SimulatorAXAdapter.sharedTranslator())
    if let helper = objc_getProtocol("AXPTranslationTokenDelegateHelper") { class_addProtocol(SimulatorAccessibilityBridge.self, helper) }
    let bridge = SimulatorAccessibilityBridge()
    guard SimulatorAXAdapter.installBridgeDelegate(bridge, translator: shared).status == .SAXOK else { throw ToolError("AX delegate installation failed") }
    accessibilityTranslator = shared; accessibilityBridge = bridge
    return (shared, bridge)
}

/// Whether the host process pid is the simulator's SpringBoard (home screen, lock screen).
private func isSpringBoard(_ pid: Int32) -> Bool {
    var path = [CChar](repeating: 0, count: 4096)
    return proc_pidpath(pid, &path, UInt32(path.count)) > 0 && String(cString: path).hasSuffix("/SpringBoard.app/SpringBoard")
}

/// The elements of the front app of a booted simulator, in tree order. With screen (a device with more than one),
/// frames are on that screen as shown.
/// The translation of the simulator's front app, for a registered token.
private func frontTranslation(_ translator: NSObject, token: String) throws -> NSObject {
    let translation = try axObject(SimulatorAXAdapter.frontApplication(translator, display: 0, token: token))
    guard SimulatorAXAdapter.setToken(token, translation: translation).status == .SAXOK else { throw ToolError("AX token installation failed") }
    return translation
}

/// The pid of the simulator's front app as its accessibility gives it (SpringBoard for the home screen,
/// Control Center and the lock screen).
func simulatorFrontPid(_ device: NSObject) throws -> Int32 {
    try SimulatorAXExecutor.sync {
        let (translator, bridge) = try translator()
        let budget = SimulatorAXBudget()
        let token = bridge.register(device, budget: budget)
        defer { bridge.unregister(token) }
        let result = SimulatorAXAdapter.pid(try frontTranslation(translator, token: token))
        try budget.check()
        guard result.status == .SAXOK, let pid = result.objectValue as? NSNumber else { throw ToolError("AX front PID unavailable") }
        return pid.int32Value
    }
}

/// The name of the executable of a pid (the front app's), for answers.
func processName(_ pid: Int32) -> String {
    var path = [CChar](repeating: 0, count: 4096)
    return proc_pidpath(pid, &path, UInt32(path.count)) > 0 ? (String(cString: path) as NSString).lastPathComponent : "pid \(pid)"
}

/// With objects, it is called with the elements and their accessibility objects while the device can still answer them.
func simulatorElements(_ device: NSObject, screen active: ActiveScreen?, maxElements: Int = 600, budget: SimulatorAXBudget = SimulatorAXBudget(),
                       objects: (([SimulatorElement], [NSObject]) throws -> Void)? = nil) throws -> [SimulatorElement] {
    try SimulatorAXExecutor.sync {
        let scope = SimulatorAXScope(deviceID: udid(of: device), deviceLifetime: String(describing: ObjectIdentifier(device)), presentation: String(describing: active), generation: 0, runtime: "legacy-established-read", qualifiedAXPDisplay: nil)
        let snapshot = try simulatorAXSnapshot(device, screen: active, scope: scope, currentScope: { scope }, budget: budget, maxNodes: maxElements)
        defer { simulatorAXInvalidate(snapshot.captureID) }
        let rows = snapshot.nodes.map(\.row)
        try SimulatorAXInspectionService.shared.withLegacyObjects(snapshot.captureID, budget: budget) { live in try objects?(rows, live) }
        return rows
    }
}

/// Use iOS's three-finger editing menu without moving the input's caret or selection.
func pasteThroughSimulatorEditMenu(_ device: NSObject, screen: ActiveScreen?, link: HIDLink) throws -> Bool {
    var input: SimulatorElement?
    var selection: NSRange?
    _ = try simulatorElements(device, screen: screen) { elements, objects in
        let inputs = elements.indices.filter { ["TextField", "TextArea"].contains(elements[$0].role) && !elements[$0].offScreen }
        let focused = inputs.first(where: {
            (SimulatorAXAdapter.read(.focused, element: objects[$0], protection: .unknown).objectValue as? NSNumber)?.boolValue == true
        })
        guard let index = focused ?? (inputs.count == 1 ? inputs.first : nil),
              let range = SimulatorAXAdapter.read(.selectedTextRange, element: objects[index], protection: .unknown).objectValue as? NSValue,
              simulatorPasteSelectionIsValid(range.rangeValue, value: elements[index].value)
        else { return }
        input = elements[index]
        selection = range.rangeValue
    }
    guard let input, let selection else { return false }
    let spread = min(30, input.frame.width / 4)
    let contacts = (-1...1).enumerated().map { index, offset in
        ["id": index + 1, "x": input.center.x + Double(offset) * spread, "y": input.center.y] as [String: Any]
    }
    let frames = ["down", "up"].enumerated().map { index, phase in
        ["time": Double(index) * 0.1, "touches": contacts.map { $0.merging(["phase": phase]) { _, new in new } }] as [String: Any]
    }
    _ = try runSimulatorGesture(arguments: ["frames": frames], device: device, screen: screen,
                                cancelled: { currentSession?.requestCancelled ?? false })
    usleep(250_000)  // UIKit exposes the editing bar before its presentation animation accepts touches.
    var preserved = false
    _ = try simulatorElements(device, screen: screen) { elements, objects in
        for index in elements.indices where elements[index].role == input.role && elements[index].value == input.value
            && input.frame.insetBy(dx: -20, dy: -20).contains(elements[index].center) {
            let range = SimulatorAXAdapter.read(.selectedTextRange, element: objects[index], protection: .unknown).objectValue as? NSValue
            preserved = range?.rangeValue == selection
            break
        }
    }
    guard preserved else { throw ToolError("입력란의 선택 범위가 바뀌어 붙여넣기를 중단했습니다. 입력란을 다시 선택하고 시도하세요.") }
    for _ in 0..<5 {
        if let item = try simulatorElements(device, screen: screen).first(where: {
            ["붙여넣기", "Paste"].contains($0.label) && !$0.offScreen
        }) {
            link.touch(item.center, phase: 0, screen: screen)
            usleep(50_000)
            link.touch(item.center, phase: 2, screen: screen)
            return true
        }
        usleep(100_000)
    }
    return false
}

/// Presses the first element named target (exact label, id or value first, then contains) with the accessibility press
/// action (AXPress), as VoiceOver does: no touch, so no coordinates, screens or rotation are involved, and an element
/// that another view covers or that is partly off the screen is pressed too. Elements a list has not made are not in the tree.
func pressSimulatorElement(_ device: NSObject, screen: ActiveScreen?, target: String) throws -> SimulatorElement {
    let wanted = target.trimmingCharacters(in: .whitespaces)
    var pressed: SimulatorElement?
    _ = try simulatorElements(device, screen: screen) { elements, objects in
        let exact = elements.indices.first { elements[$0].names.contains { $0.caseInsensitiveCompare(wanted) == .orderedSame } }
        guard let index = exact ?? elements.indices.first(where: { elements[$0].names.contains { $0.range(of: wanted, options: .caseInsensitive) != nil } })
        else { throw ToolError("No element named \"\(target)\". Run describe to see the screen.") }
        let result = SimulatorAXAdapter.dispatch(.press, element: objects[index], qualified: true)
        guard result.status == .SAXOK, result.mutationOutcome == .dispatched else { throw ToolError("AX press rejected or uncertain; do not retry automatically") }
        pressed = elements[index]
    }
    return pressed!
}

/// The elements on the screen whose label, identifier or value is target (ignoring case), or else contains
/// it. Elements wholly on the screen come first.
func simulatorMatches(_ elements: [SimulatorElement], _ target: String) -> [SimulatorElement] {
    let wanted = target.trimmingCharacters(in: .whitespaces)
    guard !wanted.isEmpty else { return [] }
    let visible = elements.filter { $0.frame.width > 0 && $0.frame.height > 0 && !$0.offScreen }
    var matches = visible.filter { $0.names.contains { $0.caseInsensitiveCompare(wanted) == .orderedSame } }
    if matches.isEmpty { matches = visible.filter { $0.names.contains { $0.range(of: wanted, options: .caseInsensitive) != nil } } }
    return matches.filter(\.inside) + matches.filter { !$0.inside }
}

/// The text of describe: the tree, or the elements that match query.
func describeSimulator(_ device: NSObject, screen: ActiveScreen?, query: String) throws -> String {
    let elements = try simulatorElements(device, screen: screen)
    let name = device.value(forKey: "name") ?? udid(of: device)
    if !query.isEmpty {
        let matches = simulatorMatches(elements, query)
        if matches.isEmpty { return "No element of \(name)'s front app is named \"\(query)\". Run describe without query to see all." }
        return "Elements of \(name) named \"\(query)\" (role, label, id, value, center x,y in points, size):\n"
            + matches.map(\.line).joined(separator: "\n")
    }
    let lines = elements.map { String(repeating: "  ", count: $0.depth) + $0.line }
    return """
        Front app of \(name) (role, label, id, value, center x,y in points, size). Tap a center with tap x/y, \
        or tap with target set to a label or id.
        """ + "\n" + lines.joined(separator: "\n")
}

/// The first element named target, waiting up to seconds for it to appear.
func waitForSimulatorElement(_ device: NSObject, screen: ActiveScreen?, target: String, seconds: Double) throws -> (SimulatorElement, [SimulatorElement]) {
    let budget = SimulatorAXBudget(seconds: seconds)
    while true {
        let matches = simulatorMatches(try simulatorElements(device, screen: screen, budget: budget), target)
        if let first = matches.first { return (first, matches) }
        if DispatchTime.now() >= budget.deadline {
            throw ToolError("No element named \"\(target)\" appeared in \(Int(seconds.rounded())) seconds. Run describe to see the screen.")
        }
        usleep(400_000)
    }
}

/// Retains the live objects only for the bounded action, never in UI state.
func pressSimulatorInspectionElement(_ device: NSObject, screen: ActiveScreen?, selected: [String: Any], pid: Int) throws {
    guard Int(try simulatorFrontPid(device)) == pid else { throw ToolError("전면 앱이 바뀌었습니다. 새로 읽으세요.") }
    _ = try simulatorElements(device, screen: screen) { elements, objects in
        let matches = elements.indices.filter { NSDictionary(dictionary: elements[$0].inspectionData).isEqual(to: selected) }
        guard matches.count == 1, let index = matches.first,
              elements[index].supportedActions.contains("AXPress"), elements[index].enabled != false else {
            throw ToolError("선택한 요소가 바뀌었거나 AX 실행을 지원하지 않습니다. 새로 읽으세요.")
        }
        let result = SimulatorAXAdapter.dispatch(.press, element: objects[index], qualified: true)
        guard result.status == .SAXOK, result.mutationOutcome == .dispatched else { throw ToolError("AX press rejected or uncertain; refresh before another action") }
    }
}


/// Root supplies authoritative device/presentation generation readback. Never pass a cached closure for editable captures.
func simulatorAXSnapshot(_ device: NSObject, screen active: ActiveScreen?, scope: SimulatorAXScope,
                         currentScope: @escaping () throws -> SimulatorAXScope,
                         budget: SimulatorAXBudget = SimulatorAXBudget(), maxNodes: Int = 600) throws -> SimulatorAXSnapshot {
    try SimulatorAXExecutor.sync {
        let backend = try simulatorAXRealBackend(device, active: active, scope: scope, currentScope: currentScope, budget: budget)
        return try SimulatorAXInspectionService.shared.capture(backend: backend, budget: budget, maxNodes: maxNodes)
    }
}
private func simulatorAXRealBackend(_ device: NSObject, active: ActiveScreen?, scope: SimulatorAXScope,
                                    currentScope: @escaping () throws -> SimulatorAXScope,
                                    budget: SimulatorAXBudget, qualification override: SimulatorAXQualification? = nil) throws -> SimulatorAXBackend {
        let (translator, bridge) = try translator()
        let token = bridge.register(device, budget: budget)
        let qualification: SimulatorAXQualification
        do {
            if let override { qualification = override }
            else {
                let translation = try frontTranslation(translator, token: token)
                let pidResult = SimulatorAXAdapter.pid(translation)
                guard pidResult.status == .SAXOK, let pid = pidResult.objectValue as? NSNumber else { throw ToolError("AX front PID unavailable") }
                let target = try SimulatorAXLifetime.current(pid.int32Value)
                qualification = SimulatorAXNativeMetadata.qualification(runtime: scope.runtime, executable: target.executable)
            }
        } catch { bridge.unregister(token); throw error }
        return SimulatorAXBackend(
            begin: { bridge.update(token, budget: $0) },
            root: { try axObject(SimulatorAXAdapter.platformElement(translator, translation: frontTranslation(translator, token: token))) },
            current: {
                let translation = try frontTranslation(translator, token: token)
                let result = SimulatorAXAdapter.pid(translation)
                guard result.status == .SAXOK, let pid = result.objectValue as? NSNumber else { throw ToolError("AX front PID failed") }
                let current = try currentScope()
                guard current == scope else { throw SimulatorAXFailure.targetChanged }
                let target = try SimulatorAXLifetime.current(pid.int32Value)
                if override == nil && qualification.semanticActions {
                    guard SimulatorAXNativeMetadata.qualification(runtime: current.runtime, executable: target.executable).semanticActions else {
                        throw ToolError("AX native provenance changed or became unavailable")
                    }
                }
                return (target, current)
            },
            read: { field, object, protection in
                if override == nil && qualification.semanticActions {
                    guard SimulatorAXNativeMetadata.isElement(object) else { throw ToolError("AX receiver image is not qualified") }
                }
                let translation = try axObject(SimulatorAXAdapter.read(.translation, element: object, protection: .unknown))
                guard SimulatorAXAdapter.setToken(token, translation: translation).status == .SAXOK else { throw ToolError("AX token failure") }
                return SimulatorAXAdapter.read(field, element: object, protection: protection)
            },
            dispatch: {
                #if SAX_LIVE_VALIDATION
                SAXLiveEvidence.dispatches += 1
                #endif
                return SimulatorAXAdapter.dispatch($0, element: $1, qualified: true)
            },
            settable: { SimulatorAXAdapter.valueSettable($0, protection: $1) },
            setValue: {
                #if SAX_LIVE_VALIDATION
                SAXLiveEvidence.dispatches += 1
                #endif
                return SimulatorAXAdapter.setValue($0, element: $1, protection: $2, qualified: true)
            },
            custom: {
                #if SAX_LIVE_VALIDATION
                SAXLiveEvidence.dispatches += 1
                #endif
                return SimulatorAXAdapter.invokeCustomAction($0, element: $1, qualified: true)
            },
            point: { point in
                guard let display = scope.qualifiedAXPDisplay else { throw ToolError("AXP display mapping unsupported") }
                let translation = try axObject(SimulatorAXAdapter.element(at: point, translator: translator, display: display, token: token))
                return try axObject(SimulatorAXAdapter.platformElement(translator, translation: translation))
            },
            release: { bridge.unregister(token) },
            normalize: { frame, depth, pid in
                let rootTurn = depth == 0 && active.map { ($0.guestRotation == "rot90" || $0.guestRotation == "rot270") && frame.size == $0.unrotated } == true
                return (isSpringBoard(pid) ? active : (rootTurn ? active : nil)).map { $0.shown(frame) } ?? active?.presentingGuestFrame(frame) ?? frame
            }, screen: active?.points ?? screenSize(of: device), qualification: qualification)
}
func simulatorAXInvalidate(_ captureID: String) {
    SimulatorAXInspectionService.shared.invalidate(captureID)
}
func simulatorAXAction(_ request: SimulatorAXActionRequest, budget: SimulatorAXBudget = SimulatorAXBudget()) throws -> SimulatorAXActionResult {
    do { return try SimulatorAXInspectionService.shared.action(request, budget: budget) }
    catch SimulatorAXFailure.targetChanged { return SimulatorAXActionResult(state: "targetChanged", delivery: "notEntered", readback: nil, receipt: nil) }
    catch SimulatorAXFailure.staleCapture { return SimulatorAXActionResult(state: "staleCapture", delivery: "notEntered", readback: nil, receipt: nil) }
    catch SimulatorAXFailure.expiredCapture { return SimulatorAXActionResult(state: "expiredCapture", delivery: "notEntered", readback: nil, receipt: nil) }
}

func simulatorAXPoint(captureID: String, point: CGPoint, budget: SimulatorAXBudget = SimulatorAXBudget()) throws -> [String: Any] {
    try SimulatorAXInspectionService.shared.point(captureID: captureID, point: point, budget: budget)
}

#if SAX_LIVE_VALIDATION
// Only compiled into the fixture-bound executable. No transport/UI flag can enter this.
func simulatorAXLiveIdentity(_ device: NSObject, scope: SimulatorAXScope,
                             validate: @escaping () throws -> SimulatorAXScope,
                             recreate: () throws -> Void) throws -> [String: Any] {
    try SimulatorAXExecutor.sync {
        let backend = try simulatorAXRealBackend(device, active: nil, scope: scope, currentScope: validate, budget: SimulatorAXBudget(seconds: 30))
        defer { backend.release() }
        func walk() throws -> [NSObject] {
            _ = try backend.current()
            var result: [NSObject] = [], seen = Set<ObjectIdentifier>()
            func visit(_ object: NSObject, _ depth: Int) throws {
                guard depth < 40, result.count < 300, seen.insert(ObjectIdentifier(object)).inserted else { return }
                result.append(object)
                let children = try backend.read(.children, object, .unknown)
                if let list = children.objectValue as? [NSObject] { for child in list { try visit(child, depth + 1) } }
            }
            try visit(backend.root(), 0)
            return result
        }
        let first = try walk(), second = try walk()
        func ids(_ list: [NSObject]) throws -> [String: NSObject] {
            var found: [String: NSObject] = [:]
            for object in list {
                if let id = try backend.read(.identifier, object, .unknown).objectValue as? String, id.hasPrefix("fixture.") { found[id] = object }
            }
            return found
        }
        let a = try ids(first), b = try ids(second)
        var rows: [[String: Any]] = []
        for id in a.keys.sorted() {
            let object = a[id]!
            let translation = try backend.read(.translation, object, .unknown).objectValue as? NSObject
            let otherTranslation = try b[id].flatMap { try backend.read(.translation, $0, .unknown).objectValue as? NSObject }
            let value = try backend.read(.value, object, id == "fixture.secure" ? .protected : .clear)
            rows.append(["identifier": id, "wrapperClass": NSStringFromClass(type(of: object)),
                         "sameWrapper": b[id] === object, "occurrences": second.filter { $0 === object }.count,
                         "sameTranslation": translation != nil && translation === otherTranslation,
                         "translationClass": translation.map { NSStringFromClass(type(of: $0)) } ?? "nil",
                         "valueStatus": value.status.rawValue,
                         "valueClass": value.objectValue.map { NSStringFromClass(type(of: $0 as AnyObject)) } ?? "nil"])
        }
        let originalRecreated = a["fixture.recreated"]
        let originalLabel = try originalRecreated.flatMap { try backend.read(.label, $0, .unknown).objectValue as? NSObject }
        let originalFrame = try originalRecreated.flatMap { try backend.read(.frame, $0, .unknown).objectValue as? NSObject }
        try recreate()
        let third = try walk(), c = try ids(third)
        let prior = a["fixture.recreated"]
        let replacement = c["fixture.recreated"]
        let replacementLabel = try replacement.flatMap { try backend.read(.label, $0, .unknown).objectValue as? NSObject }
        let replacementFrame = try replacement.flatMap { try backend.read(.frame, $0, .unknown).objectValue as? NSObject }
        return ["sameRecreatedLabel": originalLabel != nil && originalLabel == replacementLabel, "sameRecreatedFrame": originalFrame != nil && originalFrame == replacementFrame, "firstCount": first.count, "secondCount": second.count, "rows": rows,
                "recreatedOldWrapperOccurrences": prior.map { old in third.filter { $0 === old }.count } ?? -1,
                "recreatedSameWrapper": prior != nil && prior === c["fixture.recreated"],
                "semanticQualified": false, "reason": "Identity measurements alone do not establish a guest lifetime rule"]
    }
}
#endif

#if SAX_LIVE_VALIDATION
func simulatorAXLiveCapture(_ device: NSObject, scope: SimulatorAXScope, executable: String,
                            current: @escaping () throws -> SimulatorAXScope,
                            service: SimulatorAXInspectionService = .shared,
                            clear: Bool = true) throws -> SimulatorAXSnapshot {
    try SimulatorAXExecutor.sync {
        var profile = SimulatorAXQualification()
        profile.verifiedRuntime = scope.runtime; profile.verifiedExecutable = executable
        profile.semanticActions = true; profile.exactGuestIdentity = true; profile.clearProtection = clear
        profile.valueDomain = { if case .string(let value) = $0 { return value.utf16.count < 128 }; return false }
        let budget = SimulatorAXBudget(seconds: 5)
        let backend = try simulatorAXRealBackend(device, active: nil, scope: scope, currentScope: current, budget: budget, qualification: profile)
        return try service.capture(backend: backend, budget: budget)
    }
}
func simulatorAXLiveRegistrationCount() -> Int { SimulatorAXExecutor.sync { accessibilityBridge?.registrationCount ?? 0 } }
#endif

#if SAX_LIVE_VALIDATION
func simulatorAXLiveEvidence() -> [String: Int] {
    SimulatorAXExecutor.sync { ["requests": SAXLiveEvidence.requests, "replies": SAXLiveEvidence.replies,
                               "dispatches": SAXLiveEvidence.dispatches, "registeredTokens": accessibilityBridge?.registrationCount ?? 0] }
}
#endif

/// Read-only native provenance. Missing, oversized or malformed metadata fails closed.
/// This does not instantiate a translator, enumerate devices, or send a guest request.
enum SimulatorAXNativeMetadata {
    private static func plist(_ path: String) -> [String: Any]? {
        guard let f = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? f.close() }
        guard let data = try? f.read(upToCount: 65537), data.count <= 65536,
              let value = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any] else { return nil }
        return value
    }
    static func qualification(runtime: String, executable: String,
                              metadata: () -> [String: String] = read) -> SimulatorAXQualification {
        SimulatorAXProductProfile.select(runtime: runtime, executable: executable, metadata: metadata())
    }
    static func isElement(_ object: NSObject) -> Bool {
        let cls: AnyClass = type(of: object)
        guard String(cString: class_getName(cls)) == "AXPMacPlatformElement", let image = class_getImageName(cls) else { return false }
        return SimulatorAXProductProfile.canonicalImage(String(cString: image)) == SimulatorAXProductProfile.canonicalImage(SimulatorAXProductProfile.axpImage)
    }
    static func read() -> [String: String] {
        var result: [String: String] = [:]
        #if arch(arm64)
        result["architecture"] = "arm64"
        #else
        return [:]
        #endif
        var host = [CChar](repeating: 0, count: 256), count = 256
        if sysctlbyname("kern.osversion", &host, &count, nil, 0) == 0, count > 1, count <= 256 { result["hostBuild"] = String(cString: host) }
        let process = Process(), pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcode-select"); process.arguments = ["-p"]
        process.standardOutput = pipe; process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            let deadline = DispatchTime.now() + .seconds(2)
            while process.isRunning && DispatchTime.now() < deadline { Thread.sleep(forTimeInterval: 0.005) }
            guard !process.isRunning, process.terminationStatus == 0 else { if process.isRunning { kill(process.processIdentifier, SIGKILL); process.waitUntilExit() }; return [:] }
            let data = pipe.fileHandleForReading.readData(ofLength: 4097)
            guard data.count <= 4096, let raw = String(data: data, encoding: .utf8) else { return [:] }
            let developer = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard developer.hasPrefix("/"), developer.hasSuffix("/Contents/Developer"),
                  let version = plist((developer as NSString).deletingLastPathComponent + "/version.plist") else { return [:] }
            result["xcodeVersion"] = version["CFBundleShortVersionString"] as? String
            result["xcodeBuild"] = version["ProductBuildVersion"] as? String
        } catch { return [:] }
        for (prefix, name, expected) in [("axp", "AXPTranslator", SimulatorAXProductProfile.axpImage), ("core", "SimDevice", SimulatorAXProductProfile.coreImage)] {
            guard let cls = NSClassFromString(name), let image = class_getImageName(cls), SimulatorAXProductProfile.canonicalImage(String(cString: image)) == SimulatorAXProductProfile.canonicalImage(expected),
                  let bundle = plist((expected as NSString).deletingLastPathComponent + "/Resources/Info.plist"),
                  let version = bundle["CFBundleVersion"] as? String,
                  let id = bundle["CFBundleIdentifier"] as? String else { return [:] }
            result[prefix + "Image"] = SimulatorAXProductProfile.canonicalImage(String(cString: image)); result[prefix + "ID"] = id; result[prefix + "Version"] = version
        }
        for name in ["AXPTranslationObject", "AXPMacPlatformElement"] {
            guard let cls = NSClassFromString(name), let image = class_getImageName(cls), SimulatorAXProductProfile.canonicalImage(String(cString: image)) == SimulatorAXProductProfile.canonicalImage(SimulatorAXProductProfile.axpImage) else { return [:] }
        }
        result["receiverImages"] = "verified"
        return result
    }
}
