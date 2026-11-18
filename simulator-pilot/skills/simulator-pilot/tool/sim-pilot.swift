// sim-pilot: KakaoTalk 앱의 시뮬레이터 실행·로그와 테스트 사진 넣기. Xcode(xcrun simctl, swiftc)만 쓴다.
//
// 빌드: swiftc -O sim-pilot.swift -o ~/.local/bin/sim-pilot
//
//   sim-pilot devices                                   부팅된 시뮬레이터 (JSON)
//   sim-pilot schemes --udid U [--project-root DIR]     스킴별 설치·빌드 상태 (JSON)
//   sim-pilot launch --udid U --scheme S [--build | --reinstall]
//                                                       필요하면 빌드·설치하고 앱을 다시 실행
//   sim-pilot logs --udid U --scheme S [--filter K] [--seconds N] [--debug]
//                                                       os_log 스트림 (앱은 그대로 둔다)
//   sim-pilot console --udid U --scheme S [--filter K] [--seconds N]
//                                                       앱을 다시 실행하고 stdout·stderr를 본다 (끝나면 앱 종료)
//   sim-pilot claim --udid U [--note 하는 일] [--force]  이 세션이 이 기기를 쓴다고 기록 (다른 세션이 쓰는 중이면 거절)
//   sim-pilot release --udid U [--to 세션] [--force]    기록을 지운다. --to: 기다리는 세션에 넘긴다
//   sim-pilot request --udid U [--note 이유]            다른 세션이 쓰는 기기를 기다린다고 남긴다 (그 세션의 다음 명령에 보인다)
//   sim-pilot decline --udid U [--from 세션] [--note 답] 내 기기에 온 요청을 거절한다
//   sim-pilot requests                                  내게 온 요청과 내가 남긴 요청 (JSON)
//   sim-pilot sessions                                  mac-cu·sim-pilot을 쓰는 에이전트 세션과 각자 쓰는 기기 (JSON)
//   sim-pilot status                                    부팅된 기기마다 켜진 화면·방향과 사용 기록 (JSON, mac-cu 메뉴 막대와 같은 내용)
//   sim-pilot claims                                    기기별 사용 기록 (JSON, 꺼진 기기·끝난 세션은 지운다)
//   sim-pilot budget [--would-boot [--udid U] [--set default|previews]]
//                                                       동시에 켤 수 있는 대수, 켜진 기기와 쓰는 쪽 (JSON). --would-boot는 하나 더 켜도
//                                                       되는지 답한다: 되면 종료 코드 0, 꽉 찼으면 3
//   sim-pilot acquire (--udid U | --name N) [--note 하는 일] [--wait 초] [--force]
//                                                       기기를 쓴다: 켜져 있으면 그대로, 꺼져 있고 자리가 있으면 켜고 사용 기록을 남긴다.
//                                                       꽉 찼으면 3, 다른 세션이 쓰는 기기면 4
//   sim-pilot caps --udid U                             이 기기에서 되는 기기 동작(L1) 표 (capabilities와 화면 수로)
//   sim-pilot photos --udid U [--count N] [--width W] [--height H] [--seed S] [--grayscale] [--blur 1-10] [--yes]
//                                                       picsum.photos 사진을 사진 앱에 넣는다
//
// --scheme 대신 --bundle <번들 ID>로 다른 앱을 지정할 수 있다. Real 스킴(com.kakao.talk)은 --allow-real이 있어야 한다.

import Foundation

let version = "1.6.0"

let schemes: [(name: String, bundle: String)] = [
    ("Inhouse(iTeam)-Debug", "com.kakao.iPart.Talk"),
    ("Sandbox(iTeam)", "com.kakao.iPart.sandbox.Talk"),
    ("Real", "com.kakao.talk"),
    ("Alpha(iTeam)", "com.kakao.iPart.alpha.Talk"),
    ("Beta(CI)", "com.kakao.iPart.beta.Talk"),
]
let realBundle = "com.kakao.talk"

// MARK: - 공통

struct Failure: Error { let message: String }

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(("sim-pilot: " + message + "\n").data(using: .utf8)!)
    exit(1)
}

func printJSON(_ object: Any) {
    let data = try! JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    print(String(data: data, encoding: .utf8)!)
}

@discardableResult
func run(_ arguments: [String], directory: String? = nil, environment: [String: String] = [:]) -> (status: Int32, output: String, error: String) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
    process.arguments = arguments
    if let directory { process.currentDirectoryURL = URL(fileURLWithPath: directory) }
    if !environment.isEmpty { process.environment = ProcessInfo.processInfo.environment.merging(environment) { $1 } }
    let out = Pipe(), err = Pipe()
    process.standardOutput = out
    process.standardError = err
    do { try process.run() } catch { return (127, "", "\(error)") }
    let outData = out.fileHandleForReading.readDataToEndOfFile()
    let errData = err.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return (process.terminationStatus, String(decoding: outData, as: UTF8.self), String(decoding: errData, as: UTF8.self))
}

/// 인자: --key value, --flag
struct Options {
    var values: [String: String] = [:]
    var flags: Set<String> = []

    init(_ arguments: ArraySlice<String>, flags known: Set<String>) {
        var rest = arguments.makeIterator()
        while let argument = rest.next() {
            guard argument.hasPrefix("--") else { fail("알 수 없는 인자: \(argument)") }
            let key = String(argument.dropFirst(2))
            if known.contains(key) { flags.insert(key); continue }
            guard let value = rest.next() else { fail("\(argument)에 값이 필요합니다.") }
            values[key] = value
        }
    }

    func require(_ key: String) -> String {
        guard let value = values[key], !value.isEmpty else { fail("--\(key)가 필요합니다.") }
        return value
    }

    func int(_ key: String, default value: Int) -> Int {
        guard let text = values[key] else { return value }
        guard let number = Int(text) else { fail("--\(key)는 정수여야 합니다: \(text)") }
        return number
    }
}

// MARK: - 시뮬레이터

struct Device { let udid: String; let name: String; let runtime: String }

func bootedDevices() -> [Device] {
    let result = run(["simctl", "list", "devices", "booted", "-j"])
    guard result.status == 0, let json = try? JSONSerialization.jsonObject(with: Data(result.output.utf8)) as? [String: Any],
          let byRuntime = json["devices"] as? [String: [[String: Any]]]
    else { fail("simctl이 시뮬레이터 목록을 주지 않았습니다: \(result.error)") }
    var devices: [Device] = []
    for (runtime, list) in byRuntime {
        let label = runtime.components(separatedBy: "SimRuntime.").last?.replacingOccurrences(of: "-", with: ".")
            .replacingOccurrences(of: "iOS.", with: "iOS ") ?? runtime
        for device in list where device["state"] as? String == "Booted" {
            devices.append(Device(udid: device["udid"] as? String ?? "", name: device["name"] as? String ?? "", runtime: label))
        }
    }
    return devices.sorted { $0.name < $1.name }
}

func bootedDevice(_ udid: String) -> Device {
    guard let device = bootedDevices().first(where: { $0.udid.caseInsensitiveCompare(udid) == .orderedSame }) else {
        fail("\(udid)는 부팅된 시뮬레이터가 아닙니다. sim-pilot devices로 확인하세요.")
    }
    return device
}

func isInstalled(_ udid: String, _ bundle: String) -> Bool {
    run(["simctl", "get_app_container", udid, bundle]).status == 0
}

/// DerivedData에서 그 스킴의 가장 최근 시뮬레이터 빌드. 앱 이름은 스킴마다 달라서(SandboxTalk.app 등) 번들 ID로 찾는다.
/// root 레포 사본에서 만든 빌드만 본다(다른 작업 사본·워크트리의 빌드를 설치하지 않게).
func builtApp(_ scheme: String, bundle: String, root: String) -> String? {
    let fm = FileManager.default
    let derived = fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Developer/Xcode/DerivedData")
    let projects = (try? fm.contentsOfDirectory(atPath: derived.path)) ?? []
    let rootPath = URL(fileURLWithPath: root).standardizedFileURL.resolvingSymlinksInPath().path
    var newest: (path: String, date: Date)?
    for project in projects where project.hasPrefix("Talk-") {
        guard let data = try? Data(contentsOf: derived.appendingPathComponent("\(project)/info.plist")),
              let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let workspace = info["WorkspacePath"] as? String,
              URL(fileURLWithPath: workspace).standardizedFileURL.resolvingSymlinksInPath().path.hasPrefix(rootPath + "/")
        else { continue }
        let products = derived.appendingPathComponent("\(project)/Build/Products/\(scheme)-iphonesimulator")
        for name in (try? fm.contentsOfDirectory(atPath: products.path)) ?? [] where name.hasSuffix(".app") {
            let app = products.appendingPathComponent(name)
            guard let data = try? Data(contentsOf: app.appendingPathComponent("Info.plist")),
                  let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
                  info["CFBundleIdentifier"] as? String == bundle,
                  let date = (try? fm.attributesOfItem(atPath: app.path))?[.modificationDate] as? Date
            else { continue }
            if newest == nil || date > newest!.date { newest = (app.path, date) }
        }
    }
    return newest?.path
}

/// --scheme 또는 --bundle로 정한 앱. Real은 --allow-real이 있어야 한다.
func target(_ options: Options) -> (scheme: String?, bundle: String) {
    if let bundle = options.values["bundle"] {
        if bundle == realBundle && !options.flags.contains("allow-real") { fail(realWarning) }
        return (schemes.first { $0.bundle == bundle }?.name, bundle)
    }
    let scheme = options.require("scheme")
    guard let bundle = schemes.first(where: { $0.name == scheme })?.bundle else {
        fail("알 수 없는 스킴: \(scheme). 스킴: \(schemes.map(\.name).joined(separator: ", ")). 다른 앱은 --bundle로 지정하세요.")
    }
    if bundle == realBundle && !options.flags.contains("allow-real") { fail(realWarning) }
    return (scheme, bundle)
}

let realWarning = """
    Real 스킴(com.kakao.talk)은 실서비스 앱이라 로그에 실제 계정 정보가 나올 수 있습니다. \
    사용자에게 확인을 받은 뒤 --allow-real을 붙이세요.
    """

/// 앱 실행 파일 이름(로그 스트림의 process 이름).
func executableName(_ udid: String, _ bundle: String) -> String? {
    let container = run(["simctl", "get_app_container", udid, bundle, "app"])
    guard container.status == 0 else { return nil }
    let plist = URL(fileURLWithPath: container.output.trimmingCharacters(in: .whitespacesAndNewlines)).appendingPathComponent("Info.plist")
    guard let data = try? Data(contentsOf: plist),
          let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
    else { return nil }
    return info["CFBundleExecutable"] as? String
}

func projectRoot(_ options: Options) -> String {
    let root = options.values["project-root"] ?? FileManager.default.currentDirectoryPath
    guard FileManager.default.fileExists(atPath: root + "/Scripts/build.sh") else {
        fail("\(root)에 Scripts/build.sh가 없습니다. KakaoTalk 레포 루트를 --project-root로 지정하세요.")
    }
    return root
}

/// 필요하면(또는 --build면) 빌드하고, 설치돼 있지 않거나 새로 빌드했으면 설치한다.
/// --reinstall은 빌드하지 않고 DerivedData의 최신 빌드를 다시 설치한다.
func ensureInstalled(_ device: Device, scheme: String?, bundle: String, options: Options) {
    let force = options.flags.contains("build")
    if !force && !options.flags.contains("reinstall") && isInstalled(device.udid, bundle) { return }
    guard let scheme else { fail("\(bundle)이 \(device.name)에 설치돼 있지 않습니다. 스킴 앱이 아니면 직접 설치하세요.") }
    let root = projectRoot(options)
    var app = force ? nil : builtApp(scheme, bundle: bundle, root: root)
    if app == nil {
        print("[\(scheme)] ./Scripts/build.sh로 빌드합니다 (수 분 걸릴 수 있음)…")
        let build = Process()
        build.executableURL = URL(fileURLWithPath: root + "/Scripts/build.sh")
        build.arguments = [scheme]
        build.currentDirectoryURL = URL(fileURLWithPath: root)
        do { try build.run() } catch { fail("빌드를 시작하지 못했습니다: \(error)") }
        build.waitUntilExit()
        guard build.terminationStatus == 0 else { fail("빌드가 실패했습니다(종료 코드 \(build.terminationStatus)).") }
        app = builtApp(scheme, bundle: bundle, root: root)
        guard app != nil else { fail("빌드 결과물(\(scheme)-iphonesimulator, \(bundle))을 DerivedData에서 찾지 못했습니다.") }
    }
    print("[\(scheme)] \(device.name)에 설치합니다…")
    let install = run(["simctl", "install", device.udid, app!])
    guard install.status == 0 else { fail("설치가 실패했습니다: \(install.error)") }
}

// MARK: - 스트림

/// 줄 단위로 읽어 filter가 들어간 줄만 출력하고, seconds가 지나면 끝낸다.
func stream(_ arguments: [String], filter: String?, seconds: Int, environment: [String: String] = [:], onEnd: () -> Void = {}) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
    process.arguments = arguments
    if !environment.isEmpty { process.environment = ProcessInfo.processInfo.environment.merging(environment) { $1 } }
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    var buffer = Data()
    let lock = NSLock()
    pipe.fileHandleForReading.readabilityHandler = { handle in
        let chunk = handle.availableData
        lock.lock(); defer { lock.unlock() }
        buffer.append(chunk)
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = String(decoding: buffer[buffer.startIndex..<newline], as: UTF8.self)
            buffer.removeSubrange(buffer.startIndex...newline)
            if line.hasPrefix("getpwuid_r did not find") { continue }  // log stream이 시뮬레이터에서 늘 내는 잡음
            if let filter, !line.localizedCaseInsensitiveContains(filter) { continue }
            print(line)
            fflush(stdout)
        }
    }
    signal(SIGINT, SIG_IGN)
    let interrupt = DispatchSource.makeSignalSource(signal: SIGINT)
    interrupt.setEventHandler { process.terminate() }
    interrupt.resume()
    do { try process.run() } catch { fail("\(arguments.joined(separator: " ")) 실행 실패: \(error)") }
    if seconds > 0 {
        DispatchQueue.global().asyncAfter(deadline: .now() + .seconds(seconds)) { if process.isRunning { process.terminate() } }
    }
    process.waitUntilExit()
    pipe.fileHandleForReading.readabilityHandler = nil
    onEnd()
}

// MARK: - 명령

func devicesCommand() {
    let state = store.state(booted: bootedSet())
    printJSON(bootedDevices().map { device -> [String: Any] in
        var row: [String: Any] = ["udid": device.udid, "name": device.name, "runtime": device.runtime]
        if let claim = state.claims[device.udid.uppercased()] { row.merge(claimRow(claim, state.requests.filter { $0.udid == device.udid.uppercased() })) { _, new in new } }
        return row
    })
}

// MARK: - 기기 사용 기록과 세션 협업
//
// 같은 Mac의 여러 에이전트 세션(Claude Code·Codex)이 시뮬레이터를 함께 쓴다. 한 세션이 기기를 끄거나 접거나 설정을 바꾸면
// 다른 세션의 작업이 깨지므로, 쓰는 세션이 누구인지(에이전트·프로젝트·세션)와 함께 기록을 남기고, 다른 세션은 바꾸기 전에
// 그 기록을 본다. 남이 쓰는 기기가 필요하면 요청을 남기고, 쓰던 세션이 놓거나 넘겨준다. mac-cu도 같은 파일을 읽고 쓴다.

// BEGIN simulator-collab-core

/// Who an agent session is: recorded with each device it uses, so that other sessions and the person see which agent
/// of which project holds a simulator.
struct AgentIdentity: Equatable {
    /// "Claude Code", "Codex", or the app that runs the agent.
    var agent: String
    /// The agent's own session id, or "pid N" when the environment gives none.
    var session: String
    /// The folder name of the project, "" when unknown.
    var project: String
    /// The T3 thread, "" outside T3.
    var thread: String
    /// The process of the session: while it runs, its records count.
    var pid: Int32

    var label: String { project.isEmpty ? agent : "\(agent) · \(project)" }
    /// The same session: by its id, or by its process. An agent can give a new id to a session that goes on (after
    /// its context is cleared), and tools it started earlier still carry the old one.
    func isSame(_ other: AgentIdentity) -> Bool { other.session == session || other.pid == pid }
    func owns(_ claim: DeviceClaim) -> Bool { claim.by == session || claim.pid == pid }
    var json: [String: Any] { ["agent": agent, "session": session, "project": project, "thread": thread, "pid": Int(pid)] }

    init(agent: String, session: String, project: String = "", thread: String = "", pid: Int32) {
        self.agent = agent; self.session = session; self.project = project; self.thread = thread; self.pid = pid
    }

    init?(json: [String: Any]) {
        guard let session = json["session"] as? String, !session.isEmpty,
              let pid = (json["pid"] as? NSNumber)?.int32Value, pid > 0 else { return nil }
        self.init(agent: json["agent"] as? String ?? "?", session: session, project: json["project"] as? String ?? "",
                  thread: json["thread"] as? String ?? "", pid: pid)
    }

    /// From the environment of a process that the agent started. `parent`: the process that started it.
    /// `fallbackAgent`: the app that runs the agent, when the environment names no agent.
    static func detect(environment env: [String: String], directory: String, parent: Int32, fallbackAgent: String? = nil) -> AgentIdentity {
        let claude = env["CLAUDECODE"] != nil || env.keys.contains { $0.hasPrefix("CLAUDE_CODE_") }
        let codex = env.keys.contains { $0.hasPrefix("CODEX_") }
        let session = ["CLAUDE_CODE_HOST_SESSION_ID", "CLAUDE_CODE_SESSION_ID", "CODEX_SESSION_ID", "CODEX_THREAD_ID"]
            .lazy.compactMap { env[$0] }.first { !$0.isEmpty } ?? "pid \(parent)"
        return AgentIdentity(agent: claude ? "Claude Code" : codex ? "Codex" : fallbackAgent ?? "terminal", session: session,
                             project: collaborationProjectName(env["CLAUDE_PROJECT_DIR"] ?? directory),
                             thread: env["T3CODE_THREAD_ID"] ?? "", pid: Int32(env["CLAUDE_PID"] ?? "") ?? parent)
    }
}

/// The project a folder belongs to: the name of the nearest folder with .git at or above it, else of the folder.
/// "" for the home folder and the root, which are not projects.
func collaborationProjectName(_ directory: String) -> String {
    let start = URL(fileURLWithPath: directory).standardizedFileURL
    let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
    var url = start
    for _ in 0..<32 where url.path != "/" && url.path != home {
        if FileManager.default.fileExists(atPath: url.appendingPathComponent(".git").path) { return url.lastPathComponent }
        url = url.deletingLastPathComponent()
    }
    return start.path == "/" || start.path == home ? "" : start.lastPathComponent
}

func collaborationStamp(_ date: Date) -> String { ISO8601DateFormatter().string(from: date) }
func collaborationDate(_ text: String) -> Date? { ISO8601DateFormatter().date(from: text) }
func collaborationProcessAlive(_ pid: Int32) -> Bool { pid > 0 && (kill(pid, 0) == 0 || errno == EPERM) }

/// One record of claims.json. The first four fields are the format of sim-pilot 1.5 and earlier.
struct DeviceClaim: Equatable {
    var by: String
    var note: String
    var pid: Int32
    var since: String
    var agent = ""
    var project = ""
    var thread = ""
    /// mac-cu wrote it when the session sent input to the device, without `sim-pilot claim`: it lapses when unused.
    var auto = false
    var lastUsed = ""

    init(identity: AgentIdentity, note: String, auto: Bool, now: Date) {
        by = identity.session; self.note = note; pid = identity.pid; since = collaborationStamp(now)
        agent = identity.agent; project = identity.project; thread = identity.thread; self.auto = auto; lastUsed = since
    }

    init?(json: [String: Any]) {
        guard let by = json["by"] as? String, let pid = (json["pid"] as? NSNumber)?.int32Value else { return nil }
        self.by = by; self.pid = pid
        note = json["note"] as? String ?? ""; since = json["since"] as? String ?? ""
        agent = json["agent"] as? String ?? ""; project = json["project"] as? String ?? ""; thread = json["thread"] as? String ?? ""
        auto = json["auto"] as? Bool ?? false; lastUsed = json["lastUsed"] as? String ?? since
    }

    var json: [String: Any] {
        ["by": by, "note": note, "pid": Int(pid), "since": since, "agent": agent, "project": project, "thread": thread,
         "auto": auto, "lastUsed": lastUsed]
    }

    /// The agent and project, or the session id of a record without them.
    var who: String { agent.isEmpty ? by : project.isEmpty ? agent : "\(agent) · \(project)" }
    /// "Claude Code · Cards · 로그인 확인"; a record of an older sim-pilot shows its note, else its session id.
    var label: String { note.isEmpty ? who : agent.isEmpty ? note : "\(who) · \(note)" }
}

/// A session that waits for a device another session holds.
struct DeviceRequest: Equatable {
    var udid: String
    var from: AgentIdentity
    var note: String
    var at: String
    /// The holder's answer when it refused, "" while it has not.
    var declined = ""

    init(udid: String, from: AgentIdentity, note: String, now: Date) {
        self.udid = udid.uppercased(); self.from = from; self.note = note; at = collaborationStamp(now)
    }

    init?(json: [String: Any]) {
        guard let udid = json["udid"] as? String, let from = (json["from"] as? [String: Any]).flatMap(AgentIdentity.init(json:)) else { return nil }
        self.udid = udid.uppercased(); self.from = from
        note = json["note"] as? String ?? ""; at = json["at"] as? String ?? ""
        declined = json["declined"] as? String ?? ""
    }

    var json: [String: Any] { ["udid": udid, "from": from.json, "note": note, "at": at, "declined": declined] }
    var label: String { note.isEmpty ? from.label : "\(from.label) · \(note)" }
}

/// A claim that mac-cu wrote lapses this long after the session's last input.
let collaborationAutoClaimIdle: TimeInterval = 30 * 60
/// A request lapses this long after it was made.
let collaborationRequestLifetime: TimeInterval = 30 * 60
/// Times in the files are rewritten at most this often.
let collaborationTouchInterval: TimeInterval = 60

/// The claims that still count: of a running session, of a booted device (`booted` nil: not checked), and used
/// lately when mac-cu wrote them.
func liveClaims(_ all: [String: DeviceClaim], booted: Set<String>?, alive: (Int32) -> Bool, now: Date) -> [String: DeviceClaim] {
    all.filter { udid, claim in
        if let booted, !booted.contains(udid) { return false }
        if claim.auto, let used = collaborationDate(claim.lastUsed), now.timeIntervalSince(used) > collaborationAutoClaimIdle { return false }
        return alive(claim.pid)
    }
}

/// The requests that still count: the requester runs, it asked lately, and another session still holds the device.
func liveRequests(_ all: [DeviceRequest], claims: [String: DeviceClaim], alive: (Int32) -> Bool, now: Date) -> [DeviceRequest] {
    all.filter { request in
        guard alive(request.from.pid), let holder = claims[request.udid], !request.from.owns(holder) else { return false }
        guard let asked = collaborationDate(request.at) else { return false }
        return now.timeIntervalSince(asked) <= collaborationRequestLifetime
    }
}

/// A session sent input to a device. Without a claim the device becomes the session's (an automatic claim); its own
/// claim gets the time. Returns the other session that holds the device, when one does, and whether `claims` changed.
func recordSimulatorUse(_ claims: inout [String: DeviceClaim], udid: String, identity: AgentIdentity, now: Date) -> (holder: DeviceClaim?, changed: Bool) {
    let key = udid.uppercased()
    guard var claim = claims[key] else {
        claims[key] = DeviceClaim(identity: identity, note: "", auto: true, now: now)
        return (nil, true)
    }
    guard identity.owns(claim) else { return (claim, false) }
    if let used = collaborationDate(claim.lastUsed), now.timeIntervalSince(used) < collaborationTouchInterval { return (nil, false) }
    claim.lastUsed = collaborationStamp(now)
    claims[key] = claim
    return (nil, true)
}

/// Notes that a session used mac-cu or sim-pilot (`via`). True when `sessions` changed. A session is one record,
/// under the id it was first seen with; `session` in the record is the id it gave last.
func touchSession(_ sessions: inout [String: [String: Any]], identity: AgentIdentity, via: String, now: Date) -> Bool {
    let key = sessions[identity.session] != nil ? identity.session
        : sessions.first { ($0.value["pid"] as? NSNumber)?.int32Value == identity.pid }?.key ?? identity.session
    var entry = sessions[key] ?? ["firstSeen": collaborationStamp(now)]
    var tools = entry["via"] as? [String] ?? []
    if tools.contains(via), let seen = (entry["lastSeen"] as? String).flatMap(collaborationDate),
       now.timeIntervalSince(seen) < collaborationTouchInterval { return false }
    if !tools.contains(via) { tools.append(via) }
    entry.merge(identity.json) { _, new in new }
    entry["via"] = tools.sorted()
    entry["lastSeen"] = collaborationStamp(now)
    sessions[key] = entry
    return true
}

/// The three files and their lock.
struct CollaborationStore {
    let folder: URL

    /// ~/Library/Application Support/sim-pilot, or SIM_PILOT_STATE_DIR (the checks).
    static var standard: CollaborationStore {
        if let path = ProcessInfo.processInfo.environment["SIM_PILOT_STATE_DIR"], !path.isEmpty { return CollaborationStore(folder: URL(fileURLWithPath: path)) }
        return CollaborationStore(folder: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/sim-pilot"))
    }

    private func read(_ name: String) -> Any? {
        (try? Data(contentsOf: folder.appendingPathComponent(name))).flatMap { try? JSONSerialization.jsonObject(with: $0) }
    }

    private func write(_ name: String, _ object: Any) {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]) else { return }
        try? data.write(to: folder.appendingPathComponent(name), options: .atomic)
    }

    /// One reader-writer at a time, across mac-cu and sim-pilot.
    func locked<T>(_ body: () throws -> T) rethrows -> T {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let descriptor = open(folder.appendingPathComponent("state.lock").path, O_CREAT | O_RDWR, 0o644)
        guard descriptor >= 0 else { return try body() }
        defer { flock(descriptor, LOCK_UN); close(descriptor) }
        flock(descriptor, LOCK_EX)
        return try body()
    }

    private func storedClaims() -> [String: DeviceClaim] {
        var claims: [String: DeviceClaim] = [:]
        for (udid, value) in read("claims.json") as? [String: [String: Any]] ?? [:] { claims[udid.uppercased()] = DeviceClaim(json: value) }
        return claims
    }

    private func storedRequests() -> [DeviceRequest] { (read("requests.json") as? [[String: Any]] ?? []).compactMap(DeviceRequest.init(json:)) }

    /// Reads the live claims and requests, lets `body` change them, and writes what changed.
    func update<T>(booted: Set<String>? = nil, now: Date = Date(), alive: (Int32) -> Bool = collaborationProcessAlive,
                   _ body: (inout [String: DeviceClaim], inout [DeviceRequest]) throws -> T) rethrows -> T {
        try locked {
            let oldClaims = storedClaims(), oldRequests = storedRequests()
            var claims = liveClaims(oldClaims, booted: booted, alive: alive, now: now)
            var requests = liveRequests(oldRequests, claims: claims, alive: alive, now: now)
            let result = try body(&claims, &requests)
            requests = liveRequests(requests, claims: claims, alive: alive, now: now)
            if claims != oldClaims { write("claims.json", claims.mapValues(\.json)) }
            if requests != oldRequests { write("requests.json", requests.map(\.json)) }
            return result
        }
    }

    func state(booted: Set<String>? = nil, now: Date = Date()) -> (claims: [String: DeviceClaim], requests: [DeviceRequest]) {
        update(booted: booted, now: now) { claims, requests in (claims, requests) }
    }

    /// The sessions that still run, after noting `identity` (nil: only read).
    @discardableResult
    func sessions(seen identity: AgentIdentity? = nil, via: String = "", now: Date = Date(),
                  alive: (Int32) -> Bool = collaborationProcessAlive) -> [String: [String: Any]] {
        locked {
            let stored = read("sessions.json") as? [String: [String: Any]] ?? [:]
            var sessions = stored.filter { alive(($0.value["pid"] as? NSNumber)?.int32Value ?? 0) }
            var changed = sessions.count != stored.count
            if let identity, touchSession(&sessions, identity: identity, via: via, now: now) { changed = true }
            if changed { write("sessions.json", sessions) }
            return sessions
        }
    }
}

// END simulator-collab-core

let store = CollaborationStore.standard
/// The session that runs this command.
let me = AgentIdentity.detect(environment: ProcessInfo.processInfo.environment,
                              directory: FileManager.default.currentDirectoryPath, parent: getppid())

func bootedSet() -> Set<String> { Set(bootedDevices().map { $0.udid.uppercased() }) }

/// The claims of booted devices whose session still runs. Others are dropped.
func loadClaims() -> [String: DeviceClaim] { store.state(booted: bootedSet()).claims }

/// The fields a device row gets from its claim.
func claimRow(_ claim: DeviceClaim, _ requests: [DeviceRequest]) -> [String: Any] {
    var row: [String: Any] = ["claimed_by": claim.label, "since": claim.since, "mine": me.owns(claim), "session": claim.by]
    if !claim.agent.isEmpty { row["agent"] = claim.agent }
    if !claim.project.isEmpty { row["project"] = claim.project }
    if claim.auto { row["auto"] = true }
    let waiting = requests.filter { $0.declined.isEmpty }.map(\.label)
    if !waiting.isEmpty { row["requested_by"] = waiting }
    return row
}

func warn(_ message: String) { FileHandle.standardError.write(("sim-pilot: " + message + "\n").data(using: .utf8)!) }

func claimCommand(_ options: Options) {
    let device = bootedDevice(options.require("udid"))
    let udid = device.udid.uppercased(), force = options.flags.contains("force")
    let other: DeviceClaim? = store.update(booted: bootedSet()) { claims, _ in
        if let held = claims[udid], !me.owns(held), !force { return held }
        var claim = claims[udid].flatMap { me.owns($0) ? $0 : nil } ?? DeviceClaim(identity: me, note: "", auto: false, now: Date())
        claim.by = me.session
        claim.auto = false
        claim.lastUsed = collaborationStamp(Date())
        if let note = options.values["note"] { claim.note = note }
        claims[udid] = claim
        return nil
    }
    if let other {
        fail("\(device.name)는 다른 세션이 쓰는 중입니다(\(other.label), \(other.since)부터). 기다리려면 sim-pilot request --udid \(udid) --note \"<이유>\"로 요청을 남기고, 사용자가 함께 써도 된다고 하면 --force를 붙입니다.")
    }
    print("\(device.name)를 이 세션(\(me.label))이 쓴다고 기록했습니다. 끝나면 sim-pilot release --udid \(device.udid)")
}

func releaseCommand(_ options: Options) {
    let udid = options.require("udid").uppercased(), force = options.flags.contains("force"), to = options.values["to"]
    enum Outcome { case none, other(DeviceClaim), noRequest, handed(DeviceRequest), released([DeviceRequest]) }
    let outcome: Outcome = store.update(booted: bootedSet()) { claims, requests in
        guard let claim = claims[udid] else { return .none }
        guard me.owns(claim) || force else { return .other(claim) }
        let waiting = requests.filter { $0.udid == udid && $0.declined.isEmpty }
        if let to {
            let matches = waiting.filter { $0.from.session == to || $0.from.session.hasPrefix(to) }
            guard matches.count == 1 else { return .noRequest }
            claims[udid] = DeviceClaim(identity: matches[0].from, note: matches[0].note, auto: false, now: Date())
            return .handed(matches[0])
        }
        claims[udid] = nil
        return .released(waiting)
    }
    switch outcome {
    case .none: print("기록이 없습니다.")
    case .other(let claim): fail("다른 세션의 기록입니다(\(claim.label)). 지우려면 사용자에게 묻고 --force를 붙입니다.")
    case .noRequest: fail("그 세션이 남긴 요청이 없습니다(--to \(to ?? "")). sim-pilot requests로 기다리는 세션을 확인하세요.")
    case .handed(let request): print("기기를 \(request.label)에 넘겼습니다. 이 세션은 이제 이 기기를 바꾸지 않습니다.")
    case .released(let waiting):
        print("기록을 지웠습니다." + (waiting.isEmpty ? "" : " 기다리던 세션: " + waiting.map(\.label).joined(separator: ", ")))
    }
}

/// The holder of a booted device, as JSON for the requester.
func holderJSON(_ claim: DeviceClaim) -> [String: Any] {
    ["label": claim.label, "agent": claim.agent, "project": claim.project, "session": claim.by, "note": claim.note, "since": claim.since, "auto": claim.auto]
}

func requestCommand(_ options: Options) {
    let device = bootedDevice(options.require("udid"))
    let udid = device.udid.uppercased()
    let holder: DeviceClaim? = store.update(booted: bootedSet()) { claims, requests in
        guard let claim = claims[udid], !me.owns(claim) else { return claims[udid] }
        requests.removeAll { $0.udid == udid && $0.from.isSame(me) }
        requests.append(DeviceRequest(udid: udid, from: me, note: options.values["note"] ?? "", now: Date()))
        return claim
    }
    guard let holder else {
        printJSON(["requested": false, "reason": "free", "udid": udid, "name": device.name])
        warn("\(device.name)는 쓰는 세션이 없습니다. sim-pilot acquire --udid \(udid) --note \"<할 일>\"로 바로 쓰면 됩니다.")
        return
    }
    guard !me.owns(holder) else { printJSON(["requested": false, "reason": "mine", "udid": udid, "name": device.name]); return }
    printJSON(["requested": true, "udid": udid, "name": device.name, "holder": holderJSON(holder)])
    warn("요청을 남겼습니다. \(holder.who) 세션의 다음 sim-pilot·mac-cu 호출에 보입니다. 놓을 때까지 기다리려면 sim-pilot acquire --udid \(udid) --wait <초>, 답은 sim-pilot requests로 봅니다.")
}

func declineCommand(_ options: Options) {
    let udid = options.require("udid").uppercased(), from = options.values["from"]
    let answer = options.values["note"] ?? "지금은 넘겨줄 수 없습니다"
    let result: (holder: DeviceClaim?, count: Int) = store.update(booted: bootedSet()) { claims, requests in
        guard let claim = claims[udid], me.owns(claim) || options.flags.contains("force") else { return (claims[udid], -1) }
        var count = 0
        for index in requests.indices where requests[index].udid == udid && requests[index].declined.isEmpty {
            if let from, requests[index].from.session != from, !requests[index].from.session.hasPrefix(from) { continue }
            requests[index].declined = answer
            count += 1
        }
        return (claim, count)
    }
    if result.count < 0 { fail(result.holder.map { "다른 세션의 기기입니다(\($0.label)). 요청은 기기를 쓰는 세션이 답합니다." } ?? "이 기기에는 사용 기록이 없습니다.") }
    print(result.count == 0 ? "답할 요청이 없습니다." : "요청 \(result.count)건을 거절했습니다: \(answer)")
}

func requestJSON(_ request: DeviceRequest, _ claims: [String: DeviceClaim], _ names: [String: String]) -> [String: Any] {
    var row: [String: Any] = ["udid": request.udid, "name": names[request.udid] ?? "?", "from": request.from.json, "label": request.label,
                              "note": request.note, "at": request.at, "status": request.declined.isEmpty ? "waiting" : "declined"]
    if !request.declined.isEmpty { row["answer"] = request.declined }
    if let holder = claims[request.udid] { row["holder"] = holderJSON(holder) }
    return row
}

func requestsCommand() {
    let state = store.state(booted: bootedSet())
    let names = Dictionary(bootedDevices().map { ($0.udid.uppercased(), $0.name) }, uniquingKeysWith: { a, _ in a })
    printJSON(["incoming": state.requests.filter { state.claims[$0.udid].map(me.owns) ?? false }.map { requestJSON($0, state.claims, names) },
               "outgoing": state.requests.filter { $0.from.isSame(me) }.map { requestJSON($0, state.claims, names) }])
}

func sessionsCommand() {
    let state = store.state(booted: bootedSet())
    let names = Dictionary(bootedDevices().map { ($0.udid.uppercased(), $0.name) }, uniquingKeysWith: { a, _ in a })
    var sessions = store.sessions()
    // A session of an older sim-pilot has a claim and no session record.
    for claim in state.claims.values where !sessions.values.contains(where: { $0["session"] as? String == claim.by || ($0["pid"] as? NSNumber)?.int32Value == claim.pid }) {
        sessions[claim.by] = ["agent": claim.agent.isEmpty ? "?" : claim.agent, "session": claim.by, "project": claim.project,
                              "thread": claim.thread, "pid": Int(claim.pid), "via": ["sim-pilot"], "firstSeen": claim.since, "lastSeen": claim.lastUsed]
    }
    printJSON(sessions.values.sorted { ($0["lastSeen"] as? String ?? "") > ($1["lastSeen"] as? String ?? "") }.map { session -> [String: Any] in
        var row = session
        let who = AgentIdentity(json: session) ?? AgentIdentity(agent: "?", session: session["session"] as? String ?? "", pid: 0)
        row["mine"] = who.isSame(me)
        row["devices"] = state.claims.filter { who.owns($0.value) }.sorted { $0.key < $1.key }.map { udid, claim -> [String: Any] in
            ["udid": udid, "name": names[udid] ?? "?", "note": claim.note, "since": claim.since, "lastUsed": claim.lastUsed, "auto": claim.auto]
        }
        row["waitingFor"] = state.requests.filter { $0.from.isSame(who) && $0.declined.isEmpty }.map(\.udid)
        return row
    })
}

/// Tells the session that holds a device that another session waits for it. On stderr, so that JSON output stays whole.
func noteIncomingRequests() {
    let state = store.state()
    for request in state.requests where request.declined.isEmpty && (state.claims[request.udid].map(me.owns) ?? false) {
        warn("요청: \(request.label) 세션이 이 세션이 쓰는 기기 \(request.udid)를 기다립니다. 다 썼으면 sim-pilot release --udid \(request.udid) "
             + "(바로 넘기려면 --to \(request.from.session)), 계속 써야 하면 sim-pilot decline --udid \(request.udid) --note \"<언제까지>\".")
    }
}

// MARK: - 동시에 켜는 대수 제한
//
// 켜진 시뮬레이터는 한 대에 메모리 약 2GiB를 쓰고, 넘치는 만큼은 시동 디스크의 스왑으로 간다. 제한은
// ~/Library/Application Support/sim-pilot/budget.json(mac-cu 메뉴 막대에서 바꾼다)에서 읽고, 없으면 메모리와 디스크에 맞춘다.
// 아래 구간은 mac-computer-use의 mac-cu-src/SimulatorBudget.swift와 같은 글이다(scripts/tests가 다르면 실패한다).

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

/// Every device of a set with its state. The Previews set is Xcode's; a Mac without it has none.
func simctlDevices(previews: Bool) -> [(device: BudgetSimulator, booted: Bool)] {
    let result = run(["simctl"] + (previews ? ["--set", "previews"] : []) + ["list", "devices", "-j"])
    guard result.status == 0, let json = try? JSONSerialization.jsonObject(with: Data(result.output.utf8)) as? [String: Any],
          let byRuntime = json["devices"] as? [String: [[String: Any]]] else {
        if previews { return [] }
        fail("simctl이 시뮬레이터 목록을 주지 않았습니다: \(result.error)")
    }
    var devices: [(BudgetSimulator, Bool)] = []
    for (runtime, list) in byRuntime {
        let label = runtime.components(separatedBy: "SimRuntime.").last?.replacingOccurrences(of: "-", with: ".")
            .replacingOccurrences(of: "iOS.", with: "iOS ") ?? runtime
        for device in list where device["isAvailable"] as? Bool ?? true {
            devices.append((BudgetSimulator(udid: (device["udid"] as? String ?? "").uppercased(), name: device["name"] as? String ?? "",
                                            runtime: label, previews: previews), device["state"] as? String == "Booted"))
        }
    }
    return devices.sorted { ($0.0.name, $0.0.runtime, $0.0.udid) < ($1.0.name, $1.0.runtime, $1.0.udid) }
}

struct BudgetState {
    let config: SimulatorBudgetConfig
    let limits: SimulatorBudgetLimits
    /// Every device of both sets; `booted` are the ones that count.
    let all: [(device: BudgetSimulator, booted: Bool)]
    let booted: [BudgetSimulator]
    let owners: [String: [SimulatorOwner]]
    /// The devices this session uses: its claim, or a tool it started.
    let mine: Set<String>
    let unreadableClaims: Int
    var count: SimulatorBudgetCount { SimulatorBudgetCount(booted) }
}

func budgetState() -> BudgetState {
    let config = SimulatorBudgetConfig.load()
    let all = simctlDevices(previews: false) + simctlDevices(previews: true)
    let booted = all.filter(\.booted).map(\.device)
    let processes = readBudgetProcesses()
    let use = simulatorProcessUse(udids: booted.map(\.udid), processes: processes,
                                  ignoring: budgetProcessAncestors(of: getpid(), in: processes))
    let agents = readAgentDeviceOwners()
    var owners: [String: [SimulatorOwner]] = [:], mine: Set<String> = []
    for (udid, claim) in loadClaims() {
        owners[udid, default: []].append(SimulatorOwner(kind: claim.auto ? "mac-cu" : "sim-pilot", by: claim.label, pid: claim.pid))
        if me.owns(claim) { mine.insert(udid) }
    }
    // The checks run two sessions against a device that other tools of this Mac may use: with this set, only the
    // records count, so that a wait can end. Nothing is sent to the device either way.
    let recordsOnly = ProcessInfo.processInfo.environment["SIM_PILOT_CHECK_RECORDS_ONLY"] != nil
    for device in booted where !recordsOnly {
        owners[device.udid, default: []] += agents.owners[device.udid] ?? []
        let tools = use[device.udid]?.owners ?? []
        owners[device.udid, default: []] += tools
        if tools.contains(where: { budgetProcessAncestors(of: $0.pid, in: processes).contains(me.pid) }) { mine.insert(device.udid) }
    }
    return BudgetState(config: config, limits: currentSimulatorBudgetLimits(config), all: all, booted: booted, owners: owners,
                       mine: mine, unreadableClaims: agents.unreadable)
}

func budgetJSON(_ state: BudgetState) -> [String: Any] {
    let count = state.count
    var json: [String: Any] = [
        "configured": FileManager.default.fileExists(atPath: SimulatorBudgetConfig.fileURL.path),
        "limit": ["total": state.limits.total, "defaultSet": state.limits.defaultSet, "mode": state.limits.automatic ? "auto" : "manual",
                  "automaticTotal": state.limits.automaticTotal, "memoryGiB": state.limits.memoryGiB,
                  "freeDiskGiB": state.limits.freeDiskGiB.map { $0 as Any } ?? NSNull()] as [String: Any],
        "autoShutdown": ["enabled": state.config.autoShutdown, "idleMinutes": state.config.idleMinutes] as [String: Any],
        "booted": ["total": count.total, "defaultSet": count.defaultSet, "previews": count.previews],
        "over": count.isOver(state.limits),
        "canBoot": ["default": count.fits(state.limits, previews: false), "previews": count.fits(state.limits, previews: true)],
        "devices": state.booted.map { device -> [String: Any] in
            let owners = state.owners[device.udid] ?? []
            return ["udid": device.udid, "name": device.name, "runtime": device.runtime, "set": device.previews ? "previews" : "default",
                    "owners": owners.map(\.json), "owned": !owners.isEmpty, "mine": state.mine.contains(device.udid)]
        },
    ]
    if state.unreadableClaims > 0 { json["unreadableAgentDeviceClaims"] = state.unreadableClaims }
    return json
}

/// Exit codes of budget --would-boot and acquire.
let exitBudgetFull: Int32 = 3, exitOwnedByOther: Int32 = 4

func budgetCommand(_ options: Options) {
    let state = budgetState()
    var json = budgetJSON(state)
    guard options.flags.contains("would-boot") else { printJSON(json); return }
    let udid = options.values["udid"]?.uppercased()
    let known = udid.flatMap { udid in state.all.first { $0.device.udid == udid } }
    if let set = options.values["set"], set != "default", set != "previews" { fail("--set은 default 또는 previews입니다: \(set)") }
    let previews = options.values["set"].map { $0 == "previews" } ?? known?.device.previews ?? false
    var would: [String: Any] = ["set": previews ? "previews" : "default"]
    if let udid { would["udid"] = udid }
    let allowed: Bool
    if known?.booted == true {
        allowed = true
        would["alreadyBooted"] = true
        would["reason"] = "이미 켜져 있는 기기입니다."
    } else {
        allowed = state.count.fits(state.limits, previews: previews)
        would["alreadyBooted"] = false
        let count = state.count
        would["reason"] = allowed ? "자리가 있습니다." :
            "켜진 시뮬레이터가 \(count.total)대(기본 세트 \(count.defaultSet)대)이고 제한은 \(state.limits.total)대(기본 세트 \(state.limits.defaultSet)대)입니다. "
            + "owned가 false인 켜진 기기를 그대로 쓰거나, 쓰는 세션이 끝나기를 기다리거나, 사용자에게 알립니다."
    }
    would["allowed"] = allowed
    json["wouldBoot"] = would
    printJSON(json)
    if !allowed { exit(exitBudgetFull) }
}

/// One acquire at a time, so that two sessions cannot both take the last place.
func withBudgetLock<T>(_ body: () -> T) -> T {
    let file = SimulatorBudgetConfig.fileURL.deletingLastPathComponent().appendingPathComponent("budget.lock")
    try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
    let descriptor = open(file.path, O_CREAT | O_RDWR, 0o644)
    guard descriptor >= 0 else { return body() }
    defer { flock(descriptor, LOCK_UN); close(descriptor) }
    flock(descriptor, LOCK_EX)
    return body()
}

func acquireCommand(_ options: Options) {
    let wantedUDID = options.values["udid"]?.uppercased(), wantedName = options.values["name"]
    guard (wantedUDID == nil) != (wantedName == nil) else { fail("--udid 또는 --name 중 하나가 필요합니다.") }
    let deadline = Date().addingTimeInterval(TimeInterval(options.int("wait", default: 0)))
    /// Set while the wanted device is another session's: what to print when the wait ends, and whether this command left a request.
    var owned: [String: Any]?, requested: String?
    while true {
        owned = nil
        // nil: the budget is full; try again while --wait lasts.
        let outcome: [String: Any]? = withBudgetLock {
            let state = budgetState()
            let candidates = state.all.filter { !$0.device.previews }
                .filter { wantedUDID != nil ? $0.device.udid == wantedUDID : $0.device.name == wantedName }
            guard !candidates.isEmpty else {
                fail("기본 세트에 그런 기기가 없습니다: \(wantedUDID ?? wantedName ?? ""). xcrun simctl list devices로 확인하세요.")
            }
            func free(_ udid: String) -> Bool { (state.owners[udid] ?? []).isEmpty || state.mine.contains(udid) }
            let pick = candidates.first { $0.booted && free($0.device.udid) } ?? candidates.first { !$0.booted } ?? candidates[0]
            let device = pick.device
            func claim() {
                store.update { claims, _ in
                    var claim = claims[device.udid].flatMap { me.owns($0) ? $0 : nil } ?? DeviceClaim(identity: me, note: "", auto: false, now: Date())
                    claim.by = me.session
                    claim.auto = false
                    claim.lastUsed = collaborationStamp(Date())
                    if let note = options.values["note"] { claim.note = note }
                    claims[device.udid] = claim
                }
            }
            if pick.booted {
                if !free(device.udid), !options.flags.contains("force") {
                    owned = ["acquired": false, "reason": "owned", "udid": device.udid, "name": device.name,
                             "owners": (state.owners[device.udid] ?? []).map(\.json)]
                    guard Date() < deadline else { return nil }
                    // While it waits, the session that holds the device sees a request. A refusal ends the wait.
                    let answer: String? = store.update { claims, requests in
                        guard let holder = claims[device.udid], !me.owns(holder) else { return nil }
                        if let mine = requests.first(where: { $0.udid == device.udid && $0.from.isSame(me) }) {
                            return mine.declined.isEmpty ? nil : mine.declined
                        }
                        requests.append(DeviceRequest(udid: device.udid, from: me, note: options.values["note"] ?? "", now: Date()))
                        requested = device.udid
                        return nil
                    }
                    if let answer {
                        owned?["reason"] = "declined"
                        owned?["answer"] = answer
                        printJSON(owned ?? [:])
                        warn("\(device.name)를 쓰는 세션이 요청을 거절했습니다: \(answer)")
                        exit(exitOwnedByOther)
                    }
                    return nil
                }
                claim()
                return ["acquired": true, "booted": "already", "udid": device.udid, "name": device.name, "runtime": device.runtime]
            }
            guard state.count.fits(state.limits, previews: false) else { return nil }
            let boot = run(["simctl", "boot", device.udid])
            guard boot.status == 0 else { fail("\(device.name)를 켜지 못했습니다: \(boot.error.trimmingCharacters(in: .whitespacesAndNewlines))") }
            claim()
            return ["acquired": true, "booted": "now", "udid": device.udid, "name": device.name, "runtime": device.runtime]
        }
        if let outcome { printJSON(outcome); return }
        if let owned, Date() >= deadline {
            // A request this command left goes with it; one from `sim-pilot request` stays.
            if let requested { store.update { _, requests in requests.removeAll { $0.udid == requested && $0.from.isSame(me) } } }
            printJSON(owned)
            warn("\(owned["name"] as? String ?? "기기")는 다른 세션이 쓰는 중입니다. sim-pilot request로 요청을 남기거나 --wait <초>로 기다리고, 사용자가 함께 써도 된다고 하면 --force를 붙입니다.")
            exit(exitOwnedByOther)
        }
        guard Date() < deadline else {
            var json = budgetJSON(budgetState())
            json["acquired"] = false
            json["reason"] = "full"
            printJSON(json)
            FileHandle.standardError.write("sim-pilot: 동시에 켤 수 있는 시뮬레이터가 꽉 찼습니다. 새로 켜지 말고, owned가 false인 켜진 기기를 쓰거나 기다리거나 사용자에게 알립니다.\n".data(using: .utf8)!)
            exit(exitBudgetFull)
        }
        Thread.sleep(forTimeInterval: min(owned == nil ? 5 : 2, max(0.5, deadline.timeIntervalSinceNow)))
    }
}

/// devicectl's JSON result for one device (`info details`, `info displays`), nil when it fails.
func devicectlResult(_ udid: String, _ arguments: [String]) -> [String: Any]? {
    let file = FileManager.default.temporaryDirectory.appendingPathComponent("sim-pilot-\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: file) }
    guard run(["devicectl", "device"] + arguments + ["--device", udid, "--quiet", "--json-output", file.path]).status == 0,
          let data = try? Data(contentsOf: file) else { return nil }
    return (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["result"] as? [String: Any]
}

func statusCommand() {
    let state = store.state(booted: bootedSet())
    printJSON(bootedDevices().map { device -> [String: Any] in
        let screens = (devicectlResult(device.udid, ["info", "displays"])?["displays"] as? [[String: Any]] ?? [])
            .filter { ($0["type"] as? [String: Any])?["integrated"] != nil }
        let on = screens.count > 1 ? screens.first { $0["active"] as? Bool == true } : screens.first
        var row: [String: Any] = ["udid": device.udid, "name": device.name, "runtime": device.runtime, "screens": screens.count]
        if let on { row["screen"] = on["name"] as? String ?? "?"; row["orientation"] = on["currentOrientation"] as? String ?? "" }
        if let claim = state.claims[device.udid.uppercased()] { row.merge(claimRow(claim, state.requests.filter { $0.udid == device.udid.uppercased() })) { _, new in new } }
        return row
    })
}

func claimsCommand() {
    let state = store.state(booted: bootedSet())
    let names = Dictionary(bootedDevices().map { ($0.udid.uppercased(), $0.name) }, uniquingKeysWith: { a, _ in a })
    printJSON(state.claims.sorted { $0.key < $1.key }.map { udid, claim -> [String: Any] in
        var row = claimRow(claim, state.requests.filter { $0.udid == udid })
        row.merge(["udid": udid, "name": names[udid] ?? "?", "by": claim.by, "note": claim.note, "lastUsed": claim.lastUsed]) { _, new in new }
        return row
    })
}

/// The device actions this simulator supports, from devicectl's capabilities (the authority on what the device can do)
/// and its number of built-in screens (a foldable has two: hinge and its own turn).
func capsCommand(_ options: Options) {
    let device = bootedDevice(options.require("udid"))
    func json(_ arguments: [String]) -> [String: Any]? {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("sim-pilot-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        guard run(["devicectl", "device"] + arguments + ["--device", device.udid, "--quiet", "--json-output", file.path]).status == 0,
              let data = try? Data(contentsOf: file) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["result"] as? [String: Any]
    }
    guard let details = json(["info", "details"]), let list = details["capabilities"] as? [[String: Any]] else {
        fail("devicectl이 \(device.name)의 기능 목록을 주지 않았습니다.")
    }
    let caps = Set(list.compactMap { ($0["featureIdentifier"] as? String)?.replacingOccurrences(of: "com.apple.coredevice.feature.", with: "") })
    let screens = (json(["info", "displays"])?["displays"] as? [[String: Any]] ?? []).filter { ($0["type"] as? [String: Any])?["integrated"] != nil }.count
    let foldable = screens > 1
    // (동작, 필요한 capability, 방법)
    let rows: [(String, Bool, String)] = [
        ("Face ID 등록·인증", caps.contains("simulatefaceid"), "devicectl device settings biometrics / simulate biometrics"),
        ("Touch ID 등록·인증", caps.contains("simulatetouchid"), "devicectl device settings biometrics / simulate biometrics"),
        ("회전", caps.contains("remote.devicecontrol.orientation"), foldable ? "mac-cu simulator rotate (orientation set은 적용 안 됨)" : "devicectl device orientation set 또는 mac-cu simulator rotate"),
        ("접기·펴기(힌지)", foldable && caps.contains("remote.hid.vendordefined"), "mac-cu simulator hinge"),
        ("힌지 각도 읽기", foldable && caps.contains("monitormotion"), "mac-cu simulator hinge (값 없이)"),
        ("탭·스와이프", caps.contains("remote.hid.digitizer"), "mac-cu simulator tap / swipe"),
        ("1~3손가락 제스처 전송", caps.contains("remote.universalhidservice"), "mac-cu 1.21.0+ simulator gesture (서비스 존재; 앱 인식은 별도 확인)"),
        ("키 입력", caps.contains("remote.hid.keyboard"), "mac-cu simulator type / key"),
        ("하드웨어 버튼", caps.contains("remote.hid.button"), "mac-cu simulator button"),
        ("상태 막대", caps.contains("simulateStatusBar"), "devicectl device simulate statusBar"),
        ("위치·경로", caps.contains("simulatelocation"), "devicectl device simulate location"),
        ("스크린샷", caps.contains("capturescreenshot"), "devicectl device capture screenshot" + (foldable ? " --display-unique-id" : "")),
        ("화면 녹화", caps.contains("screenrecording"), "devicectl device capture screen-record"),
        ("메모리 경고", caps.contains("sendmemorywarningtoprocess"), "devicectl device process sendMemoryWarning"),
        ("손쉬운 사용(모양)", caps.contains("customizeappearancesettings"), "devicectl device settings appearance"),
        ("VoiceOver", caps.contains("voiceover"), "devicectl device settings voiceover"),
        ("StandBy", caps.contains("standby"), "devicectl device info standby"),
        ("앱 크기 조절", caps.contains("resizableappmanagement"), "devicectl device appResize"),
        ("Watch 페어링", caps.contains("companiondevicepairing"), "devicectl device pairings"),
    ]
    // iPad Pro 13-inch (M5): devicectl info displays answers "No displays found".
    print("\(device.name) (\(device.runtime)): capability \(caps.count)개, " + (screens == 0 ? "화면 정보 없음(devicectl info displays가 비어 있음)" : "화면 \(screens)개"))
    for (name, ok, how) in rows { print("\(ok ? "O" : "-") \(name)\(ok ? ": \(how)" : "")") }
}

func schemesCommand(_ options: Options) {
    let device = bootedDevice(options.require("udid"))
    let root = options.values["project-root"] ?? FileManager.default.currentDirectoryPath  // 상태 보기는 레포 밖에서도 실패하지 않게
    printJSON(schemes.map { scheme -> [String: String] in
        let status = isInstalled(device.udid, scheme.bundle) ? "installed" : (builtApp(scheme.name, bundle: scheme.bundle, root: root) != nil ? "built" : "needs_build")
        return ["scheme": scheme.name, "bundle_id": scheme.bundle, "status": status]
    })
}

func relaunch(_ device: Device, _ bundle: String) {
    run(["simctl", "terminate", device.udid, bundle])
    let launch = run(["simctl", "launch", device.udid, bundle])
    guard launch.status == 0 else { fail("실행이 실패했습니다: \(launch.error)") }
    print("[\(device.name)] \(bundle) 실행: \(launch.output.trimmingCharacters(in: .whitespacesAndNewlines))")
}

func launchCommand(_ options: Options) {
    let device = bootedDevice(options.require("udid"))
    let (scheme, bundle) = target(options)
    ensureInstalled(device, scheme: scheme, bundle: bundle, options: options)
    relaunch(device, bundle)
}

func logsCommand(_ options: Options) {
    let device = bootedDevice(options.require("udid"))
    let (_, bundle) = target(options)
    guard let process = executableName(device.udid, bundle) else { fail("\(bundle)이 \(device.name)에 설치돼 있지 않습니다. 먼저 launch 하세요.") }
    let seconds = options.int("seconds", default: 30)
    print("[\(device.name)] \(process) os_log \(seconds > 0 ? "\(seconds)초" : "중단할 때까지")\(options.values["filter"].map { ", 필터 \"\($0)\"" } ?? "")")
    print("---")
    var arguments = ["simctl", "spawn", device.udid, "log", "stream", "--style", "compact",
                     "--predicate", "process == \"\(process)\""]
    if options.flags.contains("debug") { arguments += ["--level", "debug"] }
    stream(arguments, filter: options.values["filter"], seconds: seconds)
}

func consoleCommand(_ options: Options) {
    let device = bootedDevice(options.require("udid"))
    let (scheme, bundle) = target(options)
    ensureInstalled(device, scheme: scheme, bundle: bundle, options: options)
    let seconds = options.int("seconds", default: 30)
    run(["simctl", "terminate", device.udid, bundle])
    print("[\(device.name)] \(bundle) 다시 실행, 콘솔 \(seconds > 0 ? "\(seconds)초" : "중단할 때까지") (끝나면 앱을 종료합니다)")
    print("---")
    stream(["simctl", "launch", "--console-pty", device.udid, bundle], filter: options.values["filter"], seconds: seconds,
           environment: ["SIMCTL_CHILD_OS_ACTIVITY_DT_MODE": "YES"]) {
        run(["simctl", "terminate", device.udid, bundle])
    }
}

func photosCommand(_ options: Options) {
    let device = bootedDevice(options.require("udid"))
    let count = options.int("count", default: 10)
    let width = options.int("width", default: 320), height = options.int("height", default: 320)
    guard (1...2000).contains(count) else { fail("--count는 1~2000입니다.") }
    guard (1...5000).contains(width), (1...5000).contains(height) else { fail("--width·--height는 1~5000입니다.") }
    if count > 100 && !options.flags.contains("yes") {
        fail("\(count)장은 많습니다. 사용자에게 확인을 받은 뒤 --yes를 붙이세요.")
    }
    let blur = options.values["blur"].map { Int($0) ?? -1 }
    if let blur, !(1...10).contains(blur) { fail("--blur는 1~10입니다.") }
    let seed = options.values["seed"]

    var common: [URLQueryItem] = []
    if options.flags.contains("grayscale") { common.append(URLQueryItem(name: "grayscale", value: nil)) }
    if let blur { common.append(URLQueryItem(name: "blur", value: String(blur))) }
    /// 시드가 있으면 시드-번호로 늘 같은 사진, 없으면 random 값으로 서로 다른 사진.
    func url(_ index: Int) -> URL {
        var components = URLComponents(string: "https://picsum.photos")!
        var items = common
        if let seed {
            let name = count == 1 ? seed : "\(seed)-\(index)"
            components.percentEncodedPath = "/seed/\(name.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "x")/\(width)/\(height)"
        } else {
            components.path = "/\(width)/\(height)"
            items.append(URLQueryItem(name: "random", value: String(index)))
        }
        components.queryItems = items.isEmpty ? nil : items
        return components.url!
    }

    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("sim-pilot-photos-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }

    print("[\(device.name)] picsum.photos에서 \(width)×\(height) 사진 \(count)장을 받습니다…")
    let session = URLSession(configuration: .ephemeral)
    let group = DispatchGroup()
    let limit = DispatchSemaphore(value: 8)
    let lock = NSLock()
    var files: [URL] = [], failures = 0
    for index in 0..<count {
        let source = url(index)
        limit.wait()
        group.enter()
        session.dataTask(with: source) { data, response, _ in
            defer { limit.signal(); group.leave() }
            guard let data, (response as? HTTPURLResponse)?.statusCode == 200, data.count > 100 else {
                lock.lock(); failures += 1; lock.unlock(); return
            }
            let file = folder.appendingPathComponent(String(format: "picsum-%05d.jpg", index))
            do { try data.write(to: file) } catch { lock.lock(); failures += 1; lock.unlock(); return }
            lock.lock(); files.append(file); lock.unlock()
        }.resume()
    }
    group.wait()
    guard !files.isEmpty else { fail("사진을 하나도 받지 못했습니다(네트워크 확인).") }
    files.sort { $0.path < $1.path }
    var added = 0
    for start in stride(from: 0, to: files.count, by: 50) {
        let batch = Array(files[start..<min(start + 50, files.count)])
        let result = run(["simctl", "addmedia", device.udid] + batch.map(\.path))
        guard result.status == 0 else { fail("addmedia 실패(\(added)장 넣은 뒤): \(result.error)") }
        added += batch.count
    }
    print("\(device.name) 사진 앱에 \(added)장을 넣었습니다\(failures > 0 ? " (다운로드 실패 \(failures)장)" : "").")
}

// MARK: - 진입점

let arguments = CommandLine.arguments
guard arguments.count > 1 else {
    print("""
        sim-pilot \(version)
          devices | schemes | launch | logs | console | photos | caps | status | claim | release | claims | request | decline | requests
          sessions | budget | acquire | --version
        자세한 사용법은 simulator-pilot 스킬 문서를 보세요.
        """)
    exit(0)
}
let flags: Set<String> = ["build", "reinstall", "debug", "grayscale", "yes", "allow-real", "force", "would-boot"]
let options = Options(arguments.dropFirst(2), flags: flags)
if !["--version", "version"].contains(arguments[1]) {
    store.sessions(seen: me, via: "sim-pilot")
    // budget is what hooks run before every boot: it stays quiet.
    if !["budget", "requests", "decline", "release"].contains(arguments[1]) { noteIncomingRequests() }
}
switch arguments[1] {
case "--version", "version": print(version)
case "devices": devicesCommand()
case "schemes": schemesCommand(options)
case "launch": launchCommand(options)
case "logs": logsCommand(options)
case "console": consoleCommand(options)
case "photos": photosCommand(options)
case "caps": capsCommand(options)
case "claim": claimCommand(options)
case "release": releaseCommand(options)
case "claims": claimsCommand()
case "request": requestCommand(options)
case "decline": declineCommand(options)
case "requests": requestsCommand()
case "sessions": sessionsCommand()
case "status": statusCommand()
case "budget": budgetCommand(options)
case "acquire": acquireCommand(options)
default: fail("알 수 없는 명령: \(arguments[1])")
}
