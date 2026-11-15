import AppKit
if CommandLine.arguments != [CommandLine.arguments[0], "--native-check"] || ProcessInfo.processInfo.environment["MAC_CU_NATIVE_CHECK_CHILD"] == "1" { exit(64) }
setenv("MAC_CU_NATIVE_CHECK_CHILD", "1", 1)
var checks = 0
func expect(_ b: Bool, _ message: String) { checks += 1; if !b { fatalError(message) } }
func rejected(_ body: () throws -> Void) { do { try body(); fatalError("expected rejection") } catch { checks += 1 } }
func result(_ value: Any? = nil, _ status: SAXStatus = .SAXOK, _ outcome: SAXMutationOutcome = .notEntered) -> SAXResult { SAXInspectionResult(status, value, outcome) }
final class Fake {
    let root = NSObject(), child = NSObject()
    var runtime = "fake", executable = "/fake"
    var pid: Int32 = 42, start: UInt64 = 1, generation: UInt64 = 1
    var value: Any = 2.0, enabled = true, protected = false, settable = true
    var releases = 0, dispatches = 0, cycle = false, uncertain = false, cancelOnDispatch: SimulatorAXBudget?
    var subrole: String? = "", subroleStatus: SAXStatus = .SAXOK, advertised = ["AXPress", "AXIncrement", "AXDecrement"], hasCustom = true
    var childEnabled = true, delay = false, reads = 0, missingReadback = false
    let customs = [NSAccessibilityCustomAction(name: "Duplicate", handler: { true }), NSAccessibilityCustomAction(name: "Duplicate", handler: { true })]
    var qualification = SimulatorAXQualification(verifiedRuntime: "fake", verifiedExecutable: "/fake", semanticActions: true, exactGuestIdentity: true, clearProtection: true, pointMapping: false, valueDomain: { if case .number(let n) = $0 { return (0...10).contains(n) }; return false })
    var scope: SimulatorAXScope { SimulatorAXScope(deviceID: UUIDString, deviceLifetime: "boot", presentation: "portrait", generation: generation, runtime: runtime, qualifiedAXPDisplay: nil) }
    let UUIDString = UUID().uuidString
    var backend: SimulatorAXBackend {
        SimulatorAXBackend(begin: { _ in }, root: { self.root }, current: { (SimulatorAXLifetime(pid: self.pid, startSeconds: self.start, startMicroseconds: 0, executable: self.executable), self.scope) }, read: { field, object, protection in
            self.reads += 1; if self.delay { usleep(1500) }
            switch field {
            case .children: return result(object === self.root ? [self.child] : (self.cycle ? [self.root] : []))
            case .role: return result("AXSlider")
            case .subrole: return result(self.subrole, self.subroleStatus)
            case .label: return result("")
            case .identifier: return result(nil, .SAXNil)
            case .value:
                if self.missingReadback && self.dispatches > 0 { return result(nil, .SAXNil) }
                return protection == .clear && !self.protected ? result(self.value) : result(nil, .SAXRedacted)
            case .enabled: return result(self.enabled)
            case .protectedContent: return result(self.protected)
            case .actions: return result(self.advertised)
            case .customActions: return result(self.hasCustom ? self.customs : [])
            case .frame: return result(NSValue(rect: CGRect(x: 1, y: 2, width: 3, height: 4)))
            default: return result(nil, .SAXUnsupportedSelector)
            }
        }, dispatch: { _, _ in self.dispatches += 1; self.value = 3.0; self.cancelOnDispatch?.cancel(); return result(nil, self.uncertain ? .SAXException : .SAXOK, self.uncertain ? .uncertain : .dispatched) }, settable: { _, _ in result(self.settable, self.settable ? .SAXOK : .SAXUnsupportedCapability) }, setValue: { value, _, _ in self.dispatches += 1; self.value = value; return result(nil, .SAXOK, .dispatched) }, custom: { _, _ in self.dispatches += 1; return result(nil, .SAXOK, .dispatched) }, point: { _ in self.child }, release: { self.releases += 1 }, normalize: { r, _, _ in r }, screen: CGSize(width: 100, height: 200), qualification: qualification)
    }
}
let service = SimulatorAXInspectionService()
func capture(_ f: Fake) throws -> SimulatorAXSnapshot { try service.capture(backend: f.backend) }
func action(_ s: SimulatorAXSnapshot, _ op: SimulatorAXOperation, budget: SimulatorAXBudget = SimulatorAXBudget()) throws -> SimulatorAXActionResult { try service.action(SimulatorAXActionRequest(captureID: s.captureID, nodeID: s.nodes[0].nodeID, operation: op), budget: budget) }
let f = Fake(); let s = try capture(f)
expect(s.nodes.count == 2 && s.nodes[0].childIDs == [s.nodes[1].nodeID], "ordered topology")
expect(s.nodes[1].parentID == s.nodes[0].nodeID, "parent")
expect(s.nodes[0].details["label"]?.status == "available" && s.nodes[0].details["identifier"]?.status == "nil", "nil vs empty")
expect(s.nodes[0].details["help"]?.status == "unsupported", "unsupported")
expect(s.nodes[0].customHandles.count == 2 && Set(s.nodes[0].customHandles).count == 2, "duplicate custom handles")
expect((try service.point(captureID: s.captureID, point: .zero))["state"] as? String == "unsupported", "mapping disabled")
let write = try action(s, .setValue(expected: .number(2), new: .number(4)))
expect(write.state == "postconditionObserved" && f.dispatches == 1, "one setter and readback")
let restored = try action(s, .restore(receipt: write.receipt!)); expect(restored.state == "postconditionObserved", "guarded restore")
rejected { _ = try action(s, .restore(receipt: write.receipt!)) }
for mode in 0..<7 {
    let f = Fake(); let s = try capture(f)
    switch mode { case 0: f.start += 1; case 1: f.generation += 1; case 2: f.pid += 1; case 3: f.enabled = false; case 4: f.protected = true; case 5: f.settable = false; default: f.value = 8.0 }
    rejected { _ = try action(s, .setValue(expected: .number(2), new: .number(5))) }
    expect(f.dispatches == 0 && f.releases == 1, "zero stale/protected/nonsettable dispatch")
}
for op in [SimulatorAXOperation.setValue(expected: .number(2), new: .number(11)), .setValue(expected: .number(2), new: .string("5"))] {
    let f = Fake(); let s = try capture(f); rejected { _ = try action(s, op) }; expect(f.dispatches == 0, "domain/type")
}
let c = Fake(); c.cycle = true; let cs = try capture(c); expect(!cs.truncations.isEmpty, "cycle bounded")
expect(try action(cs, .press).state == "unsupported" && c.dispatches == 0, "cycle no dispatch")
let t = Fake(); let ts = try service.capture(backend: t.backend, maxNodes: 1); expect(ts.nodes.count == 1 && !ts.truncations.isEmpty, "truncation")
let red = Fake(); red.qualification.clearProtection = false; let rs = try capture(red); expect(rs.nodes[0].typedValue == nil && rs.nodes[0].details["value"]?.status == "redacted", "unknown redaction")
let slow = Fake(); slow.delay = true; rejected { _ = try service.capture(backend: slow.backend, budget: SimulatorAXBudget(seconds: 0.005)) }; expect(slow.releases == 1 && slow.reads < 15, "whole operation deadline")
let cancelled = SimulatorAXBudget(); cancelled.cancel(); let cf = Fake(); rejected { _ = try service.capture(backend: cf.backend, budget: cancelled) }; expect(cf.reads == 0 && cf.releases == 1, "cancel cleanup")
let u = Fake(); u.uncertain = true; let us = try capture(u); expect(try action(us, .increment).state == "outcomeUncertain", "uncertain result"); rejected { _ = try action(us, .increment) }; expect(u.dispatches == 1 && u.releases == 1, "quarantine no retry")
service.invalidateAll()
let v = Fake(); let vs = try capture(v); expect(try action(vs, .decrement).state == "deliveredReadback", "void not success")
service.invalidateAll()
let custom = Fake(); let customS = try capture(custom); _ = try action(customS, .customAction(customS.nodes[0].customHandles[1])); expect(custom.dispatches == 1, "exact custom handle")
service.invalidateAll()
let no = Fake(); let ns = try capture(no); expect(try action(ns, .setValue(expected: .number(2), new: .number(2))).state == "noChange" && no.dispatches == 0, "noChange no dispatch")
let refresh = Fake(); let old = try capture(refresh); _ = try capture(refresh); rejected { _ = try action(old, .press) }; expect(refresh.releases == 1, "refresh invalidation")
service.invalidateAll()
let group = DispatchGroup()
for _ in 0..<4 { group.enter(); DispatchQueue.global().async { SimulatorAXExecutor.sync { SimulatorAXExecutor.sync { } }; group.leave() } }
expect(group.wait(timeout: .now() + 1) == .success, "concurrent nested executor")
let reply = SimulatorAXReply(); reply.finish(NSNumber(value: 1)); reply.finish(NSNumber(value: 2)); expect((reply.wait(SimulatorAXBudget()) as? NSNumber)?.intValue == 1, "duplicate callback")
let late = SimulatorAXReply(); expect(late.wait(SimulatorAXBudget(seconds: 0.001)) == nil, "timeout"); late.finish(NSNumber(value: 4)); expect(late.wait(SimulatorAXBudget(seconds: 0.001)) == nil, "late callback discarded")
let lost = Fake(); let lostS = try capture(lost); let lostBudget = SimulatorAXBudget(); lost.cancelOnDispatch = lostBudget; expect(try action(lostS, .press, budget: lostBudget).state == "outcomeUncertain", "lost reply quarantine"); expect(lost.dispatches == 1, "lost exactly one")
service.invalidateAll()
let missing = Fake(); missing.missingReadback = true; let missingS = try capture(missing)
expect(try action(missingS, .setValue(expected: .number(2), new: .number(4))).state == "outcomeUncertain", "missing setter readback uncertain")
expect(missing.dispatches == 1 && missing.releases == 1, "missing readback quarantines")
let expiryService = SimulatorAXInspectionService(retentionSeconds: 0.005)
let exp = Fake(); let expS = try expiryService.capture(backend: exp.backend)
usleep(15_000)
rejected { _ = try expiryService.action(SimulatorAXActionRequest(captureID: expS.captureID, nodeID: expS.nodes[0].nodeID, operation: .press)) }
expect(exp.releases == 1 && exp.dispatches == 0, "expiry releases exactly once")
let bridge = SimulatorAccessibilityBridge(); let tokenBudget = SimulatorAXBudget()
let token = bridge.register(NSObject(), budget: tokenBudget); let callback = bridge.callback(token as NSString)
expect(bridge.registrationCount == 1, "registered token")
bridge.unregister(token); expect(bridge.registrationCount == 0 && tokenBudget.cancelled, "token cleanup")
expect(callback(NSObject()) == nil, "late routing cannot retain device")
let deviceBudget = SimulatorAXBudget(), fakeDevice = SAXInspectionDevice() as! NSObject
let deviceToken = bridge.register(fakeDevice, budget: deviceBudget)
expect((bridge.callback(deviceToken as NSString)(NSObject()) as? NSNumber)?.intValue == 1, "closed bridge dispatch and separate completion queue")
bridge.unregister(deviceToken)
for _ in 0..<50 {
    let cell = SimulatorAXReply(), b = SimulatorAXBudget(seconds: 0.05)
    let done = DispatchGroup(); done.enter()
    DispatchQueue.global().async { cell.finish(NSNumber(value: 1)); cell.finish(NSNumber(value: 2)); done.leave() }
    expect((cell.wait(b) as? NSNumber)?.intValue == 1, "concurrent duplicate completion")
    expect(done.wait(timeout: .now() + 1) == .success, "completion finishes")
}
let concurrentService = SimulatorAXInspectionService(), captureGroup = DispatchGroup()
for _ in 0..<4 {
    captureGroup.enter(); DispatchQueue.global().async {
        let f = Fake(); do { let s = try concurrentService.capture(backend: f.backend); concurrentService.invalidate(s.captureID) } catch { fatalError("concurrent session failure") }; captureGroup.leave()
    }
}
expect(captureGroup.wait(timeout: .now() + 1) == .success, "concurrent sessions serialized")

// Product policy tests inject metadata scalars only; they do not pretend these fake receivers have native provenance.
let measuredMetadata = ["architecture": "arm64", "hostBuild": "26B123", "xcodeVersion": "27.2", "xcodeBuild": "27B48",
    "axpImage": SimulatorAXProductProfile.canonicalImage(SimulatorAXProductProfile.axpImage), "axpID": "com.apple.accessibility.AccessibilityPlatformTranslation", "axpVersion": "591.4.5",
    "coreImage": SimulatorAXProductProfile.canonicalImage(SimulatorAXProductProfile.coreImage), "coreID": "com.apple.CoreSimulator", "coreVersion": "1174.20", "receiverImages": "verified"]
let product = SimulatorAXNativeMetadata.qualification(runtime: SimulatorAXProductProfile.runtime, executable: "/guest/App", metadata: { measuredMetadata })
expect(product.semanticActions && product.exactGuestIdentity && product.clearProtection && !product.pointMapping, "measured product tuple, no point mapping")
expect(product.valueDomain?(.string(String(repeating: "a", count: 127))) == true, "bounded string domain")
for value in [SimulatorAXValue.string(String(repeating: "a", count: 128)), .number(1), .boolean(true)] { expect(product.valueDomain?(value) == false, "unqualified value domain") }
for runtime in ["iOS 27.2", "com.apple.CoreSimulator.SimRuntime.iOS-27-2-iPhone19-4|24B91016s", "com.apple.CoreSimulator.SimRuntime.iOS-27-2|24B115", "", "com.apple.CoreSimulator.SimRuntime.iOS-27-2"] {
    expect(!SimulatorAXNativeMetadata.qualification(runtime: runtime, executable: "/guest/App", metadata: { measuredMetadata }).semanticActions, "runtime identifier/build required")
}
for key in measuredMetadata.keys.sorted() {
    for replacement in ["", "unknown", measuredMetadata[key]! + "\n"] {
        var bad = measuredMetadata; bad[key] = replacement
        let q = SimulatorAXNativeMetadata.qualification(runtime: SimulatorAXProductProfile.runtime, executable: "/guest/App", metadata: { bad })
        expect(!q.semanticActions && !q.reason.isEmpty, "malformed/wrong native metadata refused: " + key)
    }
}
expect(!SimulatorAXNativeMetadata.qualification(runtime: SimulatorAXProductProfile.runtime, executable: "relative", metadata: { measuredMetadata }).semanticActions, "invalid executable refused")
expect(!SimulatorAXNativeMetadata.isElement(NSObject()), "fake receiver cannot claim native image")
expect(SimulatorAXNativeMetadata.read().isEmpty, "unloaded AXP/fake CoreSimulator cannot enable production")
// Same selection helper used by the normal factory, exercised with injected metadata and a fake transport.
let normalPolicyFake = Fake(); normalPolicyFake.runtime = SimulatorAXProductProfile.runtime
normalPolicyFake.qualification = SimulatorAXNativeMetadata.qualification(runtime: normalPolicyFake.runtime, executable: normalPolicyFake.executable, metadata: { measuredMetadata })
normalPolicyFake.value = "old"
let normalPolicyS = try capture(normalPolicyFake)
expect(normalPolicyS.qualificationFingerprint["runtime"] == SimulatorAXProductProfile.runtime, "snapshot carries qualified native fingerprint")
expect(normalPolicyS.nodes[0].capabilities.operations.contains("setValue"), "normal policy STRING capability")
let normalWrite = try action(normalPolicyS, .setValue(expected: .string("old"), new: .string("new")))
expect(normalWrite.state == "postconditionObserved" && normalWrite.receipt != nil, "normal policy string set receipt")
expect(try action(normalPolicyS, .restore(receipt: normalWrite.receipt!)).state == "postconditionObserved", "normal policy explicit string restore")
service.invalidateAll()
let normalNumeric = Fake(); normalNumeric.runtime = SimulatorAXProductProfile.runtime
normalNumeric.qualification = SimulatorAXNativeMetadata.qualification(runtime: normalNumeric.runtime, executable: normalNumeric.executable, metadata: { measuredMetadata })
let numericS = try capture(normalNumeric)
expect(!numericS.nodes[0].capabilities.operations.contains("setValue"), "normal policy numeric capability refused")
rejected { _ = try action(numericS, .setValue(expected: .number(2), new: .number(3))) }
expect(normalNumeric.dispatches == 0, "normal policy numeric backend refused")
service.invalidateAll()
let capFake = Fake(); let capSnapshot = try capture(capFake)
expect(Set(capSnapshot.nodes[0].capabilities.operations) == Set(["press", "increment", "decrement", "custom", "setValue"]), "operation names consumed by LCD")
capFake.enabled = false
expect(capSnapshot.nodes[0].capabilities.operations.contains("press"), "immutable capture metadata")
rejected { _ = try action(capSnapshot, .press) }
expect(capFake.dispatches == 0, "backend rejects despite stale enabled UI metadata")
service.invalidateAll()
for mode in 0..<8 {
    let f = Fake()
    switch mode {
    case 0: f.subrole = "AXSecureTextField"
    case 1: f.subroleStatus = .SAXUnsupportedSelector
    case 2: f.enabled = false
    case 3: f.protected = true
    case 4: f.qualification.clearProtection = false
    case 5: f.qualification = SimulatorAXQualification()
    case 6: f.cycle = true
    default: f.advertised = []; f.hasCustom = false; f.settable = false
    }
    let s = try capture(f)
    expect(s.nodes[0].capabilities.operations.isEmpty && !s.nodes[0].capabilities.reasons.isEmpty, "capability refusal with reason")
    if mode < 2 { expect(s.nodes[0].typedValue == nil, "secure/unknown subrole redacted before value read") }
    service.invalidateAll()
}
for value: Any in [true, 2.0, String(repeating: "a", count: 128), "editable"] {
    let f = Fake(); f.value = value
    f.qualification.valueDomain = product.valueDomain
    let s = try capture(f)
    expect(s.nodes[0].capabilities.operations.contains("setValue") == (value as? String == "editable"), "STRING-only product capability")
    service.invalidateAll()
}
let truncated = Fake(); let truncatedS = try service.capture(backend: truncated.backend, maxNodes: 1)
expect(truncatedS.nodes[0].capabilities.operations.isEmpty, "global truncation removes every node capability")
service.invalidateAll()

print("PASS \(checks) assertions")

let imageRoot = FileManager.default.temporaryDirectory.appendingPathComponent("ax-dyld-image-" + UUID().uuidString)
try FileManager.default.createDirectory(at: imageRoot.appendingPathComponent("Versions/A"), withIntermediateDirectories: true)
try FileManager.default.createSymbolicLink(atPath: imageRoot.appendingPathComponent("Versions/Current").path, withDestinationPath: "A")
try FileManager.default.createSymbolicLink(atPath: imageRoot.appendingPathComponent("Image").path, withDestinationPath: "Versions/Current/Image")
expect(SimulatorAXProductProfile.canonicalImage(imageRoot.appendingPathComponent("Image").path) == imageRoot.appendingPathComponent("Versions/A").resolvingSymlinksInPath().appendingPathComponent("Image").path, "dyld-cache leaf absence preserves exact resolved image equality")
try FileManager.default.removeItem(at: imageRoot)
print("PASS \(checks) AX assertions including absent dyld-cache executable")
