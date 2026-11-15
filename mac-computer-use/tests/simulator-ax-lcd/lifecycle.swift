// Appended to the existing headless AX fixtures by run-host.py.
let host = SimulatorAXHostLifecycle.shared
rejected { _ = try host.current(deviceID: "host-fixture") }
host.update(deviceID: "host-fixture", bootIdentity: nil, presentation: "screen", generation: 1, runtime: "runtime")
rejected { _ = try host.current(deviceID: "host-fixture") }
host.update(deviceID: "host-fixture", bootIdentity: "actual-boot-fixture", presentation: "screen", generation: 2, runtime: "runtime")
expect(try host.current(deviceID: "host-fixture").deviceLifetime == "actual-boot-fixture", "boot identity separate from pointer and generation")
expect(try host.current(deviceID: "host-fixture").qualifiedAXPDisplay == nil, "CoreSimulator display never becomes AXP zero")
let hostBudget = SimulatorAXBudget(); host.begin(deviceID: "host-fixture", budget: hostBudget)
host.cancelPendingReads(deviceID: "host-fixture"); expect(hostBudget.cancelled, "cancel pending read")
let enteredHostBlock = DispatchSemaphore(value: 0), releaseHostBlock = DispatchSemaphore(value: 0)
SimulatorAXExecutor.queue.async { enteredHostBlock.signal(); _ = releaseHostBlock.wait(timeout: .now() + 2) }
expect(enteredHostBlock.wait(timeout: .now() + 1) == .success, "executor blocked fixture entered")
// A lifecycle update/current read must not synchronize with the busy AX owner.
host.update(deviceID: "host-fixture", bootIdentity: "actual-boot-fixture", presentation: "rotated", generation: 3, runtime: "runtime")
expect(try host.current(deviceID: "host-fixture").generation == 3, "fresh lifecycle read independent of AX executor")
releaseHostBlock.signal()
SimulatorAXExecutor.sync {}
host.invalidate(deviceID: "host-fixture")
rejected { _ = try host.current(deviceID: "host-fixture") }
let invalidRequest: [String: Any] = ["captureID": "stale", "nodeID": "node", "operation": "press", "profile": "qualified"]
rejected { _ = try SimulatorAXEnvelope(invalidRequest) }
let routingFixture = Fake()
let routingSnapshot = try SimulatorAXInspectionService.shared.capture(backend: routingFixture.backend)
let routingScope = routingSnapshot.scope
host.update(deviceID: routingScope.deviceID, bootIdentity: routingScope.deviceLifetime, presentation: routingScope.presentation, generation: routingScope.generation, runtime: routingScope.runtime, qualifiedAXPDisplay: routingScope.qualifiedAXPDisplay)
try host.retainRouting(routingSnapshot)
expect(try host.scopeForCapture(routingSnapshot.captureID) == routingScope, "host routes exact capture scope")
host.begin(deviceID: routingScope.deviceID, budget: SimulatorAXBudget(), revokingCaptures: true)
rejected { _ = try host.scopeForCapture(routingSnapshot.captureID) }
host.invalidate(deviceID: routingScope.deviceID)
rejected { _ = try host.scopeForCapture(routingSnapshot.captureID) }
SimulatorAXExecutor.sync {}
expect(routingFixture.releases == 1, "host revocation releases only retained capture")
print("PASS host lifecycle checks; total \(checks) AX assertions")
