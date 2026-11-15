import AppKit

// A physical device's screen is watched in Xcode's Device Hub (com.apple.dt.Devices), which gets a media stream from
// the device; mac-cu only opens Device Hub at that device. Agent input stays on the device tool's CoreDevice HID path.
//
// Device Hub 27.2 (DeviceKit 255.30) registers the devices:// scheme. Its DeviceURLActionProvider handles subpath
// "device", action "open" with the required parameter "id" (a CoreDevice device identifier) and opens that device's
// compact window (measured: a 296×620 window titled with the device name). For a physical device the screen does not
// start by itself: DeviceKit's LiveDeviceActivation.Policy.shouldAutoStart returns false for DeviceReality.physical,
// so the user clicks the window's View Screen button. See docs/design/device-hub-connection-analysis.md and
// docs/physical-device-validation.md.

enum DeviceHub {
    static let bundleIdentifier = "com.apple.dt.Devices"

    /// devices://device/open?id=<identifier>
    static func url(_ id: UUID) -> URL {
        var parts = URLComponents()
        parts.scheme = "devices"
        parts.host = "device"
        parts.path = "/open"
        parts.queryItems = [URLQueryItem(name: "id", value: id.uuidString)]
        return parts.url!
    }
}

/// How Device Hub is found and asked to open a URL; replaced by fakes in checks.
struct DeviceHubLauncher {
    /// Device Hub's application bundle; nil without Xcode.
    var locate: () -> URL?
    /// Opens the URL with that application. activate: bring it to the front.
    var open: (_ url: URL, _ application: URL, _ activate: Bool) throws -> Void

    /// LaunchServices with the application named explicitly, so no other app that claims devices:// receives the
    /// identifier. With activate false the app is asked not to come to the front (as `open -g`).
    static let system = DeviceHubLauncher(locate: {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: DeviceHub.bundleIdentifier)
    }, open: { url, application, activate in
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = activate
        configuration.addsToRecentItems = false
        configuration.promptsUserIfNeeded = false
        let done = DispatchSemaphore(value: 0)
        let failure = PhysicalBox<String>()
        NSWorkspace.shared.open([url], withApplicationAt: application, configuration: configuration) { _, error in
            if let error { failure.value = error.localizedDescription }
            done.signal()
        }
        guard done.wait(timeout: .now() + 30) == .success else { throw ToolError("Device Hub did not open within 30 seconds; open Xcode > Window > Devices yourself.") }
        if let message = failure.value { throw ToolError("Device Hub did not open: \(message)") }
    })
}

/// Opens Device Hub at the device and says what the user does next.
func deviceHubView(_ id: UUID, name: String, focus: Bool, launcher: DeviceHubLauncher) throws -> String {
    guard let application = launcher.locate() else {
        throw ToolError("Xcode's Device Hub (\(DeviceHub.bundleIdentifier)) was not found. Install Xcode, open it once, then retry.")
    }
    try launcher.open(DeviceHub.url(id), application, focus)
    return "Opened \(name)'s window in Xcode Device Hub" + (focus ? "." : " without bringing it to the front; switch to Device Hub to see it.") +
        " A physical device's screen does not start by itself: the user clicks View Screen in that window (Pair first if it shows Pair). " +
        "mac-cu never clicks in Device Hub and never closes it; agent input still goes through this tool."
}
