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
    private var ready: Bool { connection != nil }
    private let configuration: URL
    private let work: URL
    private let started = ProcessInfo.processInfo.systemUptime
    private var sequence = 0
    private var finished = false

    init(owner: UUID, device: UUID, hardwareUDID: String, target: String?) throws {
        self.owner = owner
        self.device = device
        let fm = FileManager.default
        let pointer = fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/mac-cu/physical-xctest.json")
        guard let data = try? Data(contentsOf: pointer),
              let prepared = try? JSONDecoder().decode([String: String].self, from: data),
              prepared["transport"] == "usb-socket-v1", let configPath = prepared["configuration"],
              let plist = NSDictionary(contentsOfFile: configPath) as? [String: Any],
              var test = plist["MacPilotRunner"] as? [String: Any] else {
            throw ToolError("Prepare the signed MacPilot XCTest runner with physical-xctest/prepare.py first.")
        }
        self.hardwareUDID = hardwareUDID
        let products = URL(fileURLWithPath: configPath).deletingLastPathComponent()
        configuration = products.appendingPathComponent("MacPilot-\(session.uuidString).xctestrun")
        work = products.appendingPathComponent("MacPilot-\(session.uuidString)", isDirectory: true)
        try fm.createDirectory(at: work, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        do {
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
                                 "-parallel-testing-enabled", "NO", "-destination-timeout", "30", "-test-timeouts-enabled", "YES", "-maximum-test-execution-time-allowance", "960", "-resultBundlePath", work.appendingPathComponent("test.xcresult").path]
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
            } else if (!self.ready && age > 90) || age > 960 {
                cleanup(self.ready ? "XCTest session lifetime expired." : "XCTest did not report ready within 90 seconds.")
            } else {
                self.scheduleReaping(cleanup)
            }
        }
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
        if !ready {
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
                } catch {
                    candidate.close()
                    interrupt()
                    throw ToolError("The USB runner handshake failed. Rebuild the runner and start a new session.")
                }
            }
        }
        if !ready && ProcessInfo.processInfo.systemUptime - started > 90 {
            interrupt()
            throw ToolError("Runner readiness timed out. Inspect \(work.path)/xcodebuild.log and stop the session.")
        }
        return ["state": ready ? "ready" : "starting"]
    }

    private func readReply(_ socket: XCTestSocket, until deadline: Double, cancelled: () -> Bool) throws -> [String: Any] {
        let data = try socket.receive(.reply, until: deadline, cancelled: cancelled)
        guard let row = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              row["session"] as? String == session.uuidString, row["sequence"] as? Int == sequence else {
            throw XCTestSocketError.frame
        }
        return row
    }

    private func send(_ action: String, args: [String: Any], over socket: XCTestSocket, until deadline: Double, cancelled: () -> Bool) throws {
        sequence += 1
        var message: [String: Any] = ["session": session.uuidString, "sequence": sequence, "action": action]
        for field in ["target", "seconds", "text"] { message[field] = args[field] }
        try socket.send(JSONSerialization.data(withJSONObject: message), as: .request, until: deadline, cancelled: cancelled)
    }

    func command(_ action: String, args: [String: Any], cancelled: () -> Bool) throws -> [String: Any] {
        try checkProcess()
        guard let connection else { throw ToolError("Poll xctestStatus until ready.") }
        if cancelled() { throw XCTestSocketError.cancelled }
        let channel = XCTestSocket(fd: connection.fd, key: key)
        let deadline = XCTestSocket.now + 20
        let result: [String: Any]
        do {
            try send(action, args: args, over: channel, until: deadline, cancelled: cancelled)
            result = try readReply(channel, until: deadline, cancelled: cancelled)
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
        if process.isRunning, let connection, !finished {
            try? send("stop", args: [:], over: XCTestSocket(fd: connection.fd, key: key), until: XCTestSocket.now + 2, cancelled: { false })
            let deadline = ProcessInfo.processInfo.systemUptime + 10
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
