// Compile with the HIDLink declaration extracted from Simulator.swift and SimulatorGestureHID.swift.
// Golden fields were captured from the original implementation with the send functions recorded.
import AppKit
import IOKit
import XPC

let hidService = "com.apple.coredevice.feature.remote.hid.digitizer"
let vendorService = "com.apple.coredevice.feature.remote.hid.vendordefined"
struct ToolError: Error { init(_ text: String) {} }
struct ActiveScreen {
    let target: UInt64 = 0
    let foldable = false
    func normalized(_ p: CGPoint) -> CGPoint { p }
}
func showSimulatorTouches(_ id: String, contacts: [GestureContact], screen: ActiveScreen?) {}
func simulatorConnection(_ device: NSObject, _ service: String) throws -> xpc_connection_t { fatalError() }
func screenSize(of device: NSObject) -> CGSize { fatalError() }
func udid(of device: NSObject) -> String { fatalError() }
func displays(of id: String) -> [[String: Any]]? { fatalError() }

@main struct HIDTransportSelfcheck {
    static func main() throws {
        let connection = xpc_dictionary_create(nil, nil, 0)
        var simulated: [xpc_object_t] = [], external: [xpc_object_t] = []
        let size = CGSize(width: 200, height: 400)
        let simulator = HIDLink(connection: connection, size: size, deviceID: "sim", send: { simulated.append($0); return true })
        let physical = HIDLink(externalConnection: connection, size: size, deviceID: "external", send: { _, message in external.append(message); return true })
        func exercise(_ link: HIDLink) {
            link.touch(CGPoint(x: 50, y: 100), phase: 0, screen: nil)
            link.touch(CGPoint(x: 100, y: 200), phase: 1, screen: nil)
            link.touch(CGPoint(x: 150, y: 300), phase: 2, screen: nil)
            link.touch(CGPoint(x: 50, y: 100), phase: 0, screen: nil, second: CGPoint(x: 150, y: 300))
            link.key(4, down: true); link.key(4, down: false)
            link.button(page: 12, usage: 64, down: true)
        }
        exercise(simulator); exercise(physical)
        precondition(simulated.count == 7 && zip(simulated, external).allSatisfy { xpc_equal($0, $1) })
        func string(_ object: xpc_object_t, _ key: String) -> String { String(cString: xpc_dictionary_get_string(object, key)!) }
        for (i, message) in simulated.enumerated() {
            precondition(xpc_dictionary_get_count(message) == 4 && !xpc_dictionary_get_bool(message, "isBarrier"))
            precondition(string(message, "featureIdentifier") == hidService)
            let payload = xpc_dictionary_get_dictionary(message, "payload")!
            if i < 4 {
                precondition(string(message, "messageType") == "IndigoDigitizerEvent")
                precondition(xpc_dictionary_get_count(payload) == (i == 3 ? 5 : 4))
                precondition(xpc_dictionary_get_uint64(payload, "eventType") == [0, 1, 2, 0][i])
                precondition(xpc_dictionary_get_uint64(payload, "edge") == 0 && xpc_dictionary_get_uint64(payload, "target") == 0)
                let point = xpc_dictionary_get_dictionary(payload, "pointOne")!
                let value = [0.25, 0.5, 0.75, 0.25][i]
                precondition(xpc_dictionary_get_count(point) == 2 && xpc_dictionary_get_double(point, "x") == value && xpc_dictionary_get_double(point, "y") == value)
                if i == 3 { let two = xpc_dictionary_get_dictionary(payload, "pointTwo")!; precondition(xpc_dictionary_get_double(two, "x") == 0.75 && xpc_dictionary_get_double(two, "y") == 0.75) }
            } else if i < 6 {
                precondition(string(message, "messageType") == "IndigoKeyboardButtonEvent" && xpc_dictionary_get_count(payload) == 2)
                precondition(xpc_dictionary_get_uint64(payload, "usageCode") == 4 && xpc_dictionary_get_uint64(payload, "state") == UInt64(i - 3))
            } else {
                precondition(string(message, "messageType") == "IndigoButtonEvent" && xpc_dictionary_get_count(payload) == 3)
                precondition(xpc_dictionary_get_uint64(payload, "usagePage") == 12 && xpc_dictionary_get_uint64(payload, "usageCode") == 64 && xpc_dictionary_get_uint64(payload, "state") == 1)
            }
        }
        var gesture: [xpc_object_t] = []
        let link = GestureHIDLink(externalConnection: connection, size: size, deviceID: "external", services: [256: ""], send: { _, message in gesture.append(message) }, reply: { _, message, _ in gesture.append(message); return xpc_dictionary_create(nil, nil, 0) })
        try link.send([GestureContact(id: 1, point: CGPoint(x: 50, y: 100), touching: true), GestureContact(id: 2, point: CGPoint(x: 150, y: 300), touching: true)], screen: nil)
        precondition(gesture.count == 2 && string(gesture[0], "messageType") == "Request" && !xpc_dictionary_get_bool(gesture[0], "isBarrier"))
        let payload = xpc_dictionary_get_dictionary(gesture[0], "payload")!
        let send = xpc_dictionary_get_dictionary(payload, "send")!
        precondition(xpc_dictionary_get_count(gesture[0]) == 3 && xpc_dictionary_get_count(payload) == 1 && xpc_dictionary_get_count(send) == 2 && xpc_dictionary_get_uint64(send, "_1") == 256)
        var length = 0
        let bytes = xpc_dictionary_get_data(send, "_0", &length)!.assumingMemoryBound(to: UInt8.self)
        var report = Array(UnsafeBufferPointer(start: bytes, count: length))
        precondition(report.count == 58)
        report.replaceSubrange(45..<53, with: repeatElement(0, count: 8)) // timestamp is sampled at send time
        var golden = [UInt8](repeating: 0, count: 58)
        golden.replaceSubrange(0..<13, with: [9, 2, 5, 0xc0, 0, 0x40, 0, 0x40, 0xc1, 0xff, 0xbf, 0xff, 0xbf])
        golden[40] = 1; golden[41] = 2
        precondition(report == golden)
        precondition(xpc_dictionary_get_count(gesture[1]) == 2 && string(gesture[1], "messageType") == "Request" && xpc_dictionary_get_bool(gesture[1], "isBarrier"))
        print("HID transport golden and external message checks passed.")
    }
}
