// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "unified-control",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "Shared"),
        .executableTarget(name: "uc-host", dependencies: ["Shared"]),
        .executableTarget(name: "uc-viewer", dependencies: ["Shared"]),
    ]
)
