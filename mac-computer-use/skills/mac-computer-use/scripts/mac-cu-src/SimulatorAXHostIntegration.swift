import AppKit

/// Root updates this from authoritative boot/device/presentation evidence. Object pointers are never identity.
/// Locks never enter handleQueue, main, or the AX executor. Revocation is asynchronous.
final class SimulatorAXHostLifecycle {
    static let shared = SimulatorAXHostLifecycle()
    private let lock = NSLock()
    private var scopes: [String: SimulatorAXScope] = [:]
    private var captures: [String: SimulatorAXScope] = [:]
    private var budgets: [String: SimulatorAXBudget] = [:]
    func update(deviceID: String, bootIdentity: String?, presentation: String, generation: UInt64, runtime: String?, qualifiedAXPDisplay: UInt32? = nil) {
        lock.lock()
        budgets.removeValue(forKey: deviceID)?.cancel()
        if let bootIdentity, !bootIdentity.isEmpty, let runtime, !runtime.isEmpty, !deviceID.isEmpty, !presentation.isEmpty {
            scopes[deviceID] = SimulatorAXScope(deviceID: deviceID, deviceLifetime: bootIdentity, presentation: presentation, generation: generation, runtime: runtime, qualifiedAXPDisplay: qualifiedAXPDisplay)
        } else { scopes.removeValue(forKey: deviceID) }
        let revoked = takeCaptures(deviceID)
        lock.unlock()
        revoke(revoked)
    }
    /// Call on screen/rotation/reconnect/input/close; update with a new generation before another refresh.
    func invalidate(deviceID: String) {
        lock.lock(); scopes.removeValue(forKey: deviceID); budgets.removeValue(forKey: deviceID)?.cancel(); let revoked = takeCaptures(deviceID); lock.unlock(); revoke(revoked)
    }
    func cancelPendingReads(deviceID: String) {
        lock.lock(); budgets.removeValue(forKey: deviceID)?.cancel(); let revoked = takeCaptures(deviceID); lock.unlock(); revoke(revoked)
    }
    func current(deviceID: String) throws -> SimulatorAXScope {
        lock.lock(); defer { lock.unlock() }
        guard let scope = scopes[deviceID] else { throw ToolError("AX device boot/runtime/presentation identity unavailable; refresh requires authoritative lifecycle update") }; return scope
    }
    func begin(deviceID: String, budget: SimulatorAXBudget, revokingCaptures: Bool = false) {
        lock.lock(); budgets.removeValue(forKey: deviceID)?.cancel(); budgets[deviceID] = budget
        let revoked = revokingCaptures ? takeCaptures(deviceID) : []
        lock.unlock(); revoke(revoked)
    }
    // Called while locked; capture registries are host routing metadata, never guest identity.
    private func takeCaptures(_ deviceID: String) -> [String] {
        let ids = captures.filter { $0.value.deviceID == deviceID }.map(\.key)
        for id in ids { captures.removeValue(forKey: id) }; return ids
    }
    func retainRouting(_ snapshot: SimulatorAXSnapshot, budget: SimulatorAXBudget? = nil) throws {
        lock.lock(); defer { lock.unlock() }
        guard scopes[snapshot.scope.deviceID] == snapshot.scope, budget?.cancelled != true, budget.map({ DispatchTime.now() < $0.deadline }) ?? true else {
            revoke([snapshot.captureID]); throw SimulatorAXFailure.targetChanged
        }
        _ = takeCaptures(snapshot.scope.deviceID)
        captures[snapshot.captureID] = snapshot.scope
    }
    func scopeForCapture(_ captureID: String) throws -> SimulatorAXScope {
        lock.lock(); defer { lock.unlock() }
        guard let scope = captures[captureID] else { throw SimulatorAXFailure.staleCapture }; return scope
    }
    private func revoke(_ ids: [String]) {
        SimulatorAXExecutor.queue.async { for id in ids { simulatorAXInvalidate(id) } }
    }
}

func simulatorAXHostSnapshot(_ device: NSObject, deviceID: String, screen: ActiveScreen?) throws -> [String: Any] {
    guard !Thread.isMainThread else { throw ToolError("AX reads require background command dispatch") }
    let store = SimulatorAXHostLifecycle.shared, budget = SimulatorAXBudget()
    store.begin(deviceID: deviceID, budget: budget, revokingCaptures: true)
    let scope = try store.current(deviceID: deviceID)
    let snapshot = try simulatorAXSnapshot(device, screen: screen, scope: scope, currentScope: { try store.current(deviceID: deviceID) }, budget: budget)
    try store.retainRouting(snapshot, budget: budget)
    return snapshot.dictionary
}
func simulatorAXHostAction(_ wire: [String: Any], deviceID: String) throws -> [String: Any] {
    guard !Thread.isMainThread else { throw ToolError("AX actions require background command dispatch") }
    let envelope = try SimulatorAXEnvelope(wire)
    let scope = try SimulatorAXHostLifecycle.shared.current(deviceID: deviceID)
    // A retained session also checks its own fresh scope. Never route a capture through a different selected device.
    do {
        guard try SimulatorAXHostLifecycle.shared.scopeForCapture(envelope.captureID) == scope else { return ["state": "targetChanged", "delivery": "notEntered"] }
    } catch SimulatorAXFailure.staleCapture { return ["state": "staleCapture", "delivery": "notEntered"] }
    func scalar(_ value: SimulatorAXScalar) -> SimulatorAXValue { switch value { case .string(let s): return .string(s); case .number(let n): return .number(n); case .boolean(let b): return .boolean(b) } }
    let op: SimulatorAXOperation
    switch envelope.operation {
    case "press": op = .press
    case "increment": op = .increment
    case "decrement": op = .decrement
    case "custom": op = .customAction(envelope.handle!)
    case "restore": op = .restore(receipt: envelope.handle!)
    case "setValue": op = .setValue(expected: scalar(envelope.expected!), new: scalar(envelope.value!))
    default: throw SimulatorAXWireError.invalidEnvelope
    }
    let budget = SimulatorAXBudget()
    SimulatorAXHostLifecycle.shared.begin(deviceID: deviceID, budget: budget)
    return try simulatorAXAction(SimulatorAXActionRequest(captureID: envelope.captureID, nodeID: envelope.nodeID, operation: op), budget: budget).dictionary
}
