// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ContainerControl",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "ControlCore", targets: ["ControlCore"]),
        .executable(name: "cctl", targets: ["cctl"]),
    ],
    targets: [
        .target(name: "ControlCore"),
        .executableTarget(name: "cctl", dependencies: ["ControlCore"]),
        .executableTarget(name: "ContainerControl", dependencies: ["ControlCore"]),
        .testTarget(name: "ControlCoreTests", dependencies: ["ControlCore"]),
    ]
)
