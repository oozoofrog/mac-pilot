// From repository root, after `eyebuild dir device-tool`:
// D=/Volumes/eyedisk/build/mac-pilot/device-tool; S=mac-computer-use/skills/mac-computer-use/scripts/mac-cu-src
// { sed -n '1,/^@main struct HIDTransportSelfcheck/ p' mac-computer-use/tests/hid-transport-selfcheck.swift | sed '$d'; sed -n '/^final class HIDLink {/,/^var hidLinks:/p' "$S/Simulator.swift" | sed '$d'; sed -n '/^let usKeys:/,/^\/\/ MARK: - Pasteboard/p' "$S/Simulator.swift" | sed '$d'; } > "$D/device-stubs.swift"
// export TMPDIR="$D" CLANG_MODULE_CACHE_PATH="$D/cache"; FLAGS=$(python3 mac-computer-use/skills/mac-computer-use/scripts/native_build.py --emit-stub-modules "$D/modules")  # bash; in zsh use ${=FLAGS}
// swiftc -parse-as-library $FLAGS "$D/device-stubs.swift" "$S/SimulatorGestureHID.swift" "$S/PhysicalDeviceLink.swift" "$S/PhysicalDeviceSession.swift" "$S/Device.swift" "$S/DeviceHubView.swift" mac-computer-use/tests/device-tool-selfcheck.swift -o "$D/device-selfcheck" && "$D/device-selfcheck"
import AppKit
import XPC

struct ShellResult { let status: Int32; let output: String }
func shell(_ path: String, _ args: [String], timeout: Double = 15) -> ShellResult { fatalError("offline") }
func jpegBase64(_ image: CGImage, size: CGSize) throws -> String { fatalError("offline") }
struct SessionStub { let requestCancelled = false }
let currentSession: SessionStub? = nil

@main struct DeviceSelfcheck {
    static func main() throws {
        let a = UUID(), b = UUID(), size = CGSize(width: 200, height: 400)
        let devices = [a, b].map { PhysicalDeviceInfo(identifier: $0, name: "same", model: nil, osVersion: "iOS 27", transport: nil, connectionState: "Connected", pairingState: nil) }
        var locked = false, events: [xpc_object_t] = []
        let backend = DeviceBackend(list: { devices }, locked: { _ in locked }, display: { _ in size }, screenshot: { _, _ in "image" }, open: { id, size in
            HIDLink(externalConnection: xpc_dictionary_create(nil, nil, 0), size: size, deviceID: id.uuidString, send: { _, message in events.append(message); return true })
        })
        let tool = DeviceTool(backend)
        func resultText(_ result: [String: Any]) -> String { ((result["content"] as! [[String: Any]])[0]["text"] as! String) }
        let listing = try resultText(tool.call(["action": "list"]))
        precondition(listing.contains("| iOS 27 |") && !listing.contains("iOS iOS"))
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
        precondition(xctest.wiredHardwareUDID == "wired-A")
        try xctest.checkXCTestAccess(a)
        locked = true
        refuses { try xctest.checkXCTestAccess(a) }
        locked = false
        refuses { try xctest.checkXCTestAccess(b) }
        _ = try xctest.call(["action": "allow", "device": b.uuidString])
        refuses { try xctest.checkXCTestAccess(b) }
        precondition(xctest.wiredHardwareUDID == nil)
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
        // Device Hub view: only the allowed device; it reads no device state and sends no input; focus is passed through.
        var views: [(UUID, String, Bool)] = [], viewCalls = 0
        let viewing = DeviceTool(DeviceBackend(list: { devices }, locked: { _ in fatalError("view reads no lock state") },
                                               display: { _ in fatalError("view reads no display") }, screenshot: { _, _ in fatalError() },
                                               open: { _, _ in fatalError("view sends no input") }, view: { id, name, focus in
            viewCalls += 1; views.append((id, name, focus)); return "opened in Device Hub"
        }))
        refuses { _ = try viewing.call(["action": "view", "device": a.uuidString]) }
        precondition(viewCalls == 0)
        _ = try viewing.call(["action": "allow", "device": a.uuidString])
        refuses { _ = try viewing.call(["action": "view", "device": b.uuidString]) }
        refuses { _ = try viewing.call(["action": "view", "device": "same"]) }
        let viewText = try resultText(viewing.call(["action": "view", "device": a.uuidString])); precondition(viewText == "opened in Device Hub")
        _ = try viewing.call(["action": "window", "device": a.uuidString, "focus": true])  // the earlier name
        precondition(views.count == 2 && views.allSatisfy { $0.0 == a && $0.1 == "same" } && !views[0].2 && views[1].2)
        let closeText = try resultText(viewing.call(["action": "view", "device": a.uuidString, "close": true])); precondition(closeText.contains("does not close Device Hub") && viewCalls == 2)
        let listText = try resultText(viewing.call(["action": "list"])); precondition(listText.contains("Device Hub: device action view"))
        let releaseText = try resultText(viewing.call(["action": "release"])); precondition(releaseText.contains("stays open"))
        refuses { _ = try viewing.call(["action": "view", "device": a.uuidString]) }
        precondition(viewCalls == 2)
        refuses { _ = try tool.call(["action": "view", "device": b.uuidString]) }  // allowed, but this backend has no view
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
        print("device selfcheck passed: allow, pinning, lock, late lock, length cap, cancel, validation, HID recorder, missing CoreDevice, Device Hub view policy, button feature routing, barrier drain and fallback")
    }
}
