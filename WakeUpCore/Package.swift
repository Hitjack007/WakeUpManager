// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "WakeUpCore",
    platforms: [.macOS("27.0")],
    products: [
        .library(name: "WakeUpCore", targets: ["WakeUpCore"]),
        .library(name: "WakeUpSystem", targets: ["WakeUpSystem"]),
        .library(name: "WakeUpCLI", targets: ["WakeUpCLI"]),
        // The command line tool that scripts and apps use to ask for wakes.
        .executable(name: "wakeup", targets: ["wakeup"]),
        // The scheduler agent: runs the engine and listens on the socket.
        .executable(name: "wakeup-agent", targets: ["wakeup-agent"]),
        // The root helper: books and cancels wakes over XPC for the agent.
        .executable(name: "wakeup-helper", targets: ["wakeup-helper"]),
    ],
    targets: [
        .target(name: "WakeUpCore"),
        .testTarget(name: "WakeUpCoreTests", dependencies: ["WakeUpCore"]),
        // The real connections to macOS: launching jobs, the battery, power assertions, booking wakes.
        .target(name: "WakeUpSystem", dependencies: ["WakeUpCore"]),
        .testTarget(name: "WakeUpSystemTests", dependencies: ["WakeUpSystem", "WakeUpCore"]),
        .target(name: "WakeUpCLI", dependencies: ["WakeUpCore"]),
        .testTarget(name: "WakeUpCLITests", dependencies: ["WakeUpCLI", "WakeUpCore"]),
        .executableTarget(name: "wakeup", dependencies: ["WakeUpCLI", "WakeUpCore"]),
        .executableTarget(name: "wakeup-agent", dependencies: ["WakeUpSystem", "WakeUpCore"]),
        .executableTarget(name: "wakeup-helper", dependencies: ["WakeUpSystem", "WakeUpCore"]),
    ]
)
