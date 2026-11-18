// Watches how many simulators are booted, whoever booted them (Xcode, xcodebuild, simctl, the T3 Device panel,
// mac-cu), against the limit of SimulatorBudget.swift. Over the limit it warns in the menu bar and with a
// notification; when the settings allow it, it shuts down default-set devices that nobody has used for the idle time.
// CoreSimulator has no way to refuse a boot, so this acts after the fact; `sim-pilot budget` is the check before.

import AppKit
import UserNotifications

struct SimulatorBudgetSnapshot {
    var config = SimulatorBudgetConfig()
    var limits = simulatorBudgetLimits(SimulatorBudgetConfig(), memoryBytes: ProcessInfo.processInfo.physicalMemory, freeDiskBytes: nil)
    var devices: [BudgetSimulator] = []
    var owners: [String: [SimulatorOwner]] = [:]
    var idleSince: [String: Date] = [:]
    var apps: [String: Set<Int32>] = [:]
    var readAt = Date.distantPast

    var count: SimulatorBudgetCount { SimulatorBudgetCount(devices) }
    var isOver: Bool { count.isOver(limits) }
    /// Booted default-set devices that nobody uses: what "shut down now" in the menu stops.
    var unowned: [BudgetSimulator] { devices.filter { !$0.previews && owners[$0.udid, default: []].isEmpty } }

    /// The menu line: "시뮬레이터 5대 · 제한 3대(자동) · 2대 초과".
    var summary: String {
        guard !devices.isEmpty else { return "부팅된 시뮬레이터 없음 · 제한 \(limits.total)대" }
        let over = max(count.total - limits.total, count.defaultSet - limits.defaultSet, 0)
        return "시뮬레이터 \(count.total)대 · 제한 \(limits.total)대(\(limits.automatic ? "자동" : "직접 설정"))" + (over > 0 ? " · \(over)대 초과" : "")
    }
}

final class SimulatorBudgetWatch: NSObject, UNUserNotificationCenterDelegate {
    static let shared = SimulatorBudgetWatch()
    static let interval: TimeInterval = 60

    private let queue = DispatchQueue(label: "mac-cu.simulator-budget", qos: .utility, autoreleaseFrequency: .workItem)
    private let lock = NSLock()
    private var latest = SimulatorBudgetSnapshot()
    private var events: [String] = []
    private var timer: DispatchSourceTimer?
    private var warnedOver = false
    private var askedNotifications = false
    /// Main thread: the menu and the menu bar title show the snapshot.
    var onChange: (() -> Void)?

    var snapshot: SimulatorBudgetSnapshot { lock.lock(); defer { lock.unlock() }; return latest }
    /// The last automatic shutdowns, newest first.
    var recentEvents: [String] { lock.lock(); defer { lock.unlock() }; return events }

    func start() {
        guard timer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 5, repeating: Self.interval, leeway: .seconds(5))
        timer.setEventHandler { [weak self] in self?.tick() }
        timer.resume()
        self.timer = timer
    }

    /// Reads now, off the caller's thread (the menu was opened, or a setting changed).
    func refresh() { queue.async { [weak self] in self?.tick() } }

    func update(_ change: (inout SimulatorBudgetConfig) -> Void) {
        var config = SimulatorBudgetConfig.load()
        change(&config)
        do { try config.save() } catch { NSLog("mac-cu: could not write the simulator limit: \(error.localizedDescription)") }
        refresh()
    }

    /// One reading: the booted devices of both sets and everybody who uses them.
    private func read(previous: SimulatorBudgetSnapshot) -> SimulatorBudgetSnapshot {
        var next = SimulatorBudgetSnapshot()
        next.config = .load()
        next.limits = currentSimulatorBudgetLimits(next.config)
        let processes = readBudgetProcesses()
        let booted = ((try? simulatorDevices()) ?? []).filter(isBooted).map { device -> BudgetSimulator in
            let id = udid(of: device).uppercased()
            let runtime = (device.value(forKey: "runtime") as? NSObject)?.value(forKey: "name") as? String ?? ""
            return BudgetSimulator(udid: id, name: device.value(forKey: "name") as? String ?? id, runtime: runtime, previews: false)
        }
        next.devices = booted.sorted { ($0.name, $0.udid) < ($1.name, $1.udid) } + bootedPreviewSimulators(processes)
        let use = simulatorProcessUse(udids: next.devices.map(\.udid), processes: processes, ignoring: [getpid()])
        let agents = readAgentDeviceOwners()
        let claims = CollaborationStore.standard.state().claims
        let (windows, userActive): (Set<String>, Bool) = DispatchQueue.main.sync {
            (Set(simulatorWindows.keys.map { $0.uppercased() }),
             NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.apple.iphonesimulator")
        }
        for device in next.devices {
            var owners = use[device.udid]?.owners ?? []
            owners += agents.owners[device.udid] ?? []
            if let claim = claims[device.udid] { owners.append(SimulatorOwner(kind: claim.auto ? "mac-cu" : "sim-pilot", by: claim.label, pid: claim.pid)) }
            if windows.contains(device.udid) { owners.append(SimulatorOwner(kind: "lcd-window", by: "mac-cu", pid: getpid())) }
            // A claim file that could not be read may be this device's: its owner is unknown, not absent.
            if agents.unreadable > 0, !device.previews { owners.append(SimulatorOwner(kind: "agent-device", by: "읽지 못한 기록", pid: 0)) }
            next.owners[device.udid] = owners
            next.apps[device.udid] = use[device.udid]?.apps ?? []
        }
        next.idleSince = simulatorIdleSince(previous: previous.idleSince, previousApps: previous.apps, devices: next.devices,
                                            owners: next.owners, apps: next.apps, userActive: userActive, now: Date())
        next.readAt = Date()
        return next
    }

    private func tick() {
        var next = read(previous: snapshot)
        let candidates = simulatorShutdownCandidates(devices: next.devices, owners: next.owners, idleSince: next.idleSince,
                                                     limits: next.limits, config: next.config, now: Date())
        if !candidates.isEmpty {
            let reason = "제한 \(next.limits.total)대(기본 세트 \(next.limits.defaultSet)대)를 넘었고 \(next.config.idleMinutes)분 동안 쓰는 곳이 없었습니다"
            if shutDown(candidates, reason: reason, after: next) { next = read(previous: next) }
        }
        lock.lock(); latest = next; lock.unlock()
        if next.isOver, !warnedOver {
            let busy = next.devices.map { device -> String in
                let owners = next.owners[device.udid, default: []]
                return "\(device.name)\(device.previews ? "(Previews)" : ""): " + (owners.isEmpty ? "쓰는 곳 없음" : owners.map(\.by).first ?? "")
            }
            notify(title: "시뮬레이터가 제한보다 많이 켜져 있습니다", body: next.summary + "\n" + busy.joined(separator: "\n"))
        }
        warnedOver = next.isOver
        DispatchQueue.main.async { self.onChange?() }
    }

    /// Shuts down the devices that are still unused when read again just before. True when one was shut down.
    private func shutDown(_ devices: [BudgetSimulator], reason: String, after snapshot: SimulatorBudgetSnapshot) -> Bool {
        let fresh = read(previous: snapshot)
        var stopped = false
        for device in devices {
            guard fresh.devices.contains(device), fresh.owners[device.udid, default: []].isEmpty, !device.previews else { continue }
            let result = shell("/usr/bin/xcrun", ["simctl", "shutdown", device.udid], timeout: 60)
            let time = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .short)
            if result.status == 0 {
                stopped = true
                record("\(time) \(device.name) 종료: \(reason)")
                notify(title: "\(device.name) 시뮬레이터를 종료했습니다", body: "\(reason). 기기와 그 안의 데이터는 그대로이고, 다시 켜면 됩니다.")
            } else {
                record("\(time) \(device.name) 종료 실패: \(result.output.trimmingCharacters(in: .whitespacesAndNewlines).prefix(120))")
            }
        }
        return stopped
    }

    /// The menu's "shut down now": every booted default-set device that nobody uses, whatever its idle time.
    func shutDownUnowned() {
        queue.async { [weak self] in
            guard let self else { return }
            let current = self.read(previous: self.snapshot)
            _ = self.shutDown(current.unowned, reason: "메뉴에서 쓰는 곳 없는 기기 종료를 골랐습니다", after: current)
            self.tick()
        }
    }

    private func record(_ event: String) {
        lock.lock(); events.insert(event, at: 0); events = Array(events.prefix(5)); lock.unlock()
        NSLog("mac-cu simulator budget: \(event)")
    }

    private func notify(title: String, body: String) {
        // Outside the app bundle (a bare copy of the program) there is no notification center.
        guard Bundle.main.bundleIdentifier != nil else { return }
        let center = UNUserNotificationCenter.current()
        let send = {
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
        }
        guard !askedNotifications else { send(); return }
        askedNotifications = true
        center.delegate = self
        // Refused or unanswered: the menu bar still shows the warning and the menu the shutdowns.
        center.requestAuthorization(options: [.alert]) { _, _ in send() }
    }

    /// mac-cu is a menu bar app: show its notifications also while one of its windows is in front.
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list])
    }
}
