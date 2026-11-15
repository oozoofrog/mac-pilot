// Compile-only scope for capture/edit console checks. These checks do not invoke
// recording preparation or qualify AX scope reads; the whole-host build uses the
// production SimulatorAXScope from SimulatorAXInspection.swift.
struct SimulatorAXScope {
    let deviceID: String
    let deviceLifetime: String
    let presentation: String
    let generation: UInt64
    let runtime: String
}
