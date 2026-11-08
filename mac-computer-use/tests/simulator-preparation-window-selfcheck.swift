import AppKit

@main
struct SimulatorPreparationWindowSelfcheck {
    @MainActor static func descendants(_ view: NSView) -> [NSView] {
        let extra = (view as? NSTabView)?.tabViewItems.compactMap(\.view).filter { item in !view.subviews.contains { $0 === item } } ?? []
        return [view] + (view.subviews + extra).flatMap(descendants)
    }
    @MainActor static func wait(_ condition: () -> Bool) async {
        for _ in 0..<500 {
            if condition() { return }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        fatalError("Preparation UI did not settle")
    }
    @MainActor static func run() async throws {
        let session = CGSessionCopyCurrentDictionary() as? [String: Any] ?? [:]
        guard session["CGSSessionScreenIsLocked"] as? Bool != true,
              CGDisplayIsAsleep(CGMainDisplayID()) == 0, CGDisplayIsActive(CGMainDisplayID()) != 0 else {
            fputs("ENVIRONMENT: unlocked active interactive desktop required.\n", stderr); exit(2)
        }
        let previous = NSWorkspace.shared.frontmostApplication
        defer { previous?.activate(options: []) }
        let f = PreparationFixture.self
        let fake = PreparationFake()
        var opened: [String] = []
        let taskLock = NSLock()
        weak var observedTask: SimulatorPreparationTask?
        let manager = SimulatorPreparationWindow(backendFactory: { task in
            taskLock.withLock { observedTask = task }; return fake.backend()
        }, claims: { fake.owners }, openLCD: { id, _ in
            opened.append(id); return "LCD fixture opened"
        })
        manager.show()
        let window = NSApp.windows.first { $0.title == "시뮬레이터 관리 (mac-cu)" }!
        defer { window.close() }
        let views = descendants(window.contentView!)
        let tabs = views.compactMap { $0 as? NSTabView }.first!
        func button(_ title: String) -> NSButton { views.compactMap { $0 as? NSButton }.first { $0.title == title }! }
        let refresh = button("새로고침"), create = button("기기 생성"), start = button("실행 및 LCD 열기"), cancel = button("작업 취소")
        let table = views.compactMap { $0 as? NSTableView }.first!
        let runtime = views.compactMap { $0 as? NSPopUpButton }.first { $0.accessibilityLabel() == "새 기기 런타임" }!
        let types = views.compactMap { $0 as? NSPopUpButton }.first { $0.accessibilityLabel() == "새 기기 유형" }!
        let name = views.compactMap { $0 as? NSTextField }.first { $0.accessibilityLabel() == "새 기기 이름" }!
        func enterName(_ value: String) {
            name.stringValue = value
            name.delegate?.controlTextDidChange?(Notification(name: NSControl.textDidChangeNotification, object: name))
        }
        let search = views.compactMap { $0 as? NSSearchField }.first!
        let filter = views.compactMap { $0 as? NSPopUpButton }.first { $0.accessibilityLabel() == "시뮬레이터 상태 필터" }!
        func query(_ value: String) {
            search.stringValue = value; search.sendAction(search.action!, to: search.target)
        }
        let status = views.compactMap { $0 as? NSTextField }.first { $0.accessibilityLabel() == "시뮬레이터 준비 상태" }!
        let selectedName = views.compactMap { $0 as? NSTextField }.first { $0.accessibilityLabel() == "선택한 기기 이름" }!
        let selectedUsage = views.compactMap { $0 as? NSTextField }.first { $0.accessibilityLabel() == "선택한 기기 사용 기록" }!
        let identifiers = views.compactMap { $0 as? NSTextField }.first { $0.accessibilityLabel() == "선택한 기기 식별자" }!
        await wait { refresh.isEnabled }
        await wait { taskLock.withLock { observedTask == nil } }
        assert(fake.commands.isEmpty && opened.isEmpty, "Opening the manager is read-only")
        assert(table.numberOfRows == 1 && !start.isEnabled && !cancel.isEnabled)
        window.contentView!.layoutSubtreeIfNeeded()
        assert(table.enclosingScrollView!.bounds.width > table.tableColumns.reduce(0) { $0 + $1.width }, "The default device list must show all state columns beside its selection panel")
        assert(!create.isEnabled, "Empty names must be rejected before running a command")
        tabs.selectTabViewItem(at: 1)
        assert(window.firstResponder === name.currentEditor(), "Creation starts in the visible name field")
        enterName("-invalid"); assert(!create.isEnabled && fake.commands.isEmpty)
        enterName("New phone"); assert(create.isEnabled)
        tabs.selectTabViewItem(at: 0)
        table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        assert(selectedName.stringValue == "✓ Phone" && identifiers.stringValue.contains(f.id))
        query("phone ios"); assert(table.numberOfRows == 1 && table.selectedRow == 0)
        query("missing"); assert(table.numberOfRows == 0 && table.selectedRow == -1 && !start.isEnabled)
        assert(!selectedName.stringValue.contains("Phone") && selectedUsage.stringValue == "—", "Hidden targets must clear the structured selection card")
        let emptyLabel = views.compactMap { $0 as? NSTextField }.first { $0.accessibilityLabel() == "기기 목록 상태" }!
        assert(emptyLabel.stringValue.contains("검색 조건"))
        button("검색 조건 초기화").performClick(nil)
        assert(table.numberOfRows == 1 && table.selectedRow == -1 && search.stringValue.isEmpty)
        filter.selectItem(at: SimulatorPreparationFilter.booted.rawValue); filter.sendAction(filter.action!, to: filter.target)
        assert(table.numberOfRows == 0)
        filter.selectItem(at: 0); filter.sendAction(filter.action!, to: filter.target)
        assert(runtime.itemTitles[0] != runtime.itemTitles[1])
        tabs.selectTabViewItem(at: 1)
        runtime.select(runtime.itemArray.first { $0.representedObject as? String == f.duoRuntime })
        runtime.sendAction(runtime.action!, to: runtime.target)
        assert(types.numberOfItems == 1 && types.selectedItem?.representedObject as? String == f.duo)
        runtime.select(runtime.itemArray.first { $0.representedObject as? String == f.runtime })
        runtime.sendAction(runtime.action!, to: runtime.target)
        tabs.selectTabViewItem(at: 0)
        table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        assert(start.isEnabled)
        fake.snapshots = [f.json(), f.json(state: "Booted")]
        start.performClick(nil)
        assert(!refresh.isEnabled && cancel.isEnabled)
        await wait { refresh.isEnabled }
        assert(opened == [f.id] && start.title == "LCD 열기" && status.stringValue.contains("LCD 창을 열었습니다"))
        fake.owners[f.id] = "Other session"
        refresh.performClick(nil); await wait { refresh.isEnabled }
        assert(!start.isEnabled && table.selectedRow == 0)
        assert(selectedUsage.stringValue.contains("Other session"), "The blocked action names its usage record beside the target")
        fake.owners = [:]
        query(f.id)
        fake.snapshots = [f.json(), f.json(created: true)]
        tabs.selectTabViewItem(at: 1)
        enterName("New phone"); create.performClick(nil)
        await wait { refresh.isEnabled }
        assert(table.numberOfRows == 2 && manager.inventory.devices[table.selectedRow].id == f.newID)
        assert(search.stringValue.isEmpty, "A new device must be revealed when the old search would hide it")
        assert(tabs.indexOfTabViewItem(tabs.selectedTabViewItem!) == 0, "Creation exposes the confirmed new object in the device tab")
        assert(opened == [f.id], "Creation must not boot or open a guest automatically")
        // New list order must not redirect an existing selection to another device.
        fake.snapshots = [f.json(state: "Booted", created: true)]
        refresh.performClick(nil); await wait { refresh.isEnabled }
        assert(manager.inventory.devices[table.selectedRow].id == f.newID)

        window.setContentSize(NSSize(width: 700, height: 480)); window.contentView!.layoutSubtreeIfNeeded()
        tabs.selectTabViewItem(at: 1); window.contentView!.layoutSubtreeIfNeeded()
        let outer = tabs.selectedTabViewItem!.view as! NSScrollView
        assert(outer.documentView!.frame.height > outer.contentView.bounds.height, "Compact creation forms must scroll while navigation and result stay visible")
        assert(runtime.bounds.width > 500 && status.visibleRect.height > 0, "runtime=\(runtime.frame), status=\(status.frame), visible=\(status.visibleRect)")
        window.makeFirstResponder(name)
        name.currentEditor()?.doCommand(by: NSSelectorFromString("insertTab:"))
        assert(window.firstResponder === runtime, "The field-editor Tab command must focus the runtime picker")
        assert(NSApp.isActive && window.isKeyWindow, "Foreground required for programmatic keyboard routing")
        let tabEvent = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil, characters: "\t", charactersIgnoringModifiers: "\t", isARepeat: false, keyCode: 48)!
        window.sendEvent(tabEvent)
        assert(window.firstResponder === types, "The next creation field is the compatible model picker")
        let backTab = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.shift], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil, characters: "\t", charactersIgnoringModifiers: "\t", isARepeat: false, keyCode: 48)!
        window.sendEvent(backTab); assert(window.firstResponder === runtime)
        window.sendEvent(backTab); assert(window.firstResponder === name.currentEditor(), "Shift-Tab returns to the preserved name draft")
        func controlTab(_ backwards: Bool = false) {
            let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: backwards ? [.control, .shift] : [.control], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, characters: "\t", charactersIgnoringModifiers: "\t", isARepeat: false, keyCode: 48)!
            window.sendEvent(event)
        }
        controlTab(); assert(tabs.indexOfTabViewItem(tabs.selectedTabViewItem!) == 2)
        controlTab(true); assert(tabs.indexOfTabViewItem(tabs.selectedTabViewItem!) == 1 && window.firstResponder === name.currentEditor())
        controlTab(true); controlTab(true)
        assert(tabs.indexOfTabViewItem(tabs.selectedTabViewItem!) == 2, "Control-Shift-Tab wraps through the visible task tabs")
        controlTab(); assert(tabs.indexOfTabViewItem(tabs.selectedTabViewItem!) == 0)

        // Exercise the actual consent dialog with the injected backend. Even a wrong
        // selection cannot download anything, and Return must take the cancel route.
        tabs.selectTabViewItem(at: 2)
        let download = button("런타임 다운로드…")
        let beforeDialog = fake.commands.count
        var observedDialog = false
        let timer = Timer(timeInterval: 0.05, repeats: true) { timer in
            MainActor.assumeIsolated {
            guard let modal = NSApp.modalWindow else { return }
            guard NSApp.isActive && modal.isKeyWindow else { fatalError("Foreground lost during synthetic consent check") }
            let text = descendants(modal.contentView!).compactMap { $0 as? NSTextField }.map(\.stringValue).joined(separator: "\n")
            assert(text.contains("iOS") && text.contains("GB"), "Consent must identify its platform and download consequence")
            observedDialog = true; timer.invalidate()
            let enter = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: modal.windowNumber, context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36)!
            assert(modal.performKeyEquivalent(with: enter), "The consent dialog must handle Return")
            }
        }
        RunLoop.main.add(timer, forMode: .modalPanel)
        download.performClick(nil); timer.invalidate()
        await wait { NSApp.modalWindow == nil && window.isKeyWindow }
        assert(observedDialog && fake.commands.count == beforeDialog && refresh.isEnabled, "Return cancels consent without executing an installation")
        assert(window.firstResponder === download, "Cancelling consent returns focus to the initiating control")
        tabs.selectTabViewItem(at: 0)
        if let capture = ProcessInfo.processInfo.environment["SIMULATOR_PREPARATION_CAPTURE"] {
            window.setContentSize(NSSize(width: 900, height: 800)); window.contentView!.layoutSubtreeIfNeeded()
            window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard NSApp.isActive, window.isKeyWindow else { fatalError("Foreground changed before preparation capture") }
            let shot = Process(); shot.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            shot.arguments = ["-x", "-o", "-l", String(window.windowNumber), capture]
            try shot.run(); shot.waitUntilExit(); assert(shot.terminationStatus == 0)
            print("Synthetic preparation UI capture: " + capture)
        }

        let gate = DispatchSemaphore(value: 0), reached = DispatchSemaphore(value: 0)
        fake.snapshots = [f.json(), f.json(created: true)]
        fake.onCommand = { args in
            if args.contains("create") { reached.signal(); gate.wait(); return f.newID }
            return ""
        }
        tabs.selectTabViewItem(at: 1); enterName("New phone"); create.performClick(nil)
        await wait { reached.wait(timeout: .now()) == .success }
        let commandCount = fake.commands.count
        cancel.performClick(nil); assert(!cancel.isEnabled && !create.isEnabled)
        window.close(); manager.show()
        assert(!refresh.isEnabled && !create.isEnabled && fake.commands.count == commandCount,
               "Closing and reopening must retain the operation slot until cancellation settles")
        gate.signal(); await wait { refresh.isEnabled }
        assert(status.stringValue.contains("취소"), "Late successful command completion must not replace cancellation")
        fake.onCommand = nil; fake.directory = "/Library/Developer/CommandLineTools"
        refresh.performClick(nil); await wait { refresh.isEnabled }
        assert(status.stringValue.contains("전체 Xcode") && !cancel.isEnabled)
        let retry = button("목록 다시 읽기")
        assert(!retry.isHidden)
        fake.directory = "/Applications/Xcode.app/Contents/Developer"; fake.snapshots = [f.json()]
        retry.performClick(nil); await wait { refresh.isEnabled }
        fake.onCommand = { _ in throw SimulatorPreparationError("fixture create failure; keep draft") }
        tabs.selectTabViewItem(at: 1); enterName("Retained draft"); create.performClick(nil)
        await wait { refresh.isEnabled }
        assert(name.stringValue == "Retained draft" && tabs.indexOfTabViewItem(tabs.selectedTabViewItem!) == 1)
        assert(status.stringValue.contains("실패 · 기기 생성") && !retry.isHidden)
        let failures = fake.commands.count
        retry.performClick(nil); await wait { refresh.isEnabled }
        assert(fake.commands.count == failures, "Readback recovery must not repeat a failed create")
        fake.onCommand = nil
        var empty = try JSONSerialization.jsonObject(with: Data(f.json().utf8)) as! [String: Any]
        empty["devices"] = [String: Any]()
        var installed = empty["runtimes"] as! [[String: Any]]; installed[0]["isAvailable"] = false; empty["runtimes"] = installed
        fake.snapshots = [String(decoding: try JSONSerialization.data(withJSONObject: empty), as: UTF8.self)]
        tabs.selectTabViewItem(at: 0); refresh.performClick(nil); await wait { refresh.isEnabled }
        assert(table.numberOfRows == 0 && emptyLabel.stringValue.contains("아직 기기가 없습니다"))
        let runtimeList = views.compactMap { $0 as? NSTableView }.first { $0.accessibilityLabel() == "설치된 시뮬레이터 런타임" }!
        let supported = runtimeList.dataSource?.tableView?(runtimeList, objectValueFor: runtimeList.tableColumns[2], row: 0) as? String
        assert(supported == "Phone", "An unavailable runtime retains its known supported model instead of claiming zero compatibility")
        button("새 기기 만들기").performClick(nil)
        assert(tabs.indexOfTabViewItem(tabs.selectedTabViewItem!) == 1 && create.isEnabled)
        let selectsBefore = fake.selectCount
        manager.boardChanged()
        assert(refresh.isEnabled && fake.selectCount == selectsBefore, "Background inventory reads must not interrupt creation drafts")
        print("PASS interface-first preparation UI: structured selection/claims, three task tabs and Control-Tab wrapping, empty/no-match recovery, search UUID safety, name admission, compatible models, editor Tab/Shift-Tab, native consent Return cancellation/focus return without install, creation navigation, busy/cancel/late guards, draft retention and compact page scrolling")

        if ProcessInfo.processInfo.arguments.contains("--live-inventory") {
            let live = SimulatorPreparationWindow(backendFactory: { SimulatorPreparationBackend(task: $0, claims: { [:] }) }, claims: { [:] },
                openLCD: { _, _ in fatalError("The inventory check must not open an LCD or mutate a simulator") })
            // Isolated native UI and real read-only xcode-select/simctl calls.
            live.show(); window.makeKeyAndOrderFront(nil)
            let liveWindow = NSApp.windows.first { $0 !== window && $0.title == "시뮬레이터 관리 (mac-cu)" }!
            defer { liveWindow.close() }
            let liveViews = descendants(liveWindow.contentView!)
            let liveRefresh = liveViews.compactMap { $0 as? NSButton }.first { $0.title == "새로고침" }!
            await wait { liveRefresh.isEnabled }
            assert(!live.inventory.developerDirectory.isEmpty && !live.inventory.runtimes.isEmpty)
            print("PASS real inventory in native manager: \(live.inventory.devices.count) devices, \(live.inventory.runtimes.count) runtimes; no create/download/boot/open action")
        }
    }
    static func main() {
        admitNativeSelfcheck()
        let app = NSApplication.shared; app.setActivationPolicy(.accessory)
        Task { @MainActor in
            do { try await run(); exit(0) }
            catch { fputs("FAIL preparation UI: \(error)\n", stderr); exit(1) }
        }
        app.run()
    }
}
