// Compile-only unrelated types. No stub replaces the production folder function,
// hierarchy, target identity, reader, binder, or request serialization.
struct ToolError: Error {
    let message: String
    init(_ message: String) { self.message = message }
}
struct SimulatorAXScope {
    let deviceID: String
    let deviceLifetime: String
    let presentation: String
    let generation: UInt64
    let runtime: String
}
