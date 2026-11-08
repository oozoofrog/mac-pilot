import AppKit
import Foundation
import Darwin

/// One instance owns only commands it starts for one exact simulator UDID.
/// Call the public methods on the main thread; callbacks are delivered there.
final class SimulatorHostActions: NSObject {
    var onState: (String, Bool) -> Void = { _, _ in }
    var onRecording: (Bool, String) -> Void = { _, _ in }

    private let deviceID: String
    private let executable: URL
    private let queue = DispatchQueue(label: "mac-cu.simulator-host-actions")
    private var closed = false
    private var recordingAdmission = false
    private var savePanel: NSSavePanel?
    private var finite: Process?
    private var recording: Process?
    private var recordingStarted = false
    private var recordingStopping = false
    private var recordingTimedOut = false
    private var recordingOutput = Data()
    private var recordingURL: URL?
    private var recordingGeneration = UUID()
    private let timeout: TimeInterval

    init(deviceID: String) {
        self.deviceID = deviceID
        self.executable = URL(fileURLWithPath: "/usr/bin/xcrun")
        self.timeout = 15
        super.init()
    }

    // Injection is for headless tests; production always executes xcrun.
    init(deviceID: String, executable: URL, timeout: TimeInterval) {
        self.deviceID = deviceID
        self.executable = executable
        self.timeout = timeout
        super.init()
    }

    private func state(_ message: String, _ error: Bool = false) {
        DispatchQueue.main.async { [weak self] in self?.onState(message, error) }
    }
    private func recordState(_ active: Bool, _ message: String) {
        DispatchQueue.main.async { [weak self] in
            if !active { self?.recordingAdmission = false }; self?.onRecording(active, message)
        }
    }

    private static let sizes: Set<String> = ["extra-small", "small", "medium", "large", "extra-large", "extra-extra-large", "extra-extra-extra-large", "accessibility-medium", "accessibility-large", "accessibility-extra-large", "accessibility-extra-extra-large", "accessibility-extra-extra-extra-large", "increment", "decrement"]

    /// The Boolean callback indicates an error, not a pending or confirmed value.
    func run(option: String, value: String) {
        guard UUID(uuidString: deviceID) != nil else { state("정확한 기기 UDID가 필요합니다.", true); return }
        let args: [String]
        let ui: Bool
        switch option {
        case "appearance" where ["light", "dark"].contains(value),
             "increase_contrast" where ["enabled", "disabled"].contains(value),
             "content_size" where Self.sizes.contains(value):
            args = ["ui", deviceID, option, value]; ui = true
        case "location":
            let parts = value.split(separator: ",", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2, let lat = Double(parts[0]), let lon = Double(parts[1]), lat.isFinite, lon.isFinite, (-90...90).contains(lat), (-180...180).contains(lon) else {
                state("위도와 경도를 유효한 lat,lon 형식으로 입력하세요.", true); return
            }
            args = ["location", deviceID, "set", "\(lat),\(lon)"]; ui = false
        case "location-clear": args = ["location", deviceID, "clear"]; ui = false
        default: state("지원하지 않는 설정 또는 값입니다.", true); return
        }
        queue.async { [self] in
            guard !closed else { return }
            guard finite == nil else { state("다른 설정을 적용하고 있습니다.", true); return }
            state("설정을 적용하는 중…")
            finiteCommand(args) { result in
                switch result {
                case .failure(let error): self.state(error.localizedDescription, true)
                case .success:
                    if ui {
                        self.finiteCommand(["ui", self.deviceID, option]) { readback in
                            switch readback {
                            case .failure(let error): self.state("설정을 보냈지만 확인하지 못했습니다: \(error.localizedDescription)", true)
                            case .success(let text):
                                let actual = text.trimmingCharacters(in: .whitespacesAndNewlines)
                                guard !actual.isEmpty, actual != "unsupported", actual != "unknown" else { self.state("설정을 확인할 수 없습니다: \(actual)", true); return }
                                if value != "increment" && value != "decrement" && actual != value { self.state("요청한 값 \(value), 현재 값 \(actual)", true) }
                                else { self.state("\(option): \(actual)") }
                            }
                        }
                    } else { self.state("위치 명령을 보냈습니다. 기기의 위치 반영 여부는 확인되지 않았습니다.") }
                }
            }
        }
    }

    private struct CommandError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    private func drainAvailable(_ handle: FileHandle) -> Data {
        let fd = handle.fileDescriptor
        let flags = fcntl(fd, F_GETFL)
        if flags >= 0 { _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK) }
        var result = Data(), buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = read(fd, &buffer, buffer.count)
            guard count > 0 else { break }
            result.append(contentsOf: buffer.prefix(count))
            if result.count > 65536 { result.removeFirst(result.count - 65536) }
        }
        return result
    }

    // All process state and completion handling are serialized on queue. Output is
    // drained continuously and capped; timeout escalation targets only this child.
    private func finiteCommand(_ arguments: [String], completion: @escaping (Result<String, Error>) -> Void) {
        let process = Process(), pipe = Pipe()
        process.executableURL = executable; process.arguments = ["simctl"] + arguments
        process.environment = ProcessInfo.processInfo.environment.filter { !["OPENAI_API_KEY","MAC_CU_DECISION_MODEL"].contains($0.key) }
        process.standardInput = FileHandle.nullDevice; process.standardOutput = pipe; process.standardError = pipe
        var output = Data()
        var timedOut = false
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { handle.readabilityHandler = nil; return }
            self?.queue.async { output.append(data); if output.count > 65536 { output.removeFirst(output.count - 65536) } }
        }
        do { try process.run() } catch { pipe.fileHandleForReading.readabilityHandler = nil; completion(.failure(error)); return }
        finite = process
        let deadline = DispatchWorkItem { [weak self, weak process] in
            guard let self, let process, self.finite === process, process.isRunning else { return }
            timedOut = true
            process.terminate()
            self.queue.asyncAfter(deadline: .now() + 1) { if self.finite === process && process.isRunning { kill(process.processIdentifier, SIGKILL) } }
        }
        queue.asyncAfter(deadline: .now() + timeout, execute: deadline)
        process.terminationHandler = { [self] process in
            self.queue.async {
                guard self.finite === process else { return }
                deadline.cancel(); pipe.fileHandleForReading.readabilityHandler = nil
                let remaining = self.drainAvailable(pipe.fileHandleForReading); output.append(remaining)
                if output.count > 65536 { output.removeFirst(output.count - 65536) }
                self.finite = nil
                guard !self.closed else { return }
                let text = String(decoding: output, as: UTF8.self)
                if timedOut { completion(.failure(CommandError(message: "명령 시간이 초과되었습니다."))) }
                else if process.terminationStatus == 0 { completion(.success(text)) }
                else { completion(.failure(CommandError(message: "명령 실패 (\(process.terminationStatus)): \(text.suffix(2000))"))) }
            }
        }
    }

    /// Pass the exact screen ID/name/UUID obtained for the displayed screen.
    /// nil is rejected: a default can be ambiguous on multi-display devices.
    func startRecording(display: String? = nil) {
        guard UUID(uuidString: deviceID) != nil else { state("정확한 기기 UDID가 필요합니다.", true); return }
        guard let display, !display.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !display.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else { state("녹화할 화면을 확인할 수 없습니다.", true); return }
        guard !recordingAdmission else { state("녹화가 준비 중이거나 진행 중입니다.",true); return }
        recordingAdmission = true
        let panel = NSSavePanel(); savePanel = panel
        panel.nameFieldStringValue = "Simulator Recording.mov"
        panel.allowedContentTypes = [.quickTimeMovie]
        panel.begin { [weak self] response in
            self?.savePanel = nil
            guard response == .OK, let url = panel.url else { self?.recordingAdmission = false; self?.state("녹화 저장 취소"); return }
            self?.startRecording(to: url, display: display)
        }
    }

    // Also permits headless tests to bypass the save panel.
    func startRecording(to url: URL, display: String) {
        guard UUID(uuidString: deviceID) != nil, url.isFileURL, !display.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !display.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else { state("녹화 대상이 올바르지 않습니다.", true); return }
        queue.async { [self] in
            guard !closed else { return }
            guard recording == nil else { state("녹화가 이미 진행 중이거나 종료 중입니다.", true); return }
            let process = Process(), pipe = Pipe(), generation = UUID()
            process.executableURL = executable
            process.arguments = ["simctl", "io", deviceID, "recordVideo", "--display=\(display)", url.path]
            process.environment = ProcessInfo.processInfo.environment.filter { !["OPENAI_API_KEY","MAC_CU_DECISION_MODEL"].contains($0.key) }
            process.standardInput = FileHandle.nullDevice; process.standardOutput = FileHandle.nullDevice; process.standardError = pipe
            recordingGeneration = generation; recordingStarted = false; recordingStopping = false; recordingTimedOut = false; recordingOutput = Data(); recordingURL = url
            pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
                let data = handle.availableData
                guard !data.isEmpty else { handle.readabilityHandler = nil; return }
                self?.queue.async { self?.recordingData(data, process: process, generation: generation) }
            }
            do { try process.run() } catch { pipe.fileHandleForReading.readabilityHandler = nil; state("녹화를 시작하지 못했습니다: \(error.localizedDescription)", true); recordState(false,"녹화 시작 실패"); return }
            recording = process
            state("녹화를 시작하는 중…")
            process.terminationHandler = { [self] process in
                self.queue.async {
                    guard self.recording === process, self.recordingGeneration == generation else { return }
                    pipe.fileHandleForReading.readabilityHandler = nil
                    let tail = self.drainAvailable(pipe.fileHandleForReading)
                    self.recordingData(tail, process: process, generation: generation)
                    let started = self.recordingStarted, stopping = self.recordingStopping, timedOut = self.recordingTimedOut
                    let detail = String(decoding: self.recordingOutput.suffix(2000), as: UTF8.self)
                    self.recording = nil; self.recordingURL = nil; self.recordingStarted = false; self.recordingStopping = false
                    let outputSize = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0
                    let success = started && stopping && !timedOut && process.terminationStatus == 0 && outputSize > 0
                    self.recordState(false, success ? "녹화 저장됨: \(url.lastPathComponent)" : "녹화가 완료되지 않았습니다. 파일을 확인하세요.")
                    if !success { self.state("녹화 종료 오류 (\(process.terminationStatus)): \(detail)", true) }
                }
            }
            queue.asyncAfter(deadline: .now() + 15) { [weak self, weak process] in
                guard let self, let process, self.recording === process, !self.recordingStarted, !self.recordingStopping else { return }
                self.state("녹화 시작 시간이 초과되었습니다.", true); self.stopOwnedRecording(process)
            }
        }
    }

    private func recordingData(_ data: Data, process: Process, generation: UUID) {
        guard recording === process, recordingGeneration == generation else { return }
        recordingOutput.append(data)
        if recordingOutput.count > 65536 { recordingOutput.removeFirst(recordingOutput.count - 65536) }
        if !recordingStarted && !recordingStopping && process.isRunning && String(decoding: recordingOutput, as: UTF8.self).contains("Recording started") {
            recordingStarted = true; recordState(true, "녹화 중")
        }
    }

    func stopRecording() { queue.async { [self] in if let process = recording { stopOwnedRecording(process) } } }
    private func stopOwnedRecording(_ process: Process) {
        guard !recordingStopping else { return }
        recordingStopping = true
        state("녹화를 마무리하는 중…")
        if process.isRunning { kill(process.processIdentifier, SIGINT) }
        queue.asyncAfter(deadline: .now() + 10) { [weak self, weak process] in
            guard let self, let process, self.recording === process, process.isRunning else { return }
            self.state("녹화 마무리 시간이 초과되었습니다. 파일을 확인하세요.", true)
            self.recordingTimedOut = true
            process.terminate()
            self.queue.asyncAfter(deadline: .now() + 1) { if self.recording === process && process.isRunning { kill(process.processIdentifier, SIGKILL) } }
        }
    }
    func close() {
        savePanel?.cancel(nil); savePanel = nil
        queue.async { [self] in
            guard !closed else { return }; closed = true
            if let process = finite, process.isRunning {
                process.terminate()
                queue.asyncAfter(deadline: .now() + 1) { if self.finite === process && process.isRunning { kill(process.processIdentifier, SIGKILL) } }
            }
            if let process = recording { stopOwnedRecording(process) }
        }
    }
}

/// A portrait single-screen device has no ActiveScreen rotation descriptor.
func simulatorRecordingDisplayID(activeID: String?, displays: [[String:Any]]?) -> String? {
    if let activeID,!activeID.isEmpty { return activeID }
    guard let displays else { return nil }
    let integrated = displays.filter { ($0["type"] as? [String:Any])?["integrated"] != nil }
    guard integrated.count == 1, let value = integrated.first?["displayId"] else { return nil }
    return String(describing: value)
}
