import Foundation
import CoreLocation
import AVFAudio
import ImageIO

public struct SensorReplay: Sendable {
    public struct InvalidFixture: Error, LocalizedError {
        public let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }

    public struct Vector: Decodable, Sendable {
        public let x, y, z: Double
    }
    public struct Motion: Decodable, Sendable {
        public let accelerationG, rotationRate: Vector?
        public let steps: Int?
    }
    public struct Workout: Decodable, Sendable {
        public let heartRateBPM, distanceMeters, activeEnergyKcal, cadenceSPM: Double?
        public let phase: String?
    }
    public struct Location: Decodable, Sendable {
        public let latitude, longitude: Double
        public let altitudeMeters, horizontalAccuracyMeters, verticalAccuracyMeters, speedMPS, courseDegrees: Double?
        public func location(at date: Date) -> CLLocation {
            // CoreLocation treats a negative vertical accuracy as "no altitude": a given altitude defaults to exact.
            CLLocation(coordinate: .init(latitude: latitude, longitude: longitude), altitude: altitudeMeters ?? 0,
                       horizontalAccuracy: horizontalAccuracyMeters ?? 0,
                       verticalAccuracy: verticalAccuracyMeters ?? (altitudeMeters == nil ? -1 : 0),
                       course: courseDegrees ?? -1, speed: speedMPS ?? -1, timestamp: date)
        }
    }
    public struct Microphone: Decodable, Sendable {
        public let sampleRate: Int
        public let pcmS16LE: Data

        public func buffer() throws -> AVAudioPCMBuffer {
            let frames = AVAudioFrameCount(pcmS16LE.count / 2)
            guard let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: Double(sampleRate),
                                             channels: 1, interleaved: false),
                  let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames),
                  let channel = buffer.int16ChannelData else { throw InvalidFixture("Cannot allocate microphone buffer.") }
            buffer.frameLength = frames
            _ = pcmS16LE.copyBytes(to: UnsafeMutableRawBufferPointer(start: channel[0], count: pcmS16LE.count))
            return buffer
        }
    }
    public struct Camera: Decodable, Sendable {
        public let imageData: Data

        public func image() throws -> CGImage {
            guard let source = CGImageSourceCreateWithData(imageData as CFData, nil),
                  let kind = CGImageSourceGetType(source) as String?, ["public.jpeg", "public.png"].contains(kind),
                  let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                  let width = properties[kCGImagePropertyPixelWidth] as? Int,
                  let height = properties[kCGImagePropertyPixelHeight] as? Int,
                  (1...8192).contains(width), (1...8192).contains(height), width * height <= 16_777_216,
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
                throw InvalidFixture("Expected a decodable PNG or JPEG frame up to 16 megapixels.")
            }
            return image
        }
    }
    public enum Input: Sendable {
        case motion(Motion), workout(Workout), location(Location), microphone(Microphone), camera(Camera)
    }
    public struct Event: Decodable, Sendable {
        public let offsetMs: Int
        public let input: Input
        private enum Key: String, CodingKey, CaseIterable { case offsetMs, motion, workout, location, microphone, camera }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: Key.self)
            offsetMs = try c.decode(Int.self, forKey: .offsetMs)
            let channels = c.allKeys.filter { $0 != .offsetMs }
            guard channels.count == 1, let key = channels.first else { throw InvalidFixture("Expected one sensor per event.") }
            switch key {
            case .motion:
                let value = try c.decode(Motion.self, forKey: key)
                guard value.steps != nil || value.accelerationG != nil || value.rotationRate != nil,
                      value.steps.map({ $0 >= 0 }) ?? true else { throw InvalidFixture("Invalid motion sample.") }
                input = .motion(value)
            case .workout:
                let value = try c.decode(Workout.self, forKey: key)
                let metrics = [value.heartRateBPM, value.distanceMeters, value.activeEnergyKcal, value.cadenceSPM].compactMap { $0 }
                guard !metrics.isEmpty || value.phase != nil, metrics.allSatisfy({ $0 >= 0 }),
                      value.phase.map(["running", "paused", "ended"].contains) ?? true else { throw InvalidFixture("Invalid workout sample.") }
                input = .workout(value)
            case .location:
                let value = try c.decode(Location.self, forKey: key)
                guard (-90...90).contains(value.latitude), (-180...180).contains(value.longitude) else {
                    throw InvalidFixture("Invalid location coordinates.")
                }
                let nonNegative = [value.horizontalAccuracyMeters, value.verticalAccuracyMeters, value.speedMPS].compactMap { $0 }
                guard nonNegative.allSatisfy({ $0.isFinite && $0 >= 0 }), value.altitudeMeters?.isFinite ?? true,
                      value.courseDegrees.map({ (0..<360).contains($0) }) ?? true else {
                    throw InvalidFixture("Location accuracy and speed must be zero or more; course must be 0 to under 360.")
                }
                input = .location(value)
            case .microphone:
                let value = try c.decode(Microphone.self, forKey: key)
                guard (8000...192000).contains(value.sampleRate), !value.pcmS16LE.isEmpty,
                      value.pcmS16LE.count.isMultiple(of: 2) else { throw InvalidFixture("Invalid mono PCM16LE sample.") }
                input = .microphone(value)
            case .camera:
                let value = try c.decode(Camera.self, forKey: key)
                _ = try value.image()
                input = .camera(value)
            case .offsetMs: throw InvalidFixture("Missing sensor payload.")
            }
        }
    }

    public static let byteLimit = 16 * 1024 * 1024
    public let events: [Event]
    private struct Document: Decodable {
        let version: Int
        let events: [Event]
    }

    public init(data: Data) throws {
        guard data.count <= Self.byteLimit else { throw InvalidFixture("Fixture exceeds 16 MiB.") }
        let document = try JSONDecoder().decode(Document.self, from: data)
        guard document.version == 1, (1...100_000).contains(document.events.count) else {
            throw InvalidFixture("Expected version 1 and 1 to 100000 events.")
        }
        var previous = 0
        for event in document.events {
            guard (previous...86_400_000).contains(event.offsetMs) else { throw InvalidFixture("Offsets must increase or stay equal within one day.") }
            previous = event.offsetMs
        }
        events = document.events
    }

    public static func filename(id: UUID) -> String { "MacPilotReplay-" + id.uuidString + ".json" }

    private static func url(id: UUID, suffix: String = "", in directory: URL? = nil) throws -> URL {
        let base = try directory ?? FileManager.default.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: false)
        return base.appendingPathComponent(filename(id: id) + suffix)
    }

    public static func load(id: UUID) throws -> Self { try load(id: id, in: nil) }

    static func load(id: UUID, in directory: URL?) throws -> Self {
        let url = try url(id: id, in: directory)
        guard let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= byteLimit else {
            throw InvalidFixture("Fixture exceeds 16 MiB.")
        }
        return try Self(data: Data(contentsOf: url))
    }

    /// Deletes a staged fixture and its markers. devicectl cannot delete files on a device, so the app must.
    public static func remove(id: UUID) throws { try remove(id: id, in: nil) }

    static func remove(id: UUID, in directory: URL?) throws {
        for suffix in ["", ".ready", ".claim"] {
            do { try FileManager.default.removeItem(at: url(id: id, suffix: suffix, in: directory)) }
            catch let error as CocoaError where error.code == .fileNoSuchFile || error.code == .fileReadNoSuchFile {}
        }
    }

    /// Waits for one complete upload. Multiple listeners compete for each ready file. The claimed fixture is read into
    /// memory and deleted, valid or not, so uploads do not pile up in the app's backed-up Documents folder.
    public static func receiveNext() async throws -> (id: UUID, replay: SensorReplay) {
        try await receiveNext(in: nil)
    }

    static func receiveNext(in customDirectory: URL?) async throws -> (id: UUID, replay: SensorReplay) {
        let files = FileManager.default
        let directory: URL
        if let customDirectory {
            try files.createDirectory(at: customDirectory, withIntermediateDirectories: true)
            directory = customDirectory
        } else {
            directory = try files.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        }
        while true {
            try Task.checkCancellation()
            let entries = try files.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            for marker in entries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                let name = marker.deletingPathExtension().lastPathComponent
                guard marker.pathExtension == "ready", name.hasPrefix("MacPilotReplay-"),
                      let id = UUID(uuidString: String(name.dropFirst("MacPilotReplay-".count).dropLast(5))),
                      marker.lastPathComponent == filename(id: id) + ".ready" else { continue }
                let claim = directory.appendingPathComponent(filename(id: id) + ".claim")
                do { try files.moveItem(at: marker, to: claim) }
                catch let error as CocoaError where error.code == .fileNoSuchFile || error.code == .fileReadNoSuchFile { continue }
                defer { try? remove(id: id, in: directory) }
                let replay = try load(id: id, in: directory)
                return (id, replay)
            }
            try await Task.sleep(for: .milliseconds(250))
        }
    }

    @MainActor public func play(_ consume: (Event) throws -> Void) async throws {
        let clock = ContinuousClock()
        let start = clock.now
        for event in events {
            try await clock.sleep(until: start.advanced(by: .milliseconds(event.offsetMs)))
            try Task.checkCancellation()
            try consume(event)
        }
    }
}
