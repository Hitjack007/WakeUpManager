// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "WakeUpCore",
    platforms: [.macOS("27.0")],
    products: [
        .library(name: "WakeUpCore", targets: ["WakeUpCore"]),
        .library(name: "WakeUpSystem", targets: ["WakeUpSystem"]),
    ],
    targets: [
        .target(name: "WakeUpCore"),
        .testTarget(name: "WakeUpCoreTests", dependencies: ["WakeUpCore"]),
        // The real connections to macOS: launching jobs, the battery, power assertions, booking wakes.
        .target(name: "WakeUpSystem", dependencies: ["WakeUpCore"]),
        .testTarget(name: "WakeUpSystemTests", dependencies: ["WakeUpSystem", "WakeUpCore"]),
    ]
)
