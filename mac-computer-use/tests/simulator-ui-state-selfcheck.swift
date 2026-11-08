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
            assert(visible.compactMap { $0 as? NSPopUpButton }.contains { $0.itemTitles.contains("가이드 캡처") })
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
        print("PASS LCD state controls: unknown/pending/mismatch/retry, nonpreset size, keyboard state, coordinate validation/drafts, Watch layout, persistent results and stale activity rejection")
    }
}
