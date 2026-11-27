import Foundation

func sensorReplayFixtureBytes(_ path: String) throws -> Data {
    guard path.hasPrefix("/") else { throw SensorReplay.InvalidFixture("Give an absolute fixture file path.") }
    let fd = open(path, O_RDONLY | O_NONBLOCK | O_CLOEXEC)
    guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    defer { try? handle.close() }
    var info = stat()
    guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_size <= SensorReplay.byteLimit else {
        throw SensorReplay.InvalidFixture("Expected a regular fixture file up to 16 MiB.")
    }
    let data = try handle.read(upToCount: SensorReplay.byteLimit + 1) ?? Data()
    guard data.count == info.st_size else { throw SensorReplay.InvalidFixture("Fixture changed during read.") }
    return data
}

/// Runs one xcrun step and reports a failure as one plain line, so the parent does not wrap the runner's text twice.
func sensorReplayXCRun(_ runner: SimulatorPreparationTask, _ step: String, _ arguments: [String], timeout: TimeInterval) throws -> String {
    do { return try runner.run("/usr/bin/xcrun", arguments, timeout: timeout, stream: false) }
    catch let error as SimulatorPreparationError {
        let detail = error.standardError.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .last(where: { !$0.isEmpty })
            .map { ": " + $0 } ?? ""
        let reason = error.kind == .timedOut ? " timed out after \(Int(timeout)) s"
            : error.kind == .cancelled ? " was cancelled" : " failed" + detail
        throw SensorReplay.InvalidFixture(step + reason + ".")
    }
}

private func checkStageNotCancelled(_ runner: SimulatorPreparationTask, step: String) throws {
    if runner.isCancelled { throw SensorReplay.InvalidFixture(step + " was cancelled.") }
}

func stageSensorReplayCommand(
    _ arguments: [String],
    runner: SimulatorPreparationTask,
    runXC: (SimulatorPreparationTask, String, [String], TimeInterval) throws -> String = sensorReplayXCRun
) throws -> [String: Any] {
    guard arguments.count == 4, ["simulator", "device"].contains(arguments[0]),
          let device = UUID(uuidString: arguments[1]),
          arguments[2].range(of: #"^[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+$"#, options: .regularExpression) != nil else {
        throw SensorReplay.InvalidFixture("Usage: macpilot-sensor-replay simulator|device UUID BUNDLE_ID ABSOLUTE_FIXTURE.json")
    }
    try checkStageNotCancelled(runner, step: "Staging")
    let app = arguments[2]
    let data = try sensorReplayFixtureBytes(arguments[3])
    let replay = try SensorReplay(data: data)
    try checkStageNotCancelled(runner, step: "Staging")
    let id = UUID()
    let name = SensorReplay.filename(id: id)
    let relative = "Documents/" + name
    if arguments[0] == "simulator" {
        let container = try runXC(runner, "simctl get_app_container", ["simctl", "get_app_container", device.uuidString, app, "data"], 20)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard container.hasPrefix("/") else { throw SensorReplay.InvalidFixture("No simulator data container.") }
        let root = URL(fileURLWithPath: container).resolvingSymlinksInPath()
        let documents = root.appendingPathComponent("Documents")
        var dirStat = stat()
        if lstat(documents.path, &dirStat) == 0 {
            guard (dirStat.st_mode & S_IFMT) == S_IFDIR else {
                throw SensorReplay.InvalidFixture("Documents must be inside the selected app container.")
            }
        } else if errno == ENOENT {
            try FileManager.default.createDirectory(at: documents, withIntermediateDirectories: false)
        }
        guard documents.resolvingSymlinksInPath().standardizedFileURL.path == documents.standardizedFileURL.path else {
            throw SensorReplay.InvalidFixture("Documents must be inside the selected app container.")
        }
        let file = documents.appendingPathComponent(name)
        var published = false
        defer { if !published { try? FileManager.default.removeItem(at: file) } }
        try checkStageNotCancelled(runner, step: "Simulator write")
        try data.write(to: file, options: .withoutOverwriting)
        guard try sensorReplayFixtureBytes(file.path) == data else { throw SensorReplay.InvalidFixture("Simulator readback differs.") }
        try checkStageNotCancelled(runner, step: "Simulator ready marker")
        try Data().write(to: file.appendingPathExtension("ready"), options: .withoutOverwriting)
        published = true
    } else {
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("macpilot-replay-" + id.uuidString)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: scratch) }
        let source = scratch.appendingPathComponent(name)
        let readback = scratch.appendingPathComponent("readback.json")
        try data.write(to: source)
        let domain = ["--device", device.uuidString, "--domain-type", "appDataContainer", "--domain-identifier", app, "--timeout", "30"]
        // devicectl stops itself after 30 s; 45 s per step keeps the three steps inside the parent's 150 s.
        _ = try runXC(runner, "devicectl copy to", ["devicectl", "device", "copy", "to", "--source", source.path, "--destination", relative] + domain, 45)
        _ = try runXC(runner, "devicectl copy from", ["devicectl", "device", "copy", "from", "--source", relative, "--destination", readback.path] + domain, 45)
        guard try sensorReplayFixtureBytes(readback.path) == data else { throw SensorReplay.InvalidFixture("Device readback differs.") }
        try checkStageNotCancelled(runner, step: "devicectl ready marker")
        let marker = scratch.appendingPathComponent("ready")
        try Data([1]).write(to: marker)
        _ = try runXC(runner, "devicectl ready marker", ["devicectl", "device", "copy", "to", "--source", marker.path, "--destination", relative + ".ready"] + domain, 45)
    }
    return ["state": "staged", "id": id.uuidString, "app": app, "events": replay.events.count, "path": relative]
}
