// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "wgbar",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "WGCore", targets: ["WGCore"]),
        .executable(name: "wgbar-helper", targets: ["wgbar-helper"]),
        .executable(name: "wgbarctl", targets: ["wgbarctl"]),
    ],
    targets: [
        .target(name: "WGCore"),
        .executableTarget(name: "wgbar-helper", dependencies: ["WGCore"]),
        .executableTarget(name: "wgbarctl", dependencies: ["WGCore"]),
        .testTarget(name: "WGCoreTests", dependencies: ["WGCore"]),
    ]
)
