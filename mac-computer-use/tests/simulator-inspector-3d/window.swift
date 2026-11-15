import AppKit
import MetalKit

@main struct HostWindowCheck {
    static func main() {
        admitNativeSelfcheck()
        NSApplication.shared.setActivationPolicy(.accessory)
        Task { @MainActor in
            do { try await run(); exit(0) }
            catch { fputs("FAIL host UI: \(error)\n",stderr); exit(1) }
        }
        NSApplication.shared.run()
    }
    @MainActor static func run() async throws {
        let env = ProcessInfo.processInfo.environment, out = URL(fileURLWithPath: ProcessInfo.processInfo.environment["INSPECTOR_HOST_OUTPUT"]!)
        func check(_ value: @autoclosure () -> Bool, _ name: String) throws { guard value() else { throw InspectorFailure.invalid(name) }; print("PASS \(name)") }
        func views(_ v: NSView) -> [NSView] { [v]+v.subviews.flatMap(views) }
        let session = CGSessionCopyCurrentDictionary() as? [String:Any]
        try check(session?["CGSSessionScreenIsLocked"] as? Bool != true && session?["kCGSSessionOnConsoleKey"] as? Bool == true && CGDisplayIsAsleep(CGMainDisplayID()) == 0,"unlocked console")
        let previous = NSWorkspace.shared.frontmostApplication
        let types: [CGEventType] = [.leftMouseDown,.rightMouseDown,.otherMouseDown,.keyDown,.scrollWheel,.mouseMoved]
        func counters() -> [UInt32] { types.map { CGEventSource.counterForEventType(.combinedSessionState,eventType:$0) } }
        let baseline = counters()
        let context = SimulatorInspectorContext(deviceID:"archived-host-only",displayID:"archive",targetID:"expired-archive",targetLabel:"Archived capture · read-only",presentationRevision:1)
        var captures: [(Result<SimulatorInspectorCapture,Error>)->Void] = []
        var edits: [InspectorCommand] = [], undos = 0, cancels = 0, releases = 0, restored = 0
        var editReply: ((Result<[String:Any],Error>)->Void)?
        let host = NSWindow(contentRect:NSRect(x:20,y:20,width:300,height:100),styleMask:[.titled],backing:.buffered,defer:false)
        host.title = "Host focus return sentinel"
        let controller = SimulatorInspectorWindowController(context:context,callbacks:.init(capture:{ _,_,reply in captures.append(reply) },cancel:{ _,_ in cancels += 1 },edit:{ _,command,reply in edits.append(command); editReply=reply },revert:{ _,wire,reply in undos += 1; reply(.success(["operationID":wire["operationID"]!,"status":"mock restored","mutationOutcome":"mock observed","observed":1,"needsRefresh":true])) },release:{ _,_ in releases += 1 },restoreHostFocus:{ restored += 1; host.makeKeyAndOrderFront(nil) }))
        let window = controller.window!
        defer { if !controller.isClosed { controller.close() }; host.close(); if NSApp.isActive && counters()==baseline { previous?.activate(options:[]) } }
        host.makeKeyAndOrderFront(nil); window.center(); controller.showWindow(nil); window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps:true)
        func pause() async throws { try await Task.sleep(nanoseconds:220_000_000) }
        try await pause()
        func guardFocus() throws { try check(counters()==baseline && NSApp.isActive && window.isKeyWindow,"focus/input guard") }
        func button(_ title:String) throws -> NSButton { guard let b=views(window.contentView!).compactMap({$0 as? NSButton}).first(where:{$0.title==title}) else { throw InspectorFailure.invalid("missing \(title)") }; return b }
        func click(_ title:String) throws { try guardFocus(); let b=try button(title); try check(b.isEnabled,"enabled \(title)"); b.scrollToVisible(b.bounds); b.performClick(nil) }
        func shot(_ name:String,_ w:NSWindow) async throws {
            w.contentView?.layoutSubtreeIfNeeded(); try await pause()
            let p=Process(); p.executableURL=URL(fileURLWithPath:"/usr/sbin/screencapture");p.arguments=["-x","-o","-l",String(w.windowNumber),out.appendingPathComponent(name+".png").path];try p.run();p.waitUntilExit();try check(p.terminationStatus==0,"onscreen \(name)")
        }
        let all=views(window.contentView!), tree=all.compactMap{$0 as? NSOutlineView}.first!, search=all.compactMap{$0 as? NSSearchField}.first!, scene=all.compactMap{$0 as? InspectorSceneView}.first!
        let renderer=scene.delegate as! SimulatorInspectorRenderer
        try check(captures.isEmpty && controller.model.selection==nil,"open has no capture or selection")
        let raw=try JSONSerialization.jsonObject(with:Data(contentsOf:URL(fileURLWithPath:env["INSPECTOR_ARCHIVE"]!))) as! [String:Any]
        try click("캡처"); captures.last!(.success(.init(context:context,payload:raw))); controller.markStale(reason:"Archived capture · expired · read-only")
        try check(controller.model.snapshot?.assets.count == 15 && renderer.textureFailures.isEmpty,"15 actual archived PNG textures decoded")
        try check(controller.model.selection==nil,"archive initial selection empty")
        tree.expandItem(nil,expandChildren:true); tree.selectRowIndexes(IndexSet(integer:2),byExtendingSelection:false)
        let selected=controller.model.selection!
        try check(renderer.selection==selected && all.compactMap{$0 as? NSTextField}.contains{$0.stringValue.contains("주소 (읽기 전용): \(selected)")},"tree detail and outline same ID")
        let archiveApply = try button("alpha 적용"); try check(!archiveApply.isEnabled && !controller.model.canEdit("hidden"),"expired archived selection cannot edit")
        try await shot("archive-normal",window)
        let snapshot=controller.model.snapshot!, id=snapshot.order.last!
        tree.deselectAll(nil); search.stringValue=id; controller.controlTextDidChange(Notification(name:NSControl.textDidChangeNotification,object:search))
        try check(snapshot.visibleIDs(query:id).contains(id) && controller.model.selection==nil,"single matching node search no autoselection")
        search.stringValue="";controller.controlTextDidChange(Notification(name:NSControl.textDidChangeNotification,object:search))
        try guardFocus()
        var point: SIMD2<Float>?
        for x in stride(from: Float(10),to:Float(scene.bounds.width),by:15) { for y in stride(from: Float(10),to:Float(scene.bounds.height),by:15) { let p=SIMD2(x,y); if renderer.candidates(at:p).count>1 { point=p; break } }; if point != nil { break } }
        try check(point != nil,"overlapping archived polygons available")
        let local=scene.convert(NSPoint(x:CGFloat(point!.x),y:CGFloat(point!.y)),to:nil)
        let event=NSEvent.mouseEvent(with:.leftMouseUp,location:local,modifierFlags:[],timestamp:0,windowNumber:window.windowNumber,context:nil,eventNumber:1,clickCount:1,pressure:0)!
        scene.mouseUp(with:event)
        let popup=all.compactMap{$0 as? NSPopUpButton}.first!
        try check(popup.numberOfItems>2 && controller.model.selection==nil,"overlap awaits explicit candidate")
        popup.selectItem(at:1);popup.sendAction(popup.action,to:popup.target)
        try check(controller.model.selection==renderer.selection && controller.model.selection != nil,"explicit candidate selects tree/detail/outline")
        try await shot("archive-candidates",window)
        let beforeKey=renderer.camera.yaw
        scene.keyDown(with:NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:[],timestamp:0,windowNumber:window.windowNumber,context:nil,characters:"",charactersIgnoringModifiers:"",isARepeat:false,keyCode:124)!)
        try check(renderer.camera.yaw != beforeKey,"local scene arrow key orbits")
        try click("오른쪽 회전"); let yaw=renderer.camera.yaw;try click("확대");try check(renderer.camera.zoom>1,"zoom control changes camera")
        let slider=all.compactMap{$0 as? NSSlider}.first!;slider.doubleValue=55;slider.sendAction(slider.action,to:slider.target)
        try check(renderer.camera.explosion==55,"depth control changes camera")
        try await shot("archive-orbit-depth",window)
        try click("카메라 초기화");try check(renderer.camera.yaw != yaw && renderer.camera.explosion==12 && renderer.camera.zoom==1,"reset restores camera/depth")
        window.setFrame(NSRect(origin:window.frame.origin,size:window.minSize),display:true);try await shot("archive-minimum",window)
        window.setContentSize(NSSize(width:1200,height:760))
        // Explicit synthetic wire, never derived by extending archived edit authority.
        func mockNode(_ id:String)->[String:Any] { ["id":id,"className":"MOCK UIView","properties":[["propertyName":"MOCK long detail","propertyValue":String(repeating:"MOCK scrollable detail\n",count:60)]],"children":[],"hidden":false,"alpha":1.0,"editToken":"mock-token-\(id)","editableProperties":["hidden","alpha"],"geometry":["coordinateSpace":"UIScreen.fixedCoordinateSpace points","corners":[[0,0],[100,0],[100,100],[0,100]]]] }
        let mock:[String:Any] = ["captureID":"MOCK-capture","capturedAt":"MOCK host callback only","roots":[mockNode("mock-a"),mockNode("mock-b")],"capabilities":["editableProperties":["hidden","alpha"]],"editing":["inspectionID":"MOCK-inspection","ownerID":"MOCK-owner","targetEpoch":"MOCK-epoch","expiresAt":"2099-01-01T00:00:00Z","registryState":"active"]]
        func deliverMock() throws { try click("새로 캡처");captures.last!(.success(.init(context:context,payload:mock))) }
        try click("새로 캡처");let late=captures.last!;try click("취소");late(.success(.init(context:context,payload:mock)));try check(controller.model.snapshot?.captureID != "MOCK-capture","cancel rejects late capture")
        try click("새로 캡처");let replaced=captures.last!;controller.updateContext(.init(deviceID:context.deviceID,displayID:context.displayID,targetID:context.targetID,targetLabel:context.targetLabel,presentationRevision:2));replaced(.success(.init(context:context,payload:mock)));try check(controller.model.snapshot?.captureID != "MOCK-capture","generation rejects replaced capture")
        controller.updateContext(context);try deliverMock();tree.selectRowIndexes(IndexSet(integer:0),byExtendingSelection:false)
        let detailLabel=all.compactMap{$0 as? NSTextField}.first{$0.stringValue.contains("MOCK long detail")}!
        let detailScroll=detailLabel.enclosingScrollView!
        window.contentView!.layoutSubtreeIfNeeded()
        try check(detailScroll.documentView!.frame.height>detailScroll.contentView.bounds.height,"long details have scroll extent")
        detailScroll.contentView.scroll(to:NSPoint(x:0,y:100)); detailScroll.reflectScrolledClipView(detailScroll.contentView)
        try check(detailScroll.contentView.bounds.origin.y>0,"detail scroll changes viewport")
        detailScroll.contentView.scroll(to:.zero)
        let alpha=all.compactMap{$0 as? NSTextField}.first{$0.placeholderString=="alpha 0…1"}!
        alpha.stringValue="0.5";controller.controlTextDidChange(Notification(name:NSControl.textDidChangeNotification,object:alpha));try click("alpha 적용")
        let op=edits.last!.operationID.uuidString
        editReply?(.success(["operationID":op,"status":"MOCK success","mutationOutcome":"MOCK readback","observed":0.5,"undoToken":"MOCK-server-token","needsRefresh":true,"cleanup":"MOCK cleanup"]))
        try check(controller.model.draft != nil && controller.model.canRevert(),"MOCK draft/readback/restore gate")
        let restoreControl=try button("복원");restoreControl.scrollToVisible(restoreControl.bounds);try await shot("mock-readback",window);try click("복원");try check(undos==1,"MOCK explicit receipt restore")
        try deliverMock();tree.selectRowIndexes(IndexSet(integer:0),byExtendingSelection:false);alpha.stringValue="0.3";try click("alpha 적용");let pendingReply=editReply!
        tree.selectRowIndexes(IndexSet(integer:1),byExtendingSelection:false);pendingReply(.failure(InspectorFailure.invalid("MOCK late failure")));try check(undos==1 && controller.model.stale,"MOCK selection cancels without inverse edit")
        try deliverMock();tree.selectRowIndexes(IndexSet(integer:0),byExtendingSelection:false);alpha.stringValue="0.4";try click("alpha 적용");editReply?(.failure(InspectorFailure.invalid("MOCK transport error")));try check(controller.model.draft != nil && !controller.model.canEdit("alpha"),"MOCK error retains draft and requires capture")
        try deliverMock();tree.selectRowIndexes(IndexSet(integer:0),byExtendingSelection:false);alpha.stringValue="0.6";try click("alpha 적용");let closingReply=editReply!
        controller.close();closingReply(.failure(InspectorFailure.invalid("MOCK after close")));try check(controller.isClosed && undos==1 && restored==1 && host.isKeyWindow,"close no inverse and host focus returned")
        try check(renderer.cachedTextureCount==0,"close releases texture cache")
        // Exact extracted production AX browser; synthetic read-only data, no backend.
        let browser=SimulatorElementBrowser(frame:.zero), bw=NSWindow(contentRect:NSRect(x:40,y:40,width:365,height:580),styleMask:[.titled,.closable],backing:.buffered,defer:false)
        defer { bw.close() };let browserContainer=NSView(frame:NSRect(x:0,y:0,width:365,height:580)); bw.contentView=browserContainer;browserContainer.addSubview(browser);browser.frame=browserContainer.bounds;browser.autoresizingMask=[.width,.height];bw.title="Synthetic read-only AX layout";bw.makeKeyAndOrderFront(nil)
        browser.setContext("Synthetic host browser · LCD · 402×874pt")
        browser.finishRead(["pid":0,"app":"MOCK read-only","elements":[["label":"Synthetic row","role":"Button","inside":true]]],error:nil)
        try await shot("ax-browser-narrow",bw)
        browser.translatesAutoresizingMaskIntoConstraints=false; NSLayoutConstraint.activate([browser.widthAnchor.constraint(equalToConstant:341),browser.heightAnchor.constraint(equalToConstant:480),browser.topAnchor.constraint(equalTo:browserContainer.topAnchor),browser.leadingAnchor.constraint(equalTo:browserContainer.leadingAnchor)]); try await shot("ax-browser-constrained",bw)
        let state=views(browser).compactMap{$0 as? NSTextField}.first{$0.stringValue.hasPrefix("화면 요소 1개")}!
        print("AX state frame \(state.frame) fitting \(state.fittingSize)")
        try check(state.frame.height>=state.fittingSize.height,"AX state text not vertically clipped")
        try check(edits.count==4 && undos==1 && cancels>0 && releases>0,"MOCK callback counts, no guest operations")
        print("PASS host-only window checks complete; archived PNG display and MOCK editing only")
    }
}
