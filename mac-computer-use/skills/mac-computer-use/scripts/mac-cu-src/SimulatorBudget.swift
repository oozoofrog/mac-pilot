// How many simulators may be booted at once on this Mac, who uses each one, and which idle ones may be shut down.
// Foundation only, no AppKit and no CoreSimulator: the daemon (SimulatorBudgetWatch.swift) and simulator-pilot's
// sim-pilot both carry this text, and scripts/tests/test_simulator_budget_core.py fails when the two copies differ.

import Foundation

// BEGIN simulator-budget-core

/// A JSON number, not true or false (which bridge to 1 and 0).
func budgetInteger(_ value: Any?) -> Int? {
    guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
    return number.intValue
}

/// The user's settings: ~/Library/Application Support/sim-pilot/budget.json.
/// {"schemaVersion": 1, "limit": "auto" | <total>, "autoShutdown": {"enabled": true, "idleMinutes": 15}}
struct SimulatorBudgetConfig: Equatable {
    /// nil: the limit follows this Mac's memory and free disk space.
    var manualTotal: Int?
    var autoShutdown = false
    var idleMinutes = 15

    static let maximumTotal = 12
    static var fileURL: URL {
        if let path = ProcessInfo.processInfo.environment["SIM_PILOT_BUDGET_FILE"], !path.isEmpty { return URL(fileURLWithPath: path) }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/sim-pilot/budget.json")
    }

    /// A missing or unreadable file is the automatic limit without automatic shutdown.
    static func parse(_ data: Data?) -> SimulatorBudgetConfig {
        var config = SimulatorBudgetConfig()
        guard let data, let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return config }
        if let total = budgetInteger(json["limit"]) { config.manualTotal = min(max(total, 1), maximumTotal) }
        if let shutdown = json["autoShutdown"] as? [String: Any] {
            config.autoShutdown = shutdown["enabled"] as? Bool ?? false
            if let minutes = budgetInteger(shutdown["idleMinutes"]) { config.idleMinutes = min(max(minutes, 1), 24 * 60) }
        }
        return config
    }

    static func load() -> SimulatorBudgetConfig { parse(try? Data(contentsOf: fileURL)) }

    var encoded: Data {
        let json: [String: Any] = ["schemaVersion": 1, "limit": manualTotal.map { $0 as Any } ?? "auto",
                                   "autoShutdown": ["enabled": autoShutdown, "idleMinutes": idleMinutes]]
        return (try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])) ?? Data()
    }

    func save() throws {
        let file = Self.fileURL
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoded.write(to: file, options: .atomic)
    }
}

struct SimulatorBudgetLimits: Equatable {
    /// Booted simulators in every device set together.
    let total: Int
    /// Booted simulators in the default set: one place stays free for an Xcode Previews device.
    let defaultSet: Int
    let automatic: Bool
    let memoryGiB: Int
    /// nil when the free space could not be read.
    let freeDiskGiB: Int?
    /// What the automatic limit is, also while a manual one applies (the settings show it).
    let automaticTotal: Int
}

/// The automatic limit: one simulator for each 8 GiB of memory (a booted iOS simulator held about 2 GiB here, and
/// what does not fit goes to swap on the startup disk), and fewer when that disk is short: under 30 GiB free two,
/// under 15 GiB one.
func simulatorBudgetLimits(_ config: SimulatorBudgetConfig, memoryBytes: UInt64, freeDiskBytes: Int64?) -> SimulatorBudgetLimits {
    let gibibyte: UInt64 = 1 << 30
    let memory = Int((memoryBytes + gibibyte / 2) / gibibyte)
    let disk = freeDiskBytes.map { Int(max($0, 0) / Int64(gibibyte)) }
    var automatic = max(1, memory / 8)
    if let disk { automatic = min(automatic, disk < 15 ? 1 : disk < 30 ? 2 : Int.max) }
    automatic = min(automatic, SimulatorBudgetConfig.maximumTotal)
    let total = config.manualTotal ?? automatic
    return SimulatorBudgetLimits(total: total, defaultSet: max(1, total - 1), automatic: config.manualTotal == nil,
                                 memoryGiB: memory, freeDiskGiB: disk, automaticTotal: automatic)
}

/// Free space of the volume that holds the swap files (the data volume of the startup disk).
func simulatorBudgetFreeDiskBytes() -> Int64? {
    var info = statfs()
    guard statfs("/System/Volumes/Data", &info) == 0 else { return nil }
    return Int64(info.f_bavail) * Int64(info.f_bsize)
}

func currentSimulatorBudgetLimits(_ config: SimulatorBudgetConfig = .load()) -> SimulatorBudgetLimits {
    simulatorBudgetLimits(config, memoryBytes: ProcessInfo.processInfo.physicalMemory, freeDiskBytes: simulatorBudgetFreeDiskBytes())
}

struct BudgetSimulator: Equatable {
    let udid: String
    let name: String
    let runtime: String
    /// In the Xcode Previews device set, which Xcode boots by itself.
    let previews: Bool
}

struct BudgetProcess: Equatable {
    let pid: Int32
    let parent: Int32
    let command: String

    /// The file name of the executable ("xcodebuild"). A path with a space gives its part before the space.
    var name: String {
        let executable = command.split(separator: " ", maxSplits: 1).first.map(String.init) ?? ""
        return executable.split(separator: "/").last.map(String.init) ?? executable
    }
}

/// Lines of `ps -axww -o pid=,ppid=,command=`.
func parseBudgetProcesses(_ text: String) -> [BudgetProcess] {
    text.split(separator: "\n").compactMap { line in
        let parts = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
        guard parts.count == 3, let pid = Int32(parts[0]), let parent = Int32(parts[1]) else { return nil }
        return BudgetProcess(pid: pid, parent: parent, command: String(parts[2]))
    }
}

func readBudgetProcesses() -> [BudgetProcess] {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/ps")
    process.arguments = ["-axww", "-o", "pid=,ppid=,command="]
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice
    guard (try? process.run()) != nil else { return [] }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return parseBudgetProcesses(String(decoding: data, as: UTF8.self))
}

struct SimulatorOwner: Equatable {
    /// "sim-pilot" (a claim), "mac-cu" (input a session sent through mac-cu, without a claim), "agent-device" (a T3 Device panel session), "process" (a tool on the Mac that names the
    /// device), "test-runner" (a UI test runner inside the device) or "lcd-window" (an open mac-cu window).
    let kind: String
    let by: String
    let pid: Int32

    var json: [String: Any] { ["kind": kind, "by": by, "pid": Int(pid)] }
}

/// What the process list says about each booted device: who uses it, and which apps run in it.
struct SimulatorProcessUse: Equatable {
    var owners: [SimulatorOwner] = []
    /// Processes of installed apps in the device. A change means that somebody uses the device.
    var apps: Set<Int32> = []
}

/// `ignoring`: processes whose mention of a device is not a use of it (this command and its callers, the daemon
/// with the devicectl reads of its status board).
func simulatorProcessUse(udids: [String], processes: [BudgetProcess], ignoring: Set<Int32>) -> [String: SimulatorProcessUse] {
    let byPID = Dictionary(processes.map { ($0.pid, $0) }, uniquingKeysWith: { first, _ in first })
    var roots: [Int32: String] = [:]  // launchd_sim → device
    for process in processes where process.name == "launchd_sim" {
        if let udid = udids.first(where: { process.command.range(of: $0, options: .caseInsensitive) != nil }) { roots[process.pid] = udid }
    }
    /// The device a process runs in, or whether one of `ignoring` started it.
    func origin(_ process: BudgetProcess) -> (device: String?, ignored: Bool) {
        var current = process, steps = 0
        while steps < 64 {
            if let udid = roots[current.pid] { return (udid, false) }
            if ignoring.contains(current.pid) { return (nil, true) }
            guard current.parent > 1, let parent = byPID[current.parent] else { return (nil, false) }
            current = parent
            steps += 1
        }
        return (nil, false)
    }
    var use = Dictionary(udids.map { ($0, SimulatorProcessUse()) }, uniquingKeysWith: { first, _ in first })
    for process in processes where roots[process.pid] == nil {
        let from = origin(process)
        if let udid = from.device {
            guard process.command.contains("/data/Containers/Bundle/Application/") else { continue }
            use[udid]?.apps.insert(process.pid)
            if process.command.contains("-Runner.app/") { use[udid]?.owners.append(SimulatorOwner(kind: "test-runner", by: process.name, pid: process.pid)) }
        } else if !from.ignored {
            // Reading a device's status is not using it.
            if process.command.contains("devicectl device info ") { continue }
            for udid in udids where process.command.range(of: udid, options: .caseInsensitive) != nil {
                use[udid]?.owners.append(SimulatorOwner(kind: "process", by: process.name, pid: process.pid))
            }
        }
    }
    return use
}

/// A process and the processes that started it.
func budgetProcessAncestors(of pid: Int32, in processes: [BudgetProcess]) -> Set<Int32> {
    let byPID = Dictionary(processes.map { ($0.pid, $0) }, uniquingKeysWith: { first, _ in first })
    var result: Set<Int32> = [pid], current = pid
    while let process = byPID[current], process.parent > 1, !result.contains(process.parent) {
        result.insert(process.parent)
        current = process.parent
    }
    return result
}

/// When a process started, to tell it from a later process with the same number.
func budgetProcessStart(_ pid: Int32) -> Date? {
    var info = kinfo_proc(), size = MemoryLayout<kinfo_proc>.stride
    var name: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
    guard sysctl(&name, 4, &info, &size, nil, 0) == 0, size > 0, info.kp_proc.p_pid == pid else { return nil }
    let start = info.kp_proc.p_starttime
    return Date(timeIntervalSince1970: TimeInterval(start.tv_sec) + TimeInterval(start.tv_usec) / 1_000_000)
}

/// The T3 Device panel's claims (~/.agent-device/device-claims/*.json), for owners that still run. The format belongs
/// to agent-device: a file that does not parse gives no owner here, and `unreadable` counts it so that the caller
/// does not take "no owner" as known.
func agentDeviceOwners(files: [Data], start: (Int32) -> Date? = budgetProcessStart) -> (owners: [String: [SimulatorOwner]], unreadable: Int) {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "EEE MMM d HH:mm:ss yyyy"
    var owners: [String: [SimulatorOwner]] = [:], unreadable = 0
    for data in files {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let device = json["device"] as? [String: Any], let udid = device["id"] as? String,
              let pid = (json["ownerPid"] as? NSNumber)?.int32Value else { unreadable += 1; continue }
        guard device["kind"] as? String ?? "simulator" == "simulator", let started = start(pid) else { continue }
        // `ps -o lstart` text, whole seconds, local time. Without it the running process is taken as the owner.
        if let text = json["ownerStartTime"] as? String,
           let claimed = formatter.date(from: text.split(separator: " ").joined(separator: " ")),
           abs(claimed.timeIntervalSince(started)) > 2 { continue }
        let by = [json["session"] as? String, (json["workspace"] as? String).map { ($0 as NSString).lastPathComponent }]
            .compactMap { $0 }.joined(separator: " · ")
        owners[udid.uppercased(), default: []].append(SimulatorOwner(kind: "agent-device", by: by.isEmpty ? "agent-device" : by, pid: pid))
    }
    return (owners, unreadable)
}

func readAgentDeviceOwners() -> (owners: [String: [SimulatorOwner]], unreadable: Int) {
    let folder = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".agent-device/device-claims")
    let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
    return agentDeviceOwners(files: files.filter { $0.pathExtension == "json" }.compactMap { try? Data(contentsOf: $0) })
}

struct SimulatorBudgetCount: Equatable {
    let total: Int
    let defaultSet: Int
    let previews: Int

    init(_ devices: [BudgetSimulator]) {
        total = devices.count
        previews = devices.filter(\.previews).count
        defaultSet = total - previews
    }

    func isOver(_ limits: SimulatorBudgetLimits) -> Bool { total > limits.total || defaultSet > limits.defaultSet }
    /// Whether one more device of that set fits.
    func fits(_ limits: SimulatorBudgetLimits, previews: Bool) -> Bool {
        total < limits.total && (previews || defaultSet < limits.defaultSet)
    }
    /// How many default-set devices must stop to come back inside the limits (Previews devices are Xcode's).
    func excess(_ limits: SimulatorBudgetLimits) -> Int { min(defaultSet, max(total - limits.total, defaultSet - limits.defaultSet, 0)) }
}

/// Since when each default-set device has had no owner and no change of its apps. A device with an owner, a changed
/// set of apps or a user at the Simulator app starts over.
func simulatorIdleSince(previous: [String: Date], previousApps: [String: Set<Int32>], devices: [BudgetSimulator],
                        owners: [String: [SimulatorOwner]], apps: [String: Set<Int32>], userActive: Bool, now: Date) -> [String: Date] {
    var result: [String: Date] = [:]
    for device in devices where !device.previews {
        guard owners[device.udid, default: []].isEmpty else { continue }
        let unchanged = !userActive && previousApps[device.udid] == apps[device.udid, default: []]
        result[device.udid] = unchanged ? previous[device.udid] ?? now : now
    }
    return result
}

/// The devices to shut down now: only as many as the limits need, only default-set devices without an owner that
/// have been idle for the whole time, the longest idle first.
func simulatorShutdownCandidates(devices: [BudgetSimulator], owners: [String: [SimulatorOwner]], idleSince: [String: Date],
                                 limits: SimulatorBudgetLimits, config: SimulatorBudgetConfig, now: Date) -> [BudgetSimulator] {
    guard config.autoShutdown else { return [] }
    let need = SimulatorBudgetCount(devices).excess(limits)
    guard need > 0 else { return [] }
    let idle = TimeInterval(config.idleMinutes * 60)
    var idleDevices: [(device: BudgetSimulator, since: Date)] = []
    for device in devices where !device.previews && owners[device.udid, default: []].isEmpty {
        if let since = idleSince[device.udid], now.timeIntervalSince(since) >= idle { idleDevices.append((device, since)) }
    }
    idleDevices.sort { $0.since < $1.since || ($0.since == $1.since && $0.device.udid < $1.device.udid) }
    return idleDevices.prefix(need).map(\.device)
}

// END simulator-budget-core

/// The booted devices of the Xcode Previews set, from their launchd_sim processes and device.plist: no private
/// call opens that set, which belongs to Xcode.
func bootedPreviewSimulators(_ processes: [BudgetProcess]) -> [BudgetSimulator] {
    let marker = "/Previews/Simulator Devices/", prefix = "launchd_sim "
    return processes.compactMap { process -> BudgetSimulator? in
        guard process.command.hasPrefix(prefix) else { return nil }
        let path = String(process.command.dropFirst(prefix.count))
        guard let start = path.range(of: marker), let udid = path[start.upperBound...].split(separator: "/").first.map(String.init),
              UUID(uuidString: udid) != nil else { return nil }
        let device = URL(fileURLWithPath: String(path[..<start.upperBound]) + udid)
        let plist = (try? Data(contentsOf: device.appendingPathComponent("device.plist")))
            .flatMap { try? PropertyListSerialization.propertyList(from: $0, format: nil) as? [String: Any] }
        let runtime = (plist?["runtime"] as? String)?.components(separatedBy: "SimRuntime.").last?
            .replacingOccurrences(of: "-", with: ".").replacingOccurrences(of: "iOS.", with: "iOS ") ?? ""
        return BudgetSimulator(udid: udid.uppercased(), name: plist?["name"] as? String ?? "Previews", runtime: runtime, previews: true)
    }.sorted { $0.udid < $1.udid }
}
