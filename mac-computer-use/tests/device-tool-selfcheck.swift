// From repository root, after `eyebuild dir device-tool`:
// D=/Volumes/eyedisk/build/mac-pilot/device-tool; S=mac-computer-use/skills/mac-computer-use/scripts/mac-cu-src
// { sed -n '1,/^@main struct HIDTransportSelfcheck/ p' mac-computer-use/tests/hid-transport-selfcheck.swift | sed '$d'; sed -n '/^final class HIDLink {/,/^var hidLinks:/p' "$S/Simulator.swift" | sed '$d'; sed -n '/^let usKeys:/,/^\/\/ MARK: - Pasteboard/p' "$S/Simulator.swift" | sed '$d'; } > "$D/device-stubs.swift"
// export TMPDIR="$D" CLANG_MODULE_CACHE_PATH="$D/cache"; FLAGS=$(python3 mac-computer-use/skills/mac-computer-use/scripts/native_build.py --emit-stub-modules "$D/modules")  # bash; in zsh use ${=FLAGS}
// swiftc -parse-as-library $FLAGS "$D/device-stubs.swift" "$S/SimulatorGestureHID.swift" "$S/PhysicalDeviceLink.swift" "$S/PhysicalDeviceSession.swift" "$S/Device.swift" mac-computer-use/tests/device-tool-selfcheck.swift -o "$D/device-selfcheck" && "$D/device-selfcheck"
import AppKit
import XPC

struct ShellResult { let status: Int32; let output: String }
func shell(_ path: String, _ args: [String], timeout: Double = 15) -> ShellResult { fatalError("offline") }
func jpegBase64(_ image: CGImage, size: CGSize) throws -> String { fatalError("offline") }
struct SessionStub { let requestCancelled = false }
let currentSession: SessionStub? = nil

@main struct DeviceSelfcheck {
    static func main() throws {
        if ProcessInfo.processInfo.environment["DEVICE_EXPECT_NO_COREDEVICE"] == "1" {
            let outcome = PhysicalDeviceLink().inProcessCheck()
            guard case .unavailable(let reason) = outcome,
                  !coreDeviceImagesBound(),
                  reason.contains("not bound at launch") || reason.contains("framework missing") else {
                fatalError("expected CoreDevice to be unbound: \(outcome)")
            }
            print("no-coredevice selfcheck passed: \(reason)")
            return
        }
        let a = UUID(), b = UUID(), size = CGSize(width: 200, height: 400)
        let devices = [a, b].map { PhysicalDeviceInfo(identifier: $0, name: "same", model: nil, osVersion: "iOS 27", transport: nil, connectionState: "Connected", pairingState: nil) }
        var locked = false, events: [xpc_object_t] = []
        let backend = DeviceBackend(list: { devices }, locked: { _ in locked }, display: { _ in size }, screenshot: { _, _ in "image" }, open: { id, size in
            HIDLink(externalConnection: xpc_dictionary_create(nil, nil, 0), size: size, deviceID: id.uuidString, send: { _, message in events.append(message); return true })
        })
        let tool = DeviceTool(backend)
        func resultText(_ result: [String: Any]) -> String { ((result["content"] as! [[String: Any]])[0]["text"] as! String) }
        let listing = try resultText(tool.call(["action": "list"]))
        precondition(listing.contains("| iOS 27 |") && !listing.contains("iOS iOS") && !listing.contains("Device Hub"))
        func call(_ action: String, _ id: String, _ extra: [String: Any] = [:]) throws { var args = extra; args["action"] = action; args["device"] = id; _ = try tool.call(args) }
        func refuses(_ body: () throws -> Void) { do { try body(); fatalError("expected refusal") } catch {} }
        var xctestBackend = backend
        xctestBackend.list = {
            [PhysicalDeviceInfo(identifier: a, name: "same", model: nil, osVersion: nil, transport: "wired", connectionState: "Connected", pairingState: "paired", hardwareUDID: "wired-A"),
             PhysicalDeviceInfo(identifier: b, name: "same", model: nil, osVersion: nil, transport: "localNetwork", connectionState: "Connected", pairingState: "paired", hardwareUDID: "wireless-B")]
        }
        xctestBackend.xctestLocked = { _ in locked }
        let xctest = DeviceTool(xctestBackend)
        _ = try xctest.call(["action": "allow", "device": a.uuidString])
        let selected = try xctest.checkXCTestAccess(a)
        precondition(selected.hardwareUDID == "wired-A")
        locked = true
        refuses { try xctest.checkXCTestAccess(a) }
        locked = false
        refuses { try xctest.checkXCTestAccess(b) }
        _ = try xctest.call(["action": "allow", "device": b.uuidString])
        refuses { try xctest.checkXCTestAccess(b) }
        // Physical iPad: supports USB XCTest, landscape/portrait screenshots and sensor_replay; refuses Device Hub view and raw HID.
        let tabletDisplay = PhysicalDisplayState.primary(pixels: CGSize(width: 1640, height: 2360), scale: 2, rotation: "rot270", orientation: "landscapeLeft")
        let tabletInfo = PhysicalDeviceInfo(identifier: a, name: "tablet", model: nil, osVersion: "iPadOS 27",
                                            transport: "wired", connectionState: "Connected", pairingState: "paired", hardwareUDID: "wired-pad", isIPad: true)
        precondition(tabletDisplay.points(for: tabletInfo) == CGSize(width: 1180, height: 820))
        precondition(tabletDisplay.points(for: devices[0]) == nil)
        var tabletBackend = backend
        tabletBackend.list = { [tabletInfo,
                                PhysicalDeviceInfo(identifier: b, name: "wifi-pad", model: nil, osVersion: "iPadOS 27",
                                                   transport: "localNetwork", connectionState: "Connected", pairingState: "paired", hardwareUDID: "wifi-pad", isIPad: true)] }
        tabletBackend.display = { tabletDisplay.points(for: $0)! }
        tabletBackend.xctestLocked = { _ in locked }
        let tablet = DeviceTool(tabletBackend)
        let tabletList = try resultText(tablet.call(["action": "list"]))
        precondition(tabletList.contains("| iPadOS 27 |") && !tabletList.contains("Device Hub"))
        refuses { try tablet.checkFixtureAccess(a) }
        refuses { try tablet.checkXCTestAccess(a) }
        _ = try tablet.call(["action": "allow", "device": a.uuidString])
        try tablet.checkFixtureAccess(a)
        let tabletXCTest = try tablet.checkXCTestAccess(a)
        precondition(tabletXCTest.hardwareUDID == "wired-pad" && tabletXCTest.isIPad)
        let tabletShot = try resultText(tablet.call(["action": "screenshot", "device": a.uuidString]))
        precondition(tabletShot.contains("1180×820") && tabletShot.contains("XCTest"))
        refuses { _ = try tablet.call(["action": "view", "device": a.uuidString]) }
        refuses { _ = try tablet.call(["action": "window", "device": a.uuidString]) }
        refuses { _ = try tablet.call(["action": "tap", "device": a.uuidString, "x": 10, "y": 10]) }
        locked = true
        refuses { try tablet.checkFixtureAccess(a) }
        refuses { try tablet.checkXCTestAccess(a) }
        locked = false
        _ = try tablet.call(["action": "allow", "device": b.uuidString])
        refuses { try tablet.checkXCTestAccess(b) }
        // Watch fixture access falls back to devicectl lock state when in-process CoreDevice is off.
        var watchFallbackBackend = backend
        watchFallbackBackend.list = { [PhysicalDeviceInfo(identifier: a, name: "watch", model: nil, osVersion: "watchOS 27",
            transport: "localNetwork", connectionState: "Connected", pairingState: "paired", isAppleWatch: true)] }
        watchFallbackBackend.xctestLocked = { _ in throw ToolError("XCTest requires the in-process CoreDevice lock check.") }
        let watchFallback = DeviceTool(watchFallbackBackend)
        _ = try watchFallback.call(["action": "allow", "device": a.uuidString])
        try watchFallback.checkFixtureAccess(a)
        locked = true
        do { try watchFallback.checkFixtureAccess(a); fatalError("expected watch lock refusal") }
        catch let error as ToolError { precondition(error.localizedDescription.contains("Unlock") && !error.localizedDescription.contains("XCTest")) }
        locked = false
        refuses { try call("tap", a.uuidString, ["x": 1, "y": 1]) }
        refuses { try call("allow", "same") }
        try call("allow", a.uuidString)
        refuses { try call("tap", b.uuidString, ["x": 1, "y": 1]) }
        locked = true; refuses { try call("tap", a.uuidString, ["x": 1, "y": 1]) }; precondition(events.isEmpty); try call("screenshot", a.uuidString); locked = false
        refuses { try call("tap", a.uuidString) }
        refuses { try call("tap", a.uuidString, ["x": 200, "y": 1]) }
        refuses { try call("other", a.uuidString) }
        refuses { try call("button", a.uuidString, ["button": "bad"]) }
        refuses { try call("type", a.uuidString, ["text": "é"]) }
        precondition(events.isEmpty)
        let tapResult = try resultText(tool.call(["action": "tap", "device": a.uuidString, "x": 50, "y": 100, "seconds": 0.02]))
        precondition(tapResult.contains("delivery is not confirmed"))
        try call("swipe", a.uuidString, ["x": 50, "y": 100, "to_x": 100, "to_y": 200, "seconds": 0.02])
        try call("key", a.uuidString, ["key": "a"])
        try call("button", a.uuidString, ["button": "home", "seconds": 0.02])
        precondition(events.count == 20)
        func kind(_ n: Int) -> String { String(cString: xpc_dictionary_get_string(events[n], "messageType")!) }
        precondition(kind(0) == "IndigoDigitizerEvent" && kind(16) == "IndigoKeyboardButtonEvent" && kind(18) == "IndigoButtonEvent")
        // Taps, keys and Home name the digitizer feature (Home on the button feature was ignored by the device).
        func feature(_ n: Int) -> String { String(cString: xpc_dictionary_get_string(events[n], "featureIdentifier")!) }
        precondition((0..<20).allSatisfy { feature($0) == PhysicalFeature.hid })
        let p = xpc_dictionary_get_dictionary(xpc_dictionary_get_dictionary(events[0], "payload")!, "pointOne")!
        precondition(xpc_dictionary_get_double(p, "x") == 0.25 && xpc_dictionary_get_double(p, "y") == 0.25)
        try call("allow", b.uuidString); refuses { try call("tap", a.uuidString, ["x": 1, "y": 1]) }; try call("tap", b.uuidString, ["x": 1, "y": 1, "seconds": 0.02])
        // The lock state is read again after the connection opens; a device locked meanwhile receives nothing.
        var lateLock = false, lateEvents = 0, cancel = false
        let late = DeviceTool(DeviceBackend(list: { devices }, locked: { _ in lateLock }, display: { _ in size }, screenshot: { _, _ in "" }, open: { id, size in
            lateLock = true
            return HIDLink(externalConnection: xpc_dictionary_create(nil, nil, 0), size: size, deviceID: id.uuidString, send: { _, _ in lateEvents += 1; return true })
        }, cancelled: { cancel }))
        _ = try late.call(["action": "allow", "device": a.uuidString])
        do { _ = try late.call(["action": "type", "device": a.uuidString, "text": "123456"]); fatalError("expected late lock refusal") } catch let error as ToolError { _ = error }
        precondition(lateEvents == 0)
        do { _ = try tool.call(["action": "type", "device": b.uuidString, "text": String(repeating: "a", count: DeviceTool.maxTypeLength + 1)]); fatalError("expected length refusal") } catch {}
        let before = events.count; cancel = true
        let cancellable = DeviceTool(DeviceBackend(list: { devices }, locked: { _ in false }, display: { _ in size }, screenshot: { _, _ in "" }, open: backend.open, cancelled: { cancel }))
        _ = try cancellable.call(["action": "allow", "device": a.uuidString])
        do { _ = try cancellable.call(["action": "type", "device": a.uuidString, "text": "abc"]); fatalError("expected cancel") } catch {}
        precondition(events.count == before)
        let missing = DeviceTool(DeviceBackend(list: { throw PhysicalDeviceError.frameworkMissing("test") }, locked: { _ in false }, display: { _ in size }, screenshot: { _, _ in "" }, open: { _, _ in fatalError() }))
        do { _ = try missing.call(["action": "list"]); fatalError("expected missing") } catch PhysicalDeviceError.frameworkMissing { }
        refuses { _ = try tool.call(["action": "view", "device": b.uuidString]) }
        refuses { _ = try tool.call(["action": "window", "device": b.uuidString]) }
        let releaseText = try resultText(tool.call(["action": "release"]))
        precondition(!releaseText.contains("Device Hub"))
        // Physical routing and barrier: each message goes to its feature's connection, the barrier to the features the
        // action used, and the result says drained only when every one was answered (else the earlier fixed wait).
        var routed: [String: [xpc_object_t]] = [:], barriers: [String] = [], opened: [Set<String>] = []
        var answer = PhysicalHIDLink.Barrier.acknowledged, withButton = true
        func route(_ name: String) -> PhysicalInputRoute {
            PhysicalInputRoute(send: { routed[name, default: []].append($0); return true }, barrier: { wait in precondition(wait == 2); barriers.append(name); return answer })
        }
        let physical = DeviceTool(DeviceBackend(list: { devices }, locked: { _ in false }, display: { _ in size }, screenshot: { _, _ in "" },
                                                open: { _, _ in fatalError("openFeatures serves input") }, openFeatures: { id, size, wanted in
            opened.append(wanted)
            var routes = [PhysicalFeature.hid: route(PhysicalFeature.hid)]
            if withButton && wanted.contains(PhysicalFeature.button) { routes[PhysicalFeature.button] = route(PhysicalFeature.button) }
            return physicalInputLink(routes, connection: xpc_dictionary_create(nil, nil, 0), size: size, deviceID: id.uuidString)
        }))
        _ = try physical.call(["action": "allow", "device": a.uuidString])
        func timed(_ args: [String: Any]) throws -> (String, Double) {
            var call = args; call["device"] = a.uuidString
            let start = CFAbsoluteTimeGetCurrent(); let value = try resultText(physical.call(call)); return (value, CFAbsoluteTimeGetCurrent() - start)
        }
        let (pressed, pressTime) = try timed(["action": "button", "button": "volumeUp", "seconds": 0.02])
        precondition(pressed.contains("the connection drained") && !pressed.contains("not confirmed") && pressTime < 0.4)
        precondition(opened.last == [PhysicalFeature.button] && routed[PhysicalFeature.hid] == nil && barriers == [PhysicalFeature.button])
        let presses = routed[PhysicalFeature.button]!
        precondition(presses.count == 2 && presses.allSatisfy {
            String(cString: xpc_dictionary_get_string($0, "messageType")!) == "IndigoButtonEvent" &&
            String(cString: xpc_dictionary_get_string($0, "featureIdentifier")!) == PhysicalFeature.button })
        let states = presses.map { xpc_dictionary_get_dictionary($0, "payload")! }
        precondition(states.map { xpc_dictionary_get_uint64($0, "state") } == [1, 2] && states.allSatisfy {
            xpc_dictionary_get_uint64($0, "usagePage") == 0x0c && xpc_dictionary_get_uint64($0, "usageCode") == 0xE9 })
        let (tapped, tapTime) = try timed(["action": "tap", "x": 50, "y": 100, "seconds": 0.02])
        precondition(tapped.contains("the connection drained") && tapTime < 0.4 && opened.last == [PhysicalFeature.hid])
        precondition(routed[PhysicalFeature.hid]!.count == 2 && barriers == [PhysicalFeature.button, PhysicalFeature.hid])
        _ = try timed(["action": "key", "key": "a"])
        precondition(routed[PhysicalFeature.hid]!.count == 4 && barriers.last == PhysicalFeature.hid && routed[PhysicalFeature.button]!.count == 2)
        _ = try timed(["action": "button", "button": "home", "seconds": 0.02])
        precondition(opened.last == [PhysicalFeature.hid] && routed[PhysicalFeature.hid]!.count == 6 && routed[PhysicalFeature.button]!.count == 2)
        precondition(String(cString: xpc_dictionary_get_string(routed[PhysicalFeature.hid]!.last!, "messageType")!) == "IndigoButtonEvent")
        for failure in [PhysicalHIDLink.Barrier.timedOut, .failed("device error"), .unsupported] {
            answer = failure
            let (unconfirmed, waited) = try timed(["action": "tap", "x": 50, "y": 100, "seconds": 0.02])
            precondition(unconfirmed.contains("delivery is not confirmed") && !unconfirmed.contains("drained") && waited >= 0.5)
        }
        answer = .acknowledged; withButton = false
        let sentBefore = routed.values.map(\.count).reduce(0, +)
        refuses { _ = try timed(["action": "button", "button": "volumeDown", "seconds": 0.02]) }
        precondition(routed.values.map(\.count).reduce(0, +) == sentBefore)
        let barrierMessage = PhysicalHIDLink.barrierMessage()
        precondition(xpc_dictionary_get_count(barrierMessage) == 1 && xpc_dictionary_get_bool(barrierMessage, "isBarrier"))
        print("device selfcheck passed: allow, pinning, lock, late lock, length cap, cancel, validation, iPad XCTest/screenshot, HID recorder, missing CoreDevice, Device Hub exclusion, button feature routing, barrier drain and fallback")
    }
}
