import AppKit
import MetalKit

struct SimulatorInspectorCallbacks {
    // Root must complete on the main thread. Cancellation is advisory; generations are authoritative.
    var capture: (SimulatorInspectorContext, UInt64, @escaping (Result<SimulatorInspectorCapture, Error>) -> Void) -> Void
    var cancel: (SimulatorInspectorContext, UInt64) -> Void
    var edit: (SimulatorInspectorContext, InspectorCommand, @escaping (Result<[String: Any], Error>) -> Void) -> Void
    var revert: (SimulatorInspectorContext, [String: Any], @escaping (Result<[String: Any], Error>) -> Void) -> Void
    var release: (SimulatorInspectorContext, String?) -> Void
    var restoreHostFocus: () -> Void
    var prepareRecording: ((SimulatorInspectorContext, @escaping (Result<SimulatorInspectorContext, Error>) -> Void) -> Void)? = nil
}
private final class InspectorDetailStack: NSStackView { override var isFlipped: Bool { true } }

final class SimulatorInspectorWindowController: NSWindowController, NSWindowDelegate, NSOutlineViewDataSource, NSOutlineViewDelegate, NSSearchFieldDelegate {
    let model: SimulatorInspectorModel
    private var callbacks: SimulatorInspectorCallbacks
    private let tree = NSOutlineView(), search = NSSearchField(), scene = InspectorSceneView()
    private let header = NSTextField(wrappingLabelWithString: ""), status = NSTextField(wrappingLabelWithString: "캡처를 시작하세요. 캡처 중 앱이 일시 정지할 수 있습니다.")
    private let detail = NSTextField(wrappingLabelWithString: "뷰를 선택하세요."), result = NSTextField(wrappingLabelWithString: "")
    private let captureButton = NSButton(title: "캡처", target: nil, action: nil), cancelButton = NSButton(title: "취소", target: nil, action: nil)
    private var preparingRecording = false
    private let recordingButton = NSButton(title: "SwiftUI 기록을 켜고 다시 실행", target: nil, action: nil)
    private let recordingNotice = NSTextField(wrappingLabelWithString: "현재 실행 상태가 사라집니다. 기존 실행 인자와 환경 변수는 복원되지 않습니다.")
    private let hidden = NSButton(checkboxWithTitle: "hidden 초안", target: nil, action: nil), alpha = NSTextField(string: "")
    private let applyHidden = NSButton(title: "hidden 적용", target: nil, action: nil), applyAlpha = NSButton(title: "alpha 적용", target: nil, action: nil), revertButton = NSButton(title: "복원", target: nil, action: nil)
    private let depth = NSSlider(value: 12, minValue: 0, maxValue: 80, target: nil, action: nil)
    private let candidates = NSPopUpButton()
    private let rendererState = NSTextField(wrappingLabelWithString: "")
    private var renderer: SimulatorInspectorRenderer?
    private var visible = Set<String>(), candidateIDs: [String] = []
    private var updatingTreeSelection = false
    private var timer: Timer?
    private var closed = false
    var isClosed: Bool { closed }
    init(context: SimulatorInspectorContext, callbacks: SimulatorInspectorCallbacks) {
        self.model = .init(context: context); self.callbacks = callbacks
        let window = NSWindow(contentRect: NSRect(x: 0,y: 0,width: 1200,height: 760), styleMask: [.titled,.closable,.resizable,.miniaturizable], backing: .buffered, defer: false)
        window.title = "3D 뷰 검사"; window.minSize = NSSize(width: 900,height: 600)
        super.init(window: window); window.delegate = self
        build(); renderState()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.updateGates() }
    }
    required init?(coder: NSCoder) { nil }
    deinit { timer?.invalidate() }
    private func button(_ title: String, _ action: Selector) -> NSButton { NSButton(title: title, target: self, action: action) }
    private func stack(_ views: [NSView], horizontal: Bool = false) -> NSStackView {
        let s = NSStackView(views: views); s.orientation = horizontal ? .horizontal : .vertical; s.alignment = horizontal ? .centerY : .leading; s.spacing = 8; return s
    }
    private func scroll(_ content: NSView) -> NSScrollView {
        let s = NSScrollView(); s.hasVerticalScroller = true; s.hasHorizontalScroller = false; s.documentView = content
        content.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([content.leadingAnchor.constraint(equalTo: s.contentView.leadingAnchor, constant: 8), content.topAnchor.constraint(equalTo: s.contentView.topAnchor, constant: 8), content.widthAnchor.constraint(equalTo: s.contentView.widthAnchor, constant: -16)])
        return s
    }
    private func build() {
        guard let content = window?.contentView else { return }
        recordingButton.target = self; recordingButton.action = #selector(prepareRecordingNow)
        captureButton.target = self; captureButton.action = #selector(captureNow)
        cancelButton.target = self; cancelButton.action = #selector(cancelNow)
        search.placeholderString = "뷰 검색"; search.delegate = self; search.setAccessibilityLabel("뷰 검색")
        tree.columnAutoresizingStyle = .noColumnAutoresizing
        tree.headerView = nil; tree.allowsEmptySelection = true; tree.allowsMultipleSelection = false
        let column = NSTableColumn(identifier: .init("view")); column.title = "뷰"; tree.addTableColumn(column); tree.outlineTableColumn = column
        tree.delegate = self; tree.dataSource = self; tree.setAccessibilityLabel("캡처 뷰 계층")
        let treeScroll = NSScrollView(); treeScroll.hasVerticalScroller = true; treeScroll.hasHorizontalScroller = true; treeScroll.documentView = tree
        let left = stack([search,treeScroll]); left.widthAnchor.constraint(greaterThanOrEqualToConstant: 190).isActive = true
        search.widthAnchor.constraint(equalTo: left.widthAnchor).isActive = true; treeScroll.widthAnchor.constraint(equalTo: left.widthAnchor).isActive = true
        treeScroll.heightAnchor.constraint(equalTo: left.heightAnchor, constant: -36).isActive = true
        candidates.target = self; candidates.action = #selector(chooseCandidate); candidates.setAccessibilityLabel("겹친 뷰 후보")
        let camera = stack([button("왼쪽 회전",#selector(orbitLeft)),button("오른쪽 회전",#selector(orbitRight)),button("위로 회전",#selector(orbitUp)),button("아래로 회전",#selector(orbitDown))], horizontal: true)
        let zoom = stack([button("확대",#selector(zoomIn)),button("축소",#selector(zoomOut)),button("카메라 초기화",#selector(resetCamera))], horizontal: true)
        depth.target = self; depth.action = #selector(changeDepth); depth.setAccessibilityLabel("표시용 깊이 간격")
        let center = stack([rendererState,scene,camera,zoom,NSTextField(labelWithString: "표시용 깊이 간격 (pt)"),depth,candidates])
        scene.widthAnchor.constraint(equalTo: center.widthAnchor).isActive = true; scene.heightAnchor.constraint(greaterThanOrEqualToConstant: 220).isActive = true
        depth.widthAnchor.constraint(equalTo: center.widthAnchor).isActive = true
        scene.setContentHuggingPriority(.defaultLow, for: .vertical)
        applyHidden.target = self; applyHidden.action = #selector(editHidden); applyAlpha.target = self; applyAlpha.action = #selector(editAlpha)
        hidden.target = self; hidden.action = #selector(draftHidden)
        alpha.placeholderString = "alpha 0…1"; alpha.setAccessibilityLabel("alpha 초안 0부터 1"); alpha.delegate = self
        revertButton.target = self; revertButton.action = #selector(revertNow)
        let editor = InspectorDetailStack(views: [detail,hidden,applyHidden,NSTextField(labelWithString: "alpha 초안"),alpha,applyAlpha,revertButton,result])
        editor.orientation = .vertical; editor.alignment = .leading; editor.spacing = 8
        let right = scroll(editor)
        right.widthAnchor.constraint(greaterThanOrEqualToConstant: 210).isActive = true
        detail.widthAnchor.constraint(equalTo: editor.widthAnchor).isActive = true; result.widthAnchor.constraint(equalTo: editor.widthAnchor).isActive = true
        let split = NSSplitView(); split.isVertical = true; split.dividerStyle = .thin
        split.addArrangedSubview(left); split.addArrangedSubview(center); split.addArrangedSubview(right)
        let root = stack([header,stack([captureButton,cancelButton], horizontal: true),recordingButton,recordingNotice,status,split])
        root.translatesAutoresizingMaskIntoConstraints = false; content.addSubview(root)
        NSLayoutConstraint.activate([root.leadingAnchor.constraint(equalTo: content.leadingAnchor,constant: 12),root.trailingAnchor.constraint(equalTo: content.trailingAnchor,constant: -12),root.topAnchor.constraint(equalTo: content.topAnchor,constant: 12),root.bottomAnchor.constraint(equalTo: content.bottomAnchor,constant: -12),split.widthAnchor.constraint(equalTo: root.widthAnchor),split.heightAnchor.constraint(greaterThanOrEqualToConstant: 300)])
        split.setPosition(240, ofDividerAt: 0); split.setPosition(830, ofDividerAt: 1)
        do { renderer = try SimulatorInspectorRenderer(view: scene) }
        catch { rendererState.stringValue = error.localizedDescription; scene.isHidden = true }
        scene.onPick = { [weak self] p in self?.pick(p) }
        scene.onOrbit = { [weak self] x,y in self?.orbit(x,y) }
        scene.onZoom = { [weak self] d in self?.zoom(d) }
        window?.initialFirstResponder = search
    }
    // Called by the LCD owner on target/display/presentation changes, including disconnect.
    func updateContext(_ context: SimulatorInspectorContext) {
        precondition(Thread.isMainThread)
        guard context != model.context else { return }
        revoke(); model.invalidate(context: context); renderState()
    }
    func markStale(reason: String) { precondition(Thread.isMainThread); revoke(); model.invalidate(); status.stringValue = reason; renderState() }
    private func revoke() { callbacks.cancel(model.context,model.generation); callbacks.release(model.context,model.snapshot?.editing?.inspectionID) }
    @objc private func captureNow() {
        guard model.pending == nil else { return }; revoke()
        guard let generation = model.beginCapture() else { return }
        renderer?.releaseCapture(); renderState(); status.stringValue = "캡처 중…"
        let context = model.context
        callbacks.capture(context,generation) { [weak self] response in
            precondition(Thread.isMainThread); guard let self, !self.closed, self.model.generation == generation else { return }
            do {
                let capture = try response.get()
                let s = try SimulatorInspectorSnapshot.parse(capture.payload, context: capture.context)
                if self.model.acceptBoundCapture(s,generation: generation) {
                    self.renderer?.replace(s)
                    let rendererIssue = self.renderer == nil ? "3D 사용 불가" : (self.renderer!.textureFailures.isEmpty ? "" : "텍스처 \(self.renderer!.textureFailures.count)개 사용 불가 · 윤곽 표시")
                    self.rendererState.stringValue = ([rendererIssue] + s.renderingLimitations + (s.swiftUI?.hosts.values.sorted { $0.hostingNodeID < $1.hostingNodeID }.map(\.message) ?? [])).filter { !$0.isEmpty }.joined(separator: "\n")
                    self.status.stringValue = s.nodes.isEmpty ? "캡처에 뷰가 없습니다." : "\(s.nodes.count)개 뷰 · 선택 없음"
                    self.renderState()
                } else { throw InspectorFailure.invalid("이전 캡처이거나 검사 대상이 바뀌었습니다. 새로 캡처하세요.") }
            } catch { self.model.invalidate(); self.status.stringValue = "캡처 실패: \(error.localizedDescription)"; self.renderState() }
        }
    }
    @objc private func prepareRecordingNow() {
        guard !preparingRecording, model.canPrepareRecording, let action = callbacks.prepareRecording else { return }
        let context = model.context
        preparingRecording = true
        // Invalidate all graph/edit authority without discarding coordinator cleanup custody.
        model.invalidate(); renderer?.releaseCapture(); renderState()
        status.stringValue = "검사 권한을 정리하고 SwiftUI 기록을 준비하는 중…"
        action(context) { [weak self] result in
            guard let self else { return }
            self.preparingRecording = false
            guard !self.closed else { return }
            switch result {
            case .success(let bound):
                self.model.invalidate(context: bound)
                self.status.stringValue = "SwiftUI 기록 설정으로 다시 실행했습니다. 화면이 준비되면 새로 캡처하세요."
            case .failure(let error):
                self.status.stringValue = error.localizedDescription
            }
            self.renderState()
        }
    }
    @objc private func cancelNow() { revoke(); model.invalidate(); status.stringValue = "취소됨 · 이전 캡처는 읽기 전용"; renderState() }
    private func renderState() {
        candidateIDs = []; candidates.removeAllItems(); candidates.addItem(withTitle: "장면을 눌러 뷰 후보 확인"); candidates.isEnabled = false
        if model.receipt == nil { result.stringValue = "" }
        header.stringValue = "\(model.context.targetLabel) · 기기 \(model.context.deviceID) · 화면 \(model.context.displayID)\n캡처: \(model.snapshot?.capturedAt ?? "없음")\(model.stale ? " · 오래됨 / 읽기 전용" : "")"
        captureButton.title = model.snapshot == nil ? "캡처" : "새로 캡처"
        reloadTree()
        renderDetail(); updateGates()
    }
    private func reloadTree() {
        visible = model.snapshot?.visibleIDs(query: search.stringValue) ?? []
        if model.stale { visible = visible.filter { model.snapshot?.kind($0) == .uiKit } }
        let selected = model.selection.flatMap { visible.contains($0) ? $0 : nil }
        updatingTreeSelection = true
        if let snapshot = model.snapshot, let column = tree.outlineTableColumn {
            column.width = max(190, visible.map { id in
                CGFloat((snapshot.nodes[id]?.depth ?? snapshot.swiftUI?.nodes[id]?.depth ?? 0) + 1) * tree.indentationPerLevel + (snapshot.title(id) as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: NSFont.systemFontSize)]).width + 32
            }.max() ?? 190)
        }
        tree.reloadData(); tree.deselectAll(nil)
        if let selected { reveal(selected) }
        updatingTreeSelection = false
        if selected != model.selection { choose(selected) }
    }
    private func updateGates() {
        recordingButton.isHidden = !model.canPrepareRecording && !preparingRecording
        recordingNotice.isHidden = recordingButton.isHidden
        recordingButton.isEnabled = model.canPrepareRecording && !preparingRecording && callbacks.prepareRecording != nil
        captureButton.isEnabled = model.pending == nil && !model.loading && !preparingRecording; cancelButton.isEnabled = model.loading || model.pending != nil
        applyHidden.isEnabled = model.canEdit("hidden"); applyAlpha.isEnabled = model.canEdit("alpha")
        hidden.isEnabled = applyHidden.isEnabled; alpha.isEnabled = applyAlpha.isEnabled; revertButton.isEnabled = model.canRevert()
    }
    private func renderDetail() {
        renderer?.selection = model.selection; scene.needsDisplay = true
        if let id = model.selection, let n = model.snapshot?.swiftUI?.nodes[id] {
            renderer?.selection = nil
            hidden.state = .off; alpha.stringValue = ""; result.stringValue = ""
            let host = model.snapshot?.swiftUI?.hosts[n.hostingNodeID]
            let imageStatus = host?.compositeAssetID == nil ? "사용 불가" : "hosting subtree 합성 이미지"
            detail.stringValue = "SwiftUI · 읽기 전용\n" + String(n.typeName.prefix(2000)) + "\nID: " + n.id + "\n" + (host?.message ?? "") + "\n소스 위치: 사용 불가\n좌표: 검증되지 않음 · 트리에만 표시\n이미지: " + imageStatus + "\n\n" + n.properties.map { "property \($0.id): " + $0.original.displayText(limit: 1500) }.joined(separator: "\n")
            updateGates(); return
        }
        guard let id = model.selection, let n = model.snapshot?.nodes[id] else {
            detail.stringValue = "뷰를 선택하세요."; hidden.state = .off; alpha.stringValue = ""
            updateGates(); return
        }
        let textureError = n.assetID.flatMap { renderer?.textureFailures[$0] }
        let provenance = (n.assetID.flatMap { model.snapshot?.assets[$0]?.provenance } ?? n.unavailableReason ?? "텍스처 없음 · 윤곽만 표시") + (model.snapshot?.swiftUI?.hosts[id].map { "\n" + $0.message + "\n렌더링: " + $0.rendering.displayText(limit: 1000) } ?? "")
        detail.stringValue = "선택: \(n.className)\n\(n.label)\n뷰 ID: \(n.id)\nwindow: \(n.windowID ?? "Unavailable")\nscreen: \(n.screenID ?? "Unavailable")\nhidden: \(n.hidden.map { String($0) } ?? "Unavailable") · alpha: \(n.alpha.map { String($0) } ?? "Unavailable")\n\(provenance)\n\(textureError ?? "")\n\n" + n.properties.map { "\($0.name): \($0.name == "snapshotImage" ? "Image payload (see texture provenance)" : $0.value.displayText()) [fetchStatus: \($0.fetchStatus.displayText(limit: 200))]" }.joined(separator: "\n")
        hidden.state = n.hidden == true ? .on : .off; alpha.stringValue = n.alpha.map { String($0) } ?? ""
        if let draft = model.draft, draft.nodeID == id { switch draft.value { case .hidden(let b): hidden.state = b ? .on : .off; case .alpha(let a): alpha.stringValue = String(a) } }
        updateGates()
    }
    private func choose(_ id: String?) {
        // Pending response remains bound to its original node; selection never transfers edit authority.
        if model.pending != nil && id != model.selection && id.flatMap({ model.snapshot?.kind($0) }) != .swiftUI { revoke(); model.invalidate(); status.stringValue = "선택 변경으로 작업 권한이 해제되었습니다. 새 캡처 필요" }
        model.select(id); renderDetail()
        if let snapshot = model.snapshot {
            status.stringValue = "\(snapshot.nodes.count)개 뷰 · " + (model.selection.map { snapshot.title($0) }.map { "선택: " + $0 } ?? "선택 없음") + (model.stale ? " · 오래됨 / 읽기 전용" : "")
        }
    }
    private func reveal(_ id: String) {
        guard model.snapshot?.kind(id) != nil else { return }
        func expandParents(_ nodeID: String) {
            guard let parent = model.snapshot?.parent(nodeID) else { return }
            expandParents(parent); tree.expandItem(parent as NSString)
        }
        let wasUpdating = updatingTreeSelection
        updatingTreeSelection = true
        defer { updatingTreeSelection = wasUpdating }
        expandParents(id)
        let row = tree.row(forItem: id as NSString); if row >= 0 { tree.selectRowIndexes(IndexSet(integer: row),byExtendingSelection: false); tree.scrollRowToVisible(row) }
    }
    private func pick(_ p: SIMD2<Float>) {
        candidateIDs = renderer?.candidates(at: p) ?? []; candidates.removeAllItems(); candidates.isEnabled = !candidateIDs.isEmpty
        candidates.addItem(withTitle: candidateIDs.isEmpty ? "선택 후보 없음" : "겹친 뷰 \(candidateIDs.count)개 — 선택")
        for id in candidateIDs { let n = model.snapshot?.nodes[id]; candidates.addItem(withTitle: "\(n?.className ?? "") \(n?.label ?? "") · \(id)") }
        if candidateIDs.count == 1 { choose(candidateIDs[0]); reveal(candidateIDs[0]) }
    }
    @objc private func chooseCandidate() { let i = candidates.indexOfSelectedItem - 1; guard candidateIDs.indices.contains(i) else { return }; choose(candidateIDs[i]); reveal(candidateIDs[i]) }
    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int { children(item).count }
    private func children(_ item: Any?) -> [String] { let ids = (item as? String).flatMap { model.snapshot?.children($0) } ?? model.snapshot?.roots ?? []; return ids.filter { visible.contains($0) } }
    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any { children(item)[index] as NSString }
    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool { !children(item).isEmpty }
    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let id = item as? String, let snapshot = model.snapshot, snapshot.kind(id) != nil else { return nil }
        return NSTextField(labelWithString: snapshot.title(id))
    }
    func outlineViewSelectionDidChange(_ notification: Notification) {
        guard !updatingTreeSelection else { return }
        choose(tree.item(atRow: tree.selectedRow) as? String)
    }
    func controlTextDidChange(_ obj: Notification) {
        if obj.object as? NSSearchField === search {
            reloadTree()
            status.stringValue = visible.isEmpty ? "검색 결과 없음" : "검색 결과 · 선택하려면 행을 누르세요."
        } else if obj.object as? NSTextField === alpha, let id = model.selection, model.canEdit("alpha"), let a = Double(alpha.stringValue) { model.draft = (id,.alpha(a)) }
    }
    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if control === search, commandSelector == #selector(NSResponder.moveDown(_:)) { window?.makeFirstResponder(tree); return true }; return false
    }
    override func cancelOperation(_ sender: Any?) {
        if !candidateIDs.isEmpty { candidateIDs = []; candidates.removeAllItems(); return }
        if model.draft != nil { model.draft = nil; renderDetail(); return }
        if model.loading || model.pending != nil { cancelNow(); return }; close()
    }
    @objc private func draftHidden() { if let id = model.selection { model.draft = (id,.hidden(hidden.state == .on)) } }
    @objc private func editHidden() { draftHidden(); applyDraft() }
    @objc private func editAlpha() {
        guard let id = model.selection, model.canEdit("alpha"), let a = Double(alpha.stringValue), a.isFinite, (0...1).contains(a) else { result.stringValue = "alpha는 0…1의 유한값이어야 합니다."; return }
        model.draft = (id,.alpha(a)); applyDraft()
    }
    private func applyDraft() {
        guard let command = model.beginEdit(), let node = model.selection else { return }
        let g = model.generation; result.stringValue = "적용 중…"; updateGates()
        callbacks.edit(model.context,command) { [weak self] r in self?.finish(r,generation: g,node: node) }
    }
    @objc private func revertNow() {
        guard let token = model.receipt?.undoToken, let s = model.snapshot, let e = s.editing, let node = model.selection, let op = model.beginRevert() else { return }
        let g = model.generation; updateGates(); result.stringValue = "복원 중…"
        callbacks.revert(model.context,["operationID": op.uuidString,"captureID":s.captureID,"inspectionID":e.inspectionID,"ownerID":e.ownerID,"targetEpoch":e.targetEpoch,"undoToken":token]) { [weak self] r in self?.finish(r,generation: g,node: node) }
    }
    private func finish(_ response: Result<[String: Any],Error>, generation: UInt64, node: String) {
        precondition(Thread.isMainThread); guard !closed, model.generation == generation else { return }
        do {
            let receipt = try InspectorReceipt(response.get())
            guard model.complete(receipt,generation: generation,nodeID: node) else { return }
            result.stringValue = "대상: \(node)\n상태: \(receipt.status)\n변경: \(receipt.outcome)\n관측: \(receipt.observed.text)\n\(cleanupSummary(receipt.cleanup))\(receipt.needsRefresh ? "\n새 캡처 필요" : "")"
        } catch { model.failOperation(generation: generation); result.stringValue = "결과 불확실 · 재실행 전 새 캡처 필요: \(error.localizedDescription)" }
        updateGates()
    }
    private func cleanupSummary(_ value: InspectorValue) -> String {
        guard case .object(let cleanup) = value else { return "정리 상태 미확인" }
        let detached: Bool
        if case .string("success") = cleanup["detach"] { detached = true } else { detached = false }
        let recovered: Bool
        if case .object(let recovery) = cleanup["recovery"], case .bool(true) = recovery["verified"] { recovered = true } else { recovered = false }
        let reaped: Bool
        if case .bool(true) = cleanup["childrenReaped"] { reaped = true } else { reaped = false }
        return "debugger 분리: \(detached ? "확인" : "미확인")\n앱 복구: \(recovered ? "확인" : "미확인")\n자식 프로세스 종료: \(reaped ? "확인" : "미확인")"
    }
    private func orbit(_ x: Float, _ y: Float) { renderer?.camera.yaw += x; renderer?.camera.pitch = max(-1.4,min(1.4,(renderer?.camera.pitch ?? 0)+y)); scene.needsDisplay = true }
    private func zoom(_ delta: Float) { renderer?.camera.zoom = max(0.1,min(8,(renderer?.camera.zoom ?? 1)+delta)); scene.needsDisplay = true }
    @objc private func orbitLeft() { orbit(-0.15,0) }; @objc private func orbitRight() { orbit(0.15,0) }
    @objc private func orbitUp() { orbit(0,-0.15) }; @objc private func orbitDown() { orbit(0,0.15) }
    @objc private func zoomIn() { zoom(0.15) }; @objc private func zoomOut() { zoom(-0.15) }
    @objc private func resetCamera() { renderer?.camera = InspectorCamera(); depth.doubleValue = 12; scene.needsDisplay = true }
    @objc private func changeDepth() { renderer?.camera.explosion = depth.floatValue; scene.needsDisplay = true }
    func windowWillClose(_ notification: Notification) { closed = true; revoke(); model.invalidate(); renderer?.releaseCapture(); timer?.invalidate(); timer = nil; scene.onPick = { _ in }; scene.onOrbit = { _,_ in }; scene.onZoom = { _ in }; callbacks.restoreHostFocus()
        callbacks = .init(capture: { _,_,_ in }, cancel: { _,_ in }, edit: { _,_,_ in }, revert: { _,_,_ in }, release: { _,_ in }, restoreHostFocus: {}) }
}
