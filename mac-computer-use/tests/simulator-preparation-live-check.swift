import AppKit

/// Real daemon menus, shared board and manager, with explicit opt-in creation.
/// Dispatch is replaced in a temporary build; no installed daemon/socket is used.
func runSimulatorPreparationLiveCheck() -> Never {
    let session = CGSessionCopyCurrentDictionary() as? [String: Any] ?? [:]
    guard session["CGSSessionScreenIsLocked"] as? Bool != true,
          CGDisplayIsAsleep(CGMainDisplayID()) == 0, CGDisplayIsActive(CGMainDisplayID()) != 0,
          let path = ProcessInfo.processInfo.environment["PREPARATION_CHECK_OUTPUT"] else {
        fputs("ENVIRONMENT: unlocked active interactive desktop and output path required.\n", stderr); exit(2)
    }
    let previous = NSWorkspace.shared.frontmostApplication
    NSApplication.shared.setActivationPolicy(.regular)
    menuBar = MenuBar(); NSApp.delegate = menuBar
    Task { @MainActor in
        @MainActor func descendants(_ view: NSView) -> [NSView] {
            let extra = (view as? NSTabView)?.tabViewItems.compactMap(\.view).filter { item in !view.subviews.contains { $0 === item } } ?? []
            return [view] + (view.subviews + extra).flatMap(descendants)
        }
        func wait(_ condition: () -> Bool) async {
            for _ in 0..<600 {
                if condition() { return }
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
            fatalError("Live preparation manager did not settle")
        }
        let bar = menuBar!
        bar.menuNeedsUpdate(bar.menu)
        let entry = bar.menu.items.first { $0.title == "시뮬레이터 관리…" }!
        guard NSApp.sendAction(entry.action!, to: entry.target, from: entry) else { fatalError("Menu action failed") }
        let window = NSApp.windows.first { $0.title == "시뮬레이터 관리 (mac-cu)" }!
        let views = descendants(window.contentView!)
        let refresh = views.compactMap { $0 as? NSButton }.first { $0.title == "새로고침" }!
        let table = views.compactMap { $0 as? NSTableView }.first!
        let runtime = views.compactMap { $0 as? NSPopUpButton }.first { $0.accessibilityLabel() == "새 기기 런타임" }!
        await wait { refresh.isEnabled }
        assert(table.numberOfRows > 0 && runtime.numberOfItems > 0)
        assert(simulatorWindows.isEmpty, "Reading inventory must not open or operate a simulator")
        await wait { SimulatorStatusBoard.shared.updatedAt > Date.distantPast }
        let appEntry = NSApp.mainMenu!.items.first!.submenu!.items.first { $0.title == "시뮬레이터 관리…" }!
        assert(NSApp.sendAction(appEntry.action!, to: appEntry.target, from: appEntry))
        await wait { refresh.isEnabled }
        assert(NSApp.windows.filter { $0.title == window.title }.count == 1, "Both menus must share one manager")
        window.contentView!.layoutSubtreeIfNeeded()
        if let row = SimulatorPreparationWindow.shared.inventory.devices.firstIndex(where: \.booted) { table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false) }
        try? await Task.sleep(nanoseconds: 250_000_000)
        guard NSApp.isActive, window.isKeyWindow else { fatalError("Foreground changed before read-only UI capture") }
        let capture = Process(); capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        capture.arguments = ["-x", "-o", "-l", String(window.windowNumber), URL(fileURLWithPath: path).appendingPathComponent("manager.png").path]
        do { try capture.run(); capture.waitUntilExit(); assert(capture.terminationStatus == 0) }
        catch { fatalError("Capture failed: \(error)") }
        let tabs = views.compactMap { $0 as? NSTabView }.first!
        for (index, filename) in [(1, "creation.png"), (2, "runtimes.png")] {
            tabs.selectTabViewItem(at: index); window.contentView!.layoutSubtreeIfNeeded()
            try? await Task.sleep(nanoseconds: 250_000_000)
            if index == 2, let list = descendants(tabs.selectedTabViewItem!.view!).compactMap({ $0 as? NSTableView }).first, list.numberOfRows > 0 {
                list.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
            }
            guard NSApp.isActive, window.isKeyWindow else { fatalError("Foreground changed before task-page capture") }
            let shot = Process(); shot.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            shot.arguments = ["-x", "-o", "-l", String(window.windowNumber), URL(fileURLWithPath: path).appendingPathComponent(filename).path]
            do { try shot.run(); shot.waitUntilExit(); assert(shot.terminationStatus == 0) }
            catch { fatalError("Task-page capture failed: \(error)") }
        }
        tabs.selectTabViewItem(at: 0)
        print("PASS isolated production menus, singleton manager, shared status board, actual inventory (\(table.numberOfRows) devices, \(runtime.numberOfItems) available runtimes), no simulator actions so far; WindowServer capture manager.png"); fflush(stdout)
        if let raw = ProcessInfo.processInfo.environment["PREPARATION_CHECK_CREATE"] {
            do { try await preparationCreateAndStart(raw, manager: SimulatorPreparationWindow.shared, window: window, output: URL(fileURLWithPath: path)) }
            catch {
                for open in Array(simulatorWindows.values) { open.window.close() }
                window.close(); previous?.activate(options: [])
                fputs("FAIL preparation lifecycle: \(error.localizedDescription)\n", stderr); exit(1)
            }
        }
        for open in Array(simulatorWindows.values) { open.window.close() }
        window.close(); previous?.activate(options: []); exit(0)
    }
    NSApp.run(); exit(1)
}

private struct PreparationLifecycleError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

@MainActor private func preparationCreateAndStart(_ raw: String, manager: SimulatorPreparationWindow, window: NSWindow, output: URL) async throws {
    func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else { throw PreparationLifecycleError(message: message) }
        print("PASS " + message); fflush(stdout)
    }
    func wait(_ seconds: Double = 30, _ condition: () -> Bool) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + seconds
        while ProcessInfo.processInfo.systemUptime < deadline {
            if condition() { return }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        throw PreparationLifecycleError(message: "Lifecycle operation did not settle within \(seconds)s")
    }
    @MainActor func descendants(_ view: NSView) -> [NSView] {
        let extra = (view as? NSTabView)?.tabViewItems.compactMap(\.view).filter { item in !view.subviews.contains { $0 === item } } ?? []
        return [view] + (view.subviews + extra).flatMap(descendants)
    }
    let config = try JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: String] ?? [:]
    guard let requestedName = config["name"], requestedName.hasPrefix("Mac Pilot Check "),
          let runtimeID = config["runtime"], let typeID = config["type"] else { throw PreparationLifecycleError(message: "Explicit new-device configuration is required") }
    let before = Set(manager.inventory.devices.map(\.id))
    try expect(!manager.inventory.devices.contains { $0.name == requestedName }, "The test name is new; no existing device will be used")
    let views = descendants(window.contentView!)
    let tabs = views.compactMap { $0 as? NSTabView }.first!
    tabs.selectTabViewItem(at: 1)
    func button(_ title: String) -> NSButton { views.compactMap { $0 as? NSButton }.first { $0.title == title }! }
    let refresh = button("새로고침"), create = button("기기 생성"), start = button("실행 및 LCD 열기")
    let table = views.compactMap { $0 as? NSTableView }.first!
    let runtime = views.compactMap { $0 as? NSPopUpButton }.first { $0.accessibilityLabel() == "새 기기 런타임" }!
    let type = views.compactMap { $0 as? NSPopUpButton }.first { $0.accessibilityLabel() == "새 기기 유형" }!
    let name = views.compactMap { $0 as? NSTextField }.first { $0.accessibilityLabel() == "새 기기 이름" }!
    let status = views.compactMap { $0 as? NSTextField }.first { $0.accessibilityLabel() == "시뮬레이터 준비 상태" }!
    guard let runtimeItem = runtime.itemArray.first(where: { $0.representedObject as? String == runtimeID }) else { throw PreparationLifecycleError(message: "Requested runtime is not installed") }
    runtime.select(runtimeItem); runtime.sendAction(runtime.action!, to: runtime.target)
    guard let typeItem = type.itemArray.first(where: { $0.representedObject as? String == typeID }) else { throw PreparationLifecycleError(message: "Requested device type is not compatible") }
    type.select(typeItem); name.stringValue = requestedName
    name.delegate?.controlTextDidChange?(Notification(name: NSControl.textDidChangeNotification, object: name))
    try expect(NSApp.isActive && window.isKeyWindow && create.isEnabled, "Foreground create control admitted")
    create.performClick(nil); try await wait(90) { refresh.isEnabled }
    guard let created = manager.inventory.devices.first(where: { !before.contains($0.id) && $0.name == requestedName }) else { throw PreparationLifecycleError(message: "No created device readback: \(status.stringValue)") }
    let record = ["udid": created.id, "name": created.name, "runtime": created.runtimeID, "type": created.typeID]
    try JSONSerialization.data(withJSONObject: record, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("created.json"))
    try expect(created.state == "Shutdown" && created.runtimeID == runtimeID && created.typeID == typeID, "New device identity and shutdown state verified")
    try expect(table.selectedRow >= 0 && manager.inventory.devices[table.selectedRow].id == created.id && simulatorClaims()[created.id] == nil, "Only the new unclaimed UUID is selected")
    try expect(NSApp.isActive && window.isKeyWindow && start.isEnabled, "Foreground start control admitted")
    start.performClick(nil); try await wait(240) { refresh.isEnabled }
    guard let lcd = simulatorWindows[created.id] else { throw PreparationLifecycleError(message: "No actual LCD after start: \(status.stringValue)") }
    try expect(manager.inventory.devices.first { $0.id == created.id }?.booted == true, "Actual new device boot readback")
    try await wait(15) { lcd.surface != nil && lcd.window.isVisible }
    try expect(Set(simulatorWindows.keys) == [created.id], "Only the new device has an LCD")
    // No guest input is sent. Claim this newly booted test-owned device before further checks.
    let pilot = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/sim-pilot").path
    func claim(_ action: String) throws {
        let process = Process(); process.executableURL = URL(fileURLWithPath: pilot)
        process.arguments = [action, "--udid", created.id] + (action == "claim" ? ["--note", "Mac Pilot preparation lifecycle check"] : [])
        process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        try process.run(); process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw PreparationLifecycleError(message: "sim-pilot \(action) failed for the new test device") }
    }
    try claim("claim"); defer { try? claim("release") }
    try expect(simulatorClaims()[created.id] != nil, "New booted test device usage recorded")
    try expect(NSApp.isActive && lcd.window.isKeyWindow, "Foreground retained before LCD capture")
    let capture = Process(); capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
    capture.arguments = ["-x", "-o", "-l", String(lcd.window.windowNumber), output.appendingPathComponent("created-lcd.png").path]
    try capture.run(); capture.waitUntilExit(); try expect(capture.terminationStatus == 0, "Actual LCD WindowServer capture")
    lcd.window.close(); try expect(simulatorWindows[created.id] == nil, "LCD close releases its registry")
    try expect(NSApp.isActive, "Application focus retained after LCD close")
    window.makeKeyAndOrderFront(nil); refresh.performClick(nil); try await wait { refresh.isEnabled }
    try expect(!start.isEnabled, "Claimed new device is blocked by the production manager")
    try claim("release"); refresh.performClick(nil); try await wait { refresh.isEnabled }
    try expect(start.isEnabled && start.title == "LCD 열기", "Released booted device offers LCD without reboot")
    try expect(NSApp.isActive && window.isKeyWindow, "Foreground retained before LCD reopen")
    start.performClick(nil); try await wait { refresh.isEnabled }
    try await wait(15) { simulatorWindows[created.id]?.surface != nil }
    print("PASS real create→boot→LCD→close→claim guard→reopen; retained new device \(created.name) · \(created.id). No existing device was operated, no guest input, runtime download or data deletion."); fflush(stdout)
}
