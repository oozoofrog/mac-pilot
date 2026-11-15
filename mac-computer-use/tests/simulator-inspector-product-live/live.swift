import AppKit
import MetalKit

// Compiled beside the complete canonical host. Never injects a backend or calls wrappers.
// A failed/cancelled task must keep servicing main-queue custody completions.
// This wait admits no UI input or backend operation and does not grant release.
func inspectorOwnerMonotonic() -> Double {
    var value = timespec()
    guard clock_gettime(CLOCK_MONOTONIC, &value) == 0 else { return .infinity }
    return Double(value.tv_sec) + Double(value.tv_nsec) / 1_000_000_000
}

@MainActor func waitForInspectorOwner(deadline: Double, settled: () -> Bool) async -> Bool {
    while !settled() {
        guard inspectorOwnerMonotonic() < deadline else { return false }
        await withCheckedContinuation { continuation in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { continuation.resume() }
        }
    }
    return true
}

func inspectorHostChildrenSettled(_ state: [String: Any]) -> Bool {
    guard let ops = state["operations"] as? [String: [String: Any]],
          let results = state["results"] as? [String: [String: Any]] else { return false }
    return ops.allSatisfy { id, operation in
        // Ledger.finish deliberately stores only a compact cleanup summary.
        // Join the complete receipt before deciding that native child custody ended.
        guard operation["state"] as? String == "finished", let stored = results[id],
              let directory = stored["evidenceDirectory"] as? String else { return false }
        let directoryFD = Darwin.open(directory, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard directoryFD >= 0 else { return false }
        defer { Darwin.close(directoryFD) }
        let fd = openat(directoryFD, "result.json", O_RDONLY | O_NOFOLLOW)
        guard fd >= 0 else { return false }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close() }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == geteuid(),
              info.st_nlink == 1, info.st_size > 0, info.st_size <= 16_777_216,
              let bytes = try? handle.read(upToCount: 16_777_217), bytes.count == info.st_size,
              let result = (try? JSONSerialization.jsonObject(with: bytes)) as? [String: Any],
              result["operationID"] as? String == id,
              let digest = operation["digest"] as? String,
              result["requestDigest"] as? String == digest, stored["requestDigest"] as? String == digest,
              let target = state["target"] as? NSDictionary, result["target"] as? NSDictionary == target,
              let owner = state["ownerID"] as? String, result["ownerID"] as? String == owner,
              let inspection = state["inspectionID"] as? String, result["inspectionID"] as? String == inspection,
              let epoch = state["epoch"] as? String, result["targetEpoch"] as? String == epoch,
              stored["targetEpoch"] as? String == epoch,
              result["validationOnly"] as? Bool == false,
              let cleanup = result["cleanup"] as? [String: Any] else { return false }
        return cleanup["childrenReaped"] as? Bool == true && cleanup["debuggerClosed"] as? Bool == true
            && cleanup["custodyRequired"] as? Bool != true && cleanup["activeCall"] is NSNull
    }
}

func inspectorLifetimesSettled(_ histories: [[String: Any]]) -> Bool {
    !histories.isEmpty && histories.allSatisfy(inspectorHostChildrenSettled)
}

@MainActor private var failureCustody: (() async -> Bool)?

func inspectorCaptureEnvelope(_ state: [String: Any], captureID: String) throws -> [String: Any] {
    guard let operations = state["operations"] as? [String: [String: Any]],
          let results = state["results"] as? [String: [String: Any]],
          let target = state["target"] as? [String: Any] else { throw ToolError("Capture ledger is absent") }
    let matches = results.filter { $0.value["captureID"] as? String == captureID && operations[$0.key]?["kind"] as? String == "capture" }
    guard matches.count == 1, let (id, stored) = matches.first,
          let operation = operations[id], operation["state"] as? String == "finished",
          let directory = stored["evidenceDirectory"] as? String else { throw ToolError("Finished capture receipt is absent or ambiguous") }
    let directoryFD = Darwin.open(directory, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
    guard directoryFD >= 0 else { throw ToolError("Capture evidence directory is unavailable") }
    defer { Darwin.close(directoryFD) }
    let fd = openat(directoryFD, "result.json", O_RDONLY | O_NOFOLLOW)
    guard fd >= 0 else { throw ToolError("Full capture result is unavailable") }
    let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    defer { try? handle.close() }
    var info = stat()
    guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == geteuid(),
          info.st_size > 0, info.st_size <= 16_777_216,
          let bytes = try handle.read(upToCount: 16_777_217), bytes.count == info.st_size,
          var result = try JSONSerialization.jsonObject(with: bytes) as? [String: Any],
          result["status"] as? String == "success", result["operationID"] as? String == id,
          let digest = operation["digest"] as? String,
          result["requestDigest"] as? String == digest, stored["requestDigest"] as? String == digest,
          result["target"] as? NSDictionary == target as NSDictionary,
          result["validationOnly"] as? Bool == false, result["captureID"] as? String == captureID else {
        throw ToolError("Full capture result does not match its durable receipt")
    }
    for (key, stateKey) in [("ownerID", "ownerID"), ("inspectionID", "inspectionID"), ("targetEpoch", "epoch")] {
        guard let value = state[stateKey] as? String, result[key] as? String == value,
              stored[key] as? String == value else { throw ToolError("Capture ownership differs") }
    }
    // Ledger.finish omits the capture payload. Rebuild through the same converter as the host.
    result["snapshot"] = try simulatorEditableViewHierarchySnapshot(result: result, target: target)
    return result
}

func inspectorRecordingCursor(_ url: URL) throws -> [String: Any] {
    let fd = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW)
    guard fd >= 0 else { throw ToolError("Owner cursor unavailable") }
    let file = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    defer { try? file.close() }
    var info = stat()
    guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == geteuid(),
          info.st_mode & 0o077 == 0, info.st_nlink == 1, info.st_size > 0, info.st_size <= 65_536,
          let raw = try file.read(upToCount: 65_537), raw.count == info.st_size,
          let result = try JSONSerialization.jsonObject(with: raw) as? [String: Any] else { throw ToolError("Invalid owner cursor") }
    return result
}

func inspectorPublishRecordingArtifact(_ out: URL, _ name: String, _ value: Any) throws {
    guard ["recording-ready.json", "recording-action.json"].contains(name) else { throw ToolError("Unknown recording artifact") }
    let bytes = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .prettyPrinted])
    guard !bytes.isEmpty, bytes.count <= 65_536 else { throw ToolError("Recording artifact exceeds bound") }
    func directory() throws -> Int32 {
        var fd = Darwin.open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard fd >= 0 else { throw ToolError("Recording artifact root unavailable") }
        for part in out.pathComponents.dropFirst() {
            let next = openat(fd, part, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            Darwin.close(fd)
            guard next >= 0 else { throw ToolError("Recording artifact directory unavailable") }
            fd = next
        }
        return fd
    }
    let parent = try directory()
    defer { Darwin.close(parent) }
    var parentInfo = stat()
    guard fstat(parent, &parentInfo) == 0, parentInfo.st_uid == geteuid(), parentInfo.st_mode & 0o077 == 0 else {
        throw ToolError("Recording artifact directory is not private/current user")
    }
    let temporary = ".recording-" + UUID().uuidString
    let fd = openat(parent, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
    guard fd >= 0 else { throw ToolError("Recording artifact staging failed") }
    var owned = stat()
    defer {
        var current = stat()
        if fstatat(parent, temporary, &current, AT_SYMLINK_NOFOLLOW) == 0,
           current.st_dev == owned.st_dev, current.st_ino == owned.st_ino { unlinkat(parent, temporary, 0) }
        Darwin.close(fd)
    }
    guard fstat(fd, &owned) == 0, fchmod(fd, 0o600) == 0 else { throw ToolError("Recording artifact private mode failed") }
    let count = bytes.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
    guard count == bytes.count, fsync(fd) == 0, fstat(fd, &owned) == 0,
          owned.st_mode & S_IFMT == S_IFREG, owned.st_mode & 0o777 == 0o600,
          owned.st_uid == geteuid(), owned.st_nlink == 1, owned.st_size == bytes.count else {
        throw ToolError("Recording artifact write failed")
    }
    func matches(_ name: String) -> Bool {
        var current = stat()
        return fstatat(parent, name, &current, AT_SYMLINK_NOFOLLOW) == 0 &&
            current.st_dev == owned.st_dev && current.st_ino == owned.st_ino &&
            current.st_mode == owned.st_mode && current.st_uid == owned.st_uid &&
            current.st_nlink == 1 && current.st_size == owned.st_size &&
            current.st_mtimespec.tv_sec == owned.st_mtimespec.tv_sec &&
            current.st_mtimespec.tv_nsec == owned.st_mtimespec.tv_nsec
    }
    func parentMatches() throws -> Bool {
        let currentParent = try directory()
        defer { Darwin.close(currentParent) }
        var currentInfo = stat()
        return fstat(currentParent, &currentInfo) == 0 && currentInfo.st_dev == parentInfo.st_dev &&
            currentInfo.st_ino == parentInfo.st_ino && currentInfo.st_uid == parentInfo.st_uid &&
            currentInfo.st_mode == parentInfo.st_mode
    }
    guard try parentMatches(), matches(temporary) else { throw ToolError("Recording artifact staging replaced") }
    // Exclusive rename publishes the already-private complete inode; no existing destination is overwritten.
    guard renameatx_np(parent, temporary, parent, name, UInt32(RENAME_EXCL)) == 0 else { throw ToolError("Recording artifact already exists or publication failed") }
    guard try parentMatches(), matches(name), fsync(parent) == 0 else { throw ToolError("Recording artifact publication replaced") }
}

func runInspectorProductLive() -> Never {
    NSApplication.shared.setActivationPolicy(.accessory)
    Task { @MainActor in
        do { try await inspectorProductWorkflow(); exit(0) }
        catch {
            fputs("FAIL product UI: \(error)\n", stderr)
            if let failureCustody, !(await failureCustody()) {
                fputs("UNRESOLVED product UI custody; owner retained for reconciliation\n", stderr)
                return // Keep NSApplication.run and the actual owner alive.
            }
            exit(1)
        }
    }
    NSApplication.shared.run(); exit(1)
}

@MainActor private func inspectorProductWorkflow() async throws {
    let requestURL = URL(fileURLWithPath: ProcessInfo.processInfo.environment["INSPECTOR_PRODUCT_REQUEST"]!)
    let request = try JSONSerialization.jsonObject(with: Data(contentsOf: requestURL)) as! [String: Any]
    let id = request["deviceID"] as! String
    var pid = (request["pid"] as! NSNumber).int32Value
    let out = URL(fileURLWithPath: request["output"] as! String)
    var ledgerURL = URL(fileURLWithPath: request["ledger"] as! String)
    var ledgerHistory = [ledgerURL]
    let oracleURL = URL(fileURLWithPath: request["documents"] as! String).appendingPathComponent("edit-oracle.json")
    func check(_ yes: @autoclosure () -> Bool, _ message: String) throws {
        guard yes() else { throw ToolError(message) }; print("PASS \(message)")
    }
    func save(_ name: String, _ value: Any) throws {
        try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys,.prettyPrinted]).write(to: out.appendingPathComponent(name), options: .atomic)
    }
    func json(_ url: URL) throws -> [String: Any] { try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any] }
    func ledger() -> [String: Any] { (try? json(ledgerURL)) ?? [:] }
    func operations() -> [String: [String: Any]] { ledger()["operations"] as? [String: [String: Any]] ?? [:] }
    func views(_ v: NSView) -> [NSView] { [v] + v.subviews.flatMap(views) }
    let session = CGSessionCopyCurrentDictionary() as? [String: Any]
    try check(session?["CGSSessionScreenIsLocked"] as? Bool != true && session?["kCGSSessionOnConsoleKey"] as? Bool == true && CGDisplayIsAsleep(CGMainDisplayID()) == 0, "unlocked awake console")
    let previous = NSWorkspace.shared.frontmostApplication
    try check(previous?.processIdentifier == (request["hostPID"] as! NSNumber).int32Value, "original host focus")
    let events: [CGEventType] = [.leftMouseDown,.leftMouseUp,.rightMouseDown,.rightMouseUp,.otherMouseDown,.otherMouseUp,.mouseMoved,.leftMouseDragged,.rightMouseDragged,.otherMouseDragged,.keyDown,.keyUp,.flagsChanged,.scrollWheel]
    func counters() -> [UInt32] { events.map { CGEventSource.counterForEventType(.combinedSessionState, eventType: $0) } }
    let baseline = counters(), started = Date()
    func guardInput() throws {
        try check(counters() == baseline && NSApp.isActive && !FileManager.default.fileExists(atPath: out.appendingPathComponent("stop-ui").path) && Date().timeIntervalSince(started) < 1080, "input/focus/deadline guard")
    }
    func pause() async throws { try await Task.sleep(nanoseconds: 50_000_000) }
    func wait(_ label: String, seconds: Double = 165, _ predicate: () -> Bool) async throws {
        let end = Date().addingTimeInterval(seconds)
        while !predicate() { try guardInput(); guard Date() < end else { throw ToolError("deadline: \(label)") }; try await pause() }
        try guardInput()
    }
    func background<T>(_ body: @escaping () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { c in handleQueue.async { c.resume(with: Result(catching: body)) } }
    }
    let (device, active) = try await background { () -> (NSObject, ActiveScreen?) in
        let d = try bootedDevice(id), life = try SimulatorAXLifetime.current(pid)
        guard try simulatorFrontPid(d) == pid, life.executable == request["path"] as? String,
              [life.startSeconds, life.startMicroseconds] == request["start"] as? [UInt64] else { throw ToolError("selected device/target lifetime changed") }
        return (d, try activeScreen(of: d))
    }
    let defaultsDomain = Bundle.main.bundleIdentifier!
    let priorDefaults = UserDefaults.standard.persistentDomain(forName: defaultsDomain) ?? [:]
    let lcd = SimulatorWindow(device: device, active: active); simulatorWindows[id] = lcd
    failureCustody = {
        let deadline = request["ownerDeadlineMonotonic"] as! Double
        try? save("ui-cleanup.json", ["state":"waiting", "passed":false])
        let settled = await waitForInspectorOwner(deadline: deadline) {
            guard lcd.inspectionHostWorkSettled else { return false }
            return inspectorLifetimesSettled(ledgerHistory.map { (try? json($0)) ?? [:] })
        }
        try? save("ui-cleanup.json", ["state":settled ? "hostSettled" : "unresolved", "passed":false,
                                     "releaseProof":false])
        return settled
    }
    defer {
        let restore = NSApp.isActive && counters() == baseline
        lcd.window.close(); simulatorWindows.removeValue(forKey: id)
        UserDefaults.standard.setPersistentDomain(priorDefaults, forName: defaultsDomain)
        UserDefaults.standard.synchronize()
        if restore { previous?.activate(options: []) }
    }
    bringSimulatorWindowToFront(lcd) // Sole declared foreground acquisition; no repeated activation.
    if !lcd.content.toolsVisible { lcd.toggleToolbox() }
    // Activation is asynchronous. Admit no local action until it completes;
    // during this initial transition only the original host or this app may own focus.
    let activationEnd = Date().addingTimeInterval(3)
    while !NSApp.isActive {
        let front = NSWorkspace.shared.frontmostApplication?.processIdentifier
        try check(counters() == baseline && (front == previous?.processIdentifier || front == ProcessInfo.processInfo.processIdentifier)
                  && !FileManager.default.fileExists(atPath: out.appendingPathComponent("stop-ui").path)
                  && Date() < activationEnd, "initial activation input/focus/deadline guard")
        try await pause()
    }
    try guardInput()
    try await wait("initial LCD key window", seconds: 3) { lcd.window.isKeyWindow }
    func button(_ title: String, in window: NSWindow) throws -> NSButton {
        guard let b = views(window.contentView!).compactMap({ $0 as? NSButton }).first(where: { $0.title == title }) else { throw ToolError("missing control \(title)") }; return b
    }
    func click(_ title: String, in window: NSWindow) throws {
        try guardInput(); try check(window.isKeyWindow || window === lcd.toolbox.window, "local control target focus")
        let b = try button(title, in: window); try check(b.isEnabled, "enabled \(title)")
        b.scrollToVisible(b.bounds)
        if title == "3D 뷰 검사…" {
            try check(b.sendAction(b.action, to: b.target), "3D button target/action dispatched")
        } else { b.performClick(nil) }
    }
    func inspector() throws -> SimulatorInspectorWindowController {
        guard let c = NSApp.windows.compactMap({ $0.windowController as? SimulatorInspectorWindowController }).first(where: { !$0.isClosed }) else { throw ToolError("actual inspector window missing") }; return c
    }
    func open() async throws -> SimulatorInspectorWindowController {
        try click("3D 뷰 검사…", in: lcd.toolbox.window!)
        try await pause(); let c = try inspector()
        try save("open-window-state.json", NSApp.windows.map { ["title":$0.title,"key":$0.isKeyWindow,"main":$0.isMainWindow,"visible":$0.isVisible,"canKey":$0.canBecomeKey,"number":$0.windowNumber] as [String:Any] })
        try await shot("inspector-open", c.window!)
        try await wait("inspector key window", seconds: 3) { c.window?.isKeyWindow == true }
        try check(c.model.snapshot == nil && c.model.selection == nil && !c.model.loading, "open does not capture/select")
        return c
    }
    func disabled(_ c: SimulatorInspectorWindowController) throws {
        for title in ["hidden 적용","alpha 적용","복원"] { let b = try button(title, in: c.window!); try check(!b.isEnabled, "unselected disabled \(title)") }
    }
    func stableLedger(_ label: String) throws { try save(label + "-ledger.json", ledger()) }
    func released(_ label: String) async throws {
        try await wait(label) {
            let l = ledger(), ops = operations()
            guard l["authority"] as? String == "released", let proof = l["releaseProof"] as? [String: Any], let op = proof["operationID"] as? String,
                  let results = l["results"] as? [String: [String: Any]], let r = results[op], let cleanup = r["cleanup"] as? [String: Any] else { return false }
            return inspectorHostChildrenSettled(l) && !ops.isEmpty && ops.values.allSatisfy { $0["state"] as? String == "finished" } && r["registryReleased"] as? Bool == true && r["validationOnly"] as? Bool == false && cleanup["childrenReaped"] as? Bool == true && cleanup["detach"] as? String == "success" && (cleanup["recovery"] as? [String: Any])?["verified"] as? Bool == true
        }
        try stableLedger(label)
    }
    func capture(_ c: SimulatorInspectorWindowController, _ label: String) async throws -> SimulatorInspectorSnapshot {
        let old = c.model.snapshot?.captureID
        try click(old == nil ? "캡처" : "새로 캡처", in: c.window!)
        try await wait(label) { !c.model.loading }
        guard let snapshot = c.model.snapshot, snapshot.captureID != old, !c.model.stale, let editing = snapshot.editing else { throw ToolError("capture missing/failed: inspect actual status in ui.log/screenshots") }
        try check(c.model.selection == nil && editing.expiresAt > Date() && editing.expiresAt.timeIntervalSinceNow <= 120, "fresh 120s authority, no selection")
        try check(snapshot.context.targetID.hasPrefix("\(pid):"), "actual current process capture")
        let all = views(c.window!.contentView!), scene = all.compactMap { $0 as? InspectorSceneView }.first!
        guard let renderer = scene.delegate as? SimulatorInspectorRenderer else { throw ToolError("renderer unavailable") }
        try check(!snapshot.assets.isEmpty && renderer.cachedTextureCount == snapshot.assets.values.filter { snapshot.paintsTexture($0.nodeID) }.count && renderer.textureFailures.isEmpty, "current token-bound textures uploaded")
        for a in snapshot.assets.values { try a.data.write(to: out.appendingPathComponent(label + "-" + a.id + ".png")) }
        try save(label + "-identity.json", ["captureID":snapshot.captureID,"ownerID":editing.ownerID,"inspectionID":editing.inspectionID,"epoch":editing.targetEpoch,"tokens":snapshot.order.compactMap { snapshot.nodes[$0]?.editToken }])
        try stableLedger(label); try disabled(c); return snapshot
    }
    func select(_ c: SimulatorInspectorWindowController, _ snapshot: SimulatorInspectorSnapshot) throws {
        let all = views(c.window!.contentView!), tree = all.compactMap { $0 as? NSOutlineView }.first!
        guard let node = snapshot.nodes.values.first(where: { ($0.className.contains("MacCUQualificationEditTarget") || $0.className.contains("ProductWitness")) && $0.editable.contains("hidden") && $0.editable.contains("alpha") }) else { throw ToolError("independently observed editable target missing") }
        tree.expandItem(nil, expandChildren: true)
        guard let row = (0..<tree.numberOfRows).first(where: { tree.item(atRow: $0) as? String == node.id }) else { throw ToolError("outline node row unavailable") }
        tree.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        try check(c.model.selection == node.id && all.compactMap { $0 as? NSTextField }.contains { $0.stringValue.contains("뷰 ID: \(node.id)") }, "outline selection updates actual detail")
    }
    func oracle() throws -> [String: Any] { (try json(oracleURL)["samples"] as! [[String: Any]]).last! }
    func observe(_ label: String, before: [String: Any], hidden: Bool, alpha: Double, h: Int, a: Int) async throws {
        let end = Date().addingTimeInterval(8)
        while true {
            try guardInput(); let now = try oracle()
            if (now["sequence"] as! Int) > (before["sequence"] as! Int), now["hidden"] as? Bool == hidden, now["alpha"] as? Double == alpha {
                let oldCounts = before["setterCounts"] as! [String: Int], counts = now["setterCounts"] as! [String: Int]
                try check(counts["hidden"]! - oldCounts["hidden"]! == h && counts["alpha"]! - oldCounts["alpha"]! == a && (now["nodeGeneration"] as? String) == (before["nodeGeneration"] as? String), "independent guest state/exact setters \(label)")
                try save(label + "-oracle.json", now); return
            }
            guard Date() < end else { throw ToolError("oracle deadline \(label)") }; try await pause()
        }
    }
    func shot(_ label: String, _ w: NSWindow) async throws {
        try guardInput(); w.contentView!.layoutSubtreeIfNeeded(); try await pause()
        let all = views(w.contentView!)
        var geometry: [[String: Any]] = []
        for v in all {
            if v.isHiddenOrHasHiddenAncestor { continue }
            let frame = v.convert(v.bounds, to: w.contentView!)
            var row: [String: Any] = ["type":String(describing: type(of:v)),"frame":NSStringFromRect(frame),"visible":NSStringFromRect(v.visibleRect)]
            if let text = v as? NSTextField, !text.isEditable, !text.stringValue.isEmpty {
                row["text"] = String(text.stringValue.prefix(300))
                try check(text.frame.height + 1 >= text.fittingSize.height, "label vertical intrinsic extent \(label)")
                if text.enclosingScrollView == nil && !text.isHidden {
                    try check(text.visibleRect.height + 1 >= text.bounds.height, "status/header visible height \(label)")
                }
            }
            geometry.append(row)
        }
        try save(label + "-geometry.json", ["window":NSStringFromRect(w.frame),"views":geometry,"rotationMapping":"not generalized"])
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        p.arguments = ["-x","-o","-l",String(w.windowNumber),out.appendingPathComponent(label + ".png").path]
        try p.run()
        let end = Date().addingTimeInterval(5)
        while p.isRunning && Date() < end { try await pause() }
        if p.isRunning { p.terminate(); throw ToolError("screenshot child deadline") }
        p.waitUntilExit(); try check(p.terminationStatus == 0, "onscreen screenshot \(label)")
    }
    let empty = operations()
    var c = try await open(); try disabled(c)
    try check(operations().count == empty.count, "opening did not attach or capture")
    var snap: SimulatorInspectorSnapshot
    if request["focusedRemainder"] == nil || request["focusedRemainder"] as? String == "swiftui" {
    let scene = views(c.window!.contentView!).compactMap { $0 as? InspectorSceneView }.first!
    let renderer = scene.delegate as! SimulatorInspectorRenderer
    let initial = try oracle(), yaw = renderer.camera.yaw
    try click("오른쪽 회전", in: c.window!); try click("확대", in: c.window!)
    let slider = views(c.window!.contentView!).compactMap { $0 as? NSSlider }.first!
    slider.doubleValue = 40; slider.sendAction(slider.action, to: slider.target)
    try check(renderer.camera.yaw != yaw && renderer.camera.zoom > 1 && renderer.camera.explosion == 40 && operations().count == empty.count, "camera controls host only; no autocapture")
    try await observe("camera", before: initial, hidden: false, alpha: 1, h: 0, a: 0)
    snap = try await capture(c, "capture")
    if request["focusedRemainder"] as? String == "swiftui" {
        if request["recordingTransition"] as? Bool == true {
            let old = snap, oldContext = c.model.context
            let recording = try button("SwiftUI 기록을 켜고 다시 실행", in: c.window!)
            let disclosure = "현재 실행 상태가 사라집니다. 기존 실행 인자와 환경 변수는 복원되지 않습니다."
            try check(c.model.canPrepareRecording && !recording.isHiddenOrHasHiddenAncestor && recording.isEnabled,
                      "genuine initial capture offers explicit recording action")
            try check(views(c.window!.contentView!).compactMap { $0 as? NSTextField }.contains {
                $0.stringValue == disclosure && !$0.isHiddenOrHasHiddenAncestor
            }, "visible production state-loss disclosure")
            let initialOracle = try json(oracleURL)
            try check(initialOracle["graphDebugLaunchFlag"] is NSNull, "initial recording lane has no env287")
            let currentScope = try await background { try SimulatorInspectionHost.prepare(device: device, screen: active) }
            let scope: [String: Any] = ["deviceID":currentScope.deviceID,"bootIdentity":currentScope.deviceLifetime,
                "presentation":currentScope.presentation,"generation":currentScope.generation,"runtime":currentScope.runtime]
            let oldTarget = request.filter { ["pid","start","path","deviceID"].contains($0.key) }
            try inspectorPublishRecordingArtifact(out, "recording-ready.json", ["target":oldTarget,"scope":scope,"captureID":old.captureID,
                "ownerID":old.editing!.ownerID,"inspectionID":old.editing!.inspectionID,"epoch":old.editing!.targetEpoch,
                "selector":"prepareRecordingNow","disclosure":disclosure])
            try await wait("fixture armed and owner acknowledged", seconds: 12) {
                FileManager.default.fileExists(atPath: out.appendingPathComponent("recording-click-ready.json").path)
            }
            let permission = try inspectorRecordingCursor(out.appendingPathComponent("recording-click-ready.json"))
            try check(c.model.context == oldContext && c.model.snapshot?.captureID == old.captureID,
                      "open capture and arm timer did not restart")
            try guardInput()
            try check(c.window!.isKeyWindow && recording.target === c &&
                      recording.action.map(NSStringFromSelector) == "prepareRecordingNow" &&
                      recording.isEnabled && !recording.isHiddenOrHasHiddenAncestor,
                      "same visible enabled production button target/action")
            // Provenance precedes dispatch so owner loss cannot erase unknown intent.
            try inspectorPublishRecordingArtifact(out, "recording-action.json", ["restartID":permission["restartID"]!,"target":oldTarget,
                "selector":NSStringFromSelector(recording.action!),"method":"NSButton.performClick",
                "enabled":recording.isEnabled,"visible":!recording.isHiddenOrHasHiddenAncestor,
                "controllerTarget":recording.target === c,"physicalClick":false])
            recording.performClick(nil)
            try check(c.model.stale && c.model.selection == nil && !c.model.canRevert(), "action immediately revokes old UI authority")
            try await wait("independent successor admission", seconds: 60) {
                FileManager.default.fileExists(atPath: out.appendingPathComponent("recording-cursor.json").path)
            }
            let cursor = try inspectorRecordingCursor(out.appendingPathComponent("recording-cursor.json"))
            guard cursor["phase"] as? String == "admitted", cursor["revision"] as? Int == 1,
                  let binding = cursor["binding"] as? [String: Any], let target = binding["target"] as? [String: Any],
                  let result = cursor["result"] as? [String: Any], result["target"] as? NSDictionary == target as NSDictionary,
                  let next = target["pid"] as? NSNumber else { throw ToolError("Successor remains custody only") }
            try await wait("production context rebind", seconds: 8) { c.model.context != oldContext && lcd.inspectionHostWorkSettled }
            pid = next.int32Value
            try check(c.model.context.targetID.hasPrefix("\(pid):") && c.model.snapshot == nil && !c.model.loading,
                      "production rebind requires fresh capture; owner candidate cannot autocapture")
            try await released("recording-old-release")
            guard let successorLedger = cursor["ledger"] as? String,
                  URL(fileURLWithPath: successorLedger).deletingLastPathComponent() == ledgerURL.deletingLastPathComponent()
            else { throw ToolError("Owner successor ledger scope differs") }
            ledgerURL = URL(fileURLWithPath: successorLedger)
            ledgerHistory.append(ledgerURL)
            snap = try await capture(c, "recording-successor")
            c.model.select(old.order.first)
            try check(c.model.selection == nil && !c.model.accept(old,generation:c.model.generation) &&
                      snap.captureID != old.captureID && snap.editing!.targetEpoch != old.editing!.targetEpoch &&
                      Set(snap.nodes.values.compactMap(\.editToken)).isDisjoint(with: old.nodes.values.compactMap(\.editToken)),
                      "old capture graph edit and undo identities cannot reactivate")
            try save("recording-accepted.json", ["revision":1,"target":target,"captureID":snap.captureID,
                "method":"AppKit action path","physicalClick":false,"humanAcceptance":false])
        }
        let recording = try button("SwiftUI 기록을 켜고 다시 실행", in: c.window!)
        try check(recording.isHidden == !c.model.canPrepareRecording,
                  "actual recording button visibility matches snapshot eligibility")
        try check(recording.action != nil && recording.target === c,
                  "actual recording button dispatch targets production controller")
        try check(!c.model.canPrepareRecording && !recording.isEnabled,
                  "recorded launch does not offer unnecessary restart")
        try save("recording-eligibility.json", ["eligible":c.model.canPrepareRecording,
            "hidden":recording.isHidden,"enabled":recording.isEnabled,
            "clicked":request["recordingTransition"] as? Bool == true])
        guard let graph = snap.swiftUI, let node = graph.nodes.values.first(where: { n in n.properties.contains { $0.original.text.contains("ALPHA SWIFTUI 731") } }) else { throw ToolError("actual title property absent from graph") }
        try check(!graph.nodes.isEmpty && graph.hosts.values.contains { $0.compositeAssetID != nil }, "actual declarative graph and hosting composite")
        try save("swiftui-live-identity.json", ["scope":graph.scope.text,"processLifetime":graph.processLifetime.text,"graphIDs":graph.order,"hosts":graph.hosts.values.map { ["hostingNodeID":$0.hostingNodeID,"sceneID":$0.sceneID,"assetID":$0.compositeAssetID ?? ""] }])
        let currentScope = try await background { try SimulatorInspectionHost.prepare(device: device, screen: active) }
        let expectedScope: [String:Any] = ["deviceID":currentScope.deviceID,"bootIdentity":currentScope.deviceLifetime,
            "displayID":snap.context.displayID,"presentation":currentScope.presentation,"generation":currentScope.generation,"runtime":currentScope.runtime]
        let expectedScopeText = try InspectorValue(expectedScope).text
        try check(graph.scope.text == expectedScopeText, "live native boot/runtime/generation scope joined")
        try check((80...150).contains(graph.nodes.count), "actual bounded declarative topology count")
        var envelope = try inspectorCaptureEnvelope(ledger(), captureID: snap.captureID)
        guard var rawSnapshot = envelope["snapshot"] as? [String:Any],
              var wrongScope = rawSnapshot["inspectionScope"] as? [String:Any] else { throw ToolError("live capture scope envelope absent") }
        wrongScope["bootIdentity"] = "consumer-negative-" + UUID().uuidString
        rawSnapshot["inspectionScope"] = wrongScope; envelope["snapshot"] = rawSnapshot
        var rejectedBoot = false
        do { _ = try SimulatorInspectorSnapshot.parse(envelope,context:snap.context) } catch { rejectedBoot = true }
        try check(rejectedBoot, "same production consumer rejects mismatched boot join; no reboot")
        try save("boot-join-consumer-negative.json", ["passed":rejectedBoot,"realReboot":false,"scope":expectedScope,"negativeBoot":wrongScope["bootIdentity"]!])
        let tree = views(c.window!.contentView!).compactMap { $0 as? NSOutlineView }.first!
        tree.expandItem(nil, expandChildren:true)
        guard let row = (0..<tree.numberOfRows).first(where: { tree.item(atRow:$0) as? String == node.id }) else { throw ToolError("actual SwiftUI outline row missing") }
        let beforeSelection = operations().count
        tree.selectRowIndexes(IndexSet(integer:row),byExtendingSelection:false)
        try await pause()
        try check(c.model.selection == node.id && c.model.draft == nil && !c.model.canEdit("hidden") && !c.model.canRevert(), "actual outline read-only SwiftUI selection")
        try disabled(c)
        try check(snap.nodes[node.id] == nil && !snap.paintsTexture(node.id) && operations().count == beforeSelection, "tree-only selection has no plane or backend operation")
        try await shot("swiftui-selected",c.window!)
        let search = views(c.window!.contentView!).compactMap { $0 as? NSSearchField }.first!
        search.stringValue="ALPHA SWIFTUI 731";c.controlTextDidChange(Notification(name:NSControl.textDidChangeNotification,object:search))
        try check((0..<tree.numberOfRows).contains { tree.item(atRow:$0) as? String == node.id }, "actual property text search")
        search.stringValue="";c.controlTextDidChange(Notification(name:NSControl.textDidChangeNotification,object:search))
        let control: [String:Any] = ["action":"alternate","session":request["fixtureSession"]!,"pid":pid,"requestID":UUID().uuidString,"issuedUnixSeconds":Date().timeIntervalSince1970]
        try JSONSerialization.data(withJSONObject:control).write(to:oracleURL.deletingLastPathComponent().appendingPathComponent("branch-control.json"),options:.atomic)
        try await wait("independent branch change",seconds:8) { (try? json(oracleURL)["branch"] as? String) == "delta" }
        let old = snap
        snap = try await capture(c,"branch-refresh")
        try check(snap.swiftUI?.nodes.values.contains { $0.properties.contains { $0.original.text.contains("DELTA BRANCH 914") } } == true, "fresh actual branch graph")
        c.model.select(node.id)
        try check(c.model.selection == nil && !c.model.accept(old,generation:c.model.generation), "old graph selection and capture cannot reactivate")
        try await shot("swiftui-branch",c.window!)
    }
    try select(c, snap)
    let search = views(c.window!.contentView!).compactMap { $0 as? NSSearchField }.first!
    search.stringValue = "no-such-product-node"; search.sendAction(search.action, to: search.target)
    c.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: search))
    try check(c.model.selection == nil, "search clears selection without automatic selection")
    search.stringValue = ""; c.controlTextDidChange(Notification(name:NSControl.textDidChangeNotification,object:search)); try select(c, snap)
    for prop in ["hidden", "alpha"] {
        if prop == "alpha" { snap = try await capture(c, "alpha-capture"); try select(c, snap) }
        try check(snap.editing!.expiresAt.timeIntervalSinceNow > 5, "edit TTL admission")
        let before = try oracle()
        if prop == "hidden" { try click("hidden 초안", in:c.window!) }
        else { let field = views(c.window!.contentView!).compactMap { $0 as? NSTextField }.first { $0.placeholderString == "alpha 0…1" }!; field.stringValue = "0.5"; c.controlTextDidChange(Notification(name:NSControl.textDidChangeNotification,object:field)) }
        let oldOp = c.model.receipt?.operationID
        try click(prop + " 적용", in:c.window!)
        try await wait(prop + " readback") { c.model.pending == nil && c.model.receipt?.operationID != oldOp }
        try check(c.model.receipt?.outcome == "appliedObserved" && c.model.canRevert(), "real apply/readback/undo receipt \(prop)")
        try check(c.model.receipt?.observed.text == (prop == "hidden" ? "true" : "0.5"), "UI receipt observed requested value")
        try await observe(prop, before:before, hidden:prop == "hidden", alpha:prop == "alpha" ? 0.5 : 1, h:prop == "hidden" ? 1 : 0, a:prop == "alpha" ? 1 : 0)
        try await shot(prop + "-readback", c.window!)
        let applied = try oracle(), appliedOp = c.model.receipt!.operationID
        try click("복원", in:c.window!)
        try await wait(prop + " restore") { c.model.pending == nil && c.model.receipt?.operationID != appliedOp }
        try check(c.model.receipt?.outcome == "appliedObserved", "real restore readback")
        try await observe(prop + "-restore", before:applied, hidden:false, alpha:1, h:prop == "hidden" ? 1 : 0, a:prop == "alpha" ? 1 : 0)
        try stableLedger(prop + "-restored")
    }
    let token = snap.nodes.values.compactMap { $0.editToken }.sorted()
    snap = try await capture(c, "refresh")
    try check(snap.nodes.values.compactMap { $0.editToken }.sorted() != token && c.model.selection == nil, "refresh fresh tokens and deselection")
    try await shot("lcd-normal",lcd.window); try await shot("inspector-normal",c.window!)
    let lcdFrame = lcd.window.frame
    try check(lcd.window.contentMinSize.width > 0 && lcd.window.contentMinSize.height > 0, "LCD declared minimum size")
    lcd.window.setFrame(NSRect(origin:lcdFrame.origin,size:lcd.window.frameRect(forContentRect:NSRect(origin:.zero,size:lcd.window.contentMinSize)).size),display:true)
    try await shot("lcd-minimum",lcd.window); lcd.window.setFrame(lcdFrame,display:true)
    c.window!.setFrame(NSRect(origin:c.window!.frame.origin,size:c.window!.minSize),display:true)
    try select(c, snap); try await shot("inspector-minimum",c.window!)
    for title in ["hidden 초안","hidden 적용","alpha 적용","복원"] {
        let control = try button(title, in:c.window!)
        control.scrollToVisible(control.bounds); c.window!.contentView!.layoutSubtreeIfNeeded()
        try check(control.visibleRect.height + 1 >= control.bounds.height, "minimum editor control reachable \(title)")
    }
    try await shot("inspector-minimum-editor",c.window!)
    } else if request["focusedRemainder"] as? String == "pendingOnly" {
        snap = try await capture(c, "capture")
    } else {
        snap = try await capture(c, "capture")
        try select(c, snap)
        let before = try oracle()
        let field = views(c.window!.contentView!).compactMap { $0 as? NSTextField }.first { $0.placeholderString == "alpha 0…1" }!
        field.stringValue = "0.5"; c.controlTextDidChange(Notification(name:NSControl.textDidChangeNotification,object:field))
        try click("alpha 적용", in:c.window!)
        try await wait("focused alpha receipt") { c.model.pending == nil && c.model.receipt != nil }
        try check(c.model.receipt?.outcome == "appliedObserved", "focused actual apply receipt")
        try await observe("focused-alpha", before:before, hidden:false, alpha:0.5, h:0, a:1)
        try await shot("receipt-summary", c.window!)
        let applied = try oracle(), operation = c.model.receipt!.operationID
        try click("복원", in:c.window!)
        try await wait("focused restore") { c.model.pending == nil && c.model.receipt?.operationID != operation }
        try await observe("focused-restored", before:applied, hidden:false, alpha:1, h:0, a:1)
        try stableLedger("focused-restored")
        snap = try await capture(c, "refresh")
        try check(c.model.receipt == nil, "refresh revokes old receipt")
        try check(!views(c.window!.contentView!).compactMap { $0 as? NSTextField }.contains { $0.stringValue.contains(operation) }, "rendered refresh clears old operation receipt")
        try await shot("receipt-cleared", c.window!)
    }
    let oldOwner = snap.editing!.ownerID
    c.close(); try await released("close-release")
    try check(lcd.window.isKeyWindow || lcd.toolbox.window?.isKeyWindow == true, "close returns owned LCD/toolbox focus")
    c = try await open(); snap = try await capture(c, "reopen")
    // Owner identity must rotate on actual close/reopen, rather than merely changing capture ID.
    try check(snap.editing!.ownerID != oldOwner, "reopen has new owner")
    if request["focusedRemainder"] as? String == "swiftui" {
        c.close(); try await released("final-close-release")
    } else {
    // A real in-flight capture is cancelled through the UI. Wait for its actual
    // durable reservation so a pre-dispatch cancellation cannot count as late-result proof.
    let previousOperations = Set(operations().keys)
    try click("새로 캡처", in:c.window!)
    // Observe native completion while the real durable capture remains reserved.
    // This exposes late transport/UI delivery without delaying or replacing the backend.
    let reservationEnd = Date().addingTimeInterval(165)
    var folder: URL?, channel: URL?, pendingID: String?
    while true {
        try guardInput()
        let ops = operations()
        if pendingID == nil, let entry = ops.first(where: { !previousOperations.contains($0.key) && $0.value["kind"] as? String == "capture" && $0.value["state"] as? String == "reserved" }) {
            pendingID = entry.key
        }
        if let op = pendingID {
            if folder == nil {
                folder = try FileManager.default.contentsOfDirectory(at: URL(fileURLWithPath:NSTemporaryDirectory()), includingPropertiesForKeys:nil).first { url in
                    url.lastPathComponent.hasPrefix("mac-cu-views-") && (try? json(url.appendingPathComponent("request.json"))["operationID"] as? String) == op
                }
            }
            if let folder, channel == nil, let path = try? json(folder.appendingPathComponent("channel.json"))["path"] as? String { channel = URL(fileURLWithPath:path) }
            if let channel, let terminal = try? json(channel.appendingPathComponent("terminal.json")), ops[op]?["state"] as? String == "reserved" {
                try save("pending-native-terminal.json", terminal)
                try stableLedger("pending-reservation")
                break
            }
            if ops[op]?["state"] as? String == "finished" { throw ToolError("native capture reservation completed before late delivery observation") }
        }
        guard Date() < reservationEnd else { throw ToolError("native capture reservation/terminal observation deadline") }
        try await Task.sleep(nanoseconds:1_000_000)
    }
    let cancelledGeneration = c.model.generation
    try click("취소", in:c.window!)
    try check(c.model.generation > cancelledGeneration && c.model.stale && c.model.selection == nil, "pending cancel revokes UI authority")
    c.close(); try await released("pending-close-release")
    try check(c.model.stale && c.model.selection == nil && !c.model.canEdit("hidden") && !c.model.canRevert(), "actual late completion cannot restore closed UI authority")
    try check(lcd.window.isKeyWindow || lcd.toolbox.window?.isKeyWindow == true, "pending close returns owned LCD/toolbox focus")
    }
    try save("ui-result.json", ["passed":true,"method":"actual rendered LCD/3D; local performClick/sendAction/outline selection","physicalPointer":false,"humanApproval":false])
}
