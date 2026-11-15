import AppKit

@main struct AXLCDCheck {
    static var checks = 0
    static func check(_ condition: @autoclosure () -> Bool, _ message: String) { checks += 1; precondition(condition(), message) }
    static func rejects(_ body: () throws -> Void) { do { try body(); fatalError("accepted invalid input") } catch { checks += 1 } }
    static func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
    static func main() throws {
        admitNativeSelfcheck()
        let base: [String: Any] = ["captureID": "capture", "nodeID": "one", "operation": "press"]
        for operation in ["press", "increment", "decrement"] { var w = base; w["operation"] = operation; check(try! SimulatorAXEnvelope(w).operation == operation, operation) }
        for operation in ["custom", "restore"] { var w = base; w["operation"] = operation; w["handle"] = "distinct"; check(try! SimulatorAXEnvelope(w).handle == "distinct", operation) }
        for operation in ["performSelector:", "expression", "set", ""] { var w = base; w["operation"] = operation; rejects { _ = try SimulatorAXEnvelope(w) } }
        var w = base; w["selector"] = "anything"; rejects { _ = try SimulatorAXEnvelope(w) }
        for bad: Any in [1, "true", NSNull()] { rejects { _ = try SimulatorAXScalar(["type": "boolean", "value": bad]) } }
        for bad: Any in [true, "1", Double.infinity, Double.nan] { rejects { _ = try SimulatorAXScalar(["type": "number", "value": bad]) } }
        rejects { _ = try SimulatorAXScalar(["type": "number", "value": NSNumber(value: Int64(9007199254740993))]) }
        check(try! SimulatorAXScalar(["type": "boolean", "value": true]) == .boolean(true), "exact bool")
        check(try! SimulatorAXScalar(["type": "number", "value": 1]) == .number(1), "exact number")
        rejects { _ = try SimulatorAXScalar.boolean(false).draft("1") }
        rejects { _ = try SimulatorAXScalar.number(0).draft(" 1") }
        rejects { _ = try SimulatorAXScalar.number(0).draft("nan") }
        w = base; w["operation"] = "setValue"; w["expected"] = ["type": "number", "value": 1]; w["value"] = ["type": "boolean", "value": true]; rejects { _ = try SimulatorAXEnvelope(w) }
        w["value"] = ["type": "number", "value": 2]; check(try! SimulatorAXEnvelope(w).value == .number(2), "typed setter")
        let legacy: [String: Any] = ["label": "same", "x": 4, "actions": ["AXPress"]]
        var rich = legacy; rich["captureID"] = "capture"; rich["nodeID"] = "one"; rich["fields"] = [:]; rich["capabilities"] = [:]
        check(NSDictionary(dictionary: legacy).isEqual(to: simulatorAXLegacyRow(rich)), "legacy tap projection")
        _ = NSApplication.shared // No windows, services, devices or guest APIs.
        let browser = SimulatorElementBrowser(frame: CGRect(x: 0, y: 0, width: 360, height: 600))
        let views = descendants(browser)
        let table = views.compactMap { $0 as? NSTableView }.first!
        func button(_ title: String) -> NSButton { views.compactMap { $0 as? NSButton }.first { $0.title == title }! }
        var commands: [[String: Any]] = [], opens = 0
        browser.onAXAction = { commands.append($0) }; browser.onOpen3D = { opens += 1 }
        button("3D 뷰 검사…").performClick(nil); check(opens == 1 && commands.isEmpty, "3D entry never captures")
        func row(_ id: String, qualified: Bool = false) -> [String: Any] {
            ["nodeID": id, "captureID": "capture", "parentID": NSNull(), "childIDs": [String](), "label": "same", "role": "button", "inside": true, "x": 0, "y": 0, "width": 100, "height": 100,
             "fields": ["value": ["status": "redacted", "diagnostic": "unknown protection"], "help": ["status": "failed", "diagnostic": "failed"]],
             "typedValue": ["type": "number", "value": 1], "capabilities": ["operations": qualified ? ["press", "setValue", "custom"] : [], "reasons": ["qualification missing"]],
             "customActions": [["handle": "a", "name": ["status": "available", "value": "same"]], ["handle": "b", "name": ["status": "available", "value": "same"]]]]
        }
        func read(_ rows: [[String: Any]]) {
            browser.beginRead(); browser.finishRead(["pid": 42, "elements": rows, "axSnapshot": ["captureID": "capture", "nodes": rows, "target": ["pid": 42], "scope": ["deviceID": "fixture"]]], error: nil)
        }
        read([row("one"), row("two")])
        button("화면에서 선택").performClick(nil); browser.pick(at: CGPoint(x: 10, y: 10))
        check(table.selectedRow == -1 && table.numberOfRows == 2 && commands.isEmpty, "point candidates never select or dispatch")
        table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        check(!button("접근성 동작 실행 (AXPress)").isEnabled && !button("값 적용").isEnabled, "methods do not grant capability")
        check(views.compactMap { $0 as? NSTextField }.contains { $0.stringValue.contains("redacted") && $0.stringValue.contains("qualification missing") }, "field statuses and reasons")
        read([row("one", qualified: true), row("two", qualified: true)])
        table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        let custom = views.compactMap { $0 as? NSPopUpButton }.first!
        check(!button("선택한 사용자 동작 실행").isEnabled, "custom action awaits explicit choice")
        button("선택한 사용자 동작 실행").performClick(nil)
        check(commands.isEmpty, "node selection does not select a custom action")
        custom.selectItem(at: 2); custom.sendAction(custom.action, to: custom.target)
        button("선택한 사용자 동작 실행").performClick(nil)
        check(commands.last?["handle"] as? String == "b", "duplicate custom names retain separate handles")
        browser.finishAXAction(["isError": true]); commands.removeAll()
        read([row("one", qualified: true), row("two", qualified: true)])
        table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        let draft = views.compactMap { $0 as? NSTextField }.first { $0.identifier?.rawValue == "axValueDraft" }!
        draft.stringValue = "2"; button("값 적용").performClick(nil)
        check(commands.count == 1 && commands[0]["nodeID"] as? String == "one", "typed node action")
        browser.finishAXAction(["isError": true, "content": [["text": "staleCapture"]]])
        check(draft.stringValue == "2" && !button("값 적용").isEnabled, "failed draft retained without retry authority")
        read([row("one", qualified: true), row("two", qualified: true)])
        table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        button("접근성 동작 실행 (AXPress)").performClick(nil)
        table.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
        browser.finishAXAction(["structuredContent": ["axBinding": ["captureID": "capture", "nodeID": "one"], "axResult": ["state": "postconditionObserved", "restoreReceipt": "old"]]])
        check(!button("이 변경 복원").isEnabled, "late receipt cannot retarget selection")
        read([row("one", qualified: true)])
        table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        draft.stringValue = "2"; button("값 적용").performClick(nil)
        browser.finishAXAction(["structuredContent": ["axBinding": ["captureID": "capture", "nodeID": "one"], "axResult": ["state": "postconditionObserved", "delivery": "dispatched", "restoreReceipt": "receipt", "readback": ["type": "number", "value": 2]]]])
        check(button("이 변경 복원").isEnabled, "receipt enables explicit restore")
        button("이 변경 복원").performClick(nil)
        check(commands.last?["operation"] as? String == "restore" && commands.last?["handle"] as? String == "receipt", "exact receipt restore")
        browser.invalidate(); browser.finishAXAction(["structuredContent": ["axResult": ["restoreReceipt": "late"]]])
        check(!button("이 변경 복원").isEnabled, "invalidate rejects late result")
        let activity = SimulatorToolActivity(arguments: ["action": "axSnapshot"], source: "fixture")
        check(activity.inspectionRead, "typed read accounting")
        print("PASS \(checks) AX LCD headless routing/state assertions")
    }
}
