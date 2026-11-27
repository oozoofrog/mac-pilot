// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "MacPilotSensorReplay",
    platforms: [.iOS(.v16), .watchOS(.v9), .macOS(.v13)],
    products: [.library(name: "MacPilotSensorReplay", type: .dynamic, targets: ["MacPilotSensorReplay"])],
    targets: [.target(name: "MacPilotSensorReplay"), .testTarget(name: "ReplayTests", dependencies: ["MacPilotSensorReplay"])]
)
