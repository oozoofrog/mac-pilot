// Headless: the Device Hub view. The devices:// URL built for a device identifier, the launcher arguments (the
// application named explicitly, no activation unless focus), refusal without an allowed device, refusal when Device Hub
// is missing, and that view and release neither read the device nor send input nor close Device Hub. Only reads this
// Mac's Device Hub bundle (LaunchServices lookup and its Info.plist); it never launches Device Hub or touches a device.
// From the repository root after `eyebuild dir device-hub`:
// D=/Volumes/eyedisk/build/mac-pilot/device-hub; S=mac-computer-use/skills/mac-computer-use/scripts/mac-cu-src
// { sed -n '1,/^@main struct HIDTransportSelfcheck/ p' mac-computer-use/tests/hid-transport-selfcheck.swift | sed '$d'; sed -n '/^final class HIDLink {/,/^var hidLinks:/p' "$S/Simulator.swift" | sed '$d'; sed -n '/^let usKeys:/,/^\/\/ MARK: - Pasteboard/p' "$S/Simulator.swift" | sed '$d'; } > "$D/hub-stubs.swift"
// export TMPDIR="$D" CLANG_MODULE_CACHE_PATH="$D/cache"; FLAGS=$(python3 mac-computer-use/skills/mac-computer-use/scripts/native_build.py --emit-stub-modules "$D/modules")  # bash; in zsh use ${=FLAGS}
// swiftc -parse-as-library $FLAGS "$D/hub-stubs.swift" "$S/SimulatorGestureHID.swift" "$S/PhysicalDeviceLink.swift" "$S/PhysicalDeviceSession.swift" "$S/Device.swift" "$S/DeviceHubView.swift" mac-computer-use/tests/device-hub-selfcheck.swift -o "$D/device-hub-selfcheck" && "$D/device-hub-selfcheck"
// Without CoreDevice (every import from it must be weak): a copy whose CoreDevice load paths point nowhere still starts.
// cp "$D/device-hub-selfcheck" "$D/no-coredevice"; for n in CoreDevice CoreDeviceUtilities; do o=$(otool -L "$D/no-coredevice" | awk "/\/$n.framework/{print \$1}"); install_name_tool -change "$o" "/nonexistent/$n.framework/$n" "$D/no-coredevice"; done
// codesign -f -s - "$D/no-coredevice" && DEVICE_HUB_EXPECT_NO_COREDEVICE=1 "$D/no-coredevice"
import AppKit
import XPC

struct ShellResult { let status: Int32; let output: String }
func shell(_ path: String, _ args: [String], timeout: Double = 15) -> ShellResult { fatalError("offline") }
func jpegBase64(_ image: CGImage, size: CGSize) throws -> String { fatalError("offline") }
struct SessionStub { let requestCancelled = false }
let currentSession: SessionStub? = nil

func check(_ value: Bool, _ message: String, line: UInt = #line) {
    if !value { print("FAIL \(message) (line \(line))"); exit(1) }
    print("PASS \(message)")
}

@main struct DeviceHubSelfcheck {
    static func main() throws {
        if ProcessInfo.processInfo.environment["DEVICE_HUB_EXPECT_NO_COREDEVICE"] == "1" {
            // Run as on a Mac without Xcode: the CoreDevice load paths of this executable point nowhere (see the
            // no-CoreDevice build in docs/physical-device-validation.md). It must start, and the in-process path is off.
            let outcome = PhysicalDeviceLink().inProcessCheck()
            guard case .unavailable(let reason) = outcome else { return check(false, "in-process path on without CoreDevice") }
            check(!coreDeviceImagesBound() && (reason.contains("not bound at launch") || reason.contains("framework missing")),
                  "without CoreDevice the executable starts and the in-process path is off: \(reason)")
        }
        let id = UUID(uuidString: "0A1B2C3D-4E5F-4061-8293-A4B5C6D7E8F9")!, other = UUID()
        let url = DeviceHub.url(id)
        check(url.absoluteString == "devices://device/open?id=0A1B2C3D-4E5F-4061-8293-A4B5C6D7E8F9", "URL: devices://device/open?id=<identifier>")
        let parts = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        check(parts.scheme == "devices" && parts.host == "device" && parts.path == "/open" && parts.queryItems == [URLQueryItem(name: "id", value: id.uuidString)],
              "DeviceKit's DeviceURLActionProvider shape: subpath device, action open, one id parameter")

        // Launcher arguments.
        let app = URL(fileURLWithPath: "/Applications/Xcode.app/Contents/Applications/DeviceHub.app")
        var opened: [(URL, URL, Bool)] = []
        let fake = DeviceHubLauncher(locate: { app }, open: { opened.append(($0, $1, $2)) })
        let background = try deviceHubView(id, name: "phone", focus: false, launcher: fake)
        check(opened.count == 1 && opened[0].0 == url && opened[0].1 == app && opened[0].2 == false, "default: opened by the named application, not activated")
        check(background.contains("phone") && background.contains("click") && background.contains("without bringing it to the front"),
              "result names the device and says the user clicks to start the screen")
        _ = try deviceHubView(id, name: "phone", focus: true, launcher: fake)
        check(opened.count == 2 && opened[1].2 == true, "focus: activated")
        var tried = false
        do { _ = try deviceHubView(id, name: "phone", focus: false, launcher: DeviceHubLauncher(locate: { nil }, open: { _, _, _ in tried = true })); check(false, "missing") }
        catch { check(!tried && "\(error)".contains("ToolError"), "Device Hub missing: refused, nothing opened") }
        do { _ = try deviceHubView(id, name: "phone", focus: false, launcher: DeviceHubLauncher(locate: { app }, open: { _, _, _ in throw ToolError("x") })); check(false, "failure") }
        catch { check(error is ToolError, "a launch failure is reported") }

        // Through the tool: only the allowed device; view and release read nothing from the device and send nothing.
        let devices = [id, other].map { PhysicalDeviceInfo(identifier: $0, name: $0 == id ? "phone" : "another", model: nil, osVersion: "iOS 27",
                                                           transport: "wired", connectionState: "Connected", pairingState: "paired") }
        var launched: [(URL, Bool)] = [], ended: [UUID?] = []
        let hub = DeviceHubLauncher(locate: { app }, open: { url, _, activate in launched.append((url, activate)) })
        let tool = DeviceTool(DeviceBackend(list: { devices }, locked: { _ in fatalError("no lock read") }, display: { _ in fatalError("no display read") },
                                            screenshot: { _, _ in fatalError("no screenshot") }, open: { _, _ in fatalError("no input") },
                                            view: { try deviceHubView($0, name: $1, focus: $2, launcher: hub) }, endSessions: { ended.append($0) }))
        func refused(_ args: [String: Any]) -> Bool { (try? tool.call(args)) == nil }
        check(refused(["action": "view", "device": id.uuidString]) && launched.isEmpty, "no device allowed: refused, Device Hub not opened")
        check(refused(["action": "view"]) && refused(["action": "view", "device": "phone"]) && launched.isEmpty, "a name or no identifier: refused")
        _ = try tool.call(["action": "allow", "device": id.uuidString])
        check(refused(["action": "view", "device": other.uuidString]) && launched.isEmpty, "another device: refused")
        let text = ((try tool.call(["action": "view", "device": id.uuidString])["content"] as! [[String: Any]])[0]["text"] as! String)
        check(launched.count == 1 && launched[0].0 == url && !launched[0].1 && text.contains("phone"), "allowed device: Device Hub opened at its identifier")

        // Cleanup: release ends mac-cu's sessions only; Device Hub is not opened, activated or closed again.
        _ = try tool.call(["action": "release"])
        check(ended.count == 1 && ended[0] == nil && launched.count == 1, "release ends mac-cu's sessions and leaves Device Hub alone")
        check(refused(["action": "view", "device": id.uuidString]) && launched.count == 1, "after release: refused")

        // This Mac: the real lookup names Device Hub, whose Info.plist claims the devices scheme. Nothing is launched.
        if let real = DeviceHubLauncher.system.locate() {
            let info = Bundle(url: real)?.infoDictionary
            let schemes = (info?["CFBundleURLTypes"] as? [[String: Any]])?.flatMap { $0["CFBundleURLSchemes"] as? [String] ?? [] } ?? []
            check(info?["CFBundleIdentifier"] as? String == DeviceHub.bundleIdentifier && schemes.contains("devices"),
                  "installed Device Hub (\(info?["CFBundleShortVersionString"] as? String ?? "?")) at \(real.path) claims devices://")
        } else {
            print("SKIP no Device Hub on this Mac; the tool refuses view with an install hint")
        }
        print("device-hub-selfcheck: all passed")
    }
}
