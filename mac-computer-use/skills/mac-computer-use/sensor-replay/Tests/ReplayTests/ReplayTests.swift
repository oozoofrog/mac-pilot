import XCTest
@testable import MacPilotSensorReplay

final class ReplayTests: XCTestCase {
    @MainActor func testFiveInputsArriveInOrder() async throws {
        let bytes = Data("""
        {"version":1,"events":[
          {"offsetMs":0,"motion":{"steps":5,"accelerationG":{"x":1,"y":0,"z":0}}},
          {"offsetMs":1,"workout":{"heartRateBPM":120,"phase":"running"}},
          {"offsetMs":1,"location":{"latitude":37.5,"longitude":127}},
          {"offsetMs":2,"microphone":{"sampleRate":16000,"pcmS16LE":"AQD//w=="}},
          {"offsetMs":3,"camera":{"imageData":"iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAIAAACQd1PeAAAADElEQVR4nGP4z8AAAAMBAQDJ/pLvAAAAAElFTkSuQmCC"}}
        ]}
        """.utf8)
        var order = [String]()
        try await SensorReplay(data: bytes).play { event in
            switch event.input {
            case .motion(let m): XCTAssertEqual(m.steps, 5); order.append("motion")
            case .workout(let w): XCTAssertEqual(w.heartRateBPM, 120); order.append("workout")
            case .location(let l): XCTAssertEqual(l.location(at: Date()).coordinate.latitude, 37.5); order.append("location")
            case .microphone(let m):
                let buffer = try m.buffer()
                XCTAssertEqual(buffer.frameLength, 2)
                XCTAssertEqual(buffer.int16ChannelData?[0][1], -1)
                order.append("microphone")
            case .camera(let c): XCTAssertEqual(try c.image().width, 1); order.append("camera")
            }
        }
        XCTAssertEqual(order, ["motion", "workout", "location", "microphone", "camera"])
    }

    func testInvalidTailRejectsWholeReplay() {
        let input = #"{"version":1,"events":[{"offsetMs":1,"motion":{"steps":2}},{"offsetMs":0,"workout":{"phase":"ended"}}]}"#
        XCTAssertThrowsError(try SensorReplay(data: Data(input.utf8)))
    }

    func testLocationAltitudeAccuracyDefaultsAndBounds() throws {
        let valid = Data("""
        {"version":1,"events":[
          {"offsetMs":0,"location":{"latitude":37.5,"longitude":127.0,"altitudeMeters":48.5}},
          {"offsetMs":1,"location":{"latitude":37.5,"longitude":127.0}},
          {"offsetMs":2,"location":{"latitude":37.5,"longitude":127.0,"altitudeMeters":48.5,"verticalAccuracyMeters":3.25,"courseDegrees":359.5,"speedMPS":0}}
        ]}
        """.utf8)
        let events = try SensorReplay(data: valid).events
        guard case .location(let withAltitude) = events[0].input,
              case .location(let withoutAltitude) = events[1].input,
              case .location(let explicitAccuracy) = events[2].input else {
            return XCTFail("Expected location events")
        }
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        XCTAssertEqual(withAltitude.location(at: now).altitude, 48.5)
        XCTAssertEqual(withAltitude.location(at: now).verticalAccuracy, 0)
        XCTAssertEqual(withoutAltitude.location(at: now).verticalAccuracy, -1)
        XCTAssertEqual(explicitAccuracy.location(at: now).verticalAccuracy, 3.25)
        XCTAssertEqual(explicitAccuracy.location(at: now).course, 359.5)

        for bad in [
            #"{"latitude":37.5,"longitude":127,"horizontalAccuracyMeters":-0.1}"#,
            #"{"latitude":37.5,"longitude":127,"verticalAccuracyMeters":-1}"#,
            #"{"latitude":37.5,"longitude":127,"speedMPS":-2}"#,
            #"{"latitude":37.5,"longitude":127,"courseDegrees":360}"#,
            #"{"latitude":37.5,"longitude":127,"courseDegrees":-1}"#,
            #"{"latitude":90.1,"longitude":127}"#,
            #"{"latitude":37.5,"longitude":-180.1}"#,
        ] {
            let doc = #"{"version":1,"events":[{"offsetMs":0,"location":"# + bad + "}]}"
            XCTAssertThrowsError(try SensorReplay(data: Data(doc.utf8)), bad)
        }
    }

    func testReceiveNextClaimsReadyIgnoresUnreadyCleansUpAndCancels() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("sensor-replay-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let unreadyID = UUID()
        let readyID = UUID()
        let invalidID = UUID()
        let fixture = Data(#"{"version":1,"events":[{"offsetMs":0,"motion":{"steps":9}}]}"#.utf8)

        let unreadyFile = folder.appendingPathComponent(SensorReplay.filename(id: unreadyID))
        try fixture.write(to: unreadyFile)

        let readyFile = folder.appendingPathComponent(SensorReplay.filename(id: readyID))
        try fixture.write(to: readyFile)
        try Data().write(to: readyFile.appendingPathExtension("ready"))

        let (claimed, replay) = try await SensorReplay.receiveNext(in: folder)
        XCTAssertEqual(claimed, readyID)
        XCTAssertEqual(replay.events.count, 1)
        // Consumed upload and both markers are deleted; unready file stays untouched.
        for suffix in ["", ".ready", ".claim"] {
            XCTAssertFalse(FileManager.default.fileExists(atPath: readyFile.path + suffix))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: unreadyFile.path))
        XCTAssertEqual(try SensorReplay.load(id: unreadyID, in: folder).events.count, 1)
        try SensorReplay.remove(id: unreadyID, in: folder)
        XCTAssertFalse(FileManager.default.fileExists(atPath: unreadyFile.path))

        // Corrupt ready upload is rejected and still cleaned from Documents.
        let invalidFile = folder.appendingPathComponent(SensorReplay.filename(id: invalidID))
        try Data("not-json".utf8).write(to: invalidFile)
        try Data().write(to: invalidFile.appendingPathExtension("ready"))
        do {
            _ = try await SensorReplay.receiveNext(in: folder)
            XCTFail("Expected invalid fixture failure")
        } catch {}
        for suffix in ["", ".ready", ".claim"] {
            XCTAssertFalse(FileManager.default.fileExists(atPath: invalidFile.path + suffix))
        }

        // Waiting listener exits promptly on Task cancellation.
        let waiter = Task { try await SensorReplay.receiveNext(in: folder) }
        try await Task.sleep(for: .milliseconds(60))
        waiter.cancel()
        do {
            _ = try await waiter.value
            XCTFail("Expected CancellationError")
        } catch is CancellationError {}
    }
}
