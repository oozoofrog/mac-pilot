import Foundation
struct ToolError: Error { let message: String; init(_ message: String) { self.message = message } }
struct ActiveScreen { var id = "main"; var rotation = "rot0"; var guestRotation = "rot0"; var points = CGSize(width: 100,height: 200) }
func udid(of device: NSObject) -> String { "" }
func isBooted(_ device: NSObject) -> Bool { false }
func screenSize(of device: NSObject) -> CGSize { CGSize(width: 100,height: 200) }
struct SimulatorAXScope {}
final class SimulatorAXHostLifecycle {
    static let shared = SimulatorAXHostLifecycle()
    func invalidate(deviceID: String) {}
    func update(deviceID: String, bootIdentity: String?, presentation: String, generation: UInt64, runtime: String?) {}
    func current(deviceID: String) throws -> SimulatorAXScope { throw ToolError("not used by identity tests") }
}
