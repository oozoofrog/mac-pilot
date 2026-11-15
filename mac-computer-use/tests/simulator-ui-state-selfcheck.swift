import AppKit

@main
struct SimulatorUIStateSelfcheck {
    static func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
    static func popover(_ chrome: SimulatorDeviceChrome, _ name: String) -> NSPopover {
        Mirror(reflecting: chrome).children.first { $0.label == name }!.value as! NSPopover
    }
    static func main() {
        admitNativeSelfcheck()
        _ = NSApplication.shared
        let chrome = SimulatorDeviceChrome()
        chrome.updateDevice(name: "Fixture", runtime: "iOS", connected: true, foldable: true, isWatch: false, rotation: "rot0")
        let environment = popover(chrome, "environmentPopover").contentViewController!.view
        let appearance = descendants(environment).compactMap { $0 as? NSSegmentedControl }.first!
        let contrast = descendants(environment).compactMap { $0 as? NSButton }.first { $0.title == "대비 높이기" }!
        assert(appearance.selectedSegment == -1 && contrast.state == .mixed, "Unknown is not a default setting")
        chrome.receiveSetting("appearance", update: .finished(actual: "light", error: nil))
        chrome.receiveSetting("appearance", update: .applying("dark")); chrome.setHostBusy(true)
        assert(appearance.selectedSegment == 0 && !appearance.isEnabled, "Pending request cannot masquerade as confirmed")
        chrome.receiveSetting("appearance", update: .finished(actual: "light", error: "mismatch")); chrome.setHostBusy(false)
        var host: [(String,String)] = []
        chrome.onHost = { host.append(($0,$1)) }
        let retry = descendants(environment).compactMap { $0 as? NSButton }.first { $0.title == "실패한 설정 재시도" }!
        retry.performClick(nil)
        assert(host.last?.0 == "appearance" && host.last?.1 == "dark")
        chrome.receiveSetting("content_size", update: .finished(actual: "extra-extra-large", error: nil))
        assert(descendants(environment).compactMap { $0 as? NSTextField }.contains { $0.stringValue.contains("extra-extra-large") }, "Valid nonpreset values must remain visible")
        chrome.keyboardEnabled = false; chrome.updateControls()
        let input = popover(chrome, "input").contentViewController!.view
        assert(descendants(input).compactMap { $0 as? NSButton }.first { $0.title.contains("Mac 키보드") }!.state == .off)
        let location = popover(chrome, "location").contentViewController!.view
        let fields = descendants(location).compactMap { $0 as? NSTextField }.filter { $0.isEditable }
        fields[0].stringValue = "nan"; fields[1].stringValue = "0"
        let apply = descendants(location).compactMap { $0 as? NSButton }.first { $0.title == "좌표 적용" }!
        let count = host.count; apply.performClick(nil)
        assert(host.count == count && fields[0].stringValue == "nan")
        assert(descendants(location).compactMap { $0 as? NSTextField }.contains { $0.stringValue.contains("범위의 숫자") })
        fields[0].stringValue = "90"; fields[1].stringValue = "-180"; apply.performClick(nil)
        assert(host.last?.0 == "location" && host.last?.1 == "90.0,-180.0")
        chrome.receiveSetting("location", update: .finished(actual: nil, error: nil))
        assert(descendants(location).compactMap { $0 as? NSTextField }.contains { $0.stringValue.contains("반영은 미확인") })
        for watch in [false, true] {
            let tools = SimulatorToolboxView(deviceName: "Fixture", isWatch: watch)
            tools.useInspectionPresentation(); tools.setFloatingPresentation(true)
            tools.frame = CGRect(x: 0, y: 0, width: 360, height: 576); tools.layoutSubtreeIfNeeded()
            let frames = tools.visibleGlassFrames
            for (i, frame) in frames.enumerated() { assert(!frames.dropFirst(i+1).contains { $0.intersects(frame) }, "Inspection controls must not overlap, including Watch") }
            let visible = descendants(tools).filter { !$0.isHiddenOrHasHiddenAncestor }
            assert(!visible.compactMap { $0 as? NSButton }.contains { $0.title.hasPrefix("Crown") })
            assert(!visible.compactMap { $0 as? NSPopUpButton }.contains { $0.itemTitles.contains("가이드 캡처") }, "Specialist forms are initially hidden")
            let old = SimulatorToolActivity(arguments: ["action":"describe"], source: "직접 조작")
            let new = SimulatorToolActivity(arguments: ["action":"wait"], source: "직접 조작")
            tools.start(old); tools.start(new)
            assert(!tools.finish(old, response: ["content":[["type":"text", "text":"stale"]]]))
            assert(tools.finish(new, response: ["content":[["type":"text", "text":"current response"]]]))
            tools.selectResults(true)
            assert(descendants(tools).compactMap { $0 as? NSTextView }.contains { $0.string == "current response" })
            tools.selectResults(false)
            assert(descendants(tools.report.contentViewController!.view).compactMap { $0 as? NSTextView }.contains { $0.string == "current response" })
            tools.start(old)
            assert(descendants(tools.report.contentViewController!.view).compactMap { $0 as? NSTextView }.contains { $0.string == "응답 대기 중…" })
        }
        let browser = SimulatorElementBrowser(frame: CGRect(x: 0, y: 0, width: 360, height: 520))
        let table = descendants(browser).compactMap { $0 as? NSTableView }.first!
        let tap = descendants(browser).compactMap { $0 as? NSButton }.first { $0.title == "선택한 위치 탭" }!
        var taps = 0; browser.onTap = { _, _ in taps += 1 }
        browser.beginRead()
        browser.finishRead(["pid": Int32(42), "app": "Fixture", "elements": [
            ["label": "설정", "role": "button", "inside": true, "x": 10, "y": 20, "width": 30, "height": 40],
            ["label": "설정", "role": "button", "inside": false, "x": -10, "y": 20, "width": 30, "height": 40]]], error: nil)
        assert(table.numberOfRows == 2 && !tap.isEnabled)
        table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        assert(taps == 0 && tap.isEnabled, "Selection is read-only")
        tap.performClick(nil); assert(taps == 1 && !tap.isEnabled)
        table.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
        assert(!tap.isEnabled, "Partial elements cannot send an out-of-screen touch")
        browser.finishRead(["pid": 42, "app": "Fixture", "elements": [
            ["label": "부모", "role": "group", "inside": true, "depth": 0, "x": 0, "y": 0, "width": 100, "height": 100],
            ["label": "자식", "role": "button", "inside": true, "depth": 1, "x": 10, "y": 20, "width": 30, "height": 40]]], error: nil)
        var pickedFrame: CGRect?; var picking = false; var modeChanges = 0
        browser.onSelection = { pickedFrame = $0 }; browser.onPickMode = { picking = $0; modeChanges += 1 }
        let pick = descendants(browser).compactMap { $0 as? NSButton }.first { $0.title == "화면에서 선택" }!
        pick.performClick(nil); assert(picking)
        browser.pick(at: CGPoint(x: 15, y: 25))
        assert(table.numberOfRows == 2 && pickedFrame == nil && table.selectedRow == -1 && taps == 1, "AX frame candidates never send HID")
        browser.endPick(); assert(!picking && modeChanges == 2)
        browser.invalidate(); assert(modeChanges == 2, "Ordinary input invalidation must not release a newly started guest contact")
        browser.cancelRead(); assert(!tap.isEnabled)
        browser.finishRead(nil, error: "Disconnected"); assert(table.numberOfRows == 0)
        let changingTarget = SimulatorToolboxView(deviceName: "Fixture", isWatch: false)
        changingTarget.useInspectionPresentation()
        changingTarget.updateScreen(CGSize(width: 100, height: 100), name: "Same name", foldable: false, screenID: "A")
        var requests: [[String: Any]] = []
        changingTarget.onRun = { requests.append($0) }
        changingTarget.setFloatingPresentation(true)
        assert(requests.isEmpty, "Opening inspection never captures")
        changingTarget.refreshInspection()
        assert(requests.count == 1 && requests[0]["action"] as? String == "axSnapshot", "Explicit refresh uses typed AX command")
        let reading = SimulatorToolActivity(arguments: requests[0], source: "직접 조작")
        changingTarget.start(reading)
        assert(descendants(changingTarget).compactMap { $0 as? NSTextField }.contains { $0.stringValue == "화면 요소 읽는 중…" })
        changingTarget.updateScreen(CGSize(width: 100, height: 100), name: "Same name", foldable: false, screenID: "B")
        changingTarget.finish(reading, response: ["structuredContent": ["inspection": ["pid": 42, "elements": [["label": "Old target", "inside": true]]]]])
        let changingTable = descendants(changingTarget).compactMap { $0 as? NSTableView }.first!
        assert(changingTable.numberOfRows == 0, "A late snapshot cannot overwrite a new screen with equal name and size")
        changingTarget.refreshInspection()
        let missingScope = SimulatorToolActivity(arguments: requests.last!, source: "직접 조작")
        changingTarget.start(missingScope)
        changingTarget.finish(missingScope, response: ["structuredContent": ["inspection": ["pid": 42, "elements": [["label": "Unscoped", "inside": true]]]]])
        assert(changingTable.numberOfRows == 0, "A missing target scope cannot enable selection")
        changingTarget.refreshInspection()
        let scopedRead = SimulatorToolActivity(arguments: ["action": "describe", "inspection": true], source: "직접 조작")
        changingTarget.start(scopedRead)
        let scope: [String: Any] = ["device": "fixture", "screen": "B"]
        changingTarget.finish(scopedRead, response: ["structuredContent": ["inspection": ["pid": 42, "scope": scope,
            "elements": [["label": "Scoped", "inside": true, "x": 10, "y": 20, "width": 30, "height": 40]]]]])
        assert(changingTable.numberOfRows == 1)
        changingTable.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        descendants(changingTarget).compactMap { $0 as? NSButton }.first { $0.title == "선택한 위치 탭" }!.performClick(nil)
        assert(NSDictionary(dictionary: requests.last!["inspectionScope"] as! [String: Any]).isEqual(to: scope))
        let failedTap = SimulatorToolActivity(arguments: requests.last!, source: "직접 조작")
        changingTarget.start(failedTap); changingTarget.finish(failedTap, response: ["isError": true])
        changingTarget.updateScreen(CGSize(width: 100, height: 100), name: "Same name", foldable: false, screenID: "C")
        descendants(changingTarget.report.contentViewController!.view).compactMap { $0 as? NSButton }.first { $0.title == "같은 입력으로 재시도" }!.performClick(nil)
        assert(NSDictionary(dictionary: requests.last!["inspectionScope"] as! [String: Any]).isEqual(to: scope), "Retry must retain the original target for backend stale rejection")
        let hierarchy = SimulatorViewHierarchyBrowser(frame: CGRect(x: 0, y: 0, width: 360, height: 532))
        let outline = descendants(hierarchy).compactMap { $0 as? NSOutlineView }.first!
        hierarchy.finishCapture(["pid": 42, "capturedAt": "fixture time", "roots": [
            ["id": "window", "className": "UIWindow", "children": [
                ["id": "child", "className": "UIView", "parentID": "window", "siblingIndex": 0, "frame": [1,2,30,40]]]]]], error: nil)
        outline.expandItem(nil, expandChildren: true)
        assert(outline.numberOfRows == 2, "UIKit parent/child remains separate from AX")
        outline.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
        assert(descendants(hierarchy).compactMap { $0 as? NSTextView }.contains { $0.string.contains("LCD 강조 불가") && $0.string.contains("UIView") })
        hierarchy.invalidate()
        outline.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        assert(descendants(hierarchy).compactMap { $0 as? NSTextView }.contains { $0.string.contains("이전 캡처") })
        print("PASS LCD state controls: unknown/pending/mismatch/retry, nonpreset size, keyboard state, coordinate validation/drafts, Watch layout, persistent results and stale activity rejection")
    }
}
