import Foundation
import Darwin
import CryptoKit

final class PhysicalXCTestSession {
    static let actions: Set<String> = ["xctestStart", "xctestStatus", "xctestPing", "xctestDescribe", "xctestTap", "xctestType", "xctestActivate", "xctestWait", "xctestStop"]
    let owner: UUID
    let device: UUID
    private let session = UUID()
    private let process = Process()
    private static let exitLock = NSLock()
    private static weak var ownedProcess: Process?

    static func daemonWillExit() {
        exitLock.withLock {
            if let child = ownedProcess, child.isRunning { child.terminate() }
        }
    }
    private let hardwareUDID: String
    private let port = UInt16.random(in: 49152...65535)
    private let key = SymmetricKey(size: .bits256)
    private var connection: FDStream?
    private var watchFiles: WatchXCTestFiles?
    private var ready = false
    private let startupLimit: Double
    private let configuration: URL
    private let work: URL
    private let started = ProcessInfo.processInfo.systemUptime
    private var sequence = 0
    private var finished = false

    init(owner: UUID, selection: PhysicalDeviceInfo, target: String?) throws {
        guard let hardwareUDID = selection.hardwareUDID, !hardwareUDID.isEmpty else { throw ToolError("Missing hardware UDID for the selected XCTest destination.") }
        let watch = selection.isAppleWatch
        startupLimit = watch ? 240 : 90
        self.owner = owner
        self.device = selection.identifier
        let fm = FileManager.default
        let pointer = fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/mac-cu").appendingPathComponent(watch ? "watch-xctest.json" : "physical-xctest.json")
        guard let data = try? Data(contentsOf: pointer),
              let prepared = try? JSONDecoder().decode([String: String].self, from: data),
              prepared["transport"] == (watch ? "watch-files-v1" : "usb-socket-v1"), let configPath = prepared["configuration"],
              let plist = NSDictionary(contentsOfFile: configPath) as? [String: Any],
              var test = plist["MacPilotRunner"] as? [String: Any], let bundle = test["TestHostBundleIdentifier"] as? String else {
            throw ToolError("Prepare the selected platform with physical-xctest/prepare.py --platform \(watch ? "watchOS" : "iOS") first.")
        }
        self.hardwareUDID = hardwareUDID
        let products = URL(fileURLWithPath: configPath).deletingLastPathComponent()
        configuration = products.appendingPathComponent("MacPilot-\(session.uuidString).xctestrun")
        work = products.appendingPathComponent("MacPilot-\(session.uuidString)", isDirectory: true)
        try fm.createDirectory(at: work, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        do {
            if watch { watchFiles = try WatchXCTestFiles(device: device, bundle: bundle, session: session, work: work) }
            var env = test["EnvironmentVariables"] as? [String: String] ?? [:]
            env["MACPILOT_SESSION"] = session.uuidString
            env["MACPILOT_PORT"] = String(port)
            env["MACPILOT_KEY"] = key.withUnsafeBytes { Data($0).base64EncodedString() }
            env["MACPILOT_TARGET"] = target
            test["EnvironmentVariables"] = env
            test["SystemAttachmentLifetime"] = "keepNever"
            var config = plist
            config["MacPilotRunner"] = test
            let bytes = try PropertyListSerialization.data(fromPropertyList: config, format: .xml, options: 0)
            guard fm.createFile(atPath: configuration.path, contents: bytes, attributes: [.posixPermissions: 0o600]) else {
                throw ToolError("Cannot write the private XCTest configuration.")
            }
            let logURL = work.appendingPathComponent("xcodebuild.log")
            guard fm.createFile(atPath: logURL.path, contents: nil) else { throw ToolError("Cannot create the runner log.") }
            let log = try FileHandle(forWritingTo: logURL)
            defer { try? log.close() }
            process.executableURL = URL(fileURLWithPath: "/usr/bin/xcodebuild")
            process.arguments = ["test-without-building", "-xctestrun", configuration.path, "-destination", "id=\(hardwareUDID)",
                                 "-parallel-testing-enabled", "NO", "-destination-timeout", watch ? "120" : "30", "-test-timeouts-enabled", "YES", "-maximum-test-execution-time-allowance", "960", "-resultBundlePath", work.appendingPathComponent("test.xcresult").path]
            process.standardOutput = log
            process.standardError = log
            process.standardInput = FileHandle.nullDevice
            try process.run()
            Self.exitLock.withLock { Self.ownedProcess = process }
        } catch {
            try? fm.removeItem(at: work)
            try? fm.removeItem(at: configuration)
            throw error
        }
    }

    func scheduleReaping(_ cleanup: @escaping (String) -> Void) {
        handleQueue.asyncAfter(deadline: .now() + 10) { [weak self] in
            guard let self, !self.cleaned else { return }
            let age = ProcessInfo.processInfo.systemUptime - self.started
            if !self.process.isRunning {
                cleanup(self.exitDescription)
            } else if (!self.ready && age > self.startupLimit) || age > 960 {
                cleanup(self.ready ? "XCTest session lifetime expired." : self.startupError)
            } else {
                self.scheduleReaping(cleanup)
            }
        }
    }
    private var startupError: String {
        let reason = watchFiles?.lastReadError.map { " " + $0 } ?? ""
        return "XCTest did not report ready within \(Int(startupLimit)) seconds." + reason
    }

    private var cleaned = false

    private var exitDescription: String {
        let exit = "XCTest session ended (xcodebuild exit \(process.terminationStatus))."
        guard process.terminationStatus != 0,
              let log = try? FileHandle(forReadingFrom: work.appendingPathComponent("xcodebuild.log")) else { return exit }
        defer { try? log.close() }
        guard let length = try? log.seekToEnd() else { return exit }
        do {
            try log.seek(toOffset: length - min(length, 8192))
            let tail = String(decoding: try log.readToEnd() ?? Data(), as: UTF8.self)
            let lines = tail.split(separator: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            let reason = lines.last { $0.localizedCaseInsensitiveContains("error:") } ?? lines.last
            return reason.map { exit + " " + $0.suffix(400) } ?? exit
        } catch { return exit }
    }

    private func checkProcess() throws {
        guard !finished else { throw ToolError("The XCTest session is ending. Stop it before sending commands.") }
        guard process.isRunning else { throw ToolError(exitDescription) }
    }

    func status() throws -> [String: Any] {
        try checkProcess()
        if !ready, let watchFiles {
            do {
                if let record = try watchFiles.read(sequence: 0, key: key, until: XCTestSocket.now + 5) {
                    guard try validate(record)["state"] as? String == "ready" else { throw XCTestSocketError.frame }
                    ready = true
                }
            } catch {
                interrupt()
                throw ToolError("Invalid watch runner handshake. Stop the session and rebuild the watchOS runner.")
            }
        } else if !ready {
            guard let wired = try Usbmux.devices().first(where: { $0.isUSB && $0.serial.caseInsensitiveCompare(hardwareUDID) == .orderedSame }) else {
                interrupt()
                throw ToolError("The selected USB iPhone disconnected.")
            }
            if let candidate = try Usbmux.connectIfListening(wired, port: port) {
                do {
                    let channel = XCTestSocket(fd: candidate.fd, key: key)
                    let hello = try readReply(channel, until: XCTestSocket.now + 4, cancelled: { false })
                    guard hello["state"] as? String == "ready" else { throw XCTestSocketError.frame }
                    connection = candidate
                    ready = true
                } catch {
                    candidate.close()
                    interrupt()
                    throw ToolError("The USB runner handshake failed. Rebuild the runner and start a new session.")
                }
            }
        }
        if !ready && ProcessInfo.processInfo.systemUptime - started > startupLimit {
            interrupt()
            throw ToolError(startupError)
        }
        return ["state": ready ? "ready" : "starting"]
    }

    private func readReply(_ socket: XCTestSocket, until deadline: Double, cancelled: () -> Bool) throws -> [String: Any] {
        let data = try socket.receive(.reply, until: deadline, cancelled: cancelled)
        return try validate(data)
    }

    private func validate(_ data: Data) throws -> [String: Any] {
        guard let row = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              row["session"] as? String == session.uuidString, row["sequence"] as? Int == sequence else {
            throw XCTestSocketError.frame
        }
        return row
    }

    private func send(_ action: String, args: [String: Any], until deadline: Double, cancelled: () -> Bool) throws {
        sequence += 1
        var message: [String: Any] = ["session": session.uuidString, "sequence": sequence, "action": action]
        for field in ["target", "label", "seconds", "text"] { message[field] = args[field] }
        let data = try JSONSerialization.data(withJSONObject: message)
        if let watchFiles {
            try watchFiles.send(data, sequence: sequence, key: key, until: deadline)
        } else if let connection {
            try XCTestSocket(fd: connection.fd, key: key).send(data, as: .request, until: deadline, cancelled: cancelled)
        } else { throw XCTestSocketError.closed }
    }

    func command(_ action: String, args: [String: Any], cancelled: () -> Bool) throws -> [String: Any] {
        try checkProcess()
        guard ready else { throw ToolError("Poll xctestStatus until ready.") }
        if cancelled() { throw XCTestSocketError.cancelled }
        let deadline = XCTestSocket.now + (watchFiles == nil ? 20 : 45)
        let result: [String: Any]
        do {
            try send(action, args: args, until: deadline, cancelled: cancelled)
            if let watchFiles {
                while true {
                    if cancelled() { throw XCTestSocketError.cancelled }
                    guard XCTestSocket.now < deadline else { throw XCTestSocketError.timeout }
                    if let data = try watchFiles.read(sequence: sequence, key: key, until: deadline) {
                        result = try validate(data)
                        break
                    }
                    Thread.sleep(forTimeInterval: 0.2)
                }
            } else if let connection {
                result = try readReply(XCTestSocket(fd: connection.fd, key: key), until: deadline, cancelled: cancelled)
            } else { throw XCTestSocketError.closed }
        } catch {
            interrupt()
            throw ToolError("Unconfirmed XCTest delivery. Do not repeat input. Start a new session. " + error.localizedDescription)
        }
        if let error = result["error"] as? String { throw ToolError(error) }
        return result.filter { $0.key != "session" && $0.key != "sequence" }
    }

    func interrupt() {
        finished = true
        connection?.close()
        connection = nil
        if process.isRunning { process.terminate() }
    }

    @discardableResult
    func stop() -> Bool {
        if process.isRunning, ready, !finished {
            try? send("stop", args: [:], until: XCTestSocket.now + (watchFiles == nil ? 2 : 8), cancelled: { false })
            let deadline = ProcessInfo.processInfo.systemUptime + (watchFiles == nil ? 10 : 30)
            while process.isRunning && ProcessInfo.processInfo.systemUptime < deadline { Thread.sleep(forTimeInterval: 0.05) }
        }
        let exitedCleanly = !process.isRunning && process.terminationReason == .exit && process.terminationStatus == 0
        interrupt()
        let deadline = ProcessInfo.processInfo.systemUptime + 2
        while process.isRunning && ProcessInfo.processInfo.systemUptime < deadline { Thread.sleep(forTimeInterval: 0.05) }
        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        process.waitUntilExit()
        cleaned = true
        Self.exitLock.withLock {
            if Self.ownedProcess === process { Self.ownedProcess = nil }
        }
        try? FileManager.default.removeItem(at: configuration)
        try? FileManager.default.removeItem(at: work)
        return exitedCleanly
    }
}
