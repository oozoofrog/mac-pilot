import Foundation

enum PreparationFixture {
    static let id = "11111111-1111-4111-8111-111111111111"
    static let newID = "22222222-2222-4222-8222-222222222222"
    static let runtime = "com.apple.CoreSimulator.SimRuntime.iOS-27-2"
    static let duoRuntime = runtime + "-iPhone19-4"
    static let phone = "com.apple.CoreSimulator.SimDeviceType.iPhone"
    static let duo = "com.apple.CoreSimulator.SimDeviceType.iPhone-Duo"
    static func json(state: String = "Shutdown", created: Bool = false, build: String = "A1", available: Bool = true,
                     supported: Bool = true, type: String = phone) -> String {
        var runtimeRow: [String: Any] = ["identifier": runtime, "name": "iOS 27.2", "platform": "iOS", "version": "27.2", "buildversion": build, "isAvailable": available]
        if supported { runtimeRow["supportedDeviceTypes"] = [["identifier": phone]] }
        let duoRow: [String: Any] = ["identifier": duoRuntime, "name": "iOS 27.2", "platform": "iOS", "version": "27.2", "buildversion": "D1", "isAvailable": true, "supportedDeviceTypes": [["identifier": duo]]]
        var rows: [[String: Any]] = [["udid": id, "name": "Phone", "state": state, "isAvailable": available, "deviceTypeIdentifier": phone]]
        if created { rows.append(["udid": newID, "name": "New phone", "state": "Shutdown", "isAvailable": true, "deviceTypeIdentifier": type]) }
        let root: [String: Any] = ["runtimes": [runtimeRow, duoRow], "devicetypes": [
            ["identifier": phone, "name": "Phone", "productFamily": "iPhone", "minRuntimeVersion": 26 << 16, "maxRuntimeVersion": UInt32.max],
            ["identifier": duo, "name": "Duo", "productFamily": "iPhone", "minRuntimeVersion": 28 << 16, "maxRuntimeVersion": UInt32.max],
            ["identifier": "old", "name": "Old phone", "productFamily": "iPhone", "maxRuntimeVersion": 20 << 16]],
            "devices": [runtime: rows]]
        return String(decoding: try! JSONSerialization.data(withJSONObject: root), as: UTF8.self)
    }
}

final class PreparationFake {
    var snapshots: [String]
    var commands: [[String]] = []
    var selectCount = 0
    var directory = "/Applications/Xcode.app/Contents/Developer"
    var owners: [String: String] = [:]
    var onCommand: (([String]) throws -> String)?
    init(_ snapshots: [String] = [PreparationFixture.json()]) { self.snapshots = snapshots }
    func backend() -> SimulatorPreparationBackend {
        SimulatorPreparationBackend(execute: { [self] executable, args, _, _ in
            if executable == "/usr/bin/xcode-select" { selectCount += 1; return directory }
            if args == ["simctl", "list", "--json"] {
                let value = snapshots[0]; if snapshots.count > 1 { snapshots.removeFirst() }; return value
            }
            commands.append([executable] + args)
            return try onCommand?(args) ?? (args.contains("create") ? PreparationFixture.newID : "")
        }, claims: { [self] in owners })
    }
}
