# Sensor replay in a test app

Add the [MacPilotSensorReplay dynamic library](../sensor-replay/Package.swift) to the app's test host or a dedicated Debug app target. Select **Embed & Sign** for the package product in the app target. Confirm the built app contains `Frameworks/MacPilotSensorReplay.framework`. A simulator can resolve the framework from a build directory even when the installed app is missing it. On a device, dyld loads the embedded framework when the app starts. Supported targets are iOS 16+ and watchOS 9+, on devices and simulators (runtime playback verified on a physical iPad and an iPhone simulator; watchOS is SDK-typechecked on `watchos` and `watchsimulator` and not yet verified on a physical Apple Watch). Connect the sample handler to the same input consumers that normally receive sensor data. Keep the replay library out of the shipping target.

Start a task in the test app when the tester selects replay. Retain the task so that ending the test also cancels it. Stop the app's live input sources during replay. Keep workout consumers in test mode when a real workout would start a HealthKit session or write a sample.

```swift
import MacPilotSensorReplay

let playback = Task { @MainActor in
    let (id, replay) = try await SensorReplay.receiveNext()
    try await replay.play { event in
        switch event.input {
        case .microphone(let sample): try audioConsumer(sample.buffer())
        case .camera(let frame): try imageConsumer(frame.image())
        case .motion(let sample): motionConsumer(sample)
        case .location(let fix): locationConsumer(fix.location(at: Date()))
        case .workout(let sample): workoutConsumer(sample)
        }
    }
    reportCompletion(id)
}
```

Replace the five consumer functions and the completion reporter with the app's own handlers. The app controls AVFoundation capture, camera previews, system permission prompts and HealthKit access separately. This library supplies synthetic data inside that app. System services and other apps continue to read their normal sources.

## Deliver a fixture

1. Install the instrumented app. Use the explicit UDID of a booted simulator that is free or claimed by your session (`sensor_replay` refuses simulators claimed by another agent session, and records automatic use on free simulators). For a paired physical iPhone, iPad or Apple Watch, use its CoreDevice UUID from `device list` and call `device allow` in the same connection while the device is unlocked.
2. Call `sensor_replay` with `platform` (`simulator` or `device`), `device`, the app's bundle ID in `app`, and the absolute local JSON path in `fixture`. The [sample fixture](../sensor-replay/Fixtures/running.json) exercises all five inputs.
3. The tool validates the entire timeline, writes a new UUID-named file in the app's Documents directory and compares the stored bytes with the original. It then publishes a ready marker. The `staged` result contains the UUID. Check the app's observed values or completion UUID to confirm playback.

`receiveNext()` claims one ready fixture, reads it into memory, and deletes the UUID-named JSON file and its `.ready`/`.claim` markers (`SensorReplay.remove(id:)`), whether decoding succeeds or fails, so uploads do not accumulate in the app's backed-up Documents folder on physical devices (where `devicectl` cannot delete files). Cancel the waiting task to stop waiting. A cancelled or failed playback can have delivered a prefix; retain the decoded `SensorReplay` value in memory if the app needs to inspect or replay it. Apps that stage and read a known UUID without `receiveNext()` can call `SensorReplay.load(id:)` and `SensorReplay.remove(id:)` directly. Call `receiveNext()` again for a second fixture. Stage one timeline at a time when order between timelines matters.

For a cadence test, the [2.8 steps/s fixture](../sensor-replay/Fixtures/cadence-2.8.json) delivers cumulative step counts. Between 10 and 70 seconds it adds 168 steps, or 168 steps/min. In a Runner's Heart test target, forward each `motion.steps` value to the active `RunSimulatedStepSource` with `source.send(Double(event.offsetMs) / 1000, steps)`. Its cadence calibration uses elapsed seconds and cumulative steps.

## Version 1 fields

Set `version` to 1. Supply an `events` array with one sensor payload per event. `offsetMs` is elapsed milliseconds since playback began. List events in nondecreasing order. Events with the same offset retain their array order. The player uses an absolute monotonic deadline for each event.

| Payload | Fields and units |
|---|---|
| `microphone` | `sampleRate` in Hz, 8000–192000. `pcmS16LE` is base64 mono signed 16-bit PCM in little-endian order. Supply one chunk for each delivery. |
| `camera` | `imageData` is one base64 PNG or JPEG image, up to 8192 pixels per side and 16,777,216 pixels total. Use successive frames to exercise a camera consumer. |
| `motion` | `accelerationG` and `rotationRate` each take an object with `x`, `y`, `z`. Units are g and radians per second. `steps` is a cumulative nonnegative count. |
| `location` | `latitude`, `longitude` in degrees. Optional `altitudeMeters`, `horizontalAccuracyMeters` (nonnegative), `verticalAccuracyMeters` (nonnegative; defaults to `0` when `altitudeMeters` is present and `-1` otherwise), `speedMPS` (nonnegative), `courseDegrees` (`0` to under `360`). |
| `workout` | Any of `heartRateBPM`, `distanceMeters`, `activeEnergyKcal`, `cadenceSPM` or `phase` (`running`, `paused`, `ended`). Distance and energy are totals for the replayed workout. |

A fixture can contain 1–100,000 events across 24 hours and up to 16 MiB of JSON including media. This format is intended for short media fixtures and sparse workout timelines. Playback observes the app's normal scheduling and suspension.
