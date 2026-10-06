// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "FanCore",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "FanCore", targets: ["FanCore"]),
        .executable(name: "fanpilotctl", targets: ["fanpilotctl"])
    ],
    targets: [
        .target(name: "FanCore"),
        .executableTarget(name: "fanpilotctl", dependencies: ["FanCore"]),
        .testTarget(name: "FanCoreTests", dependencies: ["FanCore"])
    ]
)
