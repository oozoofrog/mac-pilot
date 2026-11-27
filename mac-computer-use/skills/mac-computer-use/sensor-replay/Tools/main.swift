import Foundation

/// Each xcrun step runs in its own process group; the parent's SIGTERM (cancel or timeout) must reach them too.
let stagingRunner = SimulatorPreparationTask()
let terminate: DispatchSourceSignal = {
    signal(SIGTERM, SIG_IGN)
    let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .global())
    source.setEventHandler { stagingRunner.cancel() }
    source.resume()
    return source
}()

do {
    _ = terminate
    let result = try stageSensorReplayCommand(Array(CommandLine.arguments.dropFirst()), runner: stagingRunner)
    print(String(decoding: try JSONSerialization.data(withJSONObject: result), as: UTF8.self))
} catch {
    FileHandle.standardError.write(Data(("Sensor replay: " + error.localizedDescription + "\n").utf8))
    exit(1)
}
