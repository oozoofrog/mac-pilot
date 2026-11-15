// CoreDevice presence and ABI checks, listing (names other than $MAC_CU_LIVE_DEVICE_NAME redacted) and, with --open <UUID>, HID
// connection open/release for one explicit device. --missing-runtime: framework absent.
// From the repository root after `eyebuild dir physical-link`:
// D=/Volumes/eyedisk/build/mac-pilot/physical-link; S=mac-computer-use/skills/mac-computer-use/scripts/mac-cu-src
// export TMPDIR="$D" CLANG_MODULE_CACHE_PATH="$D/cache"; FLAGS=$(python3 mac-computer-use/skills/mac-computer-use/scripts/native_build.py --emit-stub-modules "$D/modules")  # bash; in zsh use ${=FLAGS}
// swiftc -parse-as-library $FLAGS "$S/PhysicalDeviceLink.swift" "$S/PhysicalDeviceSession.swift" mac-computer-use/tests/physical-device-link-selfcheck.swift -o "$D/physical-link" && "$D/physical-link" --missing-runtime && "$D/physical-link"
import Foundation
import Darwin

@main struct PhysicalLinkSelfcheck {
    static func main() async throws {
        if CommandLine.arguments.contains("--missing-runtime") {
            do { _ = try PhysicalDeviceLink(openFramework: { _ in dlopen("/nonexistent/CoreDevice.framework/CoreDevice", RTLD_LAZY) }).listDevices(); fatalError("expected unavailable") }
            catch PhysicalDeviceError.frameworkMissing(let part) { print("missing runtime: CoreDevice unavailable: \(part)"); return }
        }
        do { _ = try PhysicalDeviceLink(openFramework: { _ in nil }).listDevices(); fatalError("expected framework missing") }
        catch PhysicalDeviceError.frameworkMissing { print("framework missing: passed") }
        do {
            _ = try PhysicalDeviceLink(openFramework: { _ in UnsafeMutableRawPointer(bitPattern: 1) }, findSymbol: { _, _ in nil }).listDevices()
            fatalError("expected symbol missing")
        } catch PhysicalDeviceError.symbolMissing { print("symbol missing: passed") }
        let missingInProcess = PhysicalDeviceLink(openFramework: { _ in nil })
        missingInProcess.log = { _ in }
        guard case .unavailable = missingInProcess.inProcessCheck() else { fatalError("expected in-process path off without the framework") }
        print("in-process path off without the framework: passed")
        let link = PhysicalDeviceLink()
        print("in-process check: \(link.inProcessCheck())")
        // DeviceManager updates asynchronously after first access.
        _ = try link.listDevices()
        try await Task.sleep(nanoseconds: 3_000_000_000)
        let devices = try link.listDevices()
        print("device listing: \(devices.count) device(s)")
        for device in devices { print("  \(device.name == ProcessInfo.processInfo.environment["MAC_CU_LIVE_DEVICE_NAME"] ? device.name : "[redacted]"): \(device.connectionState ?? "unknown")") }
        // A device is opened only by an explicit identifier: --open <UUID> [count]. Names never select a device.
        if let flag = CommandLine.arguments.firstIndex(of: "--open"), CommandLine.arguments.count > flag + 1 {
            guard let id = UUID(uuidString: CommandLine.arguments[flag + 1]) else { fatalError("--open needs a device UUID") }
            let count = CommandLine.arguments.count > flag + 2 ? Int(CommandLine.arguments[flag + 2]) ?? 1 : 1
            for _ in 0..<count { _ = try await link.openHID(identifier: id); try await Task.sleep(nanoseconds: 300_000_000) }
            print("HID open and release x\(count): passed")
        }
        do { _ = try await link.openHID(identifier: UUID()); fatalError("expected no such device") }
        catch PhysicalDeviceError.noSuchDevice { print("no such device: passed") }
    }
}
