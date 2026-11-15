import AppKit

/// Internal injection is used by isolated checks. No transport field can enable a validation route.
struct SimulatorInspectorBackend {
    var capture: (SimulatorViewEditableCaptureRequest, SimulatorViewCaptureCancellation) throws -> SimulatorViewCaptureResult = {
        try simulatorCaptureEditableViews($0, cancellation: $1)
    }
    var edit: (SimulatorViewEditRequest, SimulatorViewCaptureCancellation) throws -> SimulatorViewMutationResult = {
        try simulatorEditView($0, cancellation: $1)
    }
    var revert: (SimulatorViewRevertRequest, SimulatorViewCaptureCancellation) throws -> SimulatorViewMutationResult = {
        try simulatorRevertView($0, cancellation: $1)
    }
    var release: (SimulatorViewReleaseRequest, SimulatorViewCaptureCancellation) throws -> SimulatorViewMutationResult = {
        try simulatorReleaseViews($0, cancellation: $1)
    }
}

/// Main-thread owner of one inspector. Slow debugger work never occupies the LCD's HID queue.
final class SimulatorInspectorCoordinator {
    private struct Ticket {
        let id = UUID()
        let context: SimulatorInspectorContext
        let generation: UInt64
        let cancellation = SimulatorViewCaptureCancellation()
    }
    private struct Session {
        let context: SimulatorViewEditingContext
        let scope: SimulatorAXScope
        let identities: [UUID: SimulatorViewEditIdentity]
        var sequence: UInt64 = 2
    }
    private static var queues: [String: DispatchQueue] = [:] // Main-thread access; survives close/reopen.
    private weak var owner: SimulatorWindow?
    private let backend: SimulatorInspectorBackend
    private let work: DispatchQueue
    private var ownerID = UUID()
    private var revision: UInt64 = 1
    private var controller: SimulatorInspectorWindowController?
    private var pending: Ticket?
    private var session: Session?
    private var closing = false
    private var custody = 0
    private var cleanupUncertain = false
    private var recording = false

    // Host work settled is not native release proof. The harness must still
    // validate the durable release receipt before retiring a target.
    var hostWorkSettled: Bool {
        precondition(Thread.isMainThread)
        return custody == 0 && pending == nil
    }

    init(owner: SimulatorWindow, backend: SimulatorInspectorBackend = SimulatorInspectorBackend()) {
        precondition(Thread.isMainThread)
        self.owner = owner; self.backend = backend
        let queue = Self.queues[owner.id] ?? DispatchQueue(label: "mac-cu.inspector.\(owner.id)", qos: .userInitiated)
        Self.queues[owner.id] = queue; work = queue
    }

    private func context() -> SimulatorInspectorContext? {
        guard let owner else { return nil }
        return SimulatorInspectorContext(deviceID: owner.id, displayID: owner.active?.id ?? "main",
            targetID: "", targetLabel: "현재 LCD 앱 · 캡처 전", presentationRevision: revision)
    }
    func open() {
        precondition(Thread.isMainThread)
        guard !closing, let context = context() else { return }
        if let controller, !controller.isClosed { controller.showWindow(nil); controller.window?.makeKeyAndOrderFront(nil); return }
        // A new window gets new authority. The shared queue and backend release
        // proof still fence its capture behind cleanup of the prior inspection.
        ownerID = UUID()
        let callbacks = SimulatorInspectorCallbacks(
            capture: { [weak self] context, generation, completion in self?.capture(context, generation: generation, completion: completion) },
            cancel: { [weak self] context, generation in self?.cancel(context, generation: generation) },
            edit: { [weak self] context, command, completion in self?.edit(context, command: command, completion: completion) },
            revert: { [weak self] context, envelope, completion in self?.revert(context, envelope: envelope, completion: completion) },
            release: { [weak self] _, inspection in self?.release(inspectionID: inspection, reason: .refresh) },
            restoreHostFocus: { [weak self] in
                guard let self else { return }
                self.controller = nil
                guard !self.closing, let owner = self.owner, owner.window.isVisible, NSApp.isActive else { return }
                owner.window.makeKeyAndOrderFront(nil); owner.toolbox.focusInspection()
            })
        var wired = callbacks
        wired.prepareRecording = { [weak self] context, completion in self?.prepareRecording(context, completion: completion) }
        controller = SimulatorInspectorWindowController(context: context, callbacks: wired)
        controller?.window?.center(); controller?.showWindow(nil); controller?.window?.makeKeyAndOrderFront(nil)
    }

    func invalidate(reason: String) {
        precondition(Thread.isMainThread)
        pending?.cancellation.cancel(); pending = nil
        release(inspectionID: nil, reason: .targetChanged)
        revision &+= 1
        if let context = context() { controller?.updateContext(context) }
        controller?.markStale(reason: reason)
    }
    func close() {
        precondition(Thread.isMainThread)
        closing = true; invalidate(reason: "LCD 창이 닫혔습니다."); controller?.close(); controller = nil
    }
    private func cancel(_ context: SimulatorInspectorContext, generation: UInt64) {
        if let pending, pending.context == context, pending.generation == generation {
            pending.cancellation.cancel(); self.pending = nil
        }
    }
    private func current(_ ticket: Ticket) -> Bool {
        pending?.id == ticket.id && !closing && !ticket.cancellation.isCancelled &&
            owner != nil && controller?.isClosed == false && ticket.context.presentationRevision == revision
    }
    private func start(_ context: SimulatorInspectorContext, generation: UInt64) throws -> Ticket {
        guard !closing, !recording, pending == nil, let owner, context.deviceID == owner.id,
              context.presentationRevision == revision else { throw ToolError("검사 대상이 바뀌었습니다. 새로 캡처하세요.") }
        let ticket = Ticket(context: context, generation: generation); pending = ticket; return ticket
    }

    private func capture(_ context: SimulatorInspectorContext, generation: UInt64,
                         completion: @escaping (Result<SimulatorInspectorCapture, Error>) -> Void) {
        precondition(Thread.isMainThread)
        guard let owner else { completion(.failure(ToolError("LCD 창이 닫혔습니다."))); return }
        let ticket: Ticket
        do { ticket = try start(context, generation: generation) }
        catch { completion(.failure(error)); return }
        let device = owner.device, expectedPresentation = SimulatorInspectionHost.presentation(device: device, screen: owner.active)
        handleQueue.async { [self] in
            let targetResult: Result<(SimulatorViewCaptureTarget, SimulatorAXScope, String), Error> = Result {
                guard !ticket.cancellation.isCancelled else { throw ToolError("캡처가 취소되었습니다.") }
                let screen = try activeScreen(of: device)
                let scope = try SimulatorInspectionHost.prepare(device: device, screen: screen)
                guard scope.presentation == expectedPresentation, (screen?.id ?? "main") == context.displayID else {
                    throw ToolError("현재 LCD와 기기 화면이 다릅니다. 화면을 확인하고 다시 캡처하세요.")
                }
                let pid = try simulatorFrontPid(device)
                let target = try simulatorViewCaptureTarget(pid: pid, deviceID: context.deviceID)
                guard try simulatorFrontPid(device) == pid else { throw ToolError("전면 앱이 바뀌었습니다. 다시 캡처하세요.") }
                return (target, scope, processName(pid))
            }
            DispatchQueue.main.async { [self] in
                guard current(ticket) else { return }
                do {
                    let (target, scope, name) = try targetResult.get()
                    var request = SimulatorViewEditableCaptureRequest(target: target)
                    request.ownerID = ownerID
                    request.inspectionScope = ["deviceID": scope.deviceID, "bootIdentity": scope.deviceLifetime,
                        "displayID": context.displayID, "presentation": scope.presentation,
                        "generation": scope.generation, "runtime": scope.runtime]
                    let bound = SimulatorInspectorContext(deviceID: context.deviceID, displayID: context.displayID,
                        targetID: "\(target.pid):\(target.start):\(target.path)", targetLabel: "\(name) · PID \(target.pid)",
                        presentationRevision: context.presentationRevision)
                    custody += 1
                    work.async { [self] in
                        let response = Result { () throws -> SimulatorViewCaptureResult in
                            guard !ticket.cancellation.isCancelled,
                                  try SimulatorAXHostLifecycle.shared.current(deviceID: context.deviceID) == scope else {
                                throw ToolError("캡처 전에 화면 또는 대상이 바뀌었습니다.")
                            }
                            func fresh() throws {
                                try handleQueue.sync {
                                    let screen = try activeScreen(of: device)
                                    guard try SimulatorInspectionHost.prepare(device: device, screen: screen) == scope,
                                          (screen?.id ?? "main") == context.displayID,
                                          try simulatorFrontPid(device) == target.pid,
                                          NSDictionary(dictionary: try simulatorViewCaptureTarget(pid: target.pid, deviceID: context.deviceID).json).isEqual(to: target.json)
                                    else { throw ToolError("Inspection boot, presentation or target changed.") }
                                }
                            }
                            try fresh()
                            let result = try backend.capture(request, ticket.cancellation)
                            do { try fresh() }
                            catch {
                                if let arrived = try? SimulatorViewEditingContext(target: target, result: result) {
                                    let cleanup = SimulatorViewReleaseRequest(context: arrived, reason: .targetChanged, sequence: 2)
                                    _ = try? backend.release(cleanup, SimulatorViewCaptureCancellation())
                                }
                                throw error
                            }
                            return result
                        }
                        DispatchQueue.main.async { [self] in
                            custody -= 1
                            var arrived: SimulatorViewEditingContext?
                            do {
                                let result = try response.get()
                                arrived = try? SimulatorViewEditingContext(target: target, result: result)
                                guard current(ticket), try SimulatorAXHostLifecycle.shared.current(deviceID: context.deviceID) == scope else {
                                    if let arrived { release(arrived, sequence: 2, reason: .cancel) }
                                    return
                                }
                                pending = nil
                                guard result.status == .success else {
                                    throw ToolError(result.content["message"] as? String ?? "뷰 캡처를 완료하지 못했습니다: \(result.status.rawValue)")
                                }
                                let parsed = try SimulatorInspectorSnapshot.parse(result.content, context: bound)
                                if parsed.editing != nil {
                                    guard let arrived, let snapshot = result.content["snapshot"] as? [String: Any] else {
                                        throw ToolError("편집 캡처의 대상 수명을 확인할 수 없습니다.")
                                    }
                                    session = Session(context: arrived, scope: scope, identities: try Self.identities(snapshot))
                                }
                                completion(.success(SimulatorInspectorCapture(context: bound, payload: result.content)))
                            } catch {
                                if let arrived { release(arrived, sequence: 2, reason: .cancel) }
                                if pending?.id == ticket.id { pending = nil }
                                if !ticket.cancellation.isCancelled { completion(.failure(error)) }
                            }
                        }
                    }
                } catch { pending = nil; completion(.failure(error)) }
            }
        }
    }


    private func prepareRecording(_ context: SimulatorInspectorContext,
        completion: @escaping (Result<SimulatorInspectorContext, Error>) -> Void) {
        precondition(Thread.isMainThread)
        guard !recording, !closing, pending == nil, custody == 0, !cleanupUncertain,
              let owner, let s = session, context == controller?.model.context,
              context.presentationRevision == revision, context.deviceID == owner.id else {
            completion(.failure(ToolError("진행 중인 작업 또는 정리되지 않은 검사 권한이 있습니다. 재실행하지 않았습니다."))); return
        }
        let device = owner.device
        let cancellation = SimulatorViewCaptureCancellation()
        let ticket = Ticket(context: context, generation: controller?.model.generation ?? 0)
        pending = ticket; recording = true; custody += 1
        work.async { [self] in
            var releaseVerified = false
            var outcomeUncertain = false
            let response = Result { () throws -> SimulatorInspectorContext in
                func fresh() throws {
                    guard !ticket.cancellation.isCancelled else { throw ToolError("검사 대상이 바뀌었습니다.") }
                    try handleQueue.sync {
                        let screen = try activeScreen(of: device)
                        guard try SimulatorInspectionHost.prepare(device: device, screen: screen) == s.scope,
                              (screen?.id ?? "main") == context.displayID,
                              try simulatorFrontPid(device) == s.context.target.pid,
                              NSDictionary(dictionary: try simulatorViewCaptureTarget(pid: s.context.target.pid, deviceID: context.deviceID).json).isEqual(to: s.context.target.json)
                        else { throw ToolError("앱 수명, 부팅 또는 화면이 바뀌었습니다. 재실행하지 않았습니다.") }
                    }
                }
                try fresh()
                outcomeUncertain = true
                let released = try backend.release(.init(context: s.context, reason: .close, sequence: s.sequence), cancellation)
                guard released.status == .success, released.cleanup["detach"] as? String == "success",
                      released.cleanup["childrenReaped"] as? Bool == true,
                      (released.cleanup["recovery"] as? [String: Any])?["verified"] as? Bool == true,
                      released.content["registryReleased"] as? Bool == true else {
                    throw ToolError("검사 세션 정리를 확인하지 못했습니다. 재실행하지 않았습니다.")
                }
                releaseVerified = true; outcomeUncertain = false
                try fresh()
                outcomeUncertain = true
                let result = try simulatorPrepareSwiftUIRecording(target: s.context.target, scope: s.scope, cancellation: ticket.cancellation)
                if let stage = result["stage"] as? String,
                   ["notDispatched", "terminated", "newLifetimeBound"].contains(stage) {
                    outcomeUncertain = false
                }
                guard result["status"] as? String == "success", let target = result["target"] as? [String: Any],
                      let pid = target["pid"] as? Int32 else {
                    throw ToolError("재실행 결과: \(result["stage"] ?? "unknown") · \(result["message"] ?? "결과 확인 필요") · \(result["evidenceDirectory"] ?? "")")
                }
                let bound = try simulatorViewCaptureTarget(pid: pid, deviceID: context.deviceID)
                guard NSDictionary(dictionary: bound.json).isEqual(to: target),
                      try SimulatorAXHostLifecycle.shared.current(deviceID: context.deviceID) == s.scope else {
                    throw ToolError("새 실행의 수명 또는 화면을 확인하지 못했습니다. 자동 재시도하지 않습니다.")
                }
                return .init(deviceID: context.deviceID, displayID: context.displayID,
                    targetID: "\(bound.pid):\(bound.start):\(bound.path)", targetLabel: "새 실행 · PID \(bound.pid)", presentationRevision: context.presentationRevision)
            }
            let verifiedRelease = releaseVerified, uncertain = outcomeUncertain
            DispatchQueue.main.async { [self] in
                custody -= 1; recording = false
                if verifiedRelease { session = nil }
                if pending?.id == ticket.id { pending = nil }
                // Failure may include uncertain native custody or launch: require reconciliation.
                if uncertain { cleanupUncertain = true }
                guard !closing else { return }
                if ticket.cancellation.isCancelled {
                    completion(.failure(ToolError("검사 대상이 바뀌었습니다. 재실행 결과를 확인한 뒤 새로 캡처하세요.")))
                } else { completion(response) }
            }
        }
    }

    private static func identities(_ snapshot: [String: Any]) throws -> [UUID: SimulatorViewEditIdentity] {
        var result: [UUID: SimulatorViewEditIdentity] = [:]
        func visit(_ nodes: [[String: Any]], depth: Int) throws {
            guard depth <= 512 else { throw ToolError("편집 계층의 깊이가 너무 큽니다.") }
            for node in nodes {
                let identity = try SimulatorViewEditIdentity(node: node)
                guard result.count < 20_000, result.updateValue(identity, forKey: identity.editToken) == nil else {
                    throw ToolError("편집 노드 식별자가 중복되었거나 한도를 초과했습니다.")
                }
                try visit(node["children"] as? [[String: Any]] ?? [], depth: depth + 1)
            }
        }
        try visit(snapshot["roots"] as? [[String: Any]] ?? [], depth: 0); return result
    }
    private func editingSession(_ context: SimulatorInspectorContext, captureID: String,
                                inspectionID: String, ownerID: String, targetEpoch: String) throws -> Session {
        guard let session, context == controller?.model.context,
              session.context.captureID.uuidString == captureID,
              session.context.inspectionID.uuidString == inspectionID,
              session.context.ownerID.uuidString == ownerID, session.context.targetEpoch.uuidString == targetEpoch,
              try SimulatorAXHostLifecycle.shared.current(deviceID: context.deviceID) == session.scope else {
            throw ToolError("편집 권한이나 대상이 바뀌었습니다. 새로 캡처하세요.")
        }
        return session
    }
    private func edit(_ context: SimulatorInspectorContext, command: InspectorCommand,
                      completion: @escaping (Result<[String: Any], Error>) -> Void) {
        do {
            var s = try editingSession(context, captureID: command.captureID, inspectionID: command.inspection.inspectionID,
                ownerID: command.inspection.ownerID, targetEpoch: command.inspection.targetEpoch)
            guard let token = UUID(uuidString: command.editToken), let identity = s.identities[token] else { throw ToolError("선택한 편집 노드가 없습니다.") }
            func convert(_ value: InspectorEditValue) -> SimulatorViewEditableValue {
                switch value { case .hidden(let b): return .hidden(b); case .alpha(let a): return .alpha(a) }
            }
            let request = SimulatorViewEditRequest(context: s.context, identity: identity, expected: convert(command.expected),
                value: convert(command.requested), operationID: command.operationID, sequence: s.sequence)
            s.sequence &+= 1; session = s
            mutate(context, completion: completion) { [backend] in try backend.edit(request, $0) }
        } catch { completion(.failure(error)) }
    }
    private func revert(_ context: SimulatorInspectorContext, envelope: [String: Any],
                        completion: @escaping (Result<[String: Any], Error>) -> Void) {
        do {
            guard let op = (envelope["operationID"] as? String).flatMap(UUID.init(uuidString:)),
                  let undo = (envelope["undoToken"] as? String).flatMap(UUID.init(uuidString:)),
                  let capture = envelope["captureID"] as? String, let inspection = envelope["inspectionID"] as? String,
                  let owner = envelope["ownerID"] as? String, let epoch = envelope["targetEpoch"] as? String else { throw ToolError("복원 식별자가 잘못되었습니다.") }
            var s = try editingSession(context, captureID: capture, inspectionID: inspection, ownerID: owner, targetEpoch: epoch)
            let request = SimulatorViewRevertRequest(context: s.context, undoToken: undo, operationID: op, sequence: s.sequence)
            s.sequence &+= 1; session = s
            mutate(context, completion: completion) { [backend] in try backend.revert(request, $0) }
        } catch { completion(.failure(error)) }
    }
    private func mutate(_ context: SimulatorInspectorContext, completion: @escaping (Result<[String: Any], Error>) -> Void,
                        body: @escaping (SimulatorViewCaptureCancellation) throws -> SimulatorViewMutationResult) {
        do {
            let ticket = try start(context, generation: controller?.model.generation ?? 0)
            let scope = session?.scope
            custody += 1
            work.async { [self] in
                let response = Result { () throws -> [String: Any] in
                    guard !ticket.cancellation.isCancelled,
                          try SimulatorAXHostLifecycle.shared.current(deviceID: context.deviceID) == scope else { throw ToolError("실행 전에 편집 대상이 바뀌었습니다.") }
                    return try body(ticket.cancellation).content
                }
                DispatchQueue.main.async { [self] in
                    custody -= 1
                    guard current(ticket) else { return }
                    pending = nil; completion(response)
                }
            }
        } catch { completion(.failure(error)) }
    }
    private func release(inspectionID: String?, reason: SimulatorViewReleaseReason) {
        guard !recording, let session, inspectionID == nil || inspectionID == session.context.inspectionID.uuidString else { return }
        self.session = nil; release(session.context, sequence: session.sequence, reason: reason)
    }
    private func release(_ context: SimulatorViewEditingContext, sequence: UInt64, reason: SimulatorViewReleaseReason) {
        let request = SimulatorViewReleaseRequest(context: context, reason: reason, sequence: sequence)
        custody += 1
        work.async { [self] in
            defer { DispatchQueue.main.async { self.custody -= 1 } }
            do {
                let result = try backend.release(request, SimulatorViewCaptureCancellation())
                guard result.status == .success || result.status == .expired else {
                    throw ToolError("\(result.status.rawValue): \(result.content["message"] ?? "")")
                }
            } catch {
                DispatchQueue.main.async { [weak self] in
                    self?.cleanupUncertain = true
                    self?.owner?.content.chrome.showFeedback("편집 권한은 해제했지만 앱 내부 정리는 확인하지 못했습니다. \(error.localizedDescription)")
                }
            }
        }
    }
}
