import AppKit
import UniformTypeIdentifiers

/// One operation at a time. The shared status board requests refreshes; this window
/// owns no polling timer and closing it cancels only its own operation.
final class SimulatorPreparationWindow: NSObject, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate, NSSearchFieldDelegate, NSTabViewDelegate {
    typealias BackendFactory = (SimulatorPreparationTask) -> SimulatorPreparationBackend
    private let backendFactory: BackendFactory
    private let openLCD: (String, SimulatorPreparationTask) throws -> String
    private let claims: () -> [String: String]
    private var window: NSWindow?
    private let table = NSTableView()
    private let tabs = NSTabView()
    private let runtimeTable = NSTableView()
    private let runtimeCount = NSTextField(labelWithString: "목록 확인 전")
    private let installedRuntimeDetails = NSTextField(wrappingLabelWithString: "런타임을 선택하면 식별자와 호환 정보를 표시합니다.")
    private let emptyMessage = NSTextField(wrappingLabelWithString: "기기 목록 확인 전입니다.")
    private var emptyAction: NSButton!
    private var emptyGroup: NSStackView!
    private var deviceScroll: NSScrollView!
    private var retryButton: NSButton!
    private var logButton: NSButton!
    private var logScroll: NSScrollView!
    private var loaded = false
    private let search = NSSearchField()
    private let deviceFilter = PreparationPopupButton(frame: .zero, pullsDown: false)
    private let deviceCount = NSTextField(labelWithString: "")
    private let runtime = PreparationPopupButton(frame: .zero, pullsDown: false)
    private let deviceType = PreparationPopupButton(frame: .zero, pullsDown: false)
    private let platform = PreparationPopupButton(frame: .zero, pullsDown: false)
    private let name = NSTextField()
    private let nameHint = NSTextField(wrappingLabelWithString: "")
    private let selectedName = NSTextField(wrappingLabelWithString: "기기를 선택하세요")
    private let selectedState = NSTextField(wrappingLabelWithString: "")
    private let selectedUsage = NSTextField(wrappingLabelWithString: "")
    private let selectedRuntime = NSTextField(wrappingLabelWithString: "")
    private let details = NSTextField(wrappingLabelWithString: "기기를 선택하세요.")
    private let runtimeDetails = NSTextField(wrappingLabelWithString: "")
    private let status = NSTextField(wrappingLabelWithString: "Xcode 목록을 읽기 전입니다.")
    private let log = NSTextView()
    private let progress = NSProgressIndicator()
    private var refreshButton: NSButton!
    private var startButton: NSButton!
    private var createButton: NSButton!
    private var downloadButton: NSButton!
    private var importButton: NSButton!
    private var cancelButton: NSButton!
    private(set) var inventory = SimulatorPreparationInventory.empty
    private var visibleDevices: [PreparedSimulatorDevice] = []
    private var operation: SimulatorPreparationTask?
    private var generation = 0
    private var selectedID: String?
    private var updatingTable = false
    private var choosingInstallation = false
    private var automaticRefresh = false

    init(backendFactory: @escaping BackendFactory, claims: @escaping () -> [String: String],
         openLCD: @escaping (String, SimulatorPreparationTask) throws -> String) {
        self.backendFactory = backendFactory; self.claims = claims; self.openLCD = openLCD
        super.init()
    }

    func show() {
        precondition(Thread.isMainThread)
        if window == nil { build() }
        window?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        if operation == nil { refresh() }
    }

    func boardChanged() {
        guard window?.isVisible == true, operation == nil, !choosingInstallation else { return }
        guard tabs.selectedTabViewItem?.identifier as? String == "devices", !(window?.firstResponder is NSTextView) else { return }
        refresh(silent: true)
    }

    private func build() {
        let height = max(540, min(700, (NSScreen.main?.visibleFrame.height ?? 900) - 100))
        let w = PreparationManagerWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: height),
                         styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        w.title = "시뮬레이터 관리 (mac-cu)"; w.isReleasedWhenClosed = false; w.delegate = self
        w.autorecalculatesKeyViewLoop = false
        w.minSize = NSSize(width: 700, height: 480)
        func button(_ title: String, _ action: Selector) -> NSButton { NSButton(title: title, target: self, action: action) }
        func row(_ views: [NSView]) -> NSStackView {
            let row = NSStackView(views: views); row.orientation = .horizontal; row.spacing = 8; return row
        }
        func heading(_ text: String) -> NSTextField {
            let field = NSTextField(labelWithString: text); field.font = .boldSystemFont(ofSize: 13); return field
        }
        refreshButton = button("새로고침", #selector(refreshClicked))
        startButton = button("실행 및 LCD 열기", #selector(startClicked))
        createButton = button("기기 생성", #selector(createClicked))
        downloadButton = button("런타임 다운로드…", #selector(downloadClicked))
        importButton = button("DMG 가져오기…", #selector(importClicked))
        cancelButton = button("작업 취소", #selector(cancelClicked))
        progress.style = .spinning; progress.controlSize = .small; progress.isDisplayedWhenStopped = false
        for (id, title, width) in [("device", "기기", 180.0), ("runtime", "OS", 100.0), ("state", "상태 · 사용 기록", 160.0)] {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id)); column.title = title; column.width = width
            if let cell = column.dataCell as? NSTextFieldCell { cell.wraps = true; cell.usesSingleLineMode = false; cell.font = .systemFont(ofSize: 11) }
            table.addTableColumn(column)
        }
        table.delegate = self; table.dataSource = self; table.rowHeight = 42; table.allowsMultipleSelection = false
        table.setAccessibilityLabel("설치된 시뮬레이터 기기")
        search.placeholderString = "기기 이름, UDID, OS 검색"; search.setAccessibilityLabel("시뮬레이터 기기 검색")
        search.delegate = self; search.target = self; search.action = #selector(filterChanged)
        search.sendsSearchStringImmediately = true
        search.setContentHuggingPriority(.defaultLow, for: .horizontal)
        for filter in SimulatorPreparationFilter.allCases { deviceFilter.addItem(withTitle: filter.title) }
        deviceFilter.target = self; deviceFilter.action = #selector(filterChanged); deviceFilter.setAccessibilityLabel("시뮬레이터 상태 필터")
        let searchRow = row([search, deviceFilter, deviceCount])
        deviceScroll = NSScrollView(); deviceScroll.documentView = table
        deviceScroll.hasVerticalScroller = true; deviceScroll.hasHorizontalScroller = true; deviceScroll.borderType = .bezelBorder
        deviceScroll.heightAnchor.constraint(equalToConstant: 250).isActive = true
        runtime.target = self; runtime.action = #selector(runtimeChanged)
        runtime.setAccessibilityLabel("새 기기 런타임"); deviceType.setAccessibilityLabel("새 기기 유형")
        for p in ["iOS", "watchOS", "tvOS", "visionOS"] { platform.addItem(withTitle: p) }
        platform.setAccessibilityLabel("다운로드 플랫폼")
        name.placeholderString = "새 기기 이름"; name.setAccessibilityLabel("새 기기 이름"); name.delegate = self
        nameHint.font = .systemFont(ofSize: 12); nameHint.setAccessibilityLabel("기기 이름 안내")
        details.isSelectable = true; runtimeDetails.isSelectable = true
        selectedName.font = .boldSystemFont(ofSize: 19); selectedName.setAccessibilityLabel("선택한 기기 이름")
        selectedState.font = .systemFont(ofSize: 13, weight: .semibold); selectedState.setAccessibilityLabel("선택한 기기 상태")
        selectedUsage.setAccessibilityLabel("선택한 기기 사용 기록"); selectedRuntime.setAccessibilityLabel("선택한 기기 OS")
        for field in [selectedName, selectedState, selectedUsage, selectedRuntime] { field.isSelectable = true }
        status.setAccessibilityLabel("시뮬레이터 준비 상태")
        for field in [details, runtimeDetails, status] { field.font = .systemFont(ofSize: 12) }
        details.font = .monospacedSystemFont(ofSize: 10.5, weight: .regular); details.textColor = .secondaryLabelColor
        details.setAccessibilityLabel("선택한 기기 식별자")
        log.isEditable = false; log.isSelectable = true; log.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        log.textContainerInset = NSSize(width: 8, height: 8); log.autoresizingMask = [.width]
        log.textContainer?.widthTracksTextView = true; log.setAccessibilityLabel("시뮬레이터 준비 로그")
        logScroll = NSScrollView(); logScroll.documentView = log; logScroll.hasVerticalScroller = true; logScroll.borderType = .bezelBorder
        logScroll.heightAnchor.constraint(equalToConstant: 90).isActive = true; logScroll.isHidden = true
        logButton = NSButton(checkboxWithTitle: "상세 로그", target: self, action: #selector(toggleLog))
        retryButton = button("목록 다시 읽기", #selector(refreshClicked)); retryButton.isHidden = true
        emptyAction = button("목록 다시 읽기", #selector(emptyActionClicked))
        emptyMessage.setAccessibilityLabel("기기 목록 상태")
        emptyGroup = NSStackView(views: [emptyMessage, emptyAction]); emptyGroup.orientation = .vertical; emptyGroup.spacing = 12
        func page(_ views: [NSView]) -> NSScrollView {
            let stack = NSStackView(views: views); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 14
            stack.translatesAutoresizingMaskIntoConstraints = false
            let document = SimulatorPreparationDocumentView(); document.translatesAutoresizingMaskIntoConstraints = false; document.addSubview(stack)
            let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true; scroll.documentView = document
            NSLayoutConstraint.activate([
                document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
                stack.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: 16), stack.trailingAnchor.constraint(equalTo: document.trailingAnchor, constant: -16),
                stack.topAnchor.constraint(equalTo: document.topAnchor, constant: 16), stack.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -16)
            ])
            for view in views { view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
            return scroll
        }
        func card(_ views: [NSView]) -> NSBox {
            let box = NSBox(); box.boxType = .custom; box.borderWidth = 1; box.cornerRadius = 10
            box.borderColor = .separatorColor; box.contentViewMargins = NSSize(width: 16, height: 16)
            let stack = NSStackView(views: views); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 12
            stack.translatesAutoresizingMaskIntoConstraints = false; box.contentView!.addSubview(stack)
            NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: box.contentView!.leadingAnchor), stack.trailingAnchor.constraint(equalTo: box.contentView!.trailingAnchor),
                stack.topAnchor.constraint(equalTo: box.contentView!.topAnchor), stack.bottomAnchor.constraint(equalTo: box.contentView!.bottomAnchor)])
            for view in views { view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
            return box
        }
        startButton.controlSize = .large; createButton.controlSize = .large
        for primary in [startButton!, createButton!] {
            primary.bezelStyle = .rounded; primary.bezelColor = .controlAccentColor; primary.contentTintColor = .selectedControlTextColor
        }
        let selectedCard = card([heading("선택한 기기"), selectedName, selectedState, heading("사용 기록"), selectedUsage,
            heading("런타임"), selectedRuntime, details, startButton])
        selectedCard.widthAnchor.constraint(equalToConstant: 270).isActive = true
        let deviceList = NSStackView(views: [deviceScroll, emptyGroup]); deviceList.orientation = .vertical; deviceList.alignment = .leading
        deviceScroll.widthAnchor.constraint(equalTo: deviceList.widthAnchor).isActive = true
        emptyGroup.widthAnchor.constraint(equalTo: deviceList.widthAnchor).isActive = true
        deviceList.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let devices = NSStackView(views: [deviceList, selectedCard]); devices.orientation = .horizontal; devices.alignment = .top; devices.spacing = 16
        devices.distribution = .fill
        deviceList.widthAnchor.constraint(equalTo: devices.widthAnchor, constant: -286).isActive = true
        let devicePage = page([searchRow, devices])
        let creationPage = page([card([heading("새 기기"), heading("기기 이름"), name, nameHint, heading("OS 런타임"), runtime, heading("기기 모델"), deviceType, runtimeDetails, createButton,
            button("런타임 관리", #selector(showRuntimeTab))])])
        for (id, title, width) in [("name", "런타임 · 빌드", 240.0), ("availability", "상태", 100.0), ("support", "호환 기기", 170.0)] {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id)); column.title = title; column.width = width
            if let cell = column.dataCell as? NSTextFieldCell { cell.wraps = true; cell.usesSingleLineMode = false }
            runtimeTable.addTableColumn(column)
        }
        runtimeTable.delegate = self; runtimeTable.dataSource = self; runtimeTable.rowHeight = 44
        runtimeTable.setAccessibilityLabel("설치된 시뮬레이터 런타임")
        let installed = NSScrollView(); installed.documentView = runtimeTable; installed.hasVerticalScroller = true; installed.hasHorizontalScroller = true
        installed.heightAnchor.constraint(equalToConstant: 180).isActive = true; installed.borderType = .bezelBorder
        installedRuntimeDetails.isSelectable = true; installedRuntimeDetails.font = .systemFont(ofSize: 12)
        let note = NSTextField(wrappingLabelWithString: "런타임은 시뮬레이터 OS입니다. 다운로드는 수 GB와 여유 공간이 필요할 수 있습니다.")
        note.font = .systemFont(ofSize: 12); note.textColor = .secondaryLabelColor
        let help = button("Xcode 설치 안내", #selector(xcodeHelp))
        let runtimePage = page([card([heading("설치된 런타임"), runtimeCount, installed, installedRuntimeDetails]),
            card([heading("런타임 추가"), row([platform, downloadButton, importButton]), note, help])])
        tabs.delegate = self; tabs.setAccessibilityLabel("시뮬레이터 관리 작업")
        for (id, label, content) in [("devices", "기기", devicePage), ("create", "새 기기", creationPage), ("runtimes", "런타임", runtimePage)] {
            let item = NSTabViewItem(identifier: id); item.label = label; item.view = content; tabs.addTabViewItem(item)
        }
        w.switchTask = { [weak self] previous in
            guard let self, let selected = self.tabs.selectedTabViewItem else { return }
            let count = self.tabs.numberOfTabViewItems
            let index = self.tabs.indexOfTabViewItem(selected)
            self.tabs.selectTabViewItem(at: (index + (previous ? count - 1 : 1)) % count)
        }
        let title = heading("시뮬레이터"); title.font = .boldSystemFont(ofSize: 20)
        let spacer = NSView(); spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let header = row([title, spacer, refreshButton])
        let footer = NSStackView(views: [row([progress, cancelButton, retryButton, logButton]), status, logScroll])
        footer.orientation = .vertical; footer.alignment = .leading; footer.spacing = 8
        status.widthAnchor.constraint(equalTo: footer.widthAnchor).isActive = true; logScroll.widthAnchor.constraint(equalTo: footer.widthAnchor).isActive = true
        let stack = NSStackView(views: [header, tabs, footer]); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false; w.contentView!.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: w.contentView!.leadingAnchor, constant: 18), stack.trailingAnchor.constraint(equalTo: w.contentView!.trailingAnchor, constant: -18),
            stack.topAnchor.constraint(equalTo: w.contentView!.topAnchor, constant: 18), stack.bottomAnchor.constraint(equalTo: w.contentView!.bottomAnchor, constant: -18),
            header.widthAnchor.constraint(equalTo: stack.widthAnchor), tabs.widthAnchor.constraint(equalTo: stack.widthAnchor), footer.widthAnchor.constraint(equalTo: stack.widthAnchor),
            tabs.heightAnchor.constraint(greaterThanOrEqualToConstant: 240)
        ])
        tabs.setContentHuggingPriority(.defaultLow, for: .vertical)
        w.initialFirstResponder = search
        search.nextKeyView = deviceFilter; deviceFilter.nextKeyView = table; table.nextKeyView = startButton; startButton.nextKeyView = refreshButton; refreshButton.nextKeyView = tabs
        name.nextKeyView = runtime; runtime.nextKeyView = deviceType; deviceType.nextKeyView = createButton; createButton.nextKeyView = tabs
        runtimeTable.nextKeyView = platform; platform.nextKeyView = downloadButton; downloadButton.nextKeyView = importButton; importButton.nextKeyView = help; help.nextKeyView = tabs
        deviceFilter.tabNext = table; deviceFilter.tabPrevious = search
        runtime.tabNext = deviceType; runtime.tabPrevious = name
        deviceType.tabNext = createButton; deviceType.tabPrevious = runtime
        platform.tabNext = downloadButton; platform.tabPrevious = runtimeTable
        w.center(); window = w; updateControls()
    }

    func numberOfRows(in tableView: NSTableView) -> Int { tableView === runtimeTable ? inventory.runtimes.count : visibleDevices.count }
    func tableView(_ tableView: NSTableView, objectValueFor tableColumn: NSTableColumn?, row: Int) -> Any? {
        if tableView === runtimeTable {
            guard inventory.runtimes.indices.contains(row) else { return nil }
            let runtime = inventory.runtimes[row]
            switch tableColumn?.identifier.rawValue {
            case "name": return "\(runtime.name)\n\(runtime.build)"
            case "availability": return runtime.available ? "✓ 사용 가능" : "! 사용 불가"
            default:
                if let supported = runtime.supportedTypes {
                    if supported.count == 1, let id = supported.first { return inventory.types.first { $0.id == id }?.name ?? id }
                    return "\(supported.count)개 기기"
                }
                let types = inventory.compatibleTypes(for: runtime.id)
                if types.count == 1 { return types[0].name }
                return types.isEmpty ? "정보 없음" : "\(types.count)개 기기"
            }
        }
        guard visibleDevices.indices.contains(row) else { return nil }
        let device = visibleDevices[row]
        switch tableColumn?.identifier.rawValue {
        case "device": return device.name
        case "runtime": return inventory.runtimes.first { $0.id == device.runtimeID }?.name ?? device.runtimeID
        default: return "\(device.stateTitle)\(device.available ? "" : " · 사용 불가")\n\(claims()[device.id].map { "사용: \($0)" } ?? "사용 기록 없음")"
        }
    }
    func tableViewSelectionDidChange(_ notification: Notification) {
        if notification.object as? NSTableView === runtimeTable {
            let row = runtimeTable.selectedRow
            installedRuntimeDetails.stringValue = inventory.runtimes.indices.contains(row) ? inventory.runtimes[row].title : "런타임을 선택하면 식별자와 호환 정보를 표시합니다."
            return
        }
        guard !updatingTable else { return }
        selectedID = visibleDevices.indices.contains(table.selectedRow) ? visibleDevices[table.selectedRow].id : nil
        updateControls()
    }

    private var currentFilter: SimulatorPreparationFilter { SimulatorPreparationFilter(rawValue: deviceFilter.indexOfSelectedItem) ?? .all }
    @objc private func emptyActionClicked() {
        if !loaded { refresh() }
        else if inventory.devices.isEmpty { tabs.selectTabViewItem(at: 1) }
        else { search.stringValue = ""; deviceFilter.selectItem(at: 0); filterChanged(); window?.makeFirstResponder(search) }
    }
    @objc private func showRuntimeTab() { tabs.selectTabViewItem(at: 2) }
    @objc private func toggleLog() { logScroll.isHidden = logButton.state != .on }
    func tabView(_ tabView: NSTabView, didSelect tabViewItem: NSTabViewItem?) {
        switch tabViewItem?.identifier as? String {
        case "devices": tabs.nextKeyView = search; window?.makeFirstResponder(search)
        case "create": tabs.nextKeyView = name; window?.makeFirstResponder(name)
        case "runtimes": tabs.nextKeyView = runtimeTable; window?.makeFirstResponder(runtimeTable)
        default: break
        }
    }
    private func updateEmptyState() {
        deviceScroll?.isHidden = visibleDevices.isEmpty
        emptyGroup?.isHidden = !visibleDevices.isEmpty
        guard let emptyAction else { return }
        if !loaded {
            emptyMessage.stringValue = operation == nil ? "기기 목록 확인 전입니다." : "기기 목록을 읽는 중…"
            emptyAction.title = "목록 다시 읽기"
        } else if inventory.devices.isEmpty {
            emptyMessage.stringValue = "아직 기기가 없습니다. 설치된 런타임으로 새 기기를 만드세요."
            emptyAction.title = "새 기기 만들기"
        } else {
            emptyMessage.stringValue = "검색 조건에 맞는 기기가 없습니다."
            emptyAction.title = "검색 조건 초기화"
        }
        emptyAction.isEnabled = operation == nil
    }
    @objc private func filterChanged() { rebuildDevices(); updateControls() }
    func controlTextDidChange(_ notification: Notification) {
        if notification.object as? NSSearchField === search { filterChanged() }
        else { updateControls() }
    }
    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        // Route the field editor itself: recent AppKit text fields use an internal
        // hosting view, so linking only the outer field does not define its Tab path.
        if commandSelector == NSSelectorFromString("insertTab:") {
            if control === name { runtime.nextKeyView = deviceType; deviceType.nextKeyView = createButton; return window?.makeFirstResponder(runtime) == true }
            if control === search { deviceFilter.nextKeyView = table; return window?.makeFirstResponder(deviceFilter) == true }
        }
        if commandSelector == NSSelectorFromString("insertBacktab:"), control === name || control === search {
            return window?.makeFirstResponder(tabs) == true
        }
        if commandSelector == NSSelectorFromString("insertNewline:"), control === name, createButton.isEnabled {
            createButton.performClick(nil); return true
        }
        return false
    }
    private func rebuildDevices() {
        visibleDevices = inventory.devices.filter { $0.matches(query: search.stringValue, filter: currentFilter) }
        deviceCount.stringValue = loaded ? "\(visibleDevices.count) / \(inventory.devices.count)대" : "목록 확인 전"
        updatingTable = true; table.reloadData()
        if let index = visibleDevices.firstIndex(where: { $0.id == selectedID }) { table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false) }
        else { selectedID = nil; table.deselectAll(nil) }
        updatingTable = false
        updateEmptyState()
    }

    private var chosenRuntime: String { runtime.selectedItem?.representedObject as? String ?? "" }
    private func apply(_ inventory: SimulatorPreparationInventory, selected: String? = nil) {
        let previousRuntimeID = self.inventory.runtimes.indices.contains(runtimeTable.selectedRow) ? self.inventory.runtimes[runtimeTable.selectedRow].id : nil
        self.inventory = inventory; loaded = true; selectedID = selected ?? selectedID
        if let selected, let device = inventory.devices.first(where: { $0.id == selected }),
           !device.matches(query: search.stringValue, filter: currentFilter) {
            search.stringValue = ""; deviceFilter.selectItem(at: 0)
        }
        rebuildDevices()
        runtimeTable.reloadData()
        if let index = inventory.runtimes.firstIndex(where: { $0.id == previousRuntimeID }) { runtimeTable.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false) }
        else { runtimeTable.deselectAll(nil); installedRuntimeDetails.stringValue = "런타임을 선택하면 식별자와 호환 정보를 표시합니다." }
        runtimeCount.stringValue = "\(inventory.runtimes.count)개 · 사용 가능 \(inventory.runtimes.filter(\.available).count)개"
        let previous = chosenRuntime; runtime.removeAllItems()
        for r in inventory.runtimes where r.available {
            runtime.addItem(withTitle: r.title); runtime.lastItem?.representedObject = r.id
        }
        if let item = runtime.itemArray.first(where: { $0.representedObject as? String == previous }) { runtime.select(item) }
        runtimeChanged(); updateControls()
        if selected != nil { tabs.selectTabViewItem(at: 0) }
    }
    @objc private func runtimeChanged() {
        let previous = deviceType.selectedItem?.representedObject as? String
        deviceType.removeAllItems()
        for type in inventory.compatibleTypes(for: chosenRuntime) {
            deviceType.addItem(withTitle: "\(type.name) · \(type.id)"); deviceType.lastItem?.representedObject = type.id
        }
        if let item = deviceType.itemArray.first(where: { $0.representedObject as? String == previous }) { deviceType.select(item) }
        runtimeDetails.stringValue = chosenRuntime.isEmpty ? "사용 가능한 런타임이 없습니다. 런타임 관리에서 추가하세요." :
            deviceType.numberOfItems == 0 ? "이 Xcode에서 생성 가능한 기기 유형이 없습니다.\n\(chosenRuntime)" : "지원 기기 \(deviceType.numberOfItems)개 · \(chosenRuntime)"
        updateControls()
    }
    private func updateControls() {
        let idle = operation == nil
        let device = inventory.devices.first { $0.id == selectedID }
        let owner = device.flatMap { claims()[$0.id] }
        startButton?.isEnabled = idle && device?.canStart == true && owner == nil
        startButton?.title = device?.booted == true ? "LCD 열기" : device?.state == "Booting" ? "부팅 대기 및 LCD 열기" : "실행 및 LCD 열기"
        selectedName.stringValue = device.map { "✓ " + $0.name } ?? "기기를 선택하세요"
        selectedState.stringValue = device.map { "\($0.booted ? "●" : "○") \($0.stateTitle)\($0.available ? "" : " · 사용 불가")" } ?? ""
        selectedState.textColor = device?.available == false ? .systemRed : device?.booted == true ? .systemGreen : .secondaryLabelColor
        selectedUsage.stringValue = device == nil ? "—" : owner.map { "사용: \($0)\n해당 세션과 확인한 뒤 실행하세요." } ?? "사용 기록 없음"
        selectedUsage.textColor = owner == nil ? .labelColor : .systemOrange
        selectedRuntime.stringValue = device.flatMap { device in inventory.runtimes.first { $0.id == device.runtimeID }.map { "\($0.name) · \($0.build)" } } ?? (device?.runtime ?? "—")
        details.stringValue = device.map { "UDID\n\($0.id)\n\n런타임 ID\n\($0.runtimeID)" } ?? "목록에서 대상을 선택하면 식별자를 표시합니다."
        refreshButton?.isEnabled = idle; cancelButton?.isEnabled = !idle && !automaticRefresh; cancelButton?.isHidden = idle || automaticRefresh
        retryButton?.isEnabled = idle
        let validName = (try? SimulatorPreparationBackend.deviceName(name.stringValue)) != nil
        createButton?.isEnabled = idle && deviceType.selectedItem != nil && validName
        for primary in [startButton, createButton].compactMap({ $0 }) {
            primary.bezelColor = primary.isEnabled ? .controlAccentColor : nil
            primary.contentTintColor = primary.isEnabled ? .selectedControlTextColor : nil
        }
        nameHint.stringValue = validName ? "생성 후 목록에서 새 기기를 선택합니다. 실행은 별도로 누르세요." : "기기 이름은 1~80자로 입력하세요. 제어 문자와 첫 글자 -는 사용할 수 없습니다."
        nameHint.textColor = validName || name.stringValue.isEmpty ? .secondaryLabelColor : .systemRed
        downloadButton?.isEnabled = idle; importButton?.isEnabled = idle
        for control in [runtime, deviceType, platform] { control.isEnabled = idle }
        name.isEnabled = idle; table.isEnabled = idle; search.isEnabled = idle; deviceFilter.isEnabled = idle
        updateEmptyState()
    }

    private struct Result { let inventory: SimulatorPreparationInventory; let selected: String?; let message: String }
    private func run(_ title: String, operationName: String = "목록 확인", silent: Bool = false,
                     work: @escaping (SimulatorPreparationBackend, SimulatorPreparationTask) throws -> Result) {
        guard operation == nil else { return }
        let task = SimulatorPreparationTask(); operation = task; generation += 1; let token = generation
        automaticRefresh = silent
        if !silent { status.stringValue = title; log.string = ""; retryButton.isHidden = true; progress.startAnimation(nil) }
        updateControls()
        task.onOutput = { [weak self, weak task] output in DispatchQueue.main.async {
            guard let self, let task, self.generation == token, self.operation === task else { return }
            self.log.string = String((self.log.string + output).suffix(12_000))
            self.log.scrollToEndOfDocument(nil)
        } }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            let result = Swift.Result {
                let value = try work(self.backendFactory(task), task)
                try task.checkCancellation()
                return value
            }
            DispatchQueue.main.async {
                guard self.generation == token, self.operation === task else { return }
                let previousStatus = self.status.stringValue
                self.operation = nil; self.progress.stopAnimation(nil)
                if task.isCancelled {
                    self.status.stringValue = "작업이 취소되었습니다. 이미 준비한 항목은 유지합니다. 목록을 새로고침하세요."
                    self.retryButton.isHidden = false
                    self.updateControls(); return
                }
                switch result {
                case .success(let value):
                    self.apply(value.inventory, selected: value.selected)
                    if !silent { self.status.stringValue = value.message }
                case .failure(let error):
                    self.status.stringValue = "실패 · \(operationName)\n\(String(error.localizedDescription.prefix(180)))" + (self.inventory.devices.isEmpty ? "" : "\n목록은 마지막 확인값입니다. 새로고침으로 다시 확인하세요.")
                    self.log.string += "\n" + error.localizedDescription
                    self.retryButton.isHidden = false
                }
                self.updateControls()
                if self.status.stringValue != previousStatus { NSAccessibility.post(element: self.status, notification: .valueChanged) }
            }
        }
    }
    private func refresh(silent: Bool = false) {
        run("Xcode의 시뮬레이터 목록을 읽는 중…", silent: silent) { backend, _ in
            let inventory = try backend.inventory()
            return Result(inventory: inventory, selected: nil, message: "목록 확인 완료 · 기기 \(inventory.devices.count)대 · 런타임 \(inventory.runtimes.count)개")
        }
    }
    @objc private func refreshClicked() { refresh() }
    @objc private func startClicked() {
        guard let id = selectedID else { return }
        run("선택한 기기의 실행 상태를 확인하는 중…", operationName: "기기 실행 및 LCD 열기") { [openLCD, claims] backend, task in
            let inventory = try backend.boot(id)
            try task.checkCancellation()
            guard claims()[id] == nil else { throw SimulatorPreparationError("다른 세션이 사용 중입니다. LCD를 열지 않았습니다.") }
            _ = try openLCD(id, task)
            return Result(inventory: inventory, selected: id, message: "선택한 기기의 LCD 창을 열었습니다.")
        }
    }
    @objc private func createClicked() {
        let name = name.stringValue, runtime = chosenRuntime, type = deviceType.selectedItem?.representedObject as? String ?? ""
        run("기기를 생성하는 중…", operationName: "기기 생성") { backend, _ in
            let (id, inventory) = try backend.create(name: name, typeID: type, runtimeID: runtime)
            return Result(inventory: inventory, selected: id, message: "기기 생성 확인 완료. 선택한 기기를 실행하면 LCD가 열립니다.")
        }
    }
    @objc private func downloadClicked() {
        guard operation == nil, let platform = platform.titleOfSelectedItem else { return }
        choosingInstallation = true
        defer { choosingInstallation = false; window?.makeFirstResponder(operation == nil ? downloadButton : cancelButton) }
        let alert = NSAlert(); alert.messageText = "\(platform) 런타임을 다운로드하고 설치할까요?"
        alert.informativeText = "Xcode가 제공하는 런타임을 설치합니다. 수 GB의 다운로드와 여유 공간이 필요할 수 있습니다. Xcode의 라이선스·로그인·권한 요구 사항이 적용됩니다."
        alert.addButton(withTitle: "다운로드 및 설치"); alert.addButton(withTitle: "취소")
        alert.buttons[0].keyEquivalent = ""; alert.buttons[1].keyEquivalent = "\r"
        alert.window.initialFirstResponder = alert.buttons[1]
        guard alert.runModal() == .alertFirstButtonReturn, window?.isVisible == true else { return }
        run("\(platform) 런타임 다운로드·설치 중…", operationName: "\(platform) 런타임 설치") { backend, _ in
            Result(inventory: try backend.installRuntime(platform: platform), selected: nil, message: "설치 명령 완료 · 사용 가능한 \(platform) 런타임을 목록에서 확인했습니다.")
        }
    }
    @objc private func importClicked() {
        guard operation == nil else { return }
        choosingInstallation = true
        defer { choosingInstallation = false; window?.makeFirstResponder(operation == nil ? importButton : cancelButton) }
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.diskImage]; panel.allowsMultipleSelection = false; panel.canChooseDirectories = false
        panel.message = "Apple 시뮬레이터 런타임 DMG를 선택하세요."; panel.prompt = "가져오기 및 설치"
        guard panel.runModal() == .OK, let image = panel.url, window?.isVisible == true else { return }
        run("런타임 DMG를 가져오는 중…", operationName: "런타임 DMG 가져오기") { backend, _ in
            Result(inventory: try backend.installRuntime(platform: "iOS", image: image), selected: nil, message: "새로 사용 가능한 런타임을 목록에서 확인했습니다.")
        }
    }
    @objc private func cancelClicked() {
        operation?.cancel(); status.stringValue = "작업을 취소하는 중… 이미 준비한 항목은 유지합니다."; cancelButton.isEnabled = false
    }
    @objc private func xcodeHelp() {
        NSWorkspace.shared.open(URL(string: "https://developer.apple.com/xcode/")!)
    }
    func windowWillClose(_ notification: Notification) {
        // Retain the operation slot until its worker has actually stopped; reopening cannot
        // launch a second mutation while cancellation is still in progress.
        if operation != nil { cancelClicked() }
    }
}

private final class SimulatorPreparationDocumentView: NSView {
    override var isFlipped: Bool { true }
}

private final class PreparationManagerWindow: NSWindow {
    var switchTask: ((Bool) -> Void)?
    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, event.keyCode == 48, event.modifierFlags.contains(.control),
           event.modifierFlags.intersection([.command, .option]).isEmpty, let switchTask {
            switchTask(event.modifierFlags.contains(.shift)); return
        }
        super.sendEvent(event)
    }
}

/// Keep explicit Tab routes through native popup controls; Space and arrow/menu
/// handling remain AppKit's. Weak links do not retain a closed window's views.
private final class PreparationPopupButton: NSPopUpButton {
    weak var tabNext: NSView?
    weak var tabPrevious: NSView?
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 48 && event.modifierFlags.intersection([.command, .control, .option]).isEmpty,
           let target = event.modifierFlags.contains(.shift) ? tabPrevious : tabNext,
           window?.makeFirstResponder(target) == true { return }
        super.keyDown(with: event)
    }
}
