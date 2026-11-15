import AppKit
import IOSurface

/// Finite, noninteractive native regression. No scenario UI, feedback store, device,
/// HID, clipboard, daemon or user defaults. The test window stays behind the desktop.
@main struct SimulatorRotationPresentationSelfcheck {
    @MainActor static func main() {
        admitNativeSelfcheck()
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        Task { @MainActor in await check(); app.terminate(nil) }
        app.run()
    }
    @MainActor static func check() async {
        func pause(_ seconds: Double) async { try? await Task.sleep(nanoseconds:UInt64(seconds*1_000_000_000)) }
        func require(_ value: Bool,_ message: String) { precondition(value,message) }
        func descendants(_ v: NSView) -> [NSView] { [v] + v.subviews.flatMap(descendants) }
        let properties: [CFString:Any] = [kIOSurfaceWidth:128,kIOSurfaceHeight:256,kIOSurfaceBytesPerElement:4,kIOSurfaceBytesPerRow:512,kIOSurfaceAllocSize:131072,kIOSurfacePixelFormat:UInt32(0x42475241)]
        let surface = IOSurfaceCreate(properties as CFDictionary)!
        IOSurfaceLock(surface,[],nil)
        let pixels = IOSurfaceGetBaseAddress(surface).assumingMemoryBound(to:UInt8.self)
        for y in 0..<256 { for x in 0..<128 {
            let i = y*512+x*4
            pixels[i] = x<64 ? 0:255; pixels[i+1] = 0; pixels[i+2] = x<64 ? 255:0; pixels[i+3] = 255
        } }
        IOSurfaceUnlock(surface,[],nil)
        let lcd = NSView(); lcd.wantsLayer = true
        let screenLayer = CALayer(); screenLayer.contents = surface; lcd.layer?.addSublayer(screenLayer)
        let tools = SimulatorToolboxView(deviceName:"Rotation regression",isWatch:false)
        let content = SimulatorLCDContentView(lcd:lcd,tools:tools,appearance:SimulatorDeviceAppearance(typeName:"iPhone"))
        let visible = NSScreen.main!.visibleFrame
        let window = SimulatorDeviceWindow(contentRect:CGRect(x:visible.minX,y:visible.minY,width:500,height:720),styleMask:[.borderless],backing:.buffered,defer:false)
        window.isReleasedWhenClosed = false
        window.level = NSWindow.Level(rawValue:Int(CGWindowLevelForKey(.desktopWindow))-1)
        window.isOpaque = false; window.backgroundColor = .clear; window.contentView = content
        content.screen = CGSize(width:320,height:600)
        content.chrome.updateDevice(name:"Fixture",runtime:"Fixture",connected:true,foldable:true,isWatch:false,rotation:"rot0")
        content.layoutSubtreeIfNeeded(); screenLayer.frame = lcd.bounds
        window.orderBack(nil); window.displayIfNeeded()
        defer { content.cancelRotationPresentation(); window.close() }
        let frame = window.frame
        var quarter = 0
        func turn(_ delta: Int) {
            content.prepareRotationPresentation()
            quarter = (quarter+delta+8)%4
            content.screen = quarter%2 == 0 ? CGSize(width:320,height:600):CGSize(width:600,height:320)
            content.body.orientationQuarterTurns = quarter
            content.needsLayout = true; content.layoutSubtreeIfNeeded()
            content.animateRotationPresentation(signedQuarterTurns:delta)
        }
        func groups() -> [NSView] { [content.chrome.handle,content.chrome.controls,content.chrome.rail,content.chrome.resize] }
        func hidden() {
            require(content.rotationChromeSuppressed,"chrome suppression")
            require(groups().allSatisfy { $0.alphaValue == 0 && $0.isAccessibilityHidden() },"hidden surfaces/AX")
            require(groups().flatMap(descendants).compactMap { $0 as? NSButton }.allSatisfy { !$0.isEnabled },"no invisible enabled buttons")
        }
        func restored() {
            require(!content.rotationPresentationActive && !content.rotationChromeSuppressed,"bounded restoration")
            require(window.contentView === content && !content.isHidden,"same real hierarchy restored")
            require(groups().allSatisfy { $0.alphaValue == 1 && !$0.isAccessibilityHidden() },"visible surfaces/AX restored")
            require(window.frame == frame,"no frame drift")
        }
        await pause(0.2)
        CATransaction.flush()
        // Prove the renderer can cache actual surface pixels without a design preview app.
        let bitmap = content.body.bitmapImageRepForCachingDisplay(in:content.body.bounds)!
        content.body.cacheDisplay(in:content.body.bounds,to:bitmap)
        let color = bitmap.colorAt(x:bitmap.pixelsWide/4,y:bitmap.pixelsHigh/2)!.usingColorSpace(.deviceRGB)!
        require(max(color.redComponent,color.blueComponent)>0.8 && max(color.redComponent,color.blueComponent)-color.greenComponent>0.4,"IOSurface survives body snapshot")
        for delta in [1,1,1,1,-1,-1,-1,-1] {
            turn(delta); hidden(); await pause(0.12)
            require(delta>0 ? content.rotationPresentationAngle<0 : content.rotationPresentationAngle>0,"signed turn across wrap")
            require(content.hitTest(.zero)==nil,"moving LCD input guarded")
            await pause(0.56); restored()
        }
        turn(1); await pause(0.1)
        let prior = content.rotationPresentationAngle
        turn(-1); hidden()
        require(abs(content.rotationPresentationAngle-prior)<0.2,"retarget begins at sampled angle")
        // The spring first carries its earlier velocity; how long depends on frame timing. Sample until it turns back.
        var reversed = false
        for _ in 0..<20 where !reversed { await pause(0.02); reversed = content.rotationPresentationAngle>prior }
        require(reversed,"reverse direction")
        for _ in 0..<7 { turn(1); await pause(0.02); hidden() }
        await pause(0.65); restored()
        turn(1); await pause(0.48); turn(-1); hidden()
        await pause(0.18); hidden() // stale restoration callback must remain inert
        await pause(0.5); restored()
        for _ in 0..<3 { turn(1); await pause(0.08); content.cancelRotationPresentation(); restored() }
        content.reduceMotionOverride = true
        turn(-1); hidden(); await pause(0.35); restored()
        print("PASS production rotation presentation: surface pixels, signed wrap, input/AX/button guards, continuous reverse/burst, generation-safe chrome restoration, cancellation, reduced motion and stable window geometry. No foreground input or visual acceptance claimed.")
        fflush(stdout)
    }
}
