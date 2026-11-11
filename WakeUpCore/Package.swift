// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "WakeUpCore",
    platforms: [.macOS("27.0")],
    products: [
        .library(name: "WakeUpCore", targets: ["WakeUpCore"]),
    ],
    targets: [
        .target(name: "WakeUpCore"),
        .testTarget(name: "WakeUpCoreTests", dependencies: ["WakeUpCore"]),
    ]
)
