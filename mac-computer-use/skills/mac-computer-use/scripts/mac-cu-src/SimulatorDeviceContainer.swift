import AppKit

struct SimulatorDeviceAppearance {
    enum Family { case phone, tablet, watch, other }
    let family: Family
    let resources: URL?

    init(typeName: String, resources: URL? = nil) {
        family = typeName.contains("Watch") ? .watch : typeName.contains("iPad") ? .tablet : typeName.contains("iPhone") ? .phone : .other
        self.resources = resources
    }

    var bezel: CGFloat { family == .watch ? 7 : family == .tablet ? 6 : 5 }
    var fallbackCorner: CGFloat { family == .watch ? 45 : family == .phone ? 48 : 20 }

    func mask(for points: CGSize, rotation: String) -> SimulatorDeviceMask? {
        guard let resources else { return nil }
        let portrait = rotation == "rot90" || rotation == "rot270" ? CGSize(width: points.height, height: points.width) : points
        let files = (try? FileManager.default.contentsOfDirectory(at: resources, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "pdf" && !$0.lastPathComponent.hasPrefix("sensor_") }
            .compactMap(SimulatorDeviceMask.init).min { abs($0.aspect - portrait.width / portrait.height) < abs($1.aspect - portrait.width / portrait.height) }
    }
}

func simulatorDeviceAppearance(_ device: NSObject) -> SimulatorDeviceAppearance {
    let type = device.value(forKey: "deviceType") as? NSObject
    let name = type?.responds(to: NSSelectorFromString("name")) == true ? type?.value(forKey: "name") as? String ?? "" : ""
    let resources = URL(fileURLWithPath: "/Library/Developer/CoreSimulator/Profiles/DeviceTypes")
        .appendingPathComponent(name + ".simdevicetype/Contents/Resources")
    return SimulatorDeviceAppearance(typeName: name, resources: resources)
}

/// The simulator's own PDF mask supplies model-specific rounded corners and display cutouts.
final class SimulatorDeviceMask {
    let bitmap: NSBitmapImageRep
    let image: CGImage
    var aspect: CGFloat { CGFloat(bitmap.pixelsWide) / CGFloat(bitmap.pixelsHigh) }
    var cornerFraction: CGFloat {
        CGFloat((0..<bitmap.pixelsWide / 2).first { (bitmap.colorAt(x: $0, y: 0)?.alphaComponent ?? 0) > 0.5 } ?? 0) / CGFloat(bitmap.pixelsWide)
    }

    init?(_ url: URL) {
        guard let source = NSImage(contentsOf: url), let data = source.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: data), let image = bitmap.cgImage else { return nil }
        self.bitmap = bitmap
        self.image = image
    }

    func contains(_ point: CGPoint, size: CGSize, rotation: String) -> Bool {
        var u = point.x / size.width, v = point.y / size.height
        switch rotation {
        case "rot90": (u, v) = (v, 1 - u)
        case "rot180": (u, v) = (1 - u, 1 - v)
        case "rot270": (u, v) = (1 - v, u)
        default: break
        }
        let x = min(bitmap.pixelsWide - 1, max(0, Int(u * CGFloat(bitmap.pixelsWide))))
        let y = min(bitmap.pixelsHigh - 1, max(0, Int(v * CGFloat(bitmap.pixelsHigh))))
        return (bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.1
    }
}

struct SimulatorDeviceLayout {
    let body: CGRect
    let lcd: CGRect
    let tools: CGRect
    let handle: CGRect
    let controls: CGRect
    let rail: CGRect
    let resize: CGRect
}

let simulatorToolboxWidth: CGFloat = 360
let simulatorToolboxHeight: CGFloat = 576
let simulatorToolboxMinimumSize = CGSize(width: 280, height: 344)
let simulatorToolboxGap: CGFloat = 28
let simulatorToolboxRim: CGFloat = 12

/// Sizes are Mac display points, never the guest framebuffer resolution.
func simulatorToolboxSize(forLCD lcd: CGSize, bezel: CGFloat) -> CGSize {
    let height = min(simulatorToolboxHeight, max(simulatorToolboxMinimumSize.height, lcd.height + 2 * bezel))
    return CGSize(width: max(simulatorToolboxMinimumSize.width, simulatorToolboxWidth * height / simulatorToolboxHeight), height: height)
}

let simulatorChromeWidth: CGFloat = 304
let simulatorHandleSpace: CGFloat = 56
let simulatorControlSpace: CGFloat = 80
let simulatorRailSpace: CGFloat = 88

private func simulatorAttachmentShoulder(_ body: CGSize, bezel: CGFloat) -> CGFloat {
    min(28, min(body.width, body.height) * 0.08 + bezel)
}

private func simulatorAttachedScroller(_ body: CGSize, bezel: CGFloat) -> CGFloat {
    let width = min(272, max(1, body.width))
    return width - 8 < 264 && NSScroller.preferredScrollerStyle == .legacy
        ? NSScroller.scrollerWidth(for: .regular, scrollerStyle: .legacy) : 0
}

func simulatorLegacyLCDContentSize(forLCD lcd: CGSize, bezel: CGFloat, toolsVisible: Bool, focused: Bool = false, externalToolbar: Bool = false) -> CGSize {
    let tools = simulatorToolboxSize(forLCD: lcd, bezel: bezel)
    let mainWidth = max(simulatorChromeWidth, lcd.width + 2 * bezel + (focused || externalToolbar ? 0 : simulatorRailSpace))
    return CGSize(width: mainWidth + 32 + (toolsVisible ? simulatorToolboxGap + tools.width : 0),
                  height: max(lcd.height + 2 * bezel, toolsVisible ? tools.height : 0) + 32 + simulatorHandleSpace + (focused ? 0 : externalToolbar ? 48 : simulatorControlSpace))
}

func simulatorLegacyDeviceLayout(in size: CGSize, screen: CGSize, bezel: CGFloat, toolsVisible: Bool, focused: Bool = false, lcdSizeLimit: CGSize? = nil, externalToolbar: Bool = false) -> SimulatorDeviceLayout {
    let aspect = max(1, screen.width) / max(1, screen.height)
    let railSpace: CGFloat = focused || externalToolbar ? 0 : simulatorRailSpace
    let bottom: CGFloat = focused ? 0 : externalToolbar ? 48 : simulatorControlSpace
    let availableWidth = max(1, size.width - 32 - 2 * bezel - railSpace - (toolsVisible ? simulatorToolboxGap : 0))
    let toolLimit = max(0, availableWidth - 1)
    var widthLimitedHeight = availableWidth / aspect
    if toolsVisible {
        // Invert the same clamped proportional width used by simulatorToolboxSize, without iterative fitting drift.
        let minimumWidth = min(toolLimit, simulatorToolboxMinimumSize.width)
        let maximumWidth = min(toolLimit, simulatorToolboxWidth)
        let ratio = simulatorToolboxWidth / simulatorToolboxHeight
        widthLimitedHeight = (availableWidth - minimumWidth) / aspect
        if (widthLimitedHeight + 2 * bezel) * ratio > minimumWidth {
            widthLimitedHeight = (availableWidth - 2 * bezel * ratio) / (aspect + ratio)
            if (widthLimitedHeight + 2 * bezel) * ratio > maximumWidth {
                widthLimitedHeight = (availableWidth - maximumWidth) / aspect
            }
        }
    }
    let availableHeight = max(1, size.height - 32 - simulatorHandleSpace - bottom)
    let height = max(1, min(widthLimitedHeight, availableHeight - 2 * bezel, lcdSizeLimit?.height ?? .greatestFiniteMagnitude))
    let lcdSize = CGSize(width: height * aspect, height: height)
    let preferred = simulatorToolboxSize(forLCD: lcdSize, bezel: bezel)
    let toolSize = CGSize(width: min(toolLimit, preferred.width), height: max(1, min(preferred.height, availableHeight)))
    let mainWidth = max(min(simulatorChromeWidth, size.width - 32 - (toolsVisible ? simulatorToolboxGap + toolSize.width : 0)),
                        lcdSize.width + 2 * bezel + railSpace)
    let left = (size.width - mainWidth - (toolsVisible ? simulatorToolboxGap + toolSize.width : 0)) / 2
    let top = size.height - 16 - simulatorHandleSpace
    let body = CGRect(x: left + (mainWidth - railSpace - lcdSize.width - 2 * bezel) / 2,
                      y: top - lcdSize.height - 2 * bezel, width: lcdSize.width + 2 * bezel, height: lcdSize.height + 2 * bezel)
    let chromeWidth = min(mainWidth, 380)
    let handle = CGRect(x: left + (mainWidth - chromeWidth) / 2, y: top + 16, width: chromeWidth, height: 40)
    let controls = CGRect(x: left + (mainWidth - min(mainWidth, simulatorChromeWidth)) / 2,
                          y: body.minY - 72, width: min(mainWidth, simulatorChromeWidth), height: 60)
    return SimulatorDeviceLayout(body: body, lcd: body.insetBy(dx: bezel, dy: bezel),
        tools: CGRect(x: left + mainWidth, y: top - toolSize.height, width: simulatorToolboxGap + toolSize.width, height: toolSize.height),
        handle: handle, controls: controls,
        rail: CGRect(x: body.maxX + 16, y: top - min(200, body.height), width: 48, height: min(200, body.height)),
        resize: CGRect(x: externalToolbar ? body.maxX - 36 : body.maxX + 16, y: max(2, body.minY - 42), width: 36, height: 36))
}

func simulatorLCDContentSize(forLCD lcd: CGSize, bezel: CGFloat, toolsVisible: Bool, focused: Bool = false, externalToolbar: Bool = false) -> CGSize {
    if toolsVisible || externalToolbar { return simulatorLegacyLCDContentSize(forLCD: lcd, bezel: bezel, toolsVisible: toolsVisible, focused: focused, externalToolbar: externalToolbar) }
    let right: CGFloat = focused || externalToolbar ? 0 : simulatorRailSpace
    let bodySize = CGSize(width: lcd.width + 2 * bezel, height: lcd.height + 2 * bezel)
    let bottom: CGFloat = focused ? 0 : 60 + simulatorAttachedScroller(bodySize, bezel: bezel)
    let width = max(simulatorChromeWidth, lcd.width + 2 * bezel) + right
    return CGSize(width: width + 32, height: max(lcd.height + 2*bezel, focused ? 0 : 332) + 32 + simulatorHandleSpace + bottom)
}

func simulatorDeviceLayout(in size: CGSize, screen: CGSize, bezel: CGFloat, toolsVisible: Bool, focused: Bool = false, lcdSizeLimit: CGSize? = nil, externalToolbar: Bool = false, actionCount: Int = 7) -> SimulatorDeviceLayout {
    if toolsVisible || externalToolbar { return simulatorLegacyDeviceLayout(in: size, screen: screen, bezel: bezel, toolsVisible: toolsVisible, focused: focused, lcdSizeLimit: lcdSizeLimit, externalToolbar: externalToolbar) }
    let aspect = max(1,screen.width) / max(1,screen.height)
    let right: CGFloat = focused || externalToolbar ? 0 : simulatorRailSpace
    let availableWidth = max(1,size.width-32-right-2*bezel)
    let tentativeHeight = max(1,min(availableWidth/aspect, size.height-32-simulatorHandleSpace-(focused ? 0 : 60)-2*bezel, lcdSizeLimit?.height ?? .greatestFiniteMagnitude))
    let tentativeBody = CGSize(width: tentativeHeight*aspect+2*bezel, height: tentativeHeight+2*bezel)
    // Use the same content-fit scroller allowance as the inverse sizing path;
    // otherwise opening/resizing can progressively shrink the LCD in legacy mode.
    let scroller = focused ? 0 : simulatorAttachedScroller(tentativeBody, bezel: bezel)
    let barHeight: CGFloat = 52+scroller
    let bottom: CGFloat = focused ? 0 : barHeight+8
    let availableHeight = max(1,size.height-32-simulatorHandleSpace-bottom)
    let height = max(1,min(availableWidth/aspect,availableHeight-2*bezel,lcdSizeLimit?.height ?? .greatestFiniteMagnitude))
    let lcdSize = CGSize(width: height*aspect,height: height)
    let mainWidth = max(lcdSize.width+2*bezel,min(simulatorChromeWidth,max(1,size.width-32-right)))
    let left = (size.width-mainWidth-right)/2
    let top = size.height-16-simulatorHandleSpace
    let body = CGRect(x: left+(mainWidth-lcdSize.width-2*bezel)/2,y: top-lcdSize.height-2*bezel,width: lcdSize.width+2*bezel,height: lcdSize.height+2*bezel)
    // Place the host controls against the fitted body, not against the window's
    // reserved envelope. The body may be much smaller when width limits it.
    let bottomY = body.minY - barHeight
    let shoulder = simulatorAttachmentShoulder(body.size, bezel: bezel)
    let handleWidth = min(304, max(1, body.width - 2 * shoulder))
    let handleX = body.midX - handleWidth / 2
    let barWidth = min(272, max(1, body.width))
    let railX = body.midX - barWidth / 2
    let controlRows = max(1, floor((body.height - shoulder - 48) / 44))
    let controlsHeight = min(CGFloat(actionCount), controlRows) * 44 + 8
    let controlScroller = CGFloat(actionCount) > controlRows && NSScroller.preferredScrollerStyle == .legacy
        ? NSScroller.scrollerWidth(for: .regular, scrollerStyle: .legacy) : 0
    return SimulatorDeviceLayout(body: body,lcd: body.insetBy(dx: bezel,dy: bezel),
        tools: CGRect(x: body.maxX+simulatorToolboxGap,y: body.minY,width: simulatorToolboxWidth,height: min(availableHeight,simulatorToolboxHeight)),
        handle: CGRect(x: handleX,y: body.maxY,width: handleWidth,height: 44),
        controls: CGRect(x: body.maxX,y: body.maxY-shoulder-controlsHeight,width: 56+controlScroller,height: controlsHeight),
        rail: CGRect(x: railX,y: bottomY,width: barWidth,height: barHeight),
        resize: CGRect(x: body.maxX+20,y: body.minY+2,width: 36,height: 36))
}

/// Keep the entire device, handle and controls on the destination display after moves and resizes.
func simulatorConstrainedFrame(_ frame: CGRect, to visible: CGRect) -> CGRect {
    let size = CGSize(width: min(frame.width, visible.width), height: min(frame.height, visible.height))
    return CGRect(x: min(max(frame.minX, visible.minX), visible.maxX - size.width),
                  y: min(max(frame.maxY - size.height, visible.minY), visible.maxY - size.height), width: size.width, height: size.height)
}
