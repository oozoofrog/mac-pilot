import UIKit

typealias FixtureEditTarget = MacCUQualificationEditTarget

func makeFixtureEditTarget(frame: CGRect) -> FixtureEditTarget {
    let target = FixtureEditTarget(frame: frame)
    target.accessibilityIdentifier = "fixture.editTarget"
    target.backgroundColor = .systemPurple
    target.isHidden = false
    target.alpha = 1
    return target
}

final class FixtureEditOracle {
    private weak var target: FixtureEditTarget?
    private weak var parent: UIView?
    private weak var window: UIWindow?
    private weak var originalParent: UIView?
    private var parentGeneration = UUID().uuidString
    private var windowGeneration = UUID().uuidString
    private let sceneGeneration = UUID().uuidString
    private var timer: Timer?
    private let ioQueue = DispatchQueue(label: "product.independent-oracle")
    private var samples: [[String: Any]] = []
    private var sequence = 0
    private var baseline: [String: UInt]?
    private var handledControls = Set<String>()
    private var pendingReplacement: (request: [String: Any], frame: CGRect, generation: String, address: String)?
    private var controlReceipt: [String: Any]?

    func start(_ target: FixtureEditTarget) {
        guard timer == nil else { return }
        self.target = target
        originalParent = target.superview
        baseline = ["hidden": target.hiddenSetterCount, "alpha": target.alphaSetterCount]
        sample()
        timer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in self?.sample() }
    }

    private func sample() {
        processControl()
        guard let target, let scene = target.window?.windowScene, let baseline else { return }
        if parent !== target.superview { parent = target.superview; parentGeneration = UUID().uuidString }
        if window !== target.window { window = target.window; windowGeneration = UUID().uuidString }
        sequence += 1
        samples.append(["sequence": sequence, "unixSeconds": Date().timeIntervalSince1970,
            "uptimeSeconds": ProcessInfo.processInfo.systemUptime, "pid": getpid(),
            "name": "fixture.editTarget", "className": NSStringFromClass(type(of: target)),
            "address": String(describing: Unmanaged.passUnretained(target).toOpaque()),
            "frame": [target.frame.origin.x, target.frame.origin.y, target.frame.width, target.frame.height],
            "nodeGeneration": target.generation, "parentGeneration": parentGeneration,
            "windowGeneration": windowGeneration, "sceneGeneration": sceneGeneration,
            "sceneID": scene.session.persistentIdentifier, "sceneActivationState": scene.activationState.rawValue,
            "parentName": target.superview?.accessibilityIdentifier ?? "",
            "hidden": target.isHidden, "alpha": target.alpha,
            "setterCounts": ["hidden": target.hiddenSetterCount, "alpha": target.alphaSetterCount]])
        if samples.count > 128 { samples.removeFirst(samples.count - 128) }
        let value: [String: Any] = ["schemaVersion": 1, "constructionBaseline": baseline,
                "sampleIntervalSeconds": 0.4, "maximumSamples": 128, "samples": samples,
                "controlReceipt": controlReceipt as Any? ?? NSNull(), "faultEvents": FixtureEditTarget.eventSnapshot()]
        ioQueue.async {
        do {
            let bytes = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
            guard bytes.count <= 262_144 else { return }
            let directory = try FileManager.default.url(for: .documentDirectory, in: .userDomainMask,
                                                        appropriateFor: nil, create: true)
            try bytes.write(to: directory.appendingPathComponent("edit-oracle.json"), options: .atomic)
        } catch { fixtureDiagnostic("editOracle.writeFailed \(error)") }
        }
    }

    // Private owned-fixture commands only. No production request or LLDB extension.
    private func processControl() {
        if let pending = pendingReplacement {
            guard target == nil, let originalParent else { return }
            let replacement = makeFixtureEditTarget(frame: pending.frame)
            originalParent.addSubview(replacement)
            target = replacement
            controlReceipt = ["requestID": pending.request["requestID"]!, "action": "replace",
                "status": "deallocatedAndRecreated", "oldGeneration": pending.generation,
                "newGeneration": replacement.generation, "oldWeakNil": true,
                "oldAddress": pending.address,
                "newAddress": String(describing: Unmanaged.passUnretained(replacement).toOpaque())]
            pendingReplacement = nil
            return
        }
        do {
            let directory = try FileManager.default.url(for: .documentDirectory, in: .userDomainMask,
                                                       appropriateFor: nil, create: false)
            let url = directory.appendingPathComponent("fault-control.json")
            guard let bytes = try? Data(contentsOf: url), bytes.count <= 4096,
                  let request = try JSONSerialization.jsonObject(with: bytes) as? [String: Any],
                  Set(request.keys) == Set(["requestID", "action", "session", "pid", "nodeGeneration", "issuedUnixSeconds"]),
                  let requestID = request["requestID"] as? String, UUID(uuidString: requestID) != nil,
                  !handledControls.contains(requestID), handledControls.count < 16,
                  request["session"] as? String == ProcessInfo.processInfo.environment["MAC_CU_FIXTURE_SESSION"],
                  request["pid"] as? Int == Int(getpid()), let target,
                  request["nodeGeneration"] as? String == target.generation,
                  let issued = request["issuedUnixSeconds"] as? Double,
                  (0...8).contains(Date().timeIntervalSince1970 - issued),
                  let action = request["action"] as? String,
                  ["throwAfterWrite", "slowAfterWrite", "replace", "reparent"].contains(action) else { return }
            handledControls.insert(requestID)
            if action == "replace" {
                pendingReplacement = (request, target.frame, target.generation,
                    String(describing: Unmanaged.passUnretained(target).toOpaque()))
                controlReceipt = ["requestID": requestID, "action": action, "status": "removedAwaitingWeakNil"]
                target.removeFromSuperview()
            } else if action == "reparent", let originalParent {
                let parent = UIView(frame: originalParent.bounds)
                parent.accessibilityIdentifier = "fixture.reparent"
                originalParent.addSubview(parent)
                parent.addSubview(target)
                controlReceipt = ["requestID": requestID, "action": action, "status": "reparented",
                                  "nodeGeneration": target.generation]
            } else {
                let armed = target.armFault(action, requestID: requestID)
                controlReceipt = ["requestID": requestID, "action": action, "status": armed ? "armed" : "refused"]
            }
        } catch { fixtureDiagnostic("faultControl.readFailed \(error)") }
    }

    deinit { timer?.invalidate() }
}
