// Offline checks of SimulatorBudget.swift: no simulator, no process list and no settings file of this Mac are read.
// swiftc -parse-as-library SimulatorBudget.swift simulator-budget-selfcheck.swift -o check && ./check

import Foundation

@main struct SimulatorBudgetSelfcheck {
    static func main() {
        var count = 0
        func expect(_ condition: @autoclosure () -> Bool, _ message: String, line: UInt = #line) {
            count += 1
            if !condition() { print("FAIL line \(line): \(message)"); exit(1) }
        }
        let gib: UInt64 = 1 << 30

        // Settings.
        let absent = SimulatorBudgetConfig.parse(nil)
        expect(absent.manualTotal == nil && !absent.autoShutdown && absent.idleMinutes == 15, "no file: automatic, no shutdown")
        expect(SimulatorBudgetConfig.parse(Data("not json".utf8)) == absent, "broken file reads as no file")
        let written = SimulatorBudgetConfig.parse(Data(#"{"schemaVersion":1,"limit":"auto","autoShutdown":{"enabled":true,"idleMinutes":15}}"#.utf8))
        expect(written.manualTotal == nil && written.autoShutdown && written.idleMinutes == 15, "automatic with shutdown")
        let manual = SimulatorBudgetConfig.parse(Data(#"{"limit":4,"autoShutdown":{"enabled":false,"idleMinutes":0}}"#.utf8))
        expect(manual.manualTotal == 4 && !manual.autoShutdown && manual.idleMinutes == 1, "manual total, idle clamped up")
        expect(SimulatorBudgetConfig.parse(Data(#"{"limit":true}"#.utf8)).manualTotal == nil, "a boolean is not a number")
        expect(SimulatorBudgetConfig.parse(Data(#"{"limit":0}"#.utf8)).manualTotal == 1, "at least one")
        expect(SimulatorBudgetConfig.parse(Data(#"{"limit":99}"#.utf8)).manualTotal == SimulatorBudgetConfig.maximumTotal, "at most the maximum")
        for config in [absent, written, manual] { expect(SimulatorBudgetConfig.parse(config.encoded) == config, "settings survive writing") }

        // Limits from memory and disk.
        func limits(_ config: SimulatorBudgetConfig = absent, memory: UInt64, disk: Int64?) -> SimulatorBudgetLimits {
            simulatorBudgetLimits(config, memoryBytes: memory * gib, freeDiskBytes: disk.map { $0 << 30 })
        }
        let mini = limits(memory: 24, disk: 40)
        expect(mini.total == 3 && mini.defaultSet == 2 && mini.automatic && mini.memoryGiB == 24 && mini.freeDiskGiB == 40, "24 GiB: 3 and 2")
        expect(limits(memory: 8, disk: 200).total == 1 && limits(memory: 8, disk: 200).defaultSet == 1, "8 GiB: one, and it may be a default-set device")
        expect(limits(memory: 16, disk: 200).total == 2, "16 GiB: two")
        expect(limits(memory: 64, disk: 200).total == 8, "64 GiB: eight")
        expect(limits(memory: 256, disk: 900).total == SimulatorBudgetConfig.maximumTotal, "capped")
        expect(limits(memory: 24, disk: 29).total == 2, "under 30 GiB free: two")
        expect(limits(memory: 24, disk: 30).total == 3, "30 GiB free: no disk limit")
        expect(limits(memory: 24, disk: 14).total == 1, "under 15 GiB free: one")
        expect(limits(memory: 24, disk: nil).total == 3 && limits(memory: 24, disk: nil).freeDiskGiB == nil, "unknown disk: memory only")
        let raised = limits(manual, memory: 24, disk: 10)
        expect(raised.total == 4 && raised.defaultSet == 3 && !raised.automatic && raised.automaticTotal == 1, "a manual limit wins and the automatic one stays visible")

        // The process list.
        let a = "AAAAAAAA-0000-0000-0000-000000000001", b = "BBBBBBBB-0000-0000-0000-000000000002", p = "CCCCCCCC-0000-0000-0000-000000000003"
        let list = """
              10     1 launchd_sim /Users/u/Library/Developer/CoreSimulator/Devices/\(a)/data/var/run/launchd_bootstrap.plist
              11    10 /Users/u/Library/Developer/CoreSimulator/Devices/\(a)/data/Containers/Bundle/Application/X/App.app/App
              12    10 /Library/Developer/CoreSimulator/Volumes/iOS/RuntimeRoot/System/Library/CoreServices/SpringBoard.app/SpringBoard
              13    10 /Users/u/Library/Developer/CoreSimulator/Devices/\(a)/data/Containers/Bundle/Application/Y/UITests-Runner.app/UITests-Runner
              20     1 launchd_sim /Users/u/Library/Developer/CoreSimulator/Devices/\(b)/data/var/run/launchd_bootstrap.plist
              30     1 launchd_sim /Users/u/Library/Developer/Xcode/UserData/Previews/Simulator Devices/\(p)/data/var/run/launchd_bootstrap.plist
              40     1 /Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild test -destination id=\(b.lowercased())
              50     1 /Applications/mac-cu.app/Contents/MacOS/mac-cu --daemon
              51    50 /usr/bin/xcrun devicectl device info displays --device \(b)
              60     1 /bin/zsh -c sim-pilot budget --would-boot --udid \(b)
              61    60 sim-pilot budget --would-boot --udid \(b)
              70     1 /Applications/Xcode.app/Contents/Developer/usr/bin/devicectl device info details --device \(a)
              71     1 /Library/Developer/PrivateFrameworks/CoreSimulator.framework/Versions/A/Resources/bin/simctl spawn \(a) /bin/ls
            bad line
            """
        let processes = parseBudgetProcesses(list)
        expect(processes.count == 13, "thirteen processes, the bad line dropped")
        expect(processes[0].name == "launchd_sim" && processes[6].name == "xcodebuild" && processes[6].parent == 1, "names and parents")
        expect(budgetProcessAncestors(of: 61, in: processes) == [61, 60], "the command and its shell")
        let use = simulatorProcessUse(udids: [a, b, p], processes: processes, ignoring: [50, 60, 61])
        expect(use[a]?.apps == [11, 13], "installed apps of the device, not system processes")
        expect(use[a]?.owners.map(\.kind) == ["test-runner", "process"] && use[a]?.owners.last?.by == "simctl", "a test runner inside and simctl outside; a devicectl status read is no use")
        expect(use[b]?.owners == [SimulatorOwner(kind: "process", by: "xcodebuild", pid: 40)], "xcodebuild names it in lower case; the daemon's read and this command do not count")
        expect(use[p]?.owners.isEmpty == true && use[p]?.apps.isEmpty == true, "a Previews device is found by its own launchd_sim")
        let unfiltered = simulatorProcessUse(udids: [b], processes: processes, ignoring: [])[b]?.owners ?? []
        expect(unfiltered.map(\.pid) == [40, 60, 61], "without the exclusions the shell and the command count: \(unfiltered)")

        // Previews devices, from the process list alone.
        let previews = bootedPreviewSimulators(processes + parseBudgetProcesses("  31 1 launchd_sim /Users/u/Library/Developer/Xcode/UserData/Previews/Simulator Devices/not-a-device/data/var/run/launchd_bootstrap.plist"))
        expect(previews == [BudgetSimulator(udid: p, name: "Previews", runtime: "", previews: true)],
               "one Previews device, named by default when its device.plist is absent; default-set devices and a malformed folder are not Previews devices")

        // agent-device claims.
        let started = Date(timeIntervalSince1970: 1_795_020_729)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEE MMM d HH:mm:ss yyyy"
        func claim(_ udid: String, pid: Int, start: String?, kind: String = "simulator") -> Data {
            var json: [String: Any] = ["schemaVersion": 3, "session": "t3-1", "workspace": "/work/App", "ownerPid": pid,
                                       "device": ["id": udid, "kind": kind, "name": "iPhone"]]
            if let start { json["ownerStartTime"] = start }
            return try! JSONSerialization.data(withJSONObject: json)
        }
        let padded = formatter.string(from: started).replacingOccurrences(of: " ", with: "  ")
        let files = [claim(a, pid: 100, start: padded), claim(b, pid: 101, start: formatter.string(from: started.addingTimeInterval(-3600))),
                     claim(p, pid: 102, start: formatter.string(from: started)), claim(a.lowercased(), pid: 103, start: nil),
                     claim(b, pid: 100, start: formatter.string(from: started), kind: "device"), Data("{".utf8)]
        let agents = agentDeviceOwners(files: files) { pid in pid == 102 ? nil : started.addingTimeInterval(0.4) }
        expect(agents.owners[a]?.map(\.pid) == [100, 103], "a matching start (also with ps padding), and a claim without a start time")
        expect(agents.owners[a]?.first?.by == "t3-1 · App" && agents.owners[a]?.first?.kind == "agent-device", "session and workspace")
        expect(agents.owners[b] == nil, "another process took the number, and a physical device is no simulator")
        expect(agents.owners[p] == nil && agents.unreadable == 1, "a dead owner, and one unreadable file counted")

        // Counting.
        let devices = [BudgetSimulator(udid: a, name: "A", runtime: "iOS", previews: false),
                       BudgetSimulator(udid: b, name: "B", runtime: "iOS", previews: false),
                       BudgetSimulator(udid: p, name: "P", runtime: "iOS", previews: true)]
        let three = SimulatorBudgetCount(devices)
        expect(three.total == 3 && three.defaultSet == 2 && three.previews == 1, "two and one")
        expect(!three.isOver(mini) && !three.fits(mini, previews: false) && !three.fits(mini, previews: true) && three.excess(mini) == 0, "full, not over")
        let two = SimulatorBudgetCount(Array(devices.prefix(2)))
        expect(!two.fits(mini, previews: false) && two.fits(mini, previews: true), "the third place is for Previews")
        let c = BudgetSimulator(udid: "DDDDDDDD-0000-0000-0000-000000000004", name: "C", runtime: "iOS", previews: false)
        let four = SimulatorBudgetCount(devices + [c])
        expect(four.isOver(mini) && four.excess(mini) == 1, "one too many")
        let previewsOnly = SimulatorBudgetCount([devices[2], BudgetSimulator(udid: "E", name: "E", runtime: "", previews: true)])
        expect(previewsOnly.isOver(limits(memory: 8, disk: 100)) && previewsOnly.excess(limits(memory: 8, disk: 100)) == 0, "over with Previews devices only: nothing of ours to stop")

        // Idle time.
        let now = Date(timeIntervalSince1970: 2_000_000)
        let all = devices + [c]
        var idle = simulatorIdleSince(previous: [:], previousApps: [:], devices: all, owners: [b: [SimulatorOwner(kind: "process", by: "x", pid: 1)]],
                                      apps: [a: [11]], userActive: false, now: now)
        expect(idle == [a: now, c.udid: now], "first sight starts the time; an owned device and a Previews device have none")
        let later = now.addingTimeInterval(600)
        idle = simulatorIdleSince(previous: idle, previousApps: [a: [11], c.udid: []], devices: all, owners: [:], apps: [a: [11, 12]], userActive: false, now: later)
        expect(idle[a] == later && idle[c.udid] == now && idle[b] == later, "a new app starts over, an unchanged device keeps its time, a released device starts")
        expect(simulatorIdleSince(previous: idle, previousApps: [a: [11, 12], b: [], c.udid: []], devices: all, owners: [:], apps: [a: [11, 12]],
                                  userActive: true, now: later.addingTimeInterval(60)).values.allSatisfy { $0 == later.addingTimeInterval(60) },
               "the user at the Simulator app starts every device over")

        // What to shut down.
        var on = written
        func candidates(_ owners: [String: [SimulatorOwner]] = [:], idle: [String: Date], at time: Date, config: SimulatorBudgetConfig? = nil,
                        limits: SimulatorBudgetLimits = mini) -> [String] {
            simulatorShutdownCandidates(devices: all, owners: owners, idleSince: idle, limits: limits, config: config ?? on, now: time).map(\.name)
        }
        let old = now.addingTimeInterval(-3600), quarter = now.addingTimeInterval(-900)
        expect(candidates(idle: [a: old, b: quarter, c.udid: old.addingTimeInterval(1)], at: now) == ["A"], "one too many: only the longest idle")
        expect(candidates(idle: [a: now.addingTimeInterval(-899), b: quarter], at: now) == ["B"], "exactly the idle time counts, a second less does not")
        expect(candidates([b: [SimulatorOwner(kind: "sim-pilot", by: "s", pid: 1)]], idle: [a: now.addingTimeInterval(-60), b: old], at: now).isEmpty,
               "an owner protects, and a busy device waits")
        expect(candidates(idle: [a: old, b: old, c.udid: old, p: old], at: now, limits: limits(memory: 8, disk: 100)) == ["A", "B", "C"],
               "limit one with a Previews device: all of ours, never the Previews device")
        expect(candidates(idle: [a: old, b: old], at: now, config: absent).isEmpty, "off unless the settings turn it on")
        on.idleMinutes = 120
        expect(candidates(idle: [a: old, b: old], at: now).isEmpty, "the idle time comes from the settings")
        expect(simulatorShutdownCandidates(devices: devices, owners: [:], idleSince: [a: old, b: old], limits: mini, config: written, now: now).isEmpty,
               "inside the limits nothing stops")
        print("PASS \(count) simulator budget assertions; no simulator, process or settings file touched")
    }
}
